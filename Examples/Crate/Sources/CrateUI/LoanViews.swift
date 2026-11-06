#if canImport(SwiftUI)
import CrateModels
import SwiftUI

/// Friends and the records they have, through `Loan`, a link with properties of its own.
struct LoanList: View {
    @Environment(\.recordContext) private var context
    @Records(sort: \Friend.name) private var friends: [Friend]
    @Records(sort: \Album.title) private var albums: [Album]
    @State private var newFriend = ""

    private func title(_ loan: Loan) -> String {
        albums.first { $0.id == loan.album }?.title ?? "An album"
    }

    var body: some View {
        List {
            ForEach(friends) { friend in
                Section {
                    if friend.loans.isEmpty {
                        Text("Hasn't borrowed anything").foregroundStyle(.secondary)
                    }
                    ForEach(friend.loans.sorted { $0.lentOn > $1.lentOn }) { loan in
                        LoanRow(loan: loan, title: title(loan))
                            .swipeActions {
                                if !loan.returned {
                                    Button("Returned", systemImage: "checkmark") {
                                        context.markReturned(loan)
                                        try? context.save()
                                    }
                                    .tint(.green)
                                }
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    context.delete(loan)
                                    try? context.save()
                                }
                            }
                    }
                } header: {
                    HStack {
                        Text(friend.name)
                        Spacer()
                        Text("\(friend.outstanding.count) out")
                    }
                }
            }
            .onDelete { offsets in
                for index in offsets { context.delete(friends[index]) }
                try? context.save()
            }
            Section {
                HStack {
                    TextField("Add a friend", text: $newFriend).onSubmit(addFriend)
                    Button("Add", action: addFriend).disabled(newFriend.isEmpty)
                }
            } footer: {
                Text("Deleting a friend deletes their loans. Lend an album from its page.")
            }
        }
        .navigationTitle("Loans")
    }

    private func addFriend() {
        let name = newFriend.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        context.insert(Friend(name: name))
        try? context.save()
        newFriend = ""
    }
}

struct LoanRow: View {
    var loan: Loan
    var title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                if loan.returned {
                    Label("Returned", systemImage: "checkmark.circle").foregroundStyle(.green)
                } else if loan.isOverdue {
                    Label("Overdue", systemImage: "exclamationmark.circle").foregroundStyle(.red)
                } else {
                    Label("Out", systemImage: "clock").foregroundStyle(.purple)
                }
            }
            .labelStyle(.titleAndIcon)
            Text(["Lent \(loan.lentOn.formatted(date: .abbreviated, time: .omitted))", loan.due.map { "due \($0.formatted(date: .abbreviated, time: .omitted))" }, loan.note.isEmpty ? nil : loan.note]
                .compactMap { $0 }
                .joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Lends an album to a friend for the settings' number of days.
struct LendSheet: View {
    var album: Album
    @Environment(\.recordContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Records(sort: \Friend.name) private var friends: [Friend]
    @RecordStorage private var settings = CrateSettings()
    @State private var friend: Friend.ID?
    @State private var note = ""

    var body: some View {
        Form {
            Picker("Friend", selection: $friend) {
                Text("Choose").tag(Friend.ID?.none)
                ForEach(friends) { Text($0.name).tag(Optional($0.id)) }
            }
            Stepper("For \(settings.loanDays) days", value: $settings.loanDays, in: 1...90)
            TextField("Note", text: $note)
        }
        .formStyle(.grouped)
        .navigationTitle("Lend \(album.title)")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Lend") {
                    guard let friend = friends.first(where: { $0.id == self.friend }) else { return }
                    context.lend(album, to: friend, days: settings.loanDays, note: note)
                    try? context.save()
                    dismiss()
                }
                .disabled(friend == nil)
            }
        }
    }
}
#endif
