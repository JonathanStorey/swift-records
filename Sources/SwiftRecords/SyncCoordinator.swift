import Foundation

/// Drives a container's sync provider: opens it with its saved state, sends pending changes in batches,
/// applies what it reports, and works out the sync part of each context's status.
actor SyncCoordinator {
    /// Where syncing stands, which a context combines with its own saves into `status`.
    enum Phase: Sendable, Hashable {
        case idle
        case syncing
        case offline
        case signedOut
        case failed(RecordsError)
    }

    struct Policies: Sendable {
        var merge: MergePolicy
        var onSignOut: AccountPolicy
        var onAccountSwitch: AccountPolicy
        var onServerReset: AccountPolicy
    }

    private struct Key: Hashable {
        let table: String
        let id: UUID
    }

    static let batchSize = 200
    private static let stateKey = "provider.state"
    private static let accountKey = "provider.account"

    private let provider: any SyncProvider
    private let store: RecordStore
    private let policies: Policies
    private let phaseChanged: @Sendable (Phase) -> Void

    private(set) var phase: Phase = .idle {
        didSet {
            if phase != oldValue { phaseChanged(phase) }
        }
    }

    /// Changes handed to the provider and not yet acknowledged, with the fields each carried.
    private var inFlight: [Key: (change: PendingChange, fields: SyncFields?)] = [:]
    private var opening: Task<Void, Never>?
    private var fetching = 0
    private var signedOut = false

    init(provider: any SyncProvider, store: RecordStore, policies: Policies, phaseChanged: @escaping @Sendable (Phase) -> Void) {
        self.provider = provider
        self.store = store
        self.policies = policies
        self.phaseChanged = phaseChanged
    }

    // MARK: Calls from contexts

    /// Opens the provider the first time it's needed. Later calls wait for that to finish.
    func open() async {
        if opening == nil {
            opening = Task { await openProvider() }
        }
        await opening?.value
    }

    /// Sends what is pending, unless a batch is already waiting for the server.
    func send() async {
        await open()
        await sendNext()
    }

    /// Sends what is pending, then fetches the server's changes. Throws the error that ends in `failed`.
    func refresh() async throws {
        await open()
        await sendNext()
        if !signedOut {
            fetching += 1
            if phase == .idle {
                phase = .syncing
            }
            await provider.fetch()
            fetching -= 1
            settle()
        }
        if case .failed(let error) = phase {
            throw error
        }
    }

    // MARK: Driving the provider

    private func openProvider() async {
        let state = try? store.syncValue(forKey: Self.stateKey)
        // Records an earlier version of the app couldn't store may fit now.
        if let parked = (try? store.retryParked(policy: policies.merge))?.first {
            phase = .failed(.incompatibleRecord(type: parked.type, id: parked.id))
        }
        await provider.open(state: state) { [weak self] event in
            await self?.handle(event)
        }
        await sendNext()
    }

    private func sendNext() async {
        guard !signedOut, inFlight.isEmpty else { return }
        var batch: [SyncRecord] = []
        for change in (try? store.pendingChanges()) ?? [] {
            guard batch.count < Self.batchSize else { break }
            guard let (record, fields) = try? store.syncRecord(for: change) else { continue }
            inFlight[Key(table: change.table, id: change.id)] = (change, fields)
            batch.append(record)
        }
        guard !batch.isEmpty else {
            settle()
            return
        }
        phase = .syncing
        await provider.send(batch)
    }

    /// Ends `syncing` once nothing is in flight.
    private func settle() {
        if phase == .syncing, inFlight.isEmpty, fetching == 0 {
            phase = .idle
        }
    }

    // MARK: Events

    func handle(_ event: SyncEvent) async {
        switch event {
        case .received(let records, let state):
            do {
                let incompatible = try store.transaction {
                    let incompatible = try store.applyReceived(records, policy: policies.merge)
                    if let state {
                        try store.setSyncValue(state, forKey: Self.stateKey)
                    }
                    return incompatible
                }
                if let record = incompatible.first {
                    phase = .failed(.incompatibleRecord(type: record.type, id: record.id))
                } else if phase == .offline {
                    // Hearing from the server means it can be reached again.
                    phase = .syncing
                }
            } catch {
                phase = .failed(Self.recordsError(error))
            }
            // A server copy of a record in flight answers its send: it was merged and goes again.
            var answered = false
            for record in records where inFlight.removeValue(forKey: Key(table: record.type, id: record.id)) != nil {
                answered = true
            }
            if answered, inFlight.isEmpty {
                await sendNext()
            }
            settle()

        case .sent(let records, let state):
            let acknowledged = records.compactMap { record in
                inFlight.removeValue(forKey: Key(table: record.type, id: record.id)).map { (entry: $0, tag: record.tag) }
            }
            do {
                try store.transaction {
                    for (entry, tag) in acknowledged {
                        try store.acknowledge(entry.change, sent: entry.fields, tag: tag)
                    }
                    if let state {
                        try store.setSyncValue(state, forKey: Self.stateKey)
                    }
                }
                // Getting through clears being offline or full. A record that won't decode stays reported.
                if case .failed(.incompatibleRecord) = phase {} else {
                    phase = .syncing
                }
            } catch {
                phase = .failed(Self.recordsError(error))
            }
            if inFlight.isEmpty {
                await sendNext()
            }

        case .notSent(let records, let reason):
            for record in records {
                inFlight[Key(table: record.type, id: record.id)] = nil
            }
            switch reason {
            case .unreachable:
                phase = .offline
            case .storageFull:
                phase = .failed(.storageFull)
            case .rejected:
                if let record = records.first {
                    phase = .failed(.rejected(type: record.type, id: record.id))
                }
            }

        case .accountChanged(let account):
            await accountChanged(to: account)

        case .serverReset:
            inFlight = [:]
            apply(policies.onServerReset)
            await sendNext()

        case .stateChanged(let state):
            try? store.setSyncValue(state, forKey: Self.stateKey)
        }
    }

    private func accountChanged(to account: String?) async {
        let stored = (try? store.syncValue(forKey: Self.accountKey)).flatMap { $0.flatMap { String(data: $0, encoding: .utf8) } }
        guard let account else {
            signedOut = true
            inFlight = [:]
            if stored != nil {
                apply(policies.onSignOut)
                try? store.setSyncValue(nil, forKey: Self.accountKey)
            }
            phase = .signedOut
            return
        }
        signedOut = false
        if phase == .signedOut {
            phase = .idle
        }
        guard account != stored else { return }
        inFlight = [:]
        // A first sign-in uploads everything here. Another account's data follows the switch policy.
        apply(stored == nil ? .keepLocalData : policies.onAccountSwitch)
        try? store.setSyncValue(Data(account.utf8), forKey: Self.accountKey)
        await sendNext()
    }

    private func apply(_ policy: AccountPolicy) {
        do {
            switch policy {
            case .keepLocalData:
                try store.markAllPending()
            case .deleteLocalData:
                // Keep the provider's state: it describes the server, which still has everything.
                let state = try store.syncValue(forKey: Self.stateKey)
                try store.deleteAllData()
                try store.setSyncValue(state, forKey: Self.stateKey)
            }
        } catch {
            phase = .failed(Self.recordsError(error))
        }
    }

    private static func recordsError(_ error: any Error) -> RecordsError {
        (RecordsError.mapping(error) as? RecordsError) ?? .database(code: -1, message: "\(error)")
    }
}
