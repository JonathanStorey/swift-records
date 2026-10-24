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
        // CKRecord's setValue(_:forKey:) writes record fields, so call the private setters directly.
        _ = record.perform(Selector(("setEtag:")), with: "tag-abc")
        _ = record.perform(Selector(("setCreationDate:")), with: Date(timeIntervalSince1970: 1_000))
        _ = record.perform(Selector(("setModificationDate:")), with: Date(timeIntervalSince1970: 2_000))
        _ = record.perform(Selector(("setCreatorUserRecordID:")), with: CKRecord.ID(recordName: "_alice"))
        let tagged = Self.archive(record)
        print("PROBE tagged archive:\n" + Self.xml(tagged))
        let back = Self.decode(tagged)
        print("PROBE tagged decodes: tag=\(back?.recordChangeTag ?? "nil") created=\(String(describing: back?.creationDate)) modified=\(String(describing: back?.modificationDate)) creator=\(String(describing: back?.creatorUserRecordID?.recordName))")

        // Edit the plist directly: swap the tag string and decode.
        let plist = try PropertyListSerialization.propertyList(from: tagged, options: .mutableContainersAndLeaves, format: nil) as! NSMutableDictionary
        let objects = plist["$objects"] as! NSMutableArray
        let index = objects.index(of: "tag-abc")
        if index != NSNotFound {
            objects.replaceObject(at: index, with: "tag-xyz")
            let edited = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            print("PROBE edited plist decodes: tag=\(Self.decode(edited)?.recordChangeTag ?? "nil")")
        } else {
            print("PROBE no tag string in objects")
        }
    }

    /// Writes an archive from nothing but our own values, with the keys CloudKit uses, and decodes it.
    @Test func authored() {
        let zone = CKRecordZone.ID(zoneName: "recipes", ownerName: CKCurrentUserDefaultName)
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        coder.encode("Recipe", forKey: "RecordType")
        coder.encode(CKRecord.ID(recordName: "R2", zoneID: zone), forKey: "RecordID")
        coder.encode("tag-own", forKey: "ETag")
        coder.encode(Date(timeIntervalSince1970: 3_000) as NSDate, forKey: "RecordCtime")
        coder.encode(Date(timeIntervalSince1970: 4_000) as NSDate, forKey: "RecordMtime")
        coder.encode(CKRecord.ID(recordName: "_bob"), forKey: "CreatorUserRecordID")
        coder.encode(true, forKey: "KnownToServer")
        coder.finishEncoding()
        let record = Self.decode(coder.encodedData)
        print("PROBE authored decodes: \(record != nil) type=\(record?.recordType ?? "nil") name=\(record?.recordID.recordName ?? "nil") zone=\(record?.recordID.zoneID.zoneName ?? "nil") tag=\(record?.recordChangeTag ?? "nil") created=\(String(describing: record?.creationDate)) modified=\(String(describing: record?.modificationDate)) creator=\(record?.creatorUserRecordID?.recordName ?? "nil")")
        if let record {
            record["title"] = "Soup"
            print("PROBE authored record takes values: \(record["title"] as? String ?? "nil"), keys=\(record.allKeys())")
            print("PROBE authored re-archived:\n" + Self.xml(Self.archive(record)).components(separatedBy: "\n").filter { $0.contains("<string>") }.joined(separator: "\n"))
        }
    }
}
#endif
