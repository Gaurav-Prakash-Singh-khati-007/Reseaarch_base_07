//
//  SubmissionStoreTests.swift
//  ResearchBase
//
//  Created by Gaurav Khati on 20/10/26.
//


//
//  SubmissionStoreTests.swift
//  ResearchBaseTests
//
//  Owner: Agent 18 · Features: F-38
//

import XCTest
@testable import ResearchBase

@MainActor
final class SubmissionStoreTests: XCTestCase {

    private func makeStore(sink: ChangeSink? = nil) throws -> (LibraryModel, SubmissionStore) {
        let model = try ModelTestSupport.makeModel(self, sink: sink)
        return (model, SubmissionStore(model: model))
    }

    // MARK: Create and read

    func testCreateStoresASubmissionWithDefaults() throws {
        let (model, store) = try makeStore()
        defer { model.library.close() }

        let created = try store.create(NewSubmission(venue: "  NeurIPS 2027  ", deadline: "2027-05-15"))

        XCTAssertEqual(created.venue, "NeurIPS 2027")
        XCTAssertEqual(created.stage, .planned)
        XCTAssertEqual(created.deadline, "2027-05-15")
        XCTAssertNil(created.submittedAt)
        XCTAssertNil(created.decisionAt)
        XCTAssertEqual(try store.submission(id: created.id), created)
        XCTAssertEqual(try store.count(), 1)
    }

    func testEmptyVenueIsRefused() throws {
        let (model, store) = try makeStore()
        defer { model.library.close() }

        XCTAssertThrowsError(try store.create(NewSubmission(venue: "   "))) {
            XCTAssertEqual($0 as? ModelError, .emptyName)
        }
        XCTAssertEqual(try store.count(), 0)
    }

    func testBadDateIsRefused() throws {
        let (model, store) = try makeStore()
        defer { model.library.close() }

        XCTAssertThrowsError(try store.create(NewSubmission(venue: "ICML", deadline: "next Tuesday")))
        XCTAssertEqual(try store.count(), 0)
    }

    func testDraftMustExist() throws {
        let (model, store) = try makeStore()
        defer { model.library.close() }

        XCTAssertThrowsError(try store.create(NewSubmission(venue: "ICML", draftID: "missing"))) {
            XCTAssertEqual($0 as? ModelError, .notFound(kind: "draft", id: "missing"))
        }

        let draftID = try ModelTestSupport.insertDraft(model)
        let created = try store.create(NewSubmission(venue: "ICML", draftID: draftID))
        XCTAssertEqual(try store.submissions(forDraft: draftID), [created])
    }

    func testAllIsSortedBySoonestDeadlineWithNoDeadlineLast() throws {
        let (model, store) = try makeStore()
        defer { model.library.close() }

        let none = try store.create(NewSubmission(venue: "Anywhere"))
        let late = try store.create(NewSubmission(venue: "Late", deadline: "2027-09-01"))
        let soon = try store.create(NewSubmission(venue: "Soon", deadline: "2027-01-10"))

        XCTAssertEqual(try store.all().map(\.id), [soon.id, late.id, none.id])
    }

    // MARK: Stages

    func testStageChangeFillsDatesOnceAndKeepsThem() throws {
        let (model, store) = try makeStore()
        defer { model.library.close() }

        let created = try store.create(NewSubmission(venue: "ACL"))

        let submitted = try store.setStage(id: created.id, to: .submitted)
        XCTAssertNotNil(submitted.submittedAt)
        XCTAssertNil(submitted.decisionAt)

        let accepted = try store.setStage(id: created.id, to: .accepted)
        XCTAssertEqual(accepted.submittedAt, submitted.submittedAt)
        XCTAssertNotNil(accepted.decisionAt)

        let back = try store.setStage(id: created.id, to: .revision)
        XCTAssertEqual(back.submittedAt, submitted.submittedAt)
        XCTAssertEqual(back.decisionAt, accepted.decisionAt)
        XCTAssertEqual(try store.submissions(inStage: .revision).count, 1)
    }

    func testSettersChangeOneFieldAndReportIt() throws {
        let sink = RecordingChangeSink()
        let (model, store) = try makeStore(sink: sink)
        defer { model.library.close() }

        let created = try store.create(NewSubmission(venue: "ACL"))
        sink.clear()

        try store.setVenue(id: created.id, to: "ACL 2027")
        try store.setURL(id: created.id, to: " https://example.org ")
        try store.setNotes(id: created.id, to: "Check page limit")
        let updated = try store.setDeadline(id: created.id, to: "2027-02-01")

        XCTAssertEqual(updated.venue, "ACL 2027")
        XCTAssertEqual(updated.url, "https://example.org")
        XCTAssertEqual(updated.notes, "Check page limit")
        XCTAssertEqual(updated.deadline, "2027-02-01")
        XCTAssertEqual(sink.entries(type: "submission", action: .update).map(\.field),
                       ["venue", "url", "notes", "deadline"])

        // Same value again: nothing is written or reported.
        sink.clear()
        try store.setVenue(id: created.id, to: "ACL 2027")
        XCTAssertTrue(sink.entries.isEmpty)

        // Clearing a deadline.
        XCTAssertNil(try store.setDeadline(id: created.id, to: nil).deadline)
    }

