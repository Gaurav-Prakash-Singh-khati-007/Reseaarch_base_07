//
//  SettingsViewTests.swift
//  ResearchBaseTests
//
//  Owner: Agent 75 · Features: F-49, F-50, F-51, F-56, X-04, F-48, F-55
//
//  Tests the logic behind the new Settings cards: the status lines, the result texts and the
//  Keychain rows (with an in-memory store, so no real Keychain is touched). The SwiftUI cards
//  themselves are not rendered here.
//

import XCTest
@testable import ResearchBase

@MainActor
final class RBA75TextTests: XCTestCase {

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    // MARK: When

    func testWhenSaysTodayYesterdayOrTheDate() {
        let now = date(2026, 10, 23, 15)
        XCTAssertEqual(RBA75Text.when(nil, now: now, calendar: calendar), "never")
        XCTAssertTrue(RBA75Text.when(date(2026, 10, 23, 9, 5), now: now, calendar: calendar).hasPrefix("today "))
        XCTAssertTrue(RBA75Text.when(date(2026, 10, 22, 23, 0), now: now, calendar: calendar).hasPrefix("yesterday "))
        XCTAssertTrue(RBA75Text.when(date(2026, 10, 1), now: now, calendar: calendar).contains("2026"))
    }

    // MARK: Backups

    func testBackupLineLevels() {
        let now = date(2026, 10, 23, 15)
        var status = BackupStatus()

        XCTAssertEqual(RBA75Text.backupLine(status, now: now, calendar: calendar).level, .warning, "never backed up")

        status.lastResult = .ok
        status.lastBackupAt = date(2026, 10, 23, 3)
        let ok = RBA75Text.backupLine(status, now: now, calendar: calendar)
        XCTAssertEqual(ok.level, .good)
        XCTAssertTrue(ok.text.hasPrefix("Backed up today"), ok.text)

        status.lastResult = .failed
        status.detail = "The disk is full."
        let failed = RBA75Text.backupLine(status, now: now, calendar: calendar)
        XCTAssertEqual(failed.level, .bad)
        XCTAssertTrue(failed.text.contains("The disk is full."), failed.text)

        status.lastResult = .skipped
        XCTAssertEqual(RBA75Text.backupLine(status, now: now, calendar: calendar).level, .warning)
    }

    func testSecondLocationLine() {
        var status = BackupStatus()
        XCTAssertEqual(RBA75Text.secondLocationLine(status).level, .neutral)

        status.secondLocationPath = "/Volumes/Backup"
        status.secondLocationConnected = false
        let away = RBA75Text.secondLocationLine(status)
        XCTAssertEqual(away.level, .warning)
        XCTAssertTrue(away.text.contains("not connected"))

        status.secondLocationConnected = true
        XCTAssertEqual(RBA75Text.secondLocationLine(status).level, .good)
    }

    // MARK: Integrity

    func testIntegrityLine() {
        let now = date(2026, 10, 23, 15)
        XCTAssertEqual(RBA75Text.integrityLine(nil, now: now, calendar: calendar).level, .neutral)

        func line(_ result: IntegrityLastResult) -> RBA75Line {
            RBA75Text.integrityLine(IntegrityLastRun(at: now, result: result, deepAt: nil), now: now, calendar: calendar)
        }
        XCTAssertEqual(line(.ok).level, .good)
        XCTAssertEqual(line(.warnings).level, .warning)
        XCTAssertEqual(line(.errors).level, .bad)
        XCTAssertEqual(line(.unknown).level, .neutral)
        XCTAssertEqual(RBA75Text.integrityLine(IntegrityLastRun(at: nil, result: .ok, deepAt: nil)).level, .neutral)
    }

    // MARK: Practice restore

    func testDrillLine() {
        let now = date(2026, 10, 23, 15)

        XCTAssertEqual(RBA75Text.drillLine(nil, overdue: true, now: now, calendar: calendar).level, .warning)

        let passed = DrillRecord(at: date(2026, 10, 20), result: "passed", backupName: "Backup A")
        let fresh = RBA75Text.drillLine(passed, overdue: false, now: now, calendar: calendar)
        XCTAssertEqual(fresh.level, .good)
        XCTAssertTrue(fresh.text.contains("Backup A"))

        let stale = RBA75Text.drillLine(passed, overdue: true, now: now, calendar: calendar)
        XCTAssertEqual(stale.level, .warning)

        let notes = DrillRecord(at: date(2026, 10, 20), result: "notes", backupName: "Backup A")
        XCTAssertEqual(RBA75Text.drillLine(notes, overdue: false, now: now, calendar: calendar).level, .good)

        let failed = DrillRecord(at: date(2026, 10, 20), result: "failed", backupName: "Backup B")
        let bad = RBA75Text.drillLine(failed, overdue: false, now: now, calendar: calendar)
        XCTAssertEqual(bad.level, .bad)
        XCTAssertTrue(bad.text.contains("Backup B"))
    }

