//
//  SubmissionsViewTests.swift
//  ResearchBaseTests
//
//  Owner: Agent 64. Tests the pure logic behind SubmissionsView (RBA64Logic) and the
//  mapping between stored rows and screen models. No database and no UI needed.
//

import XCTest
@testable import ResearchBase

final class SubmissionsViewTests: XCTestCase {

    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// Midday on the given day, so "today" never sits on a day boundary.
    private func noon(_ day: String) -> Date {
        RBA64Logic.parseDay(day, calendar: calendar)!.addingTimeInterval(12 * 3600)
    }

    // MARK: Days text

    func testDaysUntilCountsWholeCalendarDays() {
        let now = noon("2026-10-15")
        XCTAssertEqual(RBA64Logic.daysUntil("2026-10-15", now: now, calendar: calendar), 0)
        XCTAssertEqual(RBA64Logic.daysUntil("2026-10-29", now: now, calendar: calendar), 14)
        XCTAssertEqual(RBA64Logic.daysUntil("2026-10-10", now: now, calendar: calendar), -5)
    }

    func testDaysTextWording() {
        let now = noon("2026-10-15")
        func text(_ d: String) -> String { RBA64Logic.daysText(d, now: now, calendar: calendar) }
        XCTAssertEqual(text("2026-10-15"), "today")
        XCTAssertEqual(text("2026-10-16"), "in 1 day")
        XCTAssertEqual(text("2026-10-29"), "in 14 days")
        XCTAssertEqual(text("2026-10-14"), "1 day ago")
        XCTAssertEqual(text("2026-09-24"), "21 days ago")
    }

    func testDaysTextForMissingOrUnreadableDeadline() {
        let now = noon("2026-10-15")
        XCTAssertEqual(RBA64Logic.daysText("", now: now, calendar: calendar), "No deadline")
        XCTAssertEqual(RBA64Logic.daysText("   ", now: now, calendar: calendar), "No deadline")
        XCTAssertEqual(RBA64Logic.daysText("soon", now: now, calendar: calendar), "soon")
    }

    func testFullISODeadlineIsAccepted() {
        let now = noon("2026-10-15")
        XCTAssertEqual(RBA64Logic.daysUntil("2026-10-20T09:00:00Z", now: now, calendar: calendar), 5)
        XCTAssertEqual(RBA64Logic.daysUntil("2026-10-20T09:00:00.250Z", now: now, calendar: calendar), 5)
    }

    func testDayStringRoundTrip() {
        let date = RBA64Logic.parseDay("2026-12-01", calendar: calendar)!
        XCTAssertEqual(RBA64Logic.dayString(date, calendar: calendar), "2026-12-01")
    }

    // MARK: Stage progress

    func testProgressBarFillsUpToCurrentStage() {
        XCTAssertTrue(RBA64Logic.isStageActive(.planned, current: .underReview))
        XCTAssertTrue(RBA64Logic.isStageActive(.underReview, current: .underReview))
        XCTAssertFalse(RBA64Logic.isStageActive(.revision, current: .underReview))
        XCTAssertTrue(RBA64Logic.isStageActive(.published, current: .published))
    }

    func testRejectedStopsAfterUnderReviewAndIsNotAStep() {
        XCTAssertFalse(RBA64Logic.stageOrder.contains(.rejected))
        XCTAssertTrue(RBA64Logic.isStageActive(.underReview, current: .rejected))
        XCTAssertFalse(RBA64Logic.isStageActive(.revision, current: .rejected))
        XCTAssertFalse(RBA64Logic.isStageActive(.accepted, current: .rejected))
    }

    func testStageMappingRoundTripsForEveryStoredStage() {
        for stored in StoredSubmissionStage.allCases {
            XCTAssertEqual(SubmissionStage(stored).stored, stored)
        }
        for state in StoredReviewState.allCases {
            XCTAssertEqual(ReviewerCommentStatus(state).stored, state)
        }
    }

    // MARK: LaTeX

