import Foundation
import SwiftRecords
import Testing

@Record
struct Board {
    var id = UUID()
    var title = ""
    var cards: [Card] = []
    var stickers: [Sticker] = []
}

@Record
struct Card {
    var id = UUID()
    var text = ""
    @Reference(to: \Board.cards, action: .deleteSelf) var board: Board.ID?
}

@Record
struct Sticker {
    var id = UUID()
    var name = ""
    @Reference(from: \Board.stickers) var boardIDs: Set<Board.ID>
}

@Record
struct Shelf {
    var id = UUID()
    var books: [Book] = []
}

@Record
struct Book {
    var id = UUID()
    var title = ""
    @Reference(to: \Shelf.books) var shelf: Shelf.ID?
}

@Record
struct Member {
    var id = UUID()
    var name = ""
    var memberships: [Membership] = []
}

@Record
struct Team {
    var id = UUID()
    var name = ""
    var memberships: [Membership] = []
}

/// A link with properties of its own, which belongs to both ends.
@Record
struct Membership {
    var id = UUID()
    var role = ""
    @Reference(to: \Member.memberships, action: .deleteSelf) var member: Member.ID?
    @Reference(to: \Team.memberships, action: .deleteSelf) var team: Team.ID?
}

/// A relationship whose target doesn't say how it belongs.
@Record
struct LooseBoard {
    var id = UUID()
    var cards: [Card] = []
}

/// A reference to a property that isn't a relationship to this type.
@Record
struct MisplacedReference {
    var id = UUID()
    @Reference(to: \Board.cards) var board: Board.ID?
}

@Suite struct ReferenceTests {
    let container = try! RecordContainer(for: [Board.self, Shelf.self], inMemory: true)

    private func cards() throws -> [String: Board.ID?] {
        Dictionary(uniqueKeysWithValues: try container.fetch(Card.self).map { ($0.text, $0.board) })
    }

    // MARK: Membership

    @Test func savingAParentSetsItsChildrensReferences() throws {
        let board = Board(cards: [Card(text: "A"), Card(text: "B")])
        try container.save(board)
        #expect(try cards() == ["A": board.id, "B": board.id])
    }

    @Test func settingAReferenceMovesTheChildToTheEndOfTheNewParent() throws {
        var card = Card(text: "Move me")
        let from = Board(title: "From", cards: [card])
        let to = Board(title: "To", cards: [Card(text: "Already here")])
        try container.save([from, to])

        card.board = to.id
        try container.save(card)
        #expect(try container.fetch(Board.self, id: from.id)?.cards.isEmpty == true)
        #expect(try container.fetch(Board.self, id: to.id)?.cards.map(\.text) == ["Already here", "Move me"])
    }

    @Test func movingBetweenArraysInOneSaveKeepsTheChild() throws {
        var from = Board(title: "From", cards: [Card(text: "Move me")])
        var to = Board(title: "To")
        try container.save([from, to])

        to.cards.append(from.cards.removeFirst())
        try container.save([from, to])
        #expect(try cards() == ["Move me": to.id])
        #expect(try container.fetch(Board.self, id: to.id)?.cards.map(\.text) == ["Move me"])
    }

    @Test func aChildSavedWithItsReferenceJoinsTheParent() throws {
        let board = Board(cards: [Card(text: "First")])
        try container.save(board)
        try container.save(Card(text: "Second", board: board.id))
        #expect(try container.fetch(Board.self, id: board.id)?.cards.map(\.text) == ["First", "Second"])
    }

    @Test func referencesRunAsSQLPredicates() throws {
        let board = Board(cards: [Card(text: "A")])
        try container.save([board, Board(cards: [Card(text: "B")])])
        let boardID: Board.ID? = board.id
        #expect(try container.fetch(Card.self, where: #Predicate { $0.board == boardID }).map(\.text) == ["A"])
    }

    // MARK: Actions

    @Test func deleteSelfChildrenGoWithTheirParent() throws {
        let board = Board(cards: [Card(text: "A")], stickers: [Sticker(name: "Urgent")])
        try container.save(board)
        try container.delete(board)
        #expect(try container.fetch(Card.self).isEmpty)
        // Stickers can be on many boards, so they stay.
        #expect(try container.fetch(Sticker.self).map(\.name) == ["Urgent"])
    }

