import Foundation
@testable import SwiftRecords
import Testing

@Record(name: "Clash")
struct ClashA {
    var id = UUID()
    var name = ""
}

@Record(name: "Clash")
struct ClashB {
    var id = UUID()
    var title = ""
}

@Record
struct ClashOwner {
    var id = UUID()
    var a: [ClashA] = []
    var b: [ClashB] = []
}

@Record
struct WrongInverse {
    var id = UUID()
    @Reference(from: \ToDo.tags) var todos: [ToDo.ID] = []
}

@Record
struct InverseOfAnotherType {
    var id = UUID()
    @Reference(from: \ToDo.notes) var todos: [ToDo.ID] = []
}

@Record
struct RenamedOntoAProperty {
    var id = UUID()
    var title = ""
    @Renamed(from: "title") var name = ""
}

@Record
struct RenamedTwice {
    var id = UUID()
    @Renamed(from: "label") var name = ""
    @Renamed(from: "label") var caption = ""
}

@Record
struct UnsyncableField {
    var id = UUID()
    var _hidden = ""
}

/// A provider that never answers, for checks that run before any sync.
final class SilentProvider: SyncProvider {
    func open(state: Data?, report: @escaping @Sendable (SyncEvent) async -> Void) async {}
    func send(_ records: [SyncRecord]) async {}
    func fetch() async {}
}

@Suite struct SchemaCheckTests {
    private func reason(registering types: [any Record.Type], sync: Bool = false) -> String? {
        do {
            _ = try RecordContainer(for: types, zone: .inMemory, syncProvider: sync ? SilentProvider() : nil)
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
        let container = try RecordContainer(zone: .inMemory)
        #expect(throws: RecordsError.self) { try container.store.register([ClashOwner.self]) }
        #expect(!container.store.tableExists("ClashOwner"))
    }

    @Test func inversesMustPointBack() {
        #expect(reason(registering: [WrongInverse.self])?.contains("isn't a relationship to WrongInverse") == true)
        #expect(reason(registering: [InverseOfAnotherType.self])?.contains("isn't a relationship to InverseOfAnotherType") == true)
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
