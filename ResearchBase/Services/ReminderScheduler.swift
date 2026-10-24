//
//  ReminderScheduler.swift
//  ResearchBase
//
//  Owner: Agent 32 · Features: F-46
//
//  Task due dates and submission deadlines become Mac notifications that are
//  scheduled with macOS, so they still arrive when the app is closed.
//
//    Tasks (open, not in the Trash) with a due date:
//        09:00 on the day before, and 09:00 on the due date.
//        If the task has `remind_at`, one more reminder at that exact time.
//    Submissions (stage "planned" or "revision") with a deadline:
//        09:00, 14 days, 3 days and 1 day before the deadline.
//    Backup problems:
//        `notifyBackupProblem` shows one at once (the F-49 toggle in the Reminders sheet).
//
//  Dates in the library are UTC ISO-8601 text. A date without a time ("2026-11-03")
//  means that calendar day in the person's time zone.
//
//  PUBLIC API
//    protocol ReminderNotificationCenter       the part of macOS this file needs (fakeable)
//    final class SystemReminderCenter          the real one (UserNotifications)
//    struct ReminderNotice, ReminderSettings, UpcomingDeadline, ReminderSyncResult
//    ReminderScheduler(model:center:calendar:clock:)
//        settings() / setSettings(_:)          stored in `meta` (reminders_enabled, reminders_backup_alerts)
//        requestPermission() async -> Bool
//        plan(now:) -> [ReminderNotice]        pure read; what sync would schedule
//        sync() async throws -> ReminderSyncResult     call at launch and after any task / submission change
//        clearAll() async
//        upcoming(days:includeOverdue:) -> [UpcomingDeadline]     for Home "Coming up" / "Due this week"
//        notifyBackupProblem(_:) async -> Bool
//    static let identifierPrefix = "rb.reminder."
//    Notification userInfo: ["rbKind": "task" | "submission" | "backup", "rbID": <record id>]
//
//  Choices made (the spec leaves these open)
//    * Every open task with a due date gets the two default reminders; `remind_at` adds a third.
//    * macOS keeps at most 64 pending notifications, so the 64 soonest are scheduled;
//      the next `sync()` (launch) fills in the rest.
//

import Foundation
import UserNotifications

// MARK: - Values

struct ReminderNotice: Equatable {
    enum Kind: String, Equatable { case task, submission, backup }

    let identifier: String
    let kind: Kind
    let recordID: String
    let title: String
    let body: String
    /// nil = show now.
    let fireDate: Date?
}

struct ReminderSettings: Equatable {
    /// "Allow Mac notifications".
    var enabled = true
    /// "Tell me if a backup fails".
    var backupAlerts = true
}

struct UpcomingDeadline: Equatable, Identifiable {
    enum Kind: String, Equatable { case task, submission }

    let kind: Kind
    let recordID: String
    let title: String
    /// Project name, or venue and draft.
    let detail: String
    /// The due day (start of day) or the exact due time.
    let date: Date
    /// Whole calendar days from today; 0 = today, negative = overdue.
    let daysLeft: Int

    var id: String { "\(kind.rawValue)-\(recordID)" }
}

struct ReminderSyncResult: Equatable {
    enum Outcome: Equatable {
        case scheduled
        case disabled          // switched off in settings; pending reminders were removed
        case notAuthorized     // macOS has not allowed notifications; nothing was changed
    }

    var outcome: Outcome
    var scheduled = 0
    var removed = 0
    /// Reminders macOS refused.
    var failed = 0
}

// MARK: - The part of macOS used here

protocol ReminderNotificationCenter: AnyObject {
    func requestAuthorization() async -> Bool
    func isAuthorized() async -> Bool
    func pendingIdentifiers() async -> [String]
    /// Adds (or replaces, same identifier) a notification.
    func add(_ notice: ReminderNotice) async throws
    func remove(identifiers: [String]) async
}

final class SystemReminderCenter: ReminderNotificationCenter {

    private let calendar: Calendar

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func isAuthorized() async -> Bool {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional: return true
        default: return false
        }
    }

    func pendingIdentifiers() async -> [String] {
        await center.pendingNotificationRequests().map(\.identifier)
    }

    func add(_ notice: ReminderNotice) async throws {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.sound = .default
        content.userInfo = ["rbKind": notice.kind.rawValue, "rbID": notice.recordID]

        let trigger: UNNotificationTrigger
        if let date = notice.fireDate {
            let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
        } else {
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        }
        try await center.add(UNNotificationRequest(identifier: notice.identifier, content: content, trigger: trigger))
    }

    func remove(identifiers: [String]) async {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }
}

// MARK: - Scheduler

final class ReminderScheduler {

    static let identifierPrefix = "rb.reminder."
    static let enabledKey = "reminders_enabled"
    static let backupAlertsKey = "reminders_backup_alerts"

