#if canImport(CloudKit)
import CloudKit
import Foundation
import Testing

/// A spike for the CloudKit-only plan: what a fake CloudKit server can do with real `CKRecord`s in a test
/// process, with no account and no network. Each test prints `SPIKE:` lines for the CI log.
@Suite struct CloudKitFakeSpikeTests {
    private let zone = CKRecordZone.ID(zoneName: "spike", ownerName: CKCurrentUserDefaultName)

    private func archive(_ record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    private func restore(_ data: Data) throws -> CKRecord? {
        let coder = try NSKeyedUnarchiver(forReadingFrom: data)
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }

    /// The keys `encodeSystemFields` writes, from the archive's root object.
    @Test func systemFieldKeys() throws {
        let record = CKRecord(recordType: "Recipe", recordID: CKRecord.ID(recordName: "a", zoneID: zone))
        let data = archive(record)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        let objects = plist?["$objects"] as? [Any] ?? []
        let keys = objects.compactMap { $0 as? [String: Any] }.flatMap(\.keys).sorted()
        print("SPIKE: system field keys: \(keys)")
        print("SPIKE: fresh record archive is \(data.count) bytes, changeTag \(record.recordChangeTag ?? "nil")")
        let again = archive(CKRecord(recordType: "Recipe", recordID: CKRecord.ID(recordName: "a", zoneID: zone)))
        print("SPIKE: two fresh copies archive identically: \(data == again)")
        #expect(!keys.isEmpty)
    }

    /// Whether a fake server can stamp a version on a record through CKRecord's own setter.
    @Test func changeTagThroughSetter() throws {
        let record = CKRecord(recordType: "Recipe", recordID: CKRecord.ID(recordName: "b", zoneID: zone))
        let selector = NSSelectorFromString("setRecordChangeTag:")
        let responds = record.responds(to: selector)
        print("SPIKE: CKRecord responds to setRecordChangeTag: \(responds)")
        guard responds else { return }
        record.perform(selector, with: "v2")
        print("SPIKE: tag after setter: \(record.recordChangeTag ?? "nil")")
        let restored = try restore(archive(record))
        print("SPIKE: tag after archive round trip: \(restored?.recordChangeTag ?? "nil")")
        #expect(restored?.recordChangeTag == "v2")
    }

    /// Whether a fake server can stamp a version by decoding system fields with one value replaced.
    @Test func changeTagThroughDecoder() throws {
        let record = CKRecord(recordType: "Recipe", recordID: CKRecord.ID(recordName: "c", zoneID: zone))
        let coder = try TagInjectingUnarchiver(forReadingFrom: archive(record))
        coder.requiresSecureCoding = true
        let restored = CKRecord(coder: coder)
        coder.finishDecoding()
        print("SPIKE: keys CKRecord(coder:) asked for: \(coder.asked.sorted())")
        print("SPIKE: tag after injecting decoder: \(restored?.recordChangeTag ?? "nil")")
    }

    /// Conflicts: a fake returns the server's copy inside a real CKError, as CloudKit does.
    @Test func conflictErrorCarriesServerRecord() {
        let server = CKRecord(recordType: "Recipe", recordID: CKRecord.ID(recordName: "d", zoneID: zone))
        server["title"] = "Stew"
        let error = CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: server])
        print("SPIKE: serverRecord from CKError: \(error.serverRecord?["title"] as? String ?? "nil")")
        #expect(error.serverRecord?["title"] as? String == "Stew")
    }

    /// A record rebuilt from system fields reports only the keys set on it, so a fake can apply just those.
    @Test func rebuiltRecordReportsChangedKeys() throws {
        let original = CKRecord(recordType: "Recipe", recordID: CKRecord.ID(recordName: "e", zoneID: zone))
        original["title"] = "Soup"
        let rebuilt = try #require(try restore(archive(original)))
        rebuilt["servings"] = 4 as Int64
        rebuilt.encryptedValues["notes"] = "secret"
        print("SPIKE: changed keys on rebuilt record: \(rebuilt.changedKeys().sorted())")
        print("SPIKE: rebuilt record keeps title: \(rebuilt["title"] as? String ?? "nil")")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("spike-\(UUID().uuidString)")
        try Data([1, 2, 3]).write(to: file)
        rebuilt["photo"] = CKAsset(fileURL: file)
        print("SPIKE: asset file after set: \((rebuilt["photo"] as? CKAsset)?.fileURL?.lastPathComponent ?? "nil")")
        #expect(rebuilt.changedKeys().contains("servings"))
    }
}

/// Answers the change-tag key with a chosen value, and remembers which keys were asked for.
private final class TagInjectingUnarchiver: NSKeyedUnarchiver {
    var asked: Set<String> = []

    private func injected(_ key: String) -> Any? {
        asked.insert(key)
        return key.lowercased().contains("tag") || key.lowercased().contains("etag") ? "v3" as NSString : nil
    }

    override func decodeObject(forKey key: String) -> Any? {
        injected(key) ?? super.decodeObject(forKey: key)
    }

    override func decodeObject(of classes: [AnyClass]?, forKey key: String) -> Any? {
        injected(key) ?? super.decodeObject(of: classes, forKey: key)
    }
}
#endif
