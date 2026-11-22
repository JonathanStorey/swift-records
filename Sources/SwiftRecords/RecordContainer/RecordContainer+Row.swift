import Foundation
import Versioning

extension RecordContainer {
    /// One record in the container: its identity, and up to three versions of its fields.
    struct Row: Equatable, Sendable {
        /// The record's name in CloudKit, and the table's primary key.
        var id: UUID
        /// The zone, with its owner: you for a private zone, or the sharer for a shared one.
        var zone: Zone
        /// The CloudKit record type, checked when the row is read.
        var type: String
        /// The newest system fields from the server, or `nil` before the server first confirms the record.
        var metadata: Data? = nil
        /// What the server last confirmed, or `nil` for a record never uploaded.
        var base: JSONRepresentation? = nil
        /// This device's saved changes the server has not confirmed, or `nil` when there is nothing to upload.
        var ours: JSONRepresentation? = nil
        /// A newer server version waiting to merge into `ours`. Nothing uploads while it waits.
        var theirs: JSONRepresentation? = nil
        /// The version last sent, kept until the server confirms it, because an upload holds
        /// only the fields that changed, so the confirmed record cannot say what it holds.
        var sent: JSONRepresentation? = nil
        /// A local delete the server has not confirmed.
        var isDeleted = false
        /// Why `theirs` could not merge, or, with no `theirs`, why the server rejected the
        /// upload, or why this device could not send it.
        var error: String? = nil
    }
}

extension RecordContainer.Row {
    enum Status: Equatable, Sendable {
        case synced
        case waitingToUpload
        case rejected(String)
        case conflict(String)
    }

    /// Where the record is in syncing, worked out from the columns, never stored.
    var status: Status {
        switch (theirs, error) {
        case (.some, let error): .conflict(error ?? "")
        case (nil, let error?): .rejected(error)
        case (nil, nil): ours != nil || isDeleted ? .waitingToUpload : .synced
        }
    }
}

extension RecordContainer.Row {
    /// Takes `theirs`, the server's newest version, as this row's `base`.
    ///
    /// With no local changes, there is nothing to merge. With local changes, `theirs`
    /// merges into `ours` by `merge`, the record type's own merge, and a merge that matches
    /// `theirs` leaves nothing to upload. On a conflict, or a version the type cannot read,
    /// `theirs` waits, `error` says why, and `ours` and `base` are unchanged, so nothing
    /// uploads until it is settled.
    mutating func receive(_ theirs: JSONRepresentation, merging merge: (_ ours: JSONRepresentation, _ theirs: JSONRepresentation, _ base: JSONRepresentation?) throws -> JSONRepresentation) {
        guard let ours else {
            base = theirs
            self.theirs = nil
            error = nil
            return
        }
        do {
            let merged = try merge(ours, theirs, base)
            // An explicit Optional, because JSONRepresentation is ExpressibleByNilLiteral and
            // a bare `nil` in the conditional would store JSON `null` instead of nothing.
            self.ours = merged == theirs ? Optional.none : merged
            base = theirs
            self.theirs = nil
            error = nil
        } catch let conflict as MergeConflict {
            self.theirs = theirs
            error = "Both sides changed " + conflict.paths.map(\.description).joined(separator: ", ")
        } catch {
            self.theirs = theirs
            self.error = String(describing: error)
        }
    }

    /// Takes `sent`, a version this device uploaded and the server saved, as this row's `base`.
    ///
    /// Nothing merges, because the server now holds exactly what was sent. Changes saved
    /// while it was on its way were made on top of it, so they stay in `ours` to upload
    /// next, and an `ours` that still matches `sent` leaves nothing to upload.
    mutating func confirm(_ sent: JSONRepresentation) {
        base = sent
        if ours == sent { ours = .none }
        self.sent = nil
        error = nil
    }
}
