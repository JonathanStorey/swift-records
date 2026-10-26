import Foundation
@testable import SwiftRecords
import Testing

@Suite struct PredicateTranslatorTests {
    @Test func fingerprintsMatchTheSameFilterWithTheSameValues() {
        func atLeast(_ minimum: Int) -> Predicate<ToDo> { #Predicate { $0.priority >= minimum } }
        func titled(_ title: String) -> Predicate<ToDo> { #Predicate { $0.title == title && !$0.done } }
        #expect(PredicateFingerprint.of(atLeast(2)) == PredicateFingerprint.of(atLeast(2)))
        #expect(PredicateFingerprint.of(atLeast(2)) != PredicateFingerprint.of(atLeast(3)))
        #expect(PredicateFingerprint.of(titled("A")) == PredicateFingerprint.of(titled("A")))
        #expect(PredicateFingerprint.of(titled("A")) != PredicateFingerprint.of(titled("B")))
        let fewer: Predicate<ToDo> = #Predicate { $0.priority <= 2 }
        #expect(PredicateFingerprint.of(atLeast(2)) != PredicateFingerprint.of(fewer))
    }

    @Test func translatesContainsOnAnInverse() throws {
        let id = UUID()
        let clause = try PredicateTranslator.translate(#Predicate<Note> { $0.todos.contains(id) })
        #expect(clause.sql == #"EXISTS (SELECT 1 FROM "RecordLink" AS "j1" WHERE "j1".relation IN (?) AND "j1"."to" = "Note"."id" AND "j1"."from" = ?)"#)
        #expect(clause.bindings == [.text("ToDo.notes"), try ValueCoding.encode(id)])
        #expect(clause.relations == ["RecordLink"])
    }

    @Test func translatesComparisonsAndLogic() throws {
        let clause = try PredicateTranslator.translate(#Predicate<ToDo> { !$0.done && $0.priority >= 3 })
        #expect(clause.sql == #"((NOT "ToDo"."done") AND ("ToDo"."priority" >= ?))"#)
        #expect(clause.bindings == [.integer(3)])
    }

    @Test func translatesNilChecks() throws {
        let clause = try PredicateTranslator.translate(#Predicate<ToDo> { $0.due != nil })
        #expect(clause.sql == #"("ToDo"."due" IS NOT NULL)"#)
    }

    @Test func translatesContainsToIn() throws {
        let clause = try PredicateTranslator.translate(#Predicate<ToDo> { [1, 5].contains($0.priority) })
        #expect(clause.sql == #"("ToDo"."priority" IN (?, ?))"#)
        #expect(clause.bindings == [.integer(1), .integer(5)])
    }

    @Test func encodesValuesLikeColumns() throws {
        let id = UUID()
        let clause = try PredicateTranslator.translate(#Predicate<ToDo> { $0.id == id })
        #expect(clause.bindings == [.blob(withUnsafeBytes(of: id.uuid) { Data($0) })])
    }

    @Test func rejectsRelationshipsAndComputedValues() {
        #expect(throws: PredicateTranslator.Unsupported.self) {
            try PredicateTranslator.translate(#Predicate<ToDo> { $0.title.count > 3 })
        }
        #expect(throws: PredicateTranslator.Unsupported.self) {
            try PredicateTranslator.translate(#Predicate<ToDo> { $0.notes.first?.text == "Sam" })
        }
    }

    @Test @available(macOS 15, iOS 18, *)
    func translatesStringContains() throws {
        let clause = try PredicateTranslator.translate(#Predicate<ToDo> { $0.title.contains("lp") })
        #expect(clause.sql == #"(instr("ToDo"."title", ?) > 0)"#)
    }

    @Test func translatesRelationshipContainsToExists() throws {
        let clause = try PredicateTranslator.translate(#Predicate<ToDo> { todo in
            todo.notes.contains { $0.text == "hello world" }
        })
        #expect(clause.sql == #"EXISTS (SELECT 1 FROM "RecordLink" AS "j1" JOIN "Note" AS "t1" ON "t1"."id" = "j1"."to" WHERE "j1".relation IN (?) AND "j1"."from" = "ToDo"."id" AND ("t1"."text" IS ?))"#)
        #expect(clause.bindings == [.text("ToDo.notes"), .text("hello world")])
        #expect(clause.relations == ["Note", "RecordLink"])
    }

    @Test func translatesChildrenContainsToExists() throws {
        let clause = try PredicateTranslator.translate(#Predicate<ToDo> { todo in
            todo.subtasks.contains { $0.title == "Call" }
        })
        #expect(clause.sql == #"EXISTS (SELECT 1 FROM "Subtask" AS "t1" WHERE "t1"."todo" = "ToDo"."id" AND ("t1"."title" IS ?))"#)
        #expect(clause.bindings == [.text("Call")])
        #expect(clause.relations == ["Subtask"])
    }

    @Test func nestedClosuresCanReadTheOuterRecord() throws {
        let clause = try PredicateTranslator.translate(#Predicate<ToDo> { todo in
            todo.notes.contains { $0.text == todo.title }
        })
        #expect(clause.sql.hasSuffix(#"("t1"."text" IS "ToDo"."title"))"#))
    }

    @Test func rejectsContainsOnNonRelationships() {
        #expect(throws: PredicateTranslator.Unsupported.self) {
            try PredicateTranslator.translate(#Predicate<ToDo> { $0.tags.contains { $0 == "home" } })
        }
    }
}