    func testUpcomingDeadlinesOnlyPlannedAndRevisionNotPast() throws {
        let (model, store) = try makeStore()
        defer { model.library.close() }

        let now = ISO8601DateFormatter().date(from: "2027-03-10T12:00:00Z")!

        let past = try store.create(NewSubmission(venue: "Past", deadline: "2027-03-01"))
        let soon = try store.create(NewSubmission(venue: "Soon", deadline: "2027-03-20"))
        let far = try store.create(NewSubmission(venue: "Far", deadline: "2027-08-01"))
        let sent = try store.create(NewSubmission(venue: "Sent", deadline: "2027-03-15", stage: .submitted))
        _ = try store.create(NewSubmission(venue: "NoDate"))

        let all = try store.upcomingDeadlines(from: now).map(\.id)
        XCTAssertEqual(all, [soon.id, far.id])
        XCTAssertFalse(all.contains(past.id))
        XCTAssertFalse(all.contains(sent.id))

        XCTAssertEqual(try store.upcomingDeadlines(from: now, withinDays: 14).map(\.id), [soon.id])
    }

    // MARK: Review comments

    func testCommentsReplyStateAndRounds() throws {
        let (model, store) = try makeStore()
        defer { model.library.close() }

        let sub = try store.create(NewSubmission(venue: "ACL"))
        XCTAssertEqual(try store.currentRound(forSubmission: sub.id), 1)

        let first = try store.addComment(submissionID: sub.id, reviewer: "Reviewer 2",
                                         comment: "Missing baseline.", draftLineRef: "main.tex:120")
        XCTAssertEqual(first.round, 1)
        XCTAssertEqual(first.state, .open)
        XCTAssertEqual(try store.openCommentCount(forSubmission: sub.id), 1)

        let answered = try store.setReply(commentID: first.id, to: "Added in Table 3.")
        XCTAssertEqual(answered.reply, "Added in Table 3.")
        let done = try store.setState(commentID: first.id, to: .addressed)
        XCTAssertEqual(done.state, .addressed)
        XCTAssertEqual(try store.openCommentCount(forSubmission: sub.id), 0)

        let second = try store.addComment(submissionID: sub.id, reviewer: "Reviewer 1",
                                          comment: "Clarify Section 4.", round: 2)
        XCTAssertEqual(try store.currentRound(forSubmission: sub.id), 2)
        XCTAssertEqual(try store.comments(forSubmission: sub.id).map(\.id), [first.id, second.id])
    }

    func testBlankCommentOrReviewerAndMissingSubmissionAreRefused() throws {
        let (model, store) = try makeStore()
        defer { model.library.close() }

        let sub = try store.create(NewSubmission(venue: "ACL"))

        XCTAssertThrowsError(try store.addComment(submissionID: sub.id, reviewer: " ", comment: "x"))
        XCTAssertThrowsError(try store.addComment(submissionID: sub.id, reviewer: "R1", comment: " "))
        XCTAssertThrowsError(try store.addComment(submissionID: sub.id, reviewer: "R1", comment: "x", round: 0))
        XCTAssertThrowsError(try store.addComment(submissionID: "nope", reviewer: "R1", comment: "x"))
        XCTAssertEqual(try ModelTestSupport.count(model, "review_comments"), 0)
    }

    func testRemoveSubmissionRemovesItsCommentsAndReportsThem() throws {
        let sink = RecordingChangeSink()
        let (model, store) = try makeStore(sink: sink)
        defer { model.library.close() }

        let sub = try store.create(NewSubmission(venue: "ACL"))
        let note = try store.addComment(submissionID: sub.id, reviewer: "R1", comment: "Fix figure 2.")
        let keep = try store.create(NewSubmission(venue: "ICML"))
        sink.clear()

        try store.remove(id: sub.id)

        XCTAssertNil(try store.submission(id: sub.id))
        XCTAssertNil(try store.comment(id: note.id))
        XCTAssertNotNil(try store.submission(id: keep.id))
        XCTAssertEqual(sink.entries(type: "review_comment", action: .delete).count, 1)
        XCTAssertEqual(sink.entries(type: "submission", action: .delete).count, 1)
        XCTAssertThrowsError(try store.remove(id: sub.id))
    }

    func testRemoveSingleComment() throws {
        let (model, store) = try makeStore()
        defer { model.library.close() }

        let sub = try store.create(NewSubmission(venue: "ACL"))
        let note = try store.addComment(submissionID: sub.id, reviewer: "R1", comment: "Fix figure 2.")

        try store.removeComment(id: note.id)
        XCTAssertTrue(try store.comments(forSubmission: sub.id).isEmpty)
    }

    // MARK: A failed write changes nothing

    func testFailedChangeSinkUndoesTheCreate() throws {
        let (model, store) = try makeStore(sink: FailingChangeSink(failOnCall: 0))
        defer { model.library.close() }

        XCTAssertThrowsError(try store.create(NewSubmission(venue: "ACL")))
        XCTAssertEqual(try store.count(), 0)
    }
}