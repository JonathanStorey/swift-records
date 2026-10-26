import Foundation
@testable import SwiftRecords
import Testing

/// Relationships across devices, where each side may hold an older copy or see records in any order.
@MainActor
@Suite struct RelationshipSyncTests {
    let server = TestServer()

    /// Two devices that have both seen `recipe`, and the tablet's copy of it.
    private func devices(_ recipe: SyncRecipe, cooks: [SyncCook] = []) async throws -> (Device, Device, SyncRecipe) {
        let phone = try Device(server)
        let tablet = try Device(server)
        phone.context.insert(recipe)
        for cook in cooks { phone.context.insert(cook) }
        try await phone.context.save()
        try await tablet.context.refresh()
        return (phone, tablet, try #require(try await tablet.recipes().first))
    }

    private func refresh(_ devices: Device...) async throws {
        for device in devices { try await device.context.refresh() }
    }

    // MARK: Older copies

    @Test func aChildDeletedElsewhereStaysDeleted() async throws {
        var recipe = SyncRecipe(title: "Soup", steps: [SyncStep(text: "Chop"), SyncStep(text: "Simmer")])
        let (phone, tablet, draft) = try await devices(recipe)
        var older = draft

        recipe.steps.removeFirst()
        phone.context.insert(recipe)
        try await phone.context.save()
        try await tablet.context.refresh()

        // The tablet's older copy still holds the deleted step, and saving it doesn't bring it back.
        older.title = "Tomato soup"
        tablet.context.insert(older)
        try await tablet.context.save()
        try await refresh(phone)
        for device in [phone, tablet] {
            #expect(try await device.recipes().first?.steps.map(\.text) == ["Simmer"])
            #expect(try await device.recipes().first?.title == "Tomato soup")
        }
        #expect(server.records("SyncStep").count == 1)
    }

    @Test func aLinkRemovedElsewhereStaysRemoved() async throws {
        let ana = SyncCook(name: "Ana"), ben = SyncCook(name: "Ben")
        var recipe = SyncRecipe(title: "Stew", cooks: [ana, ben])
        let (phone, tablet, draft) = try await devices(recipe)
        var older = draft

        recipe.cooks = [ben]
        phone.context.insert(recipe)
        try await phone.context.save()
        try await tablet.context.refresh()

        older.title = "Beef stew"
        tablet.context.insert(older)
        try await tablet.context.save()
        try await refresh(phone)
        for device in [phone, tablet] {
            #expect(try await device.recipes().first?.cooks.map(\.name) == ["Ben"])
        }
        #expect(server.records("RecordLink").count == 1)
    }

    @Test func removalsOnBothDevicesBothApply() async throws {
        let ana = SyncCook(name: "Ana"), ben = SyncCook(name: "Ben"), cy = SyncCook(name: "Cy")
        var recipe = SyncRecipe(title: "Pie", steps: [SyncStep(text: "A"), SyncStep(text: "B"), SyncStep(text: "C")], cooks: [ana, ben, cy])
        let (phone, tablet, draft) = try await devices(recipe)
        var other = draft

        recipe.steps.removeFirst()
        recipe.cooks.removeFirst()
        phone.context.insert(recipe)
        try await phone.context.save()
        try await tablet.context.refresh()

        other.steps.removeLast()
        other.cooks.removeLast()
        tablet.context.insert(other)
        try await tablet.context.save()
        try await refresh(phone)
        for device in [phone, tablet] {
            let saved = try #require(try await device.recipes().first)
            #expect(saved.steps.map(\.text) == ["B"])
            #expect(saved.cooks.map(\.name) == ["Ben"])
        }
    }

    // MARK: Deleted ends

    @Test func aChildAddedToARecipeDeletedElsewhereGoesWithIt() async throws {
        let recipe = SyncRecipe(title: "Tart", steps: [SyncStep(text: "Roll")])
        let (phone, tablet, draft) = try await devices(recipe)
        var older = draft

        phone.context.delete(recipe)
        try await phone.context.save()

        // The tablet adds a step before it hears of the delete.
        older.steps.append(SyncStep(text: "Bake"))
        tablet.context.insert(older)
        try await tablet.context.save()
        // The tablet learns of the delete and sends the step's, which the phone receives next time.
        try await refresh(tablet, phone)
        for device in [phone, tablet] {
            #expect(try await device.recipes().isEmpty)
            #expect(try device.context.fetch(SyncStep.self).isEmpty)
        }
    }

    @Test func anOlderCopyOfADeletedRecipeDoesntBringItBack() async throws {
        let recipe = SyncRecipe(title: "Tart", steps: [SyncStep(text: "Roll")])
        let (phone, tablet, draft) = try await devices(recipe)
        var older = draft

        phone.context.delete(recipe)
        try await phone.context.save()
        try await tablet.context.refresh()

        // The delete has arrived, and an edit sheet still holds the recipe.
        older.title = "Apple tart"
        tablet.context.insert(older)
        try await tablet.context.save()
        try await refresh(phone, tablet)
        for device in [phone, tablet] {
            #expect(try await device.recipes().isEmpty)
            #expect(try device.context.fetch(SyncStep.self).isEmpty)
        }
    }

    @Test func aLinkToACookDeletedElsewhereDisappears() async throws {
        let ana = SyncCook(name: "Ana")
        let recipe = SyncRecipe(title: "Stew")
        let (phone, tablet, draft) = try await devices(recipe, cooks: [ana])
        var older = draft

        phone.context.delete(ana)
        try await phone.context.save()

        // The tablet links the cook before it hears of the delete.
        older.cooks = [ana]
        tablet.context.insert(older)
        try await tablet.context.save()
        try await refresh(phone, tablet)
        for device in [phone, tablet] {
            #expect(try await device.recipes().first?.cooks.isEmpty == true)
            #expect(try device.context.fetch(SyncCook.self).isEmpty)
        }
    }

    // MARK: Moves

    @Test func aChildMovedOnTwoDevicesEndsUnderOneRecipe() async throws {
        let step = SyncStep(text: "Whisk")
        let soup = SyncRecipe(title: "Soup", steps: [step])
        let phone = try Device(server)
        let tablet = try Device(server)
        phone.context.insert(soup)
        phone.context.insert(SyncRecipe(title: "Stew"))
        phone.context.insert(SyncRecipe(title: "Pie"))
        try await phone.context.save()
        try await tablet.context.refresh()

        let recipes = try await phone.recipes()
        var stew = try #require(recipes.first { $0.title == "Stew" })
        var pie = try #require(try await tablet.recipes().first { $0.title == "Pie" })
        stew.steps.append(step)
        phone.context.insert(stew)
        pie.steps.append(step)
        tablet.context.insert(pie)
        try await phone.context.save()
        try await tablet.context.save()
        try await refresh(phone, tablet)

        var holders: [[String]] = []
        for device in [phone, tablet] {
            let held = try await device.recipes().filter { !$0.steps.isEmpty }.map(\.title)
            #expect(held.count == 1)
            holders.append(held)
            #expect(try device.context.fetch(SyncStep.self).count == 1)
        }
        #expect(holders[0] == holders[1])
    }

    // MARK: Arrival order

    @Test func aLinkArrivingBeforeItsRecipeResolvesLater() async throws {
        let phone = try Device(server)
        _ = try await phone.recipes()
        let recipeID = UUID.ordered()
        let cook = SyncCook(name: "Ana")
        server.put("SyncCook", id: cook.id, fields: ["name": .string("Ana")])
        server.put("RecordLink", id: _RecordLink.id(relation: "SyncRecipe.cooks", from: recipeID, to: cook.id), fields: [
            "relation": .string("SyncRecipe.cooks"), "from": .reference(recipeID, action: .deleteSelf),
            "to": .reference(cook.id, action: .deleteSelf), "created": .date(Date()),
        ])
        await phone.download()
        #expect(try phone.context.fetch(SyncCook.self).first?.recipeIDs == [recipeID])

        server.put("SyncRecipe", id: recipeID, fields: ["title": .string("Omelette")])
        await phone.download()
        #expect(try await phone.recipes().first?.cooks.map(\.name) == ["Ana"])
    }

    @Test func aStepArrivingAfterTheRecipeWasFetchedShowsOnRefresh() async throws {
        let recipe = SyncRecipe(title: "Bread", steps: [SyncStep(text: "Mix")])
        let (phone, tablet, _) = try await devices(recipe)
        server.put("SyncStep", fields: ["text": .string("Knead"), "recipe": .reference(recipe.id, action: .deleteSelf)])
        await tablet.download()
        #expect(try await tablet.recipes().first?.steps.map(\.text) == ["Mix", "Knead"])
        try await refresh(phone)
        #expect(try await phone.recipes().first?.steps.map(\.text) == ["Mix", "Knead"])
    }
}
