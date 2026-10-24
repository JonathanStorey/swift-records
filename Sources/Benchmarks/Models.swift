import Foundation
import SwiftRecords

@Record
struct Recipe {
    var id = UUID()
    var title: String
    @Indexed var servings: Int
    var rating: Double
    var tags: [String]
    var created: Date
    var steps: [Step] = []
}

@Record
struct Step {
    var id = UUID()
    var text: String
    var minutes: Int
    @Reference(to: \Recipe.steps, action: .deleteSelf) var recipe: Recipe.ID?
}

extension Recipe {
    /// A recipe with five steps, its values spread so predicates match a predictable share.
    static func sample(_ index: Int) -> Recipe {
        Recipe(
            title: "Recipe \(index)",
            servings: index % 8 + 1,
            rating: Double(index % 50) / 10,
            tags: ["tag \(index % 20)", "tag \(index % 7)"],
            created: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 60),
            steps: (0..<5).map { Step(text: "Step \($0) of recipe \(index)", minutes: $0 * 5) }
        )
    }
}
