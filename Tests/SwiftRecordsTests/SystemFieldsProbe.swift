#if canImport(CloudKit)
import CloudKit
import Foundation
import Testing

/// Throwaway: prints what a CKRecord's archived system fields hold, and whether they can be authored.
@Suite struct SystemFieldsProbe {
    static func archive(_ record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    static func xml(_ data: Data) -> String {
        let plist = try! PropertyListSerialization.propertyList(from: data, format: nil)
        let xml = try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        return String(decoding: xml, as: UTF8.self)
    }

    static func decode(_ data: Data) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }

    @Test func dump() throws {
        let zone = CKRecordZone.ID(zoneName: "recipes", ownerName: CKCurrentUserDefaultName)
        let record = CKRecord(recordType: "Recipe", recordID: CKRecord.ID(recordName: "R1", zoneID: zone))
        record["title"] = "Soup"
        print("PROBE plain archive:\n" + Self.xml(Self.archive(record)))

        // Private setters CloudKit itself uses when a record comes back from the server.
        for name in ["setEtag:", "setRecordChangeTag:", "setCreationDate:", "setModificationDate:",
                     "setCreatorUserRecordID:", "setLastModifiedUserRecordID:", "setKnownToServer:"] {
            print("PROBE responds \(name): \(record.responds(to: Selector(name)))")
        }
        if record.responds(to: Selector(("setEtag:"))) { record.setValue("tag-abc", forKey: "etag") }
        if record.responds(to: Selector(("setCreationDate:"))) { record.setValue(Date(timeIntervalSince1970: 1_000), forKey: "creationDate") }
        if record.responds(to: Selector(("setModificationDate:"))) { record.setValue(Date(timeIntervalSince1970: 2_000), forKey: "modificationDate") }
        if record.responds(to: Selector(("setCreatorUserRecordID:"))) {
            record.setValue(CKRecord.ID(recordName: "_alice"), forKey: "creatorUserRecordID")
        }
        if record.responds(to: Selector(("setKnownToServer:"))) { record.setValue(true, forKey: "knownToServer") }
        let tagged = Self.archive(record)
        print("PROBE tagged archive:\n" + Self.xml(tagged))
        let back = Self.decode(tagged)
        print("PROBE tagged decodes: tag=\(back?.recordChangeTag ?? "nil") created=\(String(describing: back?.creationDate)) modified=\(String(describing: back?.modificationDate)) creator=\(String(describing: back?.creatorUserRecordID?.recordName))")

        // Edit the plist directly: swap the tag string and decode.
        var plist = try PropertyListSerialization.propertyList(from: tagged, options: .mutableContainersAndLeaves, format: nil) as! NSMutableDictionary
        let objects = plist["$objects"] as! NSMutableArray
        if let index = objects.firstIndex(where: { ($0 as? String) == "tag-abc" }) {
            objects[index] = "tag-xyz"
            let edited = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            print("PROBE edited plist decodes: tag=\(Self.decode(edited)?.recordChangeTag ?? "nil")")
        } else {
            print("PROBE no tag string in objects")
        }
        plist = [:]
    }
}
#endif