    /// Hour of day (local) for task and submission reminders.
    static let reminderHour = 9
    static let taskDaysBefore = [1, 0]
    static let submissionDaysBefore = [14, 3, 1]
    static let maxPending = 64

    let model: LibraryModel
    private let center: ReminderNotificationCenter
    private let calendar: Calendar
    private let clock: () -> Date

    init(
        model: LibraryModel,
        center: ReminderNotificationCenter? = nil,
        calendar: Calendar = .current,
        clock: @escaping () -> Date = { Date() }
    ) {
        self.model = model
        self.center = center ?? SystemReminderCenter(calendar: calendar)
        self.calendar = calendar
        self.clock = clock
    }

    // MARK: Settings

    func settings() throws -> ReminderSettings {
        ReminderSettings(
            enabled: try flag(Self.enabledKey, default: true),
            backupAlerts: try flag(Self.backupAlertsKey, default: true)
        )
    }

    func setSettings(_ settings: ReminderSettings) throws {
        try model.atomically {
            try setFlag(Self.enabledKey, settings.enabled)
            try setFlag(Self.backupAlertsKey, settings.backupAlerts)
        }
    }

    /// Asks macOS (shows the system prompt the first time).
    func requestPermission() async -> Bool {
        await center.requestAuthorization()
    }

    // MARK: Plan

    /// Everything that should be scheduled, soonest first, at most `maxPending`.
    /// Reads the library only. Reminders in the past are left out.
    func plan(now: Date? = nil) throws -> [ReminderNotice] {
        let now = now ?? clock()
        var notices: [ReminderNotice] = []

        for task in try openTasks() {
            if let due = task.due {
                let day = calendar.startOfDay(for: due)
                for before in Self.taskDaysBefore {
                    guard let fire = reminderTime(day: day, daysBefore: before), fire > now else { continue }
                    notices.append(ReminderNotice(
                        identifier: "\(Self.identifierPrefix)task.\(task.id).d\(before)",
                        kind: .task, recordID: task.id,
                        title: before == 0 ? "Task due today" : "Task due tomorrow",
                        body: task.body, fireDate: fire))
                }
            }
            if let remind = task.remind, remind > now {
                notices.append(ReminderNotice(
                    identifier: "\(Self.identifierPrefix)task.\(task.id).remind",
                    kind: .task, recordID: task.id, title: "Reminder", body: task.body, fireDate: remind))
            }
        }

        for sub in try activeSubmissions() {
            let day = calendar.startOfDay(for: sub.deadline)
            for before in Self.submissionDaysBefore {
                guard let fire = reminderTime(day: day, daysBefore: before), fire > now else { continue }
                notices.append(ReminderNotice(
                    identifier: "\(Self.identifierPrefix)submission.\(sub.id).d\(before)",
                    kind: .submission, recordID: sub.id,
                    title: before == 1 ? "Submission deadline tomorrow" : "Submission deadline in \(before) days",
                    body: sub.body, fireDate: fire))
            }
        }

        notices.sort {
            ($0.fireDate ?? .distantPast, $0.identifier) < ($1.fireDate ?? .distantPast, $1.identifier)
        }
        return Array(notices.prefix(Self.maxPending))
    }

    // MARK: Sync

    /// Makes macOS match the library: removes reminders that no longer apply (task done,
    /// date moved, deleted) and schedules the rest. Safe to call as often as you like.
    @discardableResult
    func sync() async throws -> ReminderSyncResult {

        let settings = try settings()
        let pending = await center.pendingIdentifiers().filter { $0.hasPrefix(Self.identifierPrefix) }

        guard settings.enabled else {
            await center.remove(identifiers: pending)
            return ReminderSyncResult(outcome: .disabled, removed: pending.count)
        }
        guard await center.isAuthorized() else {
            return ReminderSyncResult(outcome: .notAuthorized)
        }

        let notices = try plan()
        let wanted = Set(notices.map(\.identifier))
        let stale = pending.filter { !wanted.contains($0) }
        await center.remove(identifiers: stale)

        var result = ReminderSyncResult(outcome: .scheduled, removed: stale.count)
        for notice in notices {
            do {
                try await center.add(notice)
                result.scheduled += 1
            } catch {
                result.failed += 1
            }
        }
        return result
    }

    /// Removes every reminder this app scheduled.
    func clearAll() async {
        let pending = await center.pendingIdentifiers().filter { $0.hasPrefix(Self.identifierPrefix) }
        await center.remove(identifiers: pending)
    }

    // MARK: Backup problems

