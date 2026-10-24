//
//  ReminderSchedulerTests.swift
//  ResearchBaseTests
//
//  Owner: Agent 32 · F-46. Uses a fake notification center, so no real notification is shown.
//

import XCTest
@testable import ResearchBase

private final class FakeCenter: ReminderNotificationCenter {
    var authorized = true
    var added: [String: ReminderNotice] = [:]
    var failIdentifiers: Set<String> = []

    func requestAuthorization() async -> Bool { authorized }
    func isAuthorized() async -> Bool { authorized }
    func pendingIdentifiers() async -> [String] { added.values.filter { $0.fireDate != nil }.map(\.identifier) }
    func add(_ notice: ReminderNotice) async throws {
        struct Refused: Error {}
        if failIdentifiers.contains(notice.identifier) { throw Refused() }
        added[notice.identifier] = notice
    }
    func remove(identifiers: [String]) async { identifiers.forEach { added[$0] = nil } }
}

@MainActor
final class ReminderSchedulerTests: XCTestCase {

    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }()

    /// 2026-10-15 12:00 UTC
    private var now: Date { date(2026, 10, 15, 12) }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func make(_ center: FakeCenter = FakeCenter(), sink: ChangeSink? = nil) throws
        -> (LibraryModel, ReminderScheduler, FakeCenter) {
        let model = try ModelTestSupport.makeModel(self, sink: sink)
        let scheduler = ReminderScheduler(model: model, center: center, calendar: calendar, clock: { self.date(2026, 10, 15, 12) })
        return (model, scheduler, center)
    }

    @discardableResult
    private func addTask(
        _ model: LibraryModel, title: String = "Read paper", due: String? = nil, remind: String? = nil,
        status: String = "todo", project: String? = nil, deleted: Bool = false
    ) throws -> String {
        let id = UUID().uuidString
        let nowText = Library.nowISO()
        var projectID: String?
        if let project {
            projectID = UUID().uuidString
            try model.database.run(
                "INSERT INTO projects (id, name, created_at, updated_at) VALUES (?, ?, ?, ?)",
                [.text(projectID!), .text(project), .text(nowText), .text(nowText)])
        }
        try model.database.run(
            "INSERT INTO tasks (id, project_id, title, status, due_at, remind_at, created_at, updated_at, deleted_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            [.text(id), LibraryModel.text(projectID), .text(title), .text(status), LibraryModel.text(due),
             LibraryModel.text(remind), .text(nowText), .text(nowText), LibraryModel.text(deleted ? nowText : nil)])
        return id
    }

    @discardableResult
    private func addSubmission(
        _ model: LibraryModel, venue: String = "NeurIPS", deadline: String?, stage: String = "planned", draftID: String? = nil
    ) throws -> String {
        let id = UUID().uuidString
        try model.database.run(
            "INSERT INTO submissions (id, draft_id, venue, deadline, stage) VALUES (?, ?, ?, ?, ?)",
            [.text(id), LibraryModel.text(draftID), .text(venue), LibraryModel.text(deadline), .text(stage)])
        return id
    }

    // MARK: Tasks

    func testTaskGetsReminderTheDayBeforeAndOnTheDueDateAt0900() throws {
        let (model, scheduler, _) = try make()
        defer { model.library.close() }
        let id = try addTask(model, due: "2026-10-20")

        let plan = try scheduler.plan(now: now)

        XCTAssertEqual(plan.map(\.fireDate), [date(2026, 10, 19, 9), date(2026, 10, 20, 9)])
        XCTAssertEqual(plan.map(\.title), ["Task due tomorrow", "Task due today"])
        XCTAssertTrue(plan.allSatisfy { $0.kind == .task && $0.recordID == id })
    }

    func testDueDateWithATimeUsesItsLocalDay() throws {
        let (model, scheduler, _) = try make()
        defer { model.library.close() }
        try addTask(model, due: "2026-10-20T17:30:00Z")

        XCTAssertEqual(try scheduler.plan(now: now).map(\.fireDate), [date(2026, 10, 19, 9), date(2026, 10, 20, 9)])
    }

    func testPastRemindersAreSkipped() throws {
        let (model, scheduler, _) = try make()
        defer { model.library.close() }
        try addTask(model, due: "2026-10-16")          // day before = 15 Oct 09:00, already past at noon
        try addTask(model, due: "2026-10-01")          // long overdue

        XCTAssertEqual(try scheduler.plan(now: now).map(\.fireDate), [date(2026, 10, 16, 9)])
    }

    func testDoneDeletedAndDatelessTasksGetNothing() throws {
        let (model, scheduler, _) = try make()
        defer { model.library.close() }
        try addTask(model, due: "2026-10-20", status: "done")
        try addTask(model, due: "2026-10-20", deleted: true)
        try addTask(model, due: nil)

        XCTAssertTrue(try scheduler.plan(now: now).isEmpty)
    }

    func testRemindAtAddsAnExactTimeReminder() throws {
        let (model, scheduler, _) = try make()
        defer { model.library.close() }
        try addTask(model, due: nil, remind: "2026-10-17T14:45:00Z")

        let plan = try scheduler.plan(now: now)
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan[0].fireDate, date(2026, 10, 17, 14, 45))
        XCTAssertEqual(plan[0].title, "Reminder")
    }

    func testTaskBodyNamesTheProject() throws {
        let (model, scheduler, _) = try make()
        defer { model.library.close() }
        try addTask(model, title: "Write intro", due: "2026-10-20", project: "Thesis")

        XCTAssertEqual(try scheduler.plan(now: now).first?.body, "Write intro · Thesis")
    }

    // MARK: Submissions

    func testSubmissionDeadlineRemindsAt14And3And1DaysBefore() throws {
        let (model, scheduler, _) = try make()
        defer { model.library.close() }
        let draft = try ModelTestSupport.insertDraft(model)
        try addSubmission(model, venue: "ICML", deadline: "2026-11-10", draftID: draft)

        let plan = try scheduler.plan(now: now)

        XCTAssertEqual(plan.map(\.fireDate), [date(2026, 10, 27, 9), date(2026, 11, 7, 9), date(2026, 11, 9, 9)])
        XCTAssertEqual(plan.map(\.title), [
            "Submission deadline in 14 days", "Submission deadline in 3 days", "Submission deadline tomorrow"])
        XCTAssertEqual(plan[0].body, "ICML · My paper")
    }

    func testOnlyPlannedAndRevisionSubmissionsRemind() throws {
        let (model, scheduler, _) = try make()
        defer { model.library.close() }
        for stage in ["submitted", "under_review", "accepted", "rejected", "published"] {
            try addSubmission(model, deadline: "2026-11-10", stage: stage)
        }
        XCTAssertTrue(try scheduler.plan(now: now).isEmpty)

        try addSubmission(model, deadline: "2026-11-10", stage: "revision")
        XCTAssertEqual(try scheduler.plan(now: now).count, 3)
    }

    func testSubmissionOfATrashedDraftOrWithoutDeadlineIsIgnored() throws {
        let (model, scheduler, _) = try make()
        defer { model.library.close() }
        let draft = try ModelTestSupport.insertDraft(model)
        try model.database.run("UPDATE drafts SET deleted_at = ? WHERE id = ?", [.text(Library.nowISO()), .text(draft)])
        try addSubmission(model, deadline: "2026-11-10", draftID: draft)
        try addSubmission(model, deadline: nil)

        XCTAssertTrue(try scheduler.plan(now: now).isEmpty)
    }

    func testPlanIsSoonestFirstAndCappedAt64() throws {
        let (model, scheduler, _) = try make()
        defer { model.library.close() }
        let start = date(2026, 12, 1)
        for offset in 0..<40 {   // 80 reminders
            let due = calendar.date(byAdding: .day, value: offset, to: start)!
            let c = calendar.dateComponents([.year, .month, .day], from: due)
            try addTask(model, due: String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!))
        }

        let plan = try scheduler.plan(now: now)
        XCTAssertEqual(plan.count, ReminderScheduler.maxPending)
        XCTAssertEqual(plan.map(\.fireDate), plan.map(\.fireDate).sorted { ($0 ?? .distantPast) < ($1 ?? .distantPast) })
    }

    // MARK: Sync

    func testSyncSchedulesRemovesStaleAndIsRepeatable() async throws {
        let (model, scheduler, center) = try make()
        defer { model.library.close() }
        let id = try addTask(model, due: "2026-10-20")

        var result = try await scheduler.sync()
        XCTAssertEqual(result.outcome, .scheduled)
        XCTAssertEqual(result.scheduled, 2)
        XCTAssertEqual(center.added.count, 2)

        result = try await scheduler.sync()
        XCTAssertEqual(result.removed, 0)
        XCTAssertEqual(center.added.count, 2)

        // The task is finished: its reminders go away.
        try model.database.run("UPDATE tasks SET status = 'done' WHERE id = ?", [.text(id)])
        result = try await scheduler.sync()
        XCTAssertEqual(result.removed, 2)
        XCTAssertTrue(center.added.isEmpty)
    }

    func testSyncCountsRefusedReminders() async throws {
        let (model, scheduler, center) = try make()
        defer { model.library.close() }
        try addTask(model, due: "2026-10-20")
        center.failIdentifiers = Set(try scheduler.plan(now: now).prefix(1).map(\.identifier))

        let result = try await scheduler.sync()

        XCTAssertEqual(result.failed, 1)
        XCTAssertEqual(result.scheduled, 1)
    }

    func testSyncDoesNothingWithoutPermissionAndClearsWhenSwitchedOff() async throws {
        let (model, scheduler, center) = try make()
        defer { model.library.close() }
        try addTask(model, due: "2026-10-20")
        _ = try await scheduler.sync()
        XCTAssertEqual(center.added.count, 2)

        center.authorized = false
        let denied = try await scheduler.sync()
        XCTAssertEqual(denied.outcome, .notAuthorized)
        XCTAssertEqual(center.added.count, 2, "nothing is changed without permission")

        center.authorized = true
        try scheduler.setSettings(ReminderSettings(enabled: false, backupAlerts: true))
        let off = try await scheduler.sync()
        XCTAssertEqual(off.outcome, .disabled)
        XCTAssertEqual(off.removed, 2)
        XCTAssertTrue(center.added.isEmpty)
    }

    func testSyncLeavesOtherAppsNotificationsAlone() async throws {
        let (model, scheduler, center) = try make()
        defer { model.library.close() }
        center.added["something.else"] = ReminderNotice(
            identifier: "something.else", kind: .task, recordID: "x", title: "t", body: "b", fireDate: now)

        _ = try await scheduler.sync()

        XCTAssertNotNil(center.added["something.else"])
    }

    // MARK: Settings and backup alerts

    func testSettingsDefaultOnAndPersist() throws {
        let (model, scheduler, _) = try make()
        defer { model.library.close() }

        XCTAssertEqual(try scheduler.settings(), ReminderSettings(enabled: true, backupAlerts: true))
        try scheduler.setSettings(ReminderSettings(enabled: true, backupAlerts: false))
        XCTAssertEqual(try scheduler.settings(), ReminderSettings(enabled: true, backupAlerts: false))
    }

    func testBackupProblemNotificationRespectsSettingsAndPermission() async throws {
        let (model, scheduler, center) = try make()
        defer { model.library.close() }

        let shown = await scheduler.notifyBackupProblem("The disk is full.")
        XCTAssertTrue(shown)
        XCTAssertEqual(center.added.values.first?.kind, .backup)
        XCTAssertNil(center.added.values.first?.fireDate, "shown at once")

        try scheduler.setSettings(ReminderSettings(enabled: true, backupAlerts: false))
        let off = await scheduler.notifyBackupProblem("again")
        XCTAssertFalse(off)

        try scheduler.setSettings(ReminderSettings())
        center.authorized = false
        let denied = await scheduler.notifyBackupProblem("again")
        XCTAssertFalse(denied)
    }

    // MARK: Home

    func testUpcomingListsTasksAndSubmissionsSoonestFirst() throws {
        let (model, scheduler, _) = try make()
        defer { model.library.close() }
        let draft = try ModelTestSupport.insertDraft(model)
        try addTask(model, title: "Due in 3", due: "2026-10-18")
        try addTask(model, title: "Overdue", due: "2026-10-10")
        try addTask(model, title: "Too far", due: "2026-11-30")
        try addTask(model, title: "Today", due: "2026-10-15")
        try addSubmission(model, venue: "ICML", deadline: "2026-10-17", draftID: draft)

        let list = try scheduler.upcoming(days: 7, now: now)

        XCTAssertEqual(list.map(\.title), ["Today", "ICML", "Due in 3"])
        XCTAssertEqual(list.map(\.daysLeft), [0, 2, 3])
        XCTAssertEqual(list[1].kind, .submission)
        XCTAssertEqual(list[1].detail, "My paper")

        let withOverdue = try scheduler.upcoming(days: 7, includeOverdue: true, now: now)
        XCTAssertEqual(withOverdue.first?.title, "Overdue")
        XCTAssertEqual(withOverdue.first?.daysLeft, -5)
    }
}
