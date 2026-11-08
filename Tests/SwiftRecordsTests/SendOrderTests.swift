import Foundation
import Identification
@testable import SwiftRecords
import SyncTestSupport
import Testing

/// CloudKit refuses a record whose `.deleteSelf` reference names a record it doesn't have, so parents go
/// before their children, and a child that goes first anyway waits for its parent.
@MainActor
@Suite struct SendOrderTests {
    let server = TestServer()

    /// Commits without sending, as the synchronous `save()` does.
    private func commit(_ context: RecordContext) throws {
        try context.save()
    }

    @Test func aChildSentBeforeItsParentGoesAgainAfterIt() async throws {
        server.checksReferences = true
        let phone = try Device(server)
        phone.provider.batchLimit = 1
        let recipeID = UUID.timestamp
        // The step is logged first, pointing at a recipe that isn't saved yet.
        let step = SyncStep(text: "Knead", recipe: recipeID)
        phone.context.insert(step)
        try commit(phone.context)
        phone.context.insert(SyncRecipe(id: recipeID, title: "Bread", steps: [step]))
        try await phone.context.save()

        #expect(server.value("SyncRecipe", recipeID, "title") == .string("Bread"))
        #expect(server.value("SyncStep", step.id, "recipe") == .reference(recipeID, action: .deleteSelf))
        #expect(try phone.container.initialStorage.store.pendingChanges().isEmpty)
        #expect(phone.context.status == .saved)
    }

    @Test func aReuploadSendsParentTypesFirst() {
        let order = RecordStore.parentsFirst([
            Book.table: Book.self, Shelf.table: Shelf.self, _RecordLink.table: _RecordLink.self, Card.table: Card.self,
            Board.table: Board.self,
        ])
        #expect(order.firstIndex(of: Shelf.table)! < order.firstIndex(of: Book.table)!)
        #expect(order.firstIndex(of: Board.table)! < order.firstIndex(of: Card.table)!)
        #expect(order.last == _RecordLink.table)
    }

    @Test func recordsDeletedBeforeTheySyncedLeaveTheEngine() async throws {
        server.isOnline = false
        let phone = try Device(server)
        let kept = SyncRecipe(title: "Soup")
        let dropped = SyncRecipe(title: "Stew")
        phone.context.insert(kept)
        phone.context.insert(dropped)
        try await phone.context.save()
        phone.context.delete(dropped)
        try await phone.context.save()
        #expect(phone.provider.pendingRecordChanges.contains { $0.id == dropped.id })

        server.isOnline = true
        try await phone.context.refresh()
        #expect(server.value("SyncRecipe", kept.id, "title") == .string("Soup"))
        #expect(!phone.provider.pendingRecordChanges.contains { $0.id == dropped.id })
    }
}