    /// Shows a notification now. False when the settings or macOS do not allow it.
    @discardableResult
    func notifyBackupProblem(_ message: String) async -> Bool {
        guard let settings = try? settings(), settings.enabled, settings.backupAlerts else { return false }
        guard await center.isAuthorized() else { return false }
        let now = clock()
        let notice = ReminderNotice(
            identifier: "\(Self.identifierPrefix)backup.\(Int(now.timeIntervalSince1970))",
            kind: .backup, recordID: "backup", title: "Backup problem", body: message, fireDate: nil)
        do {
            try await center.add(notice)
            return true
        } catch {
            return false
        }
    }

    // MARK: Home: coming up

    /// Open tasks and active submissions due within `days` days (today included), soonest first.
    /// With `includeOverdue`, earlier ones come first too (negative `daysLeft`).
    func upcoming(days: Int = 7, includeOverdue: Bool = false, now: Date? = nil) throws -> [UpcomingDeadline] {
        let today = calendar.startOfDay(for: now ?? clock())
        var found: [UpcomingDeadline] = []

        func left(_ date: Date) -> Int {
            calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: date)).day ?? 0
        }

        for task in try openTasks() {
            guard let due = task.due else { continue }
            found.append(UpcomingDeadline(kind: .task, recordID: task.id, title: task.title,
                                          detail: task.project, date: due, daysLeft: left(due)))
        }
        for sub in try activeSubmissions() {
            found.append(UpcomingDeadline(kind: .submission, recordID: sub.id, title: sub.venue,
                                          detail: sub.draftTitle, date: sub.deadline, daysLeft: left(sub.deadline)))
        }

        return found
            .filter { $0.daysLeft <= days && (includeOverdue || $0.daysLeft >= 0) }
            .sorted { ($0.date, $0.title, $0.recordID) < ($1.date, $1.title, $1.recordID) }
    }

    // MARK: Reading the library

    private struct TaskInfo {
        let id: String, title: String, project: String
        let due: Date?, remind: Date?
        var body: String { project.isEmpty ? title : "\(title) · \(project)" }
    }

    private struct SubmissionInfo {
        let id: String, venue: String, draftTitle: String
        let deadline: Date
        var body: String { draftTitle.isEmpty ? venue : "\(venue) · \(draftTitle)" }
    }

    private func openTasks() throws -> [TaskInfo] {
        let rows = try model.database.rows("""
            SELECT t.id, t.title, t.due_at, t.remind_at, p.name AS project
            FROM tasks t LEFT JOIN projects p ON p.id = t.project_id
            WHERE t.deleted_at IS NULL AND t.status != 'done' AND (t.due_at IS NOT NULL OR t.remind_at IS NOT NULL)
            ORDER BY t.id
            """)
        return rows.compactMap { row in
            guard let id = row.text("id"), let title = row.text("title") else { return nil }
            let due = row.text("due_at").flatMap { parse($0) }
            let remind = row.text("remind_at").flatMap { parse($0) }
            if due == nil && remind == nil { return nil }
            return TaskInfo(id: id, title: title, project: row.text("project") ?? "", due: due, remind: remind)
        }
    }

    private func activeSubmissions() throws -> [SubmissionInfo] {
        let rows = try model.database.rows("""
            SELECT s.id, s.venue, s.deadline, d.title AS draft_title
            FROM submissions s LEFT JOIN drafts d ON d.id = s.draft_id
            WHERE s.deadline IS NOT NULL AND s.stage IN ('planned', 'revision')
              AND (d.id IS NULL OR d.deleted_at IS NULL)
            ORDER BY s.id
            """)
        return rows.compactMap { row in
            guard let id = row.text("id"), let venue = row.text("venue"),
                  let deadline = row.text("deadline").flatMap({ parse($0) }) else { return nil }
            return SubmissionInfo(id: id, venue: venue, draftTitle: row.text("draft_title") ?? "", deadline: deadline)
        }
    }

    // MARK: Dates

    /// 09:00 local, `daysBefore` days before the day that starts at `day`.
    private func reminderTime(day: Date, daysBefore: Int) -> Date? {
        guard let earlier = calendar.date(byAdding: .day, value: -daysBefore, to: day) else { return nil }
        return calendar.date(bySettingHour: Self.reminderHour, minute: 0, second: 0, of: earlier)
    }

    /// "2026-11-03" = that day here (start of day); anything else is an ISO-8601 instant.
    private func parse(_ text: String) -> Date? {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
            let p = t.split(separator: "-").compactMap { Int($0) }
            guard p.count == 3 else { return nil }
            return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
        }
        let plain = ISO8601DateFormatter()
        if let d = plain.date(from: t) { return d }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: t)
    }

    // MARK: Settings storage

    private func flag(_ key: String, default fallback: Bool) throws -> Bool {
        guard let value = try model.database.scalarText("SELECT value FROM meta WHERE key = ?", [.text(key)]) else {
            return fallback
        }
        return value != "0"
    }

    private func setFlag(_ key: String, _ on: Bool) throws {
        try model.database.run(
            "INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", [.text(key), .text(on ? "1" : "0")]
        )
    }
}
