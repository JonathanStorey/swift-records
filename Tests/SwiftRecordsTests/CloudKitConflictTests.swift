#if canImport(CloudKit)
import CloudKit
import Foundation
@testable import SwiftRecords
import SyncTestSupport
import Testing

/// Sends every record through a real `CKRecord` on its way to and from a `TestServer`, as `CKSyncEngine`
/// would: uploads are built from the container's archived system fields, and downloads, acknowledgements
/// and a conflict's server copy come back as the container reads a `CKRecord`. The server's version tags
/// travel as each record's `recordChangeTag`, so a save only goes through when it builds on the server's
/// own system fields.
final class CloudKitRecordTransport: SyncTransport, @unchecked Sendable {
    let inner: TestTransport
    private let lock = NSLock()
    private weak var _container: RecordContainer?

    init(server: TestServer) {
        inner = TestTransport(server: server)
    }

    /// The container whose mapping builds and reads the `CKRecord`s.
    var container: RecordContainer? {
        get { lock.withLock { _container } }
        set { lock.withLock { _container = newValue } }
    }

    var identifier: String { inner.identifier }
    var scopes: Set<Zone.Scope> { inner.scopes }

    func currentUser() async throws -> String? {
        try await inner.currentUser()
    }

    func modifyRecords(_ batch: RecordBatch) async throws -> SentRecordChanges {
        var saves: [RecordChangeData] = []
        for change in batch.saves {
            // The upload CKSyncEngine would send, built on the system fields the container kept.
            let record = try mapping().ckRecord(for: change, in: Self.zoneID(change.zone))
            var sent = change
            sent.tag = Self.serverTag(of: record)
            saves.append(sent)
        }
        var deletes = batch.deletes
        for index in deletes.indices {
            deletes[index].tag = try deletes[index].tag.flatMap { try Self.serverTag(of: Self.restore($0)) }
        }
        var result = try await inner.modifyRecords(RecordBatch(saves: saves, deletes: deletes))
        result.saved = try result.saved.map(received)
        result.failed = try result.failed.map { failed in
            let original = batch.saves.first { $0.id == failed.change.id } ?? failed.change
            guard case .serverRecordChanged(let copy) = failed.failure else {
                return FailedSave(change: original, failure: failed.failure)
            }
            return FailedSave(change: original, failure: .serverRecordChanged(try received(copy)))
        }
        return result
    }

    func fetchDatabaseChanges(_ scope: Zone.Scope, since token: Data?) async throws -> DatabaseChanges {
        try await inner.fetchDatabaseChanges(scope, since: token)
    }

    func fetchZoneChanges(_ zone: Zone, since token: Data?) async throws -> ZoneChanges {
        var changes = try await inner.fetchZoneChanges(zone, since: token)
        changes.saved = try changes.saved.map(received)
        return changes
    }

    // MARK: CKRecords

    private func mapping() throws -> RecordContainer {
        guard let container else { throw SyncFailure.other("No container to map records") }
        return container
    }

    static func zoneID(_ zone: Zone) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zone.name, ownerName: zone.owner ?? CKCurrentUserDefaultName)
    }

    /// A server copy as the container receives it from CloudKit: a `CKRecord` carrying the server's version
    /// as its change tag, read back by the container.
    private func received(_ change: RecordChangeData) throws -> RecordChangeData {
        let container = try mapping()
        let record = CKRecord(recordType: change.type, recordID: CKRecord.ID(recordName: change.id.uuidString, zoneID: Self.zoneID(change.zone)))
        if let tag = change.tag {
            record.perform(NSSelectorFromString("setRecordChangeTag:"), with: String(decoding: tag, as: UTF8.self))
        }
        var withSystemFields = change
        withSystemFields.tag = Self.archive(record)
        guard change.fields != nil else { return withSystemFields }
        guard let filled = try container.ckRecord(for: withSystemFields, in: Self.zoneID(change.zone)) else {
            throw SyncFailure.other("No CKRecord for \(change.type)")
        }
        var back = try container.change(from: filled, zone: change.zone)
        back.synced = change.synced
        return back
    }

    /// The server's version a `CKRecord` builds on, or `nil` for a record the server never had.
    private static func serverTag(of record: CKRecord?) -> Data? {
        record?.recordChangeTag.map { Data($0.utf8) }
    }

    private static func archive(_ record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    private static func restore(_ data: Data) throws -> CKRecord? {
        let coder = try NSKeyedUnarchiver(forReadingFrom: data)
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }
}

/// One device whose records cross as `CKRecord`s.
@MainActor
struct CloudKitDevice {
    let transport: CloudKitRecordTransport
    let engine: PollingSyncEngine
    let container: RecordContainer
    var context: RecordContext { container.mainContext }

    init(_ server: TestServer) throws {
        transport = CloudKitRecordTransport(server: server)
        engine = PollingSyncEngine(transport: transport, automaticallySync: false, sendDelay: .milliseconds(10))
        container = try RecordContainer(for: [SyncRecipe.self], directory: nil, inMemory: true, syncProvider: engine)
        transport.container = container
    }

    func recipe(_ id: UUID) throws -> SyncRecipe? {
        try context.record(SyncRecipe.self, for: id)
    }
}

/// Two devices edit the same record, and the second save meets the first as CloudKit reports it: a
/// `serverRecordChanged` failure whose server copy is a `CKRecord`. The merge must read that copy and send
/// again on its system fields.
@MainActor
@Suite struct CloudKitConflictTests {
    let server = TestServer()

    @Test func editsToDifferentFieldsBothSurvive() async throws {
        let phone = try CloudKitDevice(server)
        let tablet = try CloudKitDevice(server)
        var recipe = SyncRecipe(title: "Cake", servings: 4, tags: ["sweet"])
        phone.context.insert(recipe)
        try await phone.context.save()
        try await tablet.context.refresh()
        #expect(try tablet.recipe(recipe.id)?.title == "Cake")

        var onTablet = recipe
        onTablet.servings = 8
        tablet.context.insert(onTablet)
        try await tablet.context.save()

        recipe.title = "Lemon cake"
        phone.context.insert(recipe)
        // The save meets the tablet's copy and merges it.
        try await phone.context.save()
        try await phone.context.refresh()
        try await tablet.context.refresh()

        for device in [phone, tablet] {
            let merged = try #require(try device.recipe(recipe.id))
            #expect(merged.title == "Lemon cake")
            #expect(merged.servings == 8)
            #expect(merged.tags == ["sweet"])
        }
        #expect(server.value("SyncRecipe", recipe.id, "title") == .string("Lemon cake"))
        #expect(server.value("SyncRecipe", recipe.id, "servings") == .int(8))
    }

    @Test func aFieldBothChangedKeepsTheServersCopy() async throws {
        let phone = try CloudKitDevice(server)
        let tablet = try CloudKitDevice(server)
        var recipe = SyncRecipe(title: "Cake")
        phone.context.insert(recipe)
        try await phone.context.save()
        try await tablet.context.refresh()

        var onTablet = recipe
        onTablet.title = "Carrot cake"
        tablet.context.insert(onTablet)
        try await tablet.context.save()

        recipe.title = "Lemon cake"
        recipe.servings = 2
        phone.context.insert(recipe)
        try await phone.context.save()
        try await phone.context.refresh()
        try await tablet.context.refresh()

        // Without `@Timestamped(.modified)` the server's copy wins the title, and the phone's other edit stays.
        for device in [phone, tablet] {
            let merged = try #require(try device.recipe(recipe.id))
            #expect(merged.title == "Carrot cake")
            #expect(merged.servings == 2)
        }
    }
}
#endif
