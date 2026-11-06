#if canImport(SwiftUI)
import CrateModels
import SwiftUI

extension Date {
    var shortly: String { formatted(date: .abbreviated, time: .shortened) }
}

/// Five stars that set a rating from 0 to 5.
struct RatingStars: View {
    @Binding var rating: Int
    var highlighted = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(1...5, id: \.self) { star in
                Image(systemName: star <= rating ? "star.fill" : "star")
                    .foregroundStyle(highlighted ? .orange : .yellow)
                    .onTapGesture { rating = rating == star ? star - 1 : star }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Rating")
        .accessibilityValue("\(rating) of 5")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: rating = min(5, rating + 1)
            case .decrement: rating = max(0, rating - 1)
            @unknown default: break
            }
        }
    }
}

/// The sync state of one record: saved and confirmed by the server, or still on its way.
struct SyncBadge: View {
    var synced: Bool

    var body: some View {
        Image(systemName: synced ? "checkmark.icloud" : "icloud.and.arrow.up")
            .foregroundStyle(synced ? Color.secondary : Color.orange)
            .help(synced ? "On the server" : "Not on the server yet")
    }
}

/// Marks a field whose unsaved edit conflicts with a change from elsewhere.
struct ConflictMark: ViewModifier {
    var active: Bool

    func body(content: Content) -> some View {
        content
            .foregroundStyle(active ? Color.orange : Color.primary)
            .overlay(alignment: .trailing) {
                if active {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
    }
}

extension View {
    func conflictMark(_ active: Bool) -> some View {
        modifier(ConflictMark(active: active))
    }
}

/// The choice an editor offers when a change from elsewhere conflicts with its edit.
struct ConflictBanner: View {
    var summary: String
    var useTheirs: () -> Void
    var keepMine: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Changed on another device", systemImage: "arrow.triangle.merge")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(summary).font(.callout)
            HStack {
                Button("Use theirs", action: useTheirs)
                Button("Keep mine", action: keepMine)
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
    }
}
#endif