    @Test func aDeleteSelfChildDroppedFromItsParentIsDeleted() throws {
        var board = Board(cards: [Card(text: "A"), Card(text: "B")])
        try container.save(board)
        board.cards.removeFirst()
        try container.save(board)
        #expect(try cards() == ["B": board.id])
    }

    @Test func aDeleteSelfChildWithoutAParentIsDeleted() throws {
        let board = Board(cards: [Card(text: "A")])
        try container.save(board)
        var card = board.cards[0]
        card.board = nil
        try container.save(card)
        #expect(try container.fetch(Card.self).isEmpty)
        #expect(try container.fetch(Board.self, id: board.id)?.cards.isEmpty == true)
    }

    @Test func noneChildrenOutliveTheirParent() throws {
        var shelf = Shelf(books: [Book(title: "Kept"), Book(title: "Dropped")])
        try container.save(shelf)
        shelf.books.removeLast()
        try container.save(shelf)
        try container.delete(shelf)

        let books = try container.fetch(Book.self)
        #expect(books.map(\.title) == ["Kept", "Dropped"])
        #expect(books.allSatisfy { $0.shelf == nil })
    }

    @Test func aFailedSaveDeletesNothing() throws {
        var board = Board(cards: [Card(text: "A")])
        try container.save(board)
        board.cards = []
        #expect(throws: RecordsError.self) {
            try container.transaction {
                try container.save(board)
                throw RecordsError.invalidValue(type: "Board", property: "title")
            }
        }
        #expect(try cards() == ["A": board.id])
    }

    @Test func aLinkRecordGoesWithEitherEnd() throws {
        let membership = Membership(role: "Captain")
        let ana = Member(name: "Ana", memberships: [membership])
        let team = Team(name: "Red", memberships: [membership])
        try container.save(ana)
        try container.save(team)
        let saved = try #require(try container.fetch(Membership.self, id: membership.id))
        #expect(saved.member == ana.id)
        #expect(saved.team == team.id)

        try container.delete(team)
        #expect(try container.fetch(Membership.self).isEmpty)
        #expect(try container.fetch(Member.self, id: ana.id)?.memberships.isEmpty == true)
    }

    // MARK: Schema

    @Test func relationshipsMustSayHowTheirTargetsBelong() {
        #expect(throws: RecordsError.self) { try RecordContainer(for: [LooseBoard.self], inMemory: true) }
        #expect(throws: RecordsError.self) { try RecordContainer(for: [MisplacedReference.self], inMemory: true) }
    }
}

@MainActor
@Suite struct ReferenceSyncTests {
    let server = TestServer()

    @Test func referencesAndListsCrossAsIDs() async throws {
        let phone = try Device(server)
        let recipe = SyncRecipe(title: "Soup", steps: [SyncStep(text: "Chop")])
        phone.context.insert(recipe)
        try await phone.context.save()

        #expect(server.value("SyncStep", recipe.steps[0].id, "recipe", as: UUID.self) == recipe.id)
        #expect(server.value("SyncRecipe", recipe.id, "steps", as: [UUID].self) == [recipe.steps[0].id])

        let tablet = try Device(server)
        try await tablet.context.refresh()
        #expect(try tablet.context.fetch(SyncStep.self).map(\.recipe) == [recipe.id])
    }

    @Test func aChildsReferenceDecidesWhichParentHoldsIt() async throws {
        let phone = try Device(server)
        let soup = SyncRecipe(title: "Soup", steps: [SyncStep(text: "Chop")])
        let stew = SyncRecipe(title: "Stew")
        phone.context.insert(soup)
        phone.context.insert(stew)
        try await phone.context.save()

        // Another device moved the step to the stew, and its recipes' lists haven't arrived yet.
        server.put("SyncStep", id: soup.steps[0].id, json: #"{"text":"Chop","recipe":"\#(stew.id)"}"#)
        try await phone.context.refresh()

        let recipes = try await phone.recipes()
        #expect(recipes.first { $0.id == soup.id }?.steps.isEmpty == true)
        #expect(recipes.first { $0.id == stew.id }?.steps.map(\.text) == ["Chop"])
    }
}
