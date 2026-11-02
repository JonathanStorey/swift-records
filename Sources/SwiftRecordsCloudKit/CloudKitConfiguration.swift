#if canImport(CloudKit)
import CloudKit
import Foundation
import os
@_spi(SyncProvider) import SwiftRecords
#if os(macOS)
import Security
#endif

/// Checks that the app is set up for CloudKit, and says how to fix it in Xcode when it isn't.
///
/// What it can see without asking the server: the iCloud entitlements, read from the code signature on
/// macOS and from the provisioning profile on an iOS device, and the Background Modes in Info.plist. What
/// only the server can tell, a container it doesn't know, comes from the first CloudKit call.
enum CloudKitConfiguration {
    static let logger = Logger(subsystem: "SwiftRecords", category: "CloudKit")

    private static let servicesKey = "com.apple.developer.icloud-services"
    private static let containersKey = "com.apple.developer.icloud-container-identifiers"

    /// The problem the app's entitlements show for `container`, or `nil` when they look right or can't be
    /// read, such as in the simulator or a test runner.
    static func entitlementProblem(container: String?) -> RecordsError? {
        guard Bundle.main.bundleURL.pathExtension == "app", let entitlements = readEntitlements() else { return nil }
        return problem(in: entitlements, container: container)
    }

    /// The problem `entitlements` show for `container`, apart from where they were read.
    static func problem(in entitlements: [String: Any], container: String?) -> RecordsError? {
        let services = entitlements[servicesKey] as? [String] ?? []
        guard services.contains("CloudKit") || services.contains("*") else { return missingCapability(container) }
        let containers = entitlements[containersKey] as? [String] ?? []
        guard let container else { return containers.isEmpty ? missingCapability(nil) : nil }
        let listed = containers.contains { allowed in
            allowed == container || allowed == "*" || (allowed.hasSuffix("*") && container.hasPrefix(allowed.dropLast()))
        }
        return listed ? nil : missingContainer(container)
    }

    /// The configuration problem behind a CloudKit error, or `nil` for any other error.
    static func problem(for error: any Error, container: String?) -> RecordsError? {
        guard let error = error as? CKError else { return nil }
        switch error.code {
        case .missingEntitlement: return missingCapability(container)
        case .badContainer: return unknownContainer(container)
        default: return nil
        }
    }

    /// Warns once when pushes can't start fetches, since sync still works without them.
    static func checkPushes() {
        #if os(iOS) || os(tvOS) || os(visionOS) || os(watchOS)
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        guard !modes.contains("remote-notification") else { return }
        logger.error("""
            SwiftRecords: changes from other devices won't arrive while the app is in the background, because \
            it lacks the Remote notifications background mode. In Xcode, select the app target, open Signing & \
            Capabilities, click + Capability, add Background Modes and tick Remote notifications. Until then, \
            changes arrive when the app returns to the foreground or refreshes.
            """)
        #endif
    }

    /// Logs a configuration problem where Xcode's console shows it, with the steps to fix it.
    static func report(_ error: RecordsError) {
        guard case .syncNotConfigured(let problem, let fix) = error else { return }
        logger.fault("SwiftRecords can't sync with CloudKit. \(problem, privacy: .public) \(fix, privacy: .public)")
    }

    // MARK: Problems

    private static func missingCapability(_ container: String?) -> RecordsError {
        .syncNotConfigured(
            problem: "The app doesn't have the iCloud capability with CloudKit.",
            fix: """
                In Xcode, select the app target, open Signing & Capabilities, click + Capability and add iCloud. \
                Under Services tick CloudKit, then under Containers tick \(container.map { "\"\($0)\"" } ?? "the app's container"), \
                or click + to create it. Then add Background Modes and tick Remote notifications, so pushes start fetches.
                """
        )
    }

    private static func missingContainer(_ container: String) -> RecordsError {
        .syncNotConfigured(
            problem: "The app's iCloud entitlement doesn't list the container \"\(container)\".",
            fix: """
                In Xcode, select the app target, open Signing & Capabilities and, under iCloud > Containers, tick \
                "\(container)" or click + to add it. The name must match CKContainer(identifier:) exactly, \
                including the "iCloud." prefix.
                """
        )
    }

    private static func unknownContainer(_ container: String?) -> RecordsError {
        let name = container.map { "\"\($0)\"" } ?? "the app's container"
        return .syncNotConfigured(
            problem: "CloudKit doesn't recognize \(name).",
            fix: """
                In Xcode, select the app target, open Signing & Capabilities and check that \(name) is ticked under \
                iCloud > Containers, spelled as in CKContainer(identifier:). If it's ticked, click the refresh \
                button below the list, and check in the CloudKit Console that the container belongs to the app's team.
                """
        )
    }

    // MARK: Reading entitlements

    private static func readEntitlements() -> [String: Any]? {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        var entitlements: [String: Any] = [:]
        for key in [servicesKey, containersKey] {
            if let value = SecTaskCopyValueForEntitlement(task, key as CFString, nil) {
                entitlements[key] = value
            }
        }
        return entitlements
        #else
        // A device build carries its provisioning profile, and the app's entitlements can't exceed it. The
        // simulator and App Store builds have none, and go unchecked.
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let profile = try? PropertyListSerialization.propertyList(
                  from: data[start.lowerBound..<end.upperBound], format: nil
              ) as? [String: Any] else { return nil }
        return profile["Entitlements"] as? [String: Any]
        #endif
    }
}
#endif