    func testLatexEscapeHandlesSpecialCharacters() {
        XCTAssertEqual(RBA64Logic.latexEscape("50% & $5 #1 a_b {x}"), ##"50\% \& \$5 \#1 a\_b \{x\}"##)
        XCTAssertEqual(RBA64Logic.latexEscape("~ ^"), #"\textasciitilde{} \textasciicircum{}"#)
        XCTAssertEqual(RBA64Logic.latexEscape(#"a\b"#), #"a\textbackslash{}b"#)
    }

    func testLatexEscapeDoesNotDoubleEscape() {
        // The backslash that starts an escape must not itself be escaped again.
        XCTAssertEqual(RBA64Logic.latexEscape("%"), #"\%"#)
    }

    // MARK: Response letter

    private func comment(_ reviewer: String, _ text: String, reply: String = "",
                         round: Int = 1, ref: String = "") -> ReviewerCommentModel {
        ReviewerCommentModel(reviewer: reviewer, comment: text, reply: reply,
                             status: .open, draftLineRef: ref, round: round)
    }

    func testResponseLetterGroupsByReviewerInOrderOfAppearance() {
        let letter = RBA64Logic.responseLetter(venue: "MLSys 2027", comments: [
            comment("Reviewer 2", "B1"),
            comment("Reviewer 1", "A1"),
            comment("Reviewer 2", "B2"),
        ])
        let r2 = letter.range(of: #"\subsection*{Reviewer 2}"#)!
        let r1 = letter.range(of: #"\subsection*{Reviewer 1}"#)!
        XCTAssertTrue(r2.lowerBound < r1.lowerBound)
        XCTAssertTrue(letter.contains(#"\paragraph{Comment 1.1.}"#))
        XCTAssertTrue(letter.contains(#"\paragraph{Comment 1.2.}"#))
        XCTAssertTrue(letter.contains(#"\paragraph{Comment 2.1.}"#))
    }

    func testResponseLetterUsesLatestRoundByDefault() {
        let comments = [comment("Reviewer 1", "OLDTEXT", round: 1), comment("Reviewer 1", "NEWTEXT", round: 2)]
        let letter = RBA64Logic.responseLetter(venue: "V", comments: comments)
        XCTAssertTrue(letter.contains("NEWTEXT"))
        XCTAssertFalse(letter.contains("OLDTEXT"))
        XCTAssertTrue(letter.contains(#"\textbf{Round:} 2"#))

        let first = RBA64Logic.responseLetter(venue: "V", comments: comments, round: 1)
        XCTAssertTrue(first.contains("OLDTEXT"))
        XCTAssertFalse(first.contains("NEWTEXT"))
    }

    func testResponseLetterMarksMissingRepliesAndEscapesText() {
        let letter = RBA64Logic.responseLetter(venue: "A & B", comments: [
            comment("Reviewer 1", "Report 95% CI", reply: ""),
            comment("Reviewer 1", "Second", reply: "Done in main.tex", ref: "main.tex:41"),
        ])
        XCTAssertTrue(letter.contains(#"Report 95\% CI"#))
        XCTAssertTrue(letter.contains("(No reply written yet.)"))
        XCTAssertTrue(letter.contains(#"A \& B"#))
        XCTAssertTrue(letter.contains(#"Changed in main.tex:41."#))
    }

    func testResponseLetterIsAValidLatexShell() {
        let letter = RBA64Logic.responseLetter(venue: "V", comments: [comment("R1", "c")])
        XCTAssertTrue(letter.hasPrefix("% Response to reviewers"))
        XCTAssertTrue(letter.contains(#"\begin{document}"#))
        XCTAssertTrue(letter.hasSuffix("\\end{document}\n"))
    }

    func testResponseLetterWithNoCommentsStillBuilds() {
        let letter = RBA64Logic.responseLetter(venue: "V", comments: [])
        XCTAssertTrue(letter.contains(#"\end{document}"#))
        XCTAssertFalse(letter.contains(#"\subsection*"#))
    }

    // MARK: Stored row -> screen model

    func testModelFromStoredRowWithoutDraftOrDeadline() {
        let stored = StoredSubmission(id: "s1", draftID: nil, venue: "ICLR 2027", deadline: nil,
                                      submittedAt: nil, decisionAt: nil, stage: .planned, url: "", notes: "")
        let model = SubmissionModel(stored: stored, draftTitle: nil, comments: [])
        XCTAssertEqual(model.draftName, "No draft linked")
        XCTAssertEqual(model.deadline, "")
        XCTAssertEqual(model.round, 0)
        XCTAssertNil(model.draftID)
    }

    func testModelFromStoredRowKeepsCommentsAndLatestRound() {
        let stored = StoredSubmission(id: "s1", draftID: "d1", venue: "V", deadline: "2026-10-29",
                                      submittedAt: "2026-10-01T00:00:00Z", decisionAt: nil,
                                      stage: .underReview, url: "https://x", notes: "n")
        let comments = [
            StoredReviewComment(id: "c1", submissionID: "s1", round: 1, reviewer: "R1", comment: "a",
                                reply: "r", state: .addressed, draftLineRef: "main.tex:3"),
            StoredReviewComment(id: "c2", submissionID: "s1", round: 2, reviewer: "R2", comment: "b",
                                reply: "", state: .disagree, draftLineRef: ""),
        ]
        let model = SubmissionModel(stored: stored, draftTitle: "My paper", comments: comments)
        XCTAssertEqual(model.draftName, "My paper")
        XCTAssertEqual(model.round, 2)
        XCTAssertEqual(model.stage, .underReview)
        XCTAssertEqual(model.reviewerComments.map(\.id), ["c1", "c2"])
        XCTAssertEqual(model.reviewerComments[0].status, .addressed)
        XCTAssertEqual(model.reviewerComments[1].status, .disagree)
        XCTAssertEqual(model.submittedAt, "2026-10-01T00:00:00Z")
    }
}
