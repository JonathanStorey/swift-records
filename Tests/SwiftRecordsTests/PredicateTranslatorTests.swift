import Foundation
@testable import SwiftRecords
import Testing

@Suite struct PredicateTranslatorTests {
    @Test func translatesComparisonsAndLogic() throws {
        let clause = try PredicateTranslator.translate(#Predicate<ToDo> { !$0.done && $0.priority >= 3 })
        #expect(clause.sql == #"((NOT "done") AND ("priority" >= ?))"#)
        #expect(clause.bindings == [.integer(3)])
    }

    @Test func translatesNilChecks() throws {
        let clause = try PredicateTranslator.translate(#Predicate<ToDo> { $0.due != nil })
        #expect(clause.sql == #"("due" IS NOT NULL)"#)
    }

    @Test func translatesContainsToIn() throws {
        let clause = try PredicateTranslator.translate(#Predicate<ToDo> { [1, 5].contains($0.priority) })
        #expect(clause.sql == #"("priority" IN (?, ?))"#)
        #expect(clause.bindings == [.integer(1), .integer(5)])
    }

    @Test func encodesValuesLikeColumns() throws {
        let id = UUID()
        let clause = try PredicateTranslator.translate(#Predicate<ToDo> { $0.id == id })
        #expect(clause.bindings == [.text(id.uuidString)])
    }

    @Test func rejectsRelationshipsAndComputedValues() {
        #expect(throws: PredicateTranslator.Unsupported.self) {
            try PredicateTranslator.translate(#Predicate<ToDo> { $0.title.count > 3 })
        }
        #expect(throws: PredicateTranslator.Unsupported.self) {
            try PredicateTranslator.translate(#Predicate<ToDo> { $0.owner?.name == "Sam" })
        }
    }

    @Test @available(macOS 15, iOS 18, *)
    func translatesStringContains() throws {
        let clause = try PredicateTranslator.translate(#Predicate<ToDo> { $0.title.contains("lp") })
        #expect(clause.sql == #"(instr("title", ?) > 0)"#)
    }
}
