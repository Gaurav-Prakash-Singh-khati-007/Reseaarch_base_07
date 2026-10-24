//
//  SubmissionStore.swift
//  ResearchBase
//
//  Owner: Agent 18 · Features: F-38
//
//  Submission tracker storage: the `submissions` table (venue, deadline,
//  stage, link, notes) and its `review_comments` table (reviewer comment,
//  your reply, state). This file only talks to the database; the screen
//  (SubmissionsView, Agent 64) calls it.
//
//  PUBLIC API
//    Types
//      StoredSubmissionStage      planned, submitted, underReview, revision, accepted, rejected, published
//      StoredReviewState          open, addressed, disagree
//      StoredSubmission           one row of `submissions`
//      StoredReviewComment        one row of `review_comments`
//      NewSubmission              what you pass to create(_:)
//    SubmissionStore(model: LibraryModel)
//      create(_ new: NewSubmission) throws -> StoredSubmission
//      submission(id:) throws -> StoredSubmission?
//      all() throws -> [StoredSubmission]                      soonest deadline first, no-deadline last
//      submissions(forDraft:) throws -> [StoredSubmission]
//      submissions(inStage:) throws -> [StoredSubmission]
//      upcomingDeadlines(from:withinDays:) throws -> [StoredSubmission]   planned/revision only (F-46, Home)
//      count() throws -> Int
//      setVenue(id:to:) / setDeadline(id:to:) / setDraft(id:to:) / setURL(id:to:) / setNotes(id:to:)
//      setStage(id:to:) throws -> StoredSubmission             fills submitted/decision dates once
//      setDecisionDates(id:submittedAt:decisionAt:) throws -> StoredSubmission
//      remove(id:) throws                                      also removes its review comments
//      addComment(submissionID:reviewer:comment:round:draftLineRef:) throws -> StoredReviewComment
//      comments(forSubmission:) throws -> [StoredReviewComment]
//      comment(id:) throws -> StoredReviewComment?
//      setReply(commentID:to:) / setState(commentID:to:) throws -> StoredReviewComment
//      removeComment(id:) throws
//      openCommentCount(forSubmission:) throws -> Int
//      currentRound(forSubmission:) throws -> Int
//
//  Notes
//    * Names start with "Stored" because SubmissionsView.swift already uses
//      SubmissionStage / SubmissionModel / ReviewerCommentModel for the screen.
//    * The schema has no `deleted_at` for these tables, so remove(...) really
//      deletes, and the old values are reported to the change sink first.
//    * Dates are kept as text, exactly as the schema stores them. Both
//      "2026-10-15" and full ISO-8601 ("2026-10-15T09:00:00Z") are accepted.
//    * LibraryModel is a finished file and is not edited, so there is no
//      `model.submissions` shortcut. Create the store with
//      `SubmissionStore(model: model)` and keep it.
//

import Foundation

// MARK: - Types

enum StoredSubmissionStage: String, CaseIterable, Equatable {
    case planned
    case submitted
    case underReview = "under_review"
    case revision
    case accepted
    case rejected
    case published

    /// Plain-words name for lists and pickers.
    var label: String {
        switch self {
        case .planned: return "Planned"
        case .submitted: return "Submitted"
        case .underReview: return "Under review"
        case .revision: return "Revision"
        case .accepted: return "Accepted"
        case .rejected: return "Rejected"
        case .published: return "Published"
        }
    }

    /// True while a deadline still matters: you have not sent it yet, or you owe a revision.
    var needsDeadline: Bool {
        self == .planned || self == .revision
    }
}

enum StoredReviewState: String, CaseIterable, Equatable {
    case open
    case addressed
    case disagree

    var label: String {
        switch self {
        case .open: return "Open"
        case .addressed: return "Addressed"
        case .disagree: return "Respectfully disagree"
        }
    }
}

struct StoredSubmission: Equatable, Identifiable {
    let id: String
    let draftID: String?
    let venue: String
    let deadline: String?
    let submittedAt: String?
    let decisionAt: String?
    let stage: StoredSubmissionStage
    let url: String
    let notes: String
}

struct StoredReviewComment: Equatable, Identifiable {
    let id: String
    let submissionID: String
    let round: Int
    let reviewer: String
    let comment: String
    let reply: String
    let state: StoredReviewState
    let draftLineRef: String
}

struct NewSubmission {
    var venue: String
    var draftID: String? = nil
    var deadline: String? = nil
    var stage: StoredSubmissionStage = .planned
    var url: String = ""
    var notes: String = ""
}

// MARK: - Store

final class SubmissionStore {

    unowned let model: LibraryModel

