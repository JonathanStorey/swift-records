import CloudKit
import Foundation
import SwiftRecords

/// Checks the Mac's iCloud account and the app's container before anything syncs, so a run that can't
/// reach CloudKit says why instead of failing every scenario.
enum AccountChecks {
    struct Check {
        let name: String
        let passed: Bool
        let detail: String
    }

    @MainActor
    static func run(_ backend: CloudKitBackend) async -> [Check] {
        var checks: [Check] = []
        let container = backend.container
        let identifier = container.containerIdentifier ?? "none"
        checks.append(Check(
            name: "The app has an iCloud container", passed: container.containerIdentifier != nil, detail: identifier
        ))

        let status: CKAccountStatus
        do {
            status = try await container.accountStatus()
        } catch {
            checks.append(Check(name: "The account status can be read", passed: false, detail: "\(error)"))
            return checks
        }
        checks.append(Check(name: "An iCloud account is signed in", passed: status == .available, detail: describe(status)))
        guard status == .available else { return checks }

        do {
            let user = try await container.userRecordID()
            checks.append(Check(name: "The user record can be fetched", passed: true, detail: user.recordName))
        } catch {
            checks.append(Check(name: "The user record can be fetched", passed: false, detail: "\(error)"))
        }

        // A device that syncs ends a refresh saved, not signed out or failed.
        do {
            let zone = try backend.freshZone()
            let device = try backend.makeDevice([], zone: zone)
            try await device.mainContext.refresh()
            let shown = device.mainContext.status
            checks.append(Check(name: "A device refreshes and shows saved", passed: shown == .saved, detail: "\(shown)"))
            await backend.cleanUp(zone)
        } catch {
            checks.append(Check(name: "A device refreshes and shows saved", passed: false, detail: "\(error)"))
        }
        return checks
    }

    private static func describe(_ status: CKAccountStatus) -> String {
        switch status {
        case .available: "available"
        case .noAccount: "no account: sign in to iCloud in System Settings"
        case .restricted: "restricted by parental controls or a profile"
        case .couldNotDetermine: "could not be determined"
        case .temporarilyUnavailable: "temporarily unavailable: finish signing in to iCloud"
        @unknown default: "unknown (\(status.rawValue))"
        }
    }
}