    // MARK: Results

    func testBackupResults() {
        let skipped = RBA75Text.backupResult(.skipped(reason: "Not enough free space."))
        XCTAssertFalse(skipped.succeeded)
        XCTAssertTrue(skipped.title.contains("Not enough free space."))

        let failed = RBA75Text.backupResult(.failed(message: "Copy failed."))
        XCTAssertFalse(failed.succeeded)
        XCTAssertTrue(failed.title.contains("Copy failed."))

        let summary = BackupSummary(
            date: Date(), folderName: "ResearchBase Backup 2026-10-23 03-00-00",
            primaryURL: URL(fileURLWithPath: "/tmp/a"), secondURL: nil,
            bytes: 2_000_000, copies: 1, warnings: ["One PDF was missing."], prunedCount: 2)
        let done = RBA75Text.backupResult(.completed(summary))
        XCTAssertTrue(done.succeeded)
        XCTAssertTrue(done.title.contains("2026-10-23"))
        XCTAssertTrue(done.details.contains("One PDF was missing."), "warnings are shown, not hidden")
        XCTAssertTrue(done.details.contains { $0.contains("2 older backups were removed") })
        XCTAssertTrue(done.details[0].contains("1 copy"))
    }

    func testExportResultKeepsWarnings() {
        let result = ExportEverythingResult(
            folder: URL(fileURLWithPath: "/tmp/ResearchBase Export"),
            itemCount: 3, noteCount: 2, pdfCount: 1, draftFolderCount: 1, bytes: 1_000, warnings: ["A note had no title."])
        let shown = RBA75Text.exportResult(result)
        XCTAssertTrue(shown.succeeded)
        XCTAssertEqual(shown.title, "Exported to ResearchBase Export")
        XCTAssertTrue(shown.details[0].hasPrefix("3 items · 2 notes · 1 PDFs · 1 drafts"))
        XCTAssertTrue(shown.details.contains("A note had no title."))
    }
}

// MARK: - Keys and tokens (F-56)

@MainActor
final class RBA75SecretsTests: XCTestCase {

    func testRowsShowOnlyAMaskedKey() throws {
        let key = "sk-abcdefghijklmnop1234"
        let store = InMemorySecretStore([.openAlexAPIKey: key])

        let rows = RBA75Secrets.rows(in: store)

        XCTAssertEqual(rows.map(\.name), SecretName.all)
        let open = try XCTUnwrap(rows.first { $0.name == .openAlexAPIKey })
        XCTAssertTrue(open.isSet)
        XCTAssertEqual(open.masked, "••••1234")
        XCTAssertFalse((open.masked ?? "").contains("abcdefgh"), "the whole key is never shown")

        let other = try XCTUnwrap(rows.first { $0.name == .semanticScholarAPIKey })
        XCTAssertFalse(other.isSet)
        XCTAssertNil(other.masked)
    }

    func testSaveTrimsAndReplaces() throws {
        let store = InMemorySecretStore()

        try RBA75Secrets.save("  first-key-1111  \n", for: .crossrefPlusToken, in: store)
        XCTAssertEqual(try store.read(.crossrefPlusToken), "first-key-1111")

        try RBA75Secrets.save("second-key-2222", for: .crossrefPlusToken, in: store)
        XCTAssertEqual(try store.read(.crossrefPlusToken), "second-key-2222")
    }

    func testEmptyKeyIsRefusedAndKeepsTheOldOne() throws {
        let store = InMemorySecretStore([.semanticScholarAPIKey: "keep-me-9999"])

        XCTAssertThrowsError(try RBA75Secrets.save("   ", for: .semanticScholarAPIKey, in: store))
        XCTAssertEqual(try store.read(.semanticScholarAPIKey), "keep-me-9999")
    }

    func testRemove() throws {
        let store = InMemorySecretStore([.openAlexAPIKey: "some-key-0000"])

        try RBA75Secrets.remove(.openAlexAPIKey, in: store)
        XCTAssertNil(try store.read(.openAlexAPIKey))
        XCTAssertNoThrow(try RBA75Secrets.remove(.openAlexAPIKey, in: store), "removing a missing key is fine")
        XCTAssertFalse(RBA75Secrets.rows(in: store).contains { $0.isSet })
    }
}

final class RBA75EraseLogicTests: XCTestCase {

    func testOnlyTheExactWordConfirms() {
        XCTAssertTrue(RBA75EraseLogic.isConfirmed("ERASE"))
        XCTAssertTrue(RBA75EraseLogic.isConfirmed("  ERASE \n"))
        XCTAssertFalse(RBA75EraseLogic.isConfirmed("erase"))
        XCTAssertFalse(RBA75EraseLogic.isConfirmed("ERAS"))
        XCTAssertFalse(RBA75EraseLogic.isConfirmed(""))
        XCTAssertFalse(RBA75EraseLogic.isConfirmed("RESTORE"))
    }
}