    init(model: LibraryModel) {
        self.model = model
    }

    // MARK: Create

    @discardableResult
    func create(_ new: NewSubmission) throws -> StoredSubmission {

        let venue = new.venue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !venue.isEmpty else { throw ModelError.emptyName }
        let deadline = try Self.cleanDate(new.deadline, field: "deadline")

        return try model.atomically {

            if let draftID = new.draftID { try requireDraft(draftID) }

            let id = model.newID()
            let stamps = Self.stamps(for: new.stage, submittedAt: nil, decisionAt: nil, now: model.now())

            try model.database.run(
                """
                INSERT INTO submissions (id, draft_id, venue, deadline, submitted_at, decision_at, stage, url, notes)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [.text(id), LibraryModel.text(new.draftID), .text(venue), LibraryModel.text(deadline),
                 LibraryModel.text(stamps.submittedAt), LibraryModel.text(stamps.decisionAt),
                 .text(new.stage.rawValue), .text(new.url), .text(new.notes)]
            )

            let created = StoredSubmission(
                id: id, draftID: new.draftID, venue: venue, deadline: deadline,
                submittedAt: stamps.submittedAt, decisionAt: stamps.decisionAt,
                stage: new.stage, url: new.url, notes: new.notes
            )
            try model.record("submission", id, .create, field: "submission", new: Self.snapshot(created))
            return created
        }
    }

    // MARK: Read

    func submission(id: String) throws -> StoredSubmission? {
        guard let row = try model.database.rows("SELECT * FROM submissions WHERE id = ?", [.text(id)]).first else {
            return nil
        }
        return try Self.submission(from: row)
    }

    /// Soonest deadline first. Submissions without a deadline come last.
    func all() throws -> [StoredSubmission] {
        try model.database.rows("SELECT * FROM submissions").map { try Self.submission(from: $0) }
            .sorted { Self.deadlineOrder($0, $1) }
    }

    func submissions(forDraft draftID: String) throws -> [StoredSubmission] {
        try model.database.rows("SELECT * FROM submissions WHERE draft_id = ?", [.text(draftID)])
            .map { try Self.submission(from: $0) }
            .sorted { Self.deadlineOrder($0, $1) }
    }

    func submissions(inStage stage: StoredSubmissionStage) throws -> [StoredSubmission] {
        try model.database.rows("SELECT * FROM submissions WHERE stage = ?", [.text(stage.rawValue)])
            .map { try Self.submission(from: $0) }
            .sorted { Self.deadlineOrder($0, $1) }
    }

    /// Deadlines that still matter (stage planned or revision), today or later,
    /// soonest first. `withinDays` keeps only those due in that many days or fewer.
    func upcomingDeadlines(from now: Date = Date(), withinDays: Int? = nil) throws -> [StoredSubmission] {

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let limit = withinDays.flatMap { calendar.date(byAdding: .day, value: $0, to: today) }

        var found: [(StoredSubmission, Date)] = []
        for item in try all() where item.stage.needsDeadline {
            guard let text = item.deadline, let due = Self.parseDate(text) else { continue }
            if calendar.startOfDay(for: due) < today { continue }
            if let limit, calendar.startOfDay(for: due) > limit { continue }
            found.append((item, due))
        }
        return found.sorted { $0.1 < $1.1 }.map { $0.0 }
    }

    func count() throws -> Int {
        Int(try model.database.scalarInt("SELECT COUNT(*) FROM submissions") ?? 0)
    }

    // MARK: Edit

    @discardableResult
    func setVenue(id: String, to venue: String) throws -> StoredSubmission {
        let trimmed = venue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ModelError.emptyName }
        return try model.atomically {
            let existing = try require(id)
            return try change(existing, field: "venue", column: "venue", value: .text(trimmed),
                              old: existing.venue, new: trimmed)
        }
    }

    /// Pass nil to clear the deadline.
    @discardableResult
    func setDeadline(id: String, to deadline: String?) throws -> StoredSubmission {
        let cleaned = try Self.cleanDate(deadline, field: "deadline")
        return try model.atomically {
            let existing = try require(id)
            return try change(existing, field: "deadline", column: "deadline", value: LibraryModel.text(cleaned),
                              old: existing.deadline, new: cleaned)
        }
    }

    /// Pass nil to unlink the draft.
    @discardableResult
    func setDraft(id: String, to draftID: String?) throws -> StoredSubmission {
        try model.atomically {
            let existing = try require(id)
            if let draftID { try requireDraft(draftID) }
            return try change(existing, field: "draft_id", column: "draft_id", value: LibraryModel.text(draftID),
                              old: existing.draftID, new: draftID)
        }
    }

    @discardableResult
    func setURL(id: String, to url: String) throws -> StoredSubmission {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        return try model.atomically {
            let existing = try require(id)
            return try change(existing, field: "url", column: "url", value: .text(trimmed),
                              old: existing.url, new: trimmed)
        }
    }

    @discardableResult
    func setNotes(id: String, to notes: String) throws -> StoredSubmission {
        try model.atomically {
            let existing = try require(id)
            return try change(existing, field: "notes", column: "notes", value: .text(notes),
                              old: existing.notes, new: notes)
        }
    }

    /// Moves a submission to a new stage. The first time it reaches "submitted" (or beyond)
    /// the submitted date is filled in; the first time it reaches accepted, rejected or
    /// published the decision date is filled in. Dates already set are never overwritten.
    @discardableResult
    func setStage(id: String, to stage: StoredSubmissionStage) throws -> StoredSubmission {
        try model.atomically {
            let existing = try require(id)
            if existing.stage == stage { return existing }

            let stamps = Self.stamps(for: stage, submittedAt: existing.submittedAt,
                                     decisionAt: existing.decisionAt, now: model.now())

            try model.database.run(
                "UPDATE submissions SET stage = ?, submitted_at = ?, decision_at = ? WHERE id = ?",
                [.text(stage.rawValue), LibraryModel.text(stamps.submittedAt),
                 LibraryModel.text(stamps.decisionAt), .text(id)]
            )
            try model.record("submission", id, .update, field: "stage",
                             old: existing.stage.rawValue, new: stage.rawValue)
            if stamps.submittedAt != existing.submittedAt {
                try model.record("submission", id, .update, field: "submitted_at",
                                 old: existing.submittedAt, new: stamps.submittedAt)
            }
            if stamps.decisionAt != existing.decisionAt {
                try model.record("submission", id, .update, field: "decision_at",
                                 old: existing.decisionAt, new: stamps.decisionAt)
            }

            return StoredSubmission(
                id: existing.id, draftID: existing.draftID, venue: existing.venue,
                deadline: existing.deadline, submittedAt: stamps.submittedAt, decisionAt: stamps.decisionAt,
                stage: stage, url: existing.url, notes: existing.notes
            )
        }
    }

    /// For correcting the two dates by hand. Pass nil to clear one.
    @discardableResult
    func setDecisionDates(id: String, submittedAt: String?, decisionAt: String?) throws -> StoredSubmission {
        let submitted = try Self.cleanDate(submittedAt, field: "submitted date")
        let decided = try Self.cleanDate(decisionAt, field: "decision date")
        return try model.atomically {
            let existing = try require(id)
            if existing.submittedAt == submitted && existing.decisionAt == decided { return existing }

            try model.database.run(
                "UPDATE submissions SET submitted_at = ?, decision_at = ? WHERE id = ?",
                [LibraryModel.text(submitted), LibraryModel.text(decided), .text(id)]
            )
            if existing.submittedAt != submitted {
                try model.record("submission", id, .update, field: "submitted_at",
                                 old: existing.submittedAt, new: submitted)
            }
            if existing.decisionAt != decided {
                try model.record("submission", id, .update, field: "decision_at",
                                 old: existing.decisionAt, new: decided)
            }

            return StoredSubmission(
                id: existing.id, draftID: existing.draftID, venue: existing.venue,
                deadline: existing.deadline, submittedAt: submitted, decisionAt: decided,
                stage: existing.stage, url: existing.url, notes: existing.notes
            )
        }
    }

    // MARK: Remove

    /// Deletes the submission and its review comments. The schema has no `deleted_at`
    /// here, so everything removed is reported to the change sink with its old values.
    func remove(id: String) throws {
        try model.atomically {
            let existing = try require(id)

            for item in try comments(forSubmission: id) {
                try model.record("review_comment", item.id, .delete, field: "review_comment",
                                 old: Self.snapshot(item), new: nil)
            }
            try model.database.run("DELETE FROM review_comments WHERE submission_id = ?", [.text(id)])
            try model.database.run("DELETE FROM submissions WHERE id = ?", [.text(id)])
            try model.record("submission", id, .delete, field: "submission",
                             old: Self.snapshot(existing), new: nil)
        }
    }

    // MARK: Review comments

    /// Adds a reviewer comment. `round` defaults to the latest round so far (1 when there is none).
    @discardableResult
    func addComment(
        submissionID: String,
        reviewer: String,
        comment: String,
        round: Int? = nil,
        draftLineRef: String = ""
    ) throws -> StoredReviewComment {

        let who = reviewer.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !who.isEmpty else { throw ModelError.invalidValue("reviewer name is empty") }
        guard !text.isEmpty else { throw ModelError.invalidValue("comment is empty") }
        if let round, round < 1 { throw ModelError.invalidValue("round must be 1 or more") }

        return try model.atomically {
            _ = try require(submissionID)

            let id = model.newID()
            let useRound = try round ?? currentRound(forSubmission: submissionID)

            try model.database.run(
                """
                INSERT INTO review_comments (id, submission_id, round, reviewer, comment, reply, state, draft_line_ref)
                VALUES (?, ?, ?, ?, ?, '', 'open', ?)
                """,
                [.text(id), .text(submissionID), .int(Int64(useRound)), .text(who), .text(text), .text(draftLineRef)]
            )

            let created = StoredReviewComment(
                id: id, submissionID: submissionID, round: useRound, reviewer: who, comment: text,
                reply: "", state: .open, draftLineRef: draftLineRef
            )
            try model.record("review_comment", id, .create, field: "review_comment", new: Self.snapshot(created))
            return created
        }
    }

    /// Oldest round first, then in the order they were added.
    func comments(forSubmission submissionID: String) throws -> [StoredReviewComment] {
        try model.database.rows(
            "SELECT * FROM review_comments WHERE submission_id = ? ORDER BY round, rowid",
            [.text(submissionID)]
        ).map { try Self.comment(from: $0) }
    }

    func comment(id: String) throws -> StoredReviewComment? {
        guard let row = try model.database.rows("SELECT * FROM review_comments WHERE id = ?", [.text(id)]).first else {
            return nil
        }
        return try Self.comment(from: row)
    }

    @discardableResult
    func setReply(commentID: String, to reply: String) throws -> StoredReviewComment {
        try model.atomically {
            let existing = try requireComment(commentID)
            if existing.reply == reply { return existing }

            try model.database.run("UPDATE review_comments SET reply = ? WHERE id = ?", [.text(reply), .text(commentID)])
            try model.record("review_comment", commentID, .update, field: "reply", old: existing.reply, new: reply)

            return StoredReviewComment(
                id: existing.id, submissionID: existing.submissionID, round: existing.round,
                reviewer: existing.reviewer, comment: existing.comment, reply: reply,
                state: existing.state, draftLineRef: existing.draftLineRef
            )
        }
    }

    @discardableResult
    func setState(commentID: String, to state: StoredReviewState) throws -> StoredReviewComment {
        try model.atomically {
            let existing = try requireComment(commentID)
            if existing.state == state { return existing }

            try model.database.run("UPDATE review_comments SET state = ? WHERE id = ?",
                                   [.text(state.rawValue), .text(commentID)])
            try model.record("review_comment", commentID, .update, field: "state",
                             old: existing.state.rawValue, new: state.rawValue)

            return StoredReviewComment(
                id: existing.id, submissionID: existing.submissionID, round: existing.round,
                reviewer: existing.reviewer, comment: existing.comment, reply: existing.reply,
                state: state, draftLineRef: existing.draftLineRef
            )
        }
    }

    func removeComment(id: String) throws {
        try model.atomically {
            let existing = try requireComment(id)
            try model.database.run("DELETE FROM review_comments WHERE id = ?", [.text(id)])
            try model.record("review_comment", id, .delete, field: "review_comment",
                             old: Self.snapshot(existing), new: nil)
        }
    }

    /// Comments still waiting for an answer (state "open").
    func openCommentCount(forSubmission submissionID: String) throws -> Int {
        Int(try model.database.scalarInt(
            "SELECT COUNT(*) FROM review_comments WHERE submission_id = ? AND state = 'open'",
            [.text(submissionID)]
        ) ?? 0)
    }

    /// The highest review round so far; 1 when there are no comments yet.
    func currentRound(forSubmission submissionID: String) throws -> Int {
        Int(try model.database.scalarInt(
            "SELECT MAX(round) FROM review_comments WHERE submission_id = ?",
            [.text(submissionID)]
        ) ?? 1)
    }

    // MARK: Helpers

    private func require(_ id: String) throws -> StoredSubmission {
        guard let found = try submission(id: id) else { throw ModelError.notFound(kind: "submission", id: id) }
        return found
    }

    private func requireComment(_ id: String) throws -> StoredReviewComment {
        guard let found = try comment(id: id) else { throw ModelError.notFound(kind: "review comment", id: id) }
        return found
    }

    private func requireDraft(_ draftID: String) throws {
        let found = try model.database.scalarInt(
            "SELECT 1 FROM drafts WHERE id = ? AND deleted_at IS NULL", [.text(draftID)]
        )
        if found == nil { throw ModelError.notFound(kind: "draft", id: draftID) }
    }

    /// Writes one column, reports it, and returns the submission with the change applied.
    /// `column` always comes from a fixed list in this file, never from user text.
    private func change(
        _ existing: StoredSubmission,
        field: String,
        column: String,
        value: SQLValue,
        old: String?,
        new: String?
    ) throws -> StoredSubmission {

        if old == new { return existing }

        try model.database.run("UPDATE submissions SET \(column) = ? WHERE id = ?", [value, .text(existing.id)])
        try model.record("submission", existing.id, .update, field: field, old: old, new: new)

        guard let updated = try submission(id: existing.id) else {
            throw ModelError.notFound(kind: "submission", id: existing.id)
        }
        return updated
    }

    /// Which stage sets which date. Dates that are already filled in stay as they are.
    private static func stamps(
        for stage: StoredSubmissionStage,
        submittedAt: String?,
        decisionAt: String?,
        now: String
    ) -> (submittedAt: String?, decisionAt: String?) {
        var submitted = submittedAt
        var decided = decisionAt
        switch stage {
        case .planned:
            break
        case .submitted, .underReview, .revision:
            if submitted == nil { submitted = now }
        case .accepted, .rejected, .published:
            if submitted == nil { submitted = now }
            if decided == nil { decided = now }
        }
        return (submitted, decided)
    }

    /// Accepts "2026-10-15" or full ISO-8601. nil and empty text both mean "no date".
    private static func cleanDate(_ text: String?, field: String) throws -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        guard parseDate(trimmed) != nil else { throw ModelError.invalidValue("\(field) is not a date") }
        return trimmed
    }

    private static func parseDate(_ text: String) -> Date? {
        // Plain day: 2026-10-15 (read as that day in the Mac's own time zone).
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        if text.count == 10, let date = day.date(from: text) { return date }

        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }

    /// Soonest deadline first; no deadline last; ties by venue name.
    private static func deadlineOrder(_ a: StoredSubmission, _ b: StoredSubmission) -> Bool {
        let first = a.deadline.flatMap { parseDate($0) }
        let second = b.deadline.flatMap { parseDate($0) }
        switch (first, second) {
        case let (x?, y?):
            if x != y { return x < y }
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            break
        }
        return a.venue.localizedCaseInsensitiveCompare(b.venue) == .orderedAscending
    }

    // MARK: Rows and snapshots

    static func submission(from row: SQLRow) throws -> StoredSubmission {
        guard let id = row.text("id"),
              let venue = row.text("venue"),
              let stageText = row.text("stage"), let stage = StoredSubmissionStage(rawValue: stageText) else {
            throw ModelError.invalidValue("submission row")
        }
        return StoredSubmission(
            id: id,
            draftID: row.text("draft_id"),
            venue: venue,
            deadline: row.text("deadline"),
            submittedAt: row.text("submitted_at"),
            decisionAt: row.text("decision_at"),
            stage: stage,
            url: row.text("url") ?? "",
            notes: row.text("notes") ?? ""
        )
    }

    static func comment(from row: SQLRow) throws -> StoredReviewComment {
        guard let id = row.text("id"),
              let submissionID = row.text("submission_id"),
              let reviewer = row.text("reviewer"),
              let comment = row.text("comment"),
              let stateText = row.text("state"), let state = StoredReviewState(rawValue: stateText) else {
            throw ModelError.invalidValue("review comment row")
        }
        return StoredReviewComment(
            id: id,
            submissionID: submissionID,
            round: Int(row.int("round") ?? 1),
            reviewer: reviewer,
            comment: comment,
            reply: row.text("reply") ?? "",
            state: state,
            draftLineRef: row.text("draft_line_ref") ?? ""
        )
    }

    private static func snapshot(_ item: StoredSubmission) -> String {
        LibraryModel.json([
            "id": item.id,
            "draft_id": item.draftID ?? NSNull(),
            "venue": item.venue,
            "deadline": item.deadline ?? NSNull(),
            "submitted_at": item.submittedAt ?? NSNull(),
            "decision_at": item.decisionAt ?? NSNull(),
            "stage": item.stage.rawValue,
            "url": item.url,
            "notes": item.notes
        ] as [String: Any])
    }

    private static func snapshot(_ item: StoredReviewComment) -> String {
        LibraryModel.json([
            "id": item.id,
            "submission_id": item.submissionID,
            "round": item.round,
            "reviewer": item.reviewer,
            "comment": item.comment,
            "reply": item.reply,
            "state": item.state.rawValue,
            "draft_line_ref": item.draftLineRef
        ] as [String: Any])
    }
}
