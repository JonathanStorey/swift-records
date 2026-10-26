import Foundation
@testable import SwiftRecords
import Testing

@Record("Clash")
struct ClashA {
    var id = UUID.ordered()
    var name = ""
}

@Record("Clash")
struct ClashB {
    var id = UUID.ordered()
    var title = ""
}

@Record
struct ClashOwner {
    var id = UUID.ordered()
    @Reference(to: ClashA.self) var a: [ClashA] = []
    @Reference(to: ClashB.self) var b: [ClashB] = []
}

@Record
struct WrongInverse {
    var id = UUID.ordered()
    @Reference(to: \ToDo.tags) var todos: Set<ToDo.ID>
}

@Record
struct InverseOfAnotherType {
    var id = UUID.ordered()
    @Reference(to: \ToDo.notes) var todos: Set<ToDo.ID>
}

@Record
struct RenamedOntoAProperty {
    var id = UUID.ordered()
    var title = ""
    @Renamed(from: "title") var name = ""
}

@Record
struct RenamedTwice {
    var id = UUID.ordered()
    @Renamed(from: "label") var name = ""
    @Renamed(from: "label") var caption = ""
}

@Record
struct UnsyncableField {
    var id = UUID.ordered()
    var _hidden = ""
}

/// A provider that is never signed in, for checks that run before any sync.
final class SilentProvider: SyncProvider {
    func userID() async throws -> String? { nil }
    func uploadRecordChanges(_ changes: [RecordChangeData]) async throws -> [UploadResult] { [] }
    func downloadRecordChanges(in zone: Zone, after cursor: Data?) async throws -> RecordDownload {
        RecordDownload(changes: [], cursor: cursor)
    }
    func uploadAssets(_ assets: [RecordAssetData]) async throws {}
    func downloadAsset(id: String, zone: Zone, into directory: URL) async throws -> URL { throw SyncError.offline }
}

@Suite struct SchemaCheckTests {
    private func reason(registering types: [any Record.Type], sync: Bool = false) -> String? {
        do {
            if sync {
                _ = try RecordContainer(for: types, inMemory: true, syncProvider: SilentProvider())
            } else {
                _ = try RecordContainer(for: types, inMemory: true)
            }
            return nil
        } catch RecordsError.invalidSchema(_, let reason) {
            return reason
        } catch {
            return "unexpected \(error)"
        }
    }

    @Test func soundTypesRegister() {
        #expect(reason(registering: [ToDo.self, Folder.self]) == nil)
        #expect(reason(registering: [SyncRecipe.self], sync: true) == nil)
    }

    @Test func twoTypesCantShareAStoredName() throws {
        #expect(reason(registering: [ClashOwner.self])?.contains("both stored as \"Clash\"") == true)
        // Nothing was created.
        let container = try RecordContainer(inMemory: true)
        #expect(throws: RecordsError.self) { try container.initialStorage.store.register([ClashOwner.self]) }
        #expect(!container.initialStorage.store.tableExists("ClashOwner"))
    }

    @Test func inversesMustPointBack() {
        #expect(reason(registering: [WrongInverse.self])?.contains("isn't a many-to-many relationship to WrongInverse") == true)
        #expect(reason(registering: [InverseOfAnotherType.self])?.contains("isn't a many-to-many relationship to InverseOfAnotherType") == true)
    }

    @Test func renamesMustNotCollide() {
        #expect(reason(registering: [RenamedOntoAProperty.self])?.contains("still a property's name") == true)
        #expect(reason(registering: [RenamedTwice.self])?.contains("both renamed from \"label\"") == true)
    }

    @Test func syncNeedsServerSafeNames() {
        #expect(reason(registering: [UnsyncableField.self]) == nil)
        #expect(reason(registering: [UnsyncableField.self], sync: true)?.contains("\"_hidden\" can't sync") == true)
        #expect(RecordStore.isSyncSafe("Recipe_2"))
        #expect(!RecordStore.isSyncSafe("2Recipe"))
        #expect(!RecordStore.isSyncSafe("café"))
        #expect(!RecordStore.isSyncSafe(""))
        #expect(!RecordStore.isSyncSafe(String(repeating: "a", count: 256)))
    }
}
