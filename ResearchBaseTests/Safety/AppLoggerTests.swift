//
//  AppLoggerTests.swift
//  ResearchBase
//
//  Created by Gaurav Khati on 20/10/26.
//


//
//  AppLoggerTests.swift
//  ResearchBaseTests
//
//  Owner: Agent 1 · Features: F-52 (logging and visible errors)
//  Every test uses its own logger writing to a temporary folder,
//  never to the real ~/Library/Logs/ResearchBase.
//

import XCTest
@testable import ResearchBase

@MainActor
final class AppLoggerTests: XCTestCase {

    private struct Mystery: Error {}

    private func makeLogger(
        maxFileBytes: Int = 1_000_000,
        maxFiles: Int = 3,
        maxRecent: Int = 1000
    ) throws -> (AppLogger, URL) {
        let folder = try TestSupport.makeTempDirectory(self)
            .appendingPathComponent("logs", isDirectory: true)
        let logger = AppLogger(
            logDirectory: folder,
            maxFileBytes: maxFileBytes,
            maxFiles: maxFiles,
            maxRecent: maxRecent,
            subsystem: "ResearchBase.tests"
        )
        return (logger, folder)
    }

    // MARK: Writing and reading

    func testEntriesAreWrittenAsJSONLinesAndReadBack() throws {
        let (logger, folder) = try makeLogger()

        logger.info("Library opened", category: "storage")
        logger.warning("Disk is getting full", category: "storage")
        logger.flush()

        let entries = logger.entriesFromFiles()
        XCTAssertEqual(entries.map(\.message), ["Library opened", "Disk is getting full"])
        XCTAssertEqual(entries.map(\.level), [.info, .warning])
        XCTAssertEqual(entries.first?.category, "storage")

        let text = try String(contentsOf: folder.appendingPathComponent("researchbase.log"), encoding: .utf8)
        XCTAssertEqual(text.split(separator: "\n").count, 2)
    }

    func testDebugStaysInMemoryButNotInTheFile() throws {
        let (logger, _) = try makeLogger()

        logger.debug("only in memory")
        logger.info("in both")
        logger.flush()

        XCTAssertEqual(logger.recentEntries().map(\.message), ["only in memory", "in both"])
        XCTAssertEqual(logger.entriesFromFiles().map(\.message), ["in both"])
        XCTAssertEqual(logger.recentEntries(minimumLevel: .info).map(\.message), ["in both"])
    }

    func testMinimumFileLevelCanBeRaised() throws {
        let (logger, _) = try makeLogger()
        logger.setMinimumFileLevel(.error)

        logger.info("skipped")
        logger.error("kept")
        logger.flush()

        XCTAssertEqual(logger.entriesFromFiles().map(\.message), ["kept"])
    }

    func testRecentEntriesAreCappedAndKeepTheNewest() throws {
        let (logger, _) = try makeLogger(maxRecent: 10)

        for index in 0..<25 { logger.info("m\(index)") }
        logger.flush()

        let recent = logger.recentEntries(limit: 100)
        XCTAssertEqual(recent.count, 10)
        XCTAssertEqual(recent.first?.message, "m15")
        XCTAssertEqual(recent.last?.message, "m24")
    }

    func testFileLoggingCanBeSwitchedOff() throws {
        let (logger, folder) = try makeLogger()
        logger.configure(logDirectory: nil)

        logger.info("not written")
        logger.flush()

        XCTAssertNil(logger.logFileURL)
        XCTAssertTrue(logger.entriesFromFiles().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertEqual(logger.recentEntries().count, 1)
    }

    // MARK: Rotation

    func testFilesRotateAndOnlyTheNewestAreKept() throws {
        let (logger, folder) = try makeLogger(maxFileBytes: 400, maxFiles: 3)

        for index in 0..<80 { logger.info("line \(index)") }
        logger.flush()

        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertLessThanOrEqual(names.count, 3)
        XCTAssertFalse(names.contains("researchbase.3.log"))
        XCTAssertEqual(logger.entriesFromFiles(limit: 1).first?.message, "line 79")
        XCTAssertEqual(logger.logFileURLs.count, names.count)
    }

    func testDeleteLogFilesRemovesThemFromDisk() throws {
        let (logger, _) = try makeLogger()

        logger.info("one")
        logger.flush()
        XCTAssertEqual(logger.logFileURLs.count, 1)

        logger.deleteLogFiles()
        XCTAssertTrue(logger.logFileURLs.isEmpty)
        XCTAssertTrue(logger.entriesFromFiles().isEmpty)
    }

    // MARK: Errors

    func testLoggingAnErrorKeepsPlainWordsAndTechnicalDetailApart() throws {
        let (logger, _) = try makeLogger()

        logger.error(ModelError.emptyName, context: "Could not save the tag", show: false)
        logger.flush()

        let entry = try XCTUnwrap(logger.recentEntries().last)
        XCTAssertEqual(entry.level, .error)
        XCTAssertTrue(entry.message.contains("Could not save the tag"))
        XCTAssertTrue(entry.message.contains("A name cannot be empty."))
        XCTAssertTrue(try XCTUnwrap(entry.detail).contains("emptyName"))
    }

    func testPlainMessagesForCommonFailures() {
        XCTAssertEqual(AppErrorText.plain(ModelError.emptyName), "A name cannot be empty.")

        XCTAssertTrue(AppErrorText.plain(CocoaError(.fileWriteOutOfSpace)).contains("disk is full"))
        XCTAssertTrue(AppErrorText.plain(CocoaError(.fileNoSuchFile)).contains("could not be found"))
        XCTAssertTrue(AppErrorText.plain(CocoaError(.fileWriteNoPermission)).contains("not allowed"))
        XCTAssertTrue(AppErrorText.plain(URLError(.notConnectedToInternet)).contains("internet"))
        XCTAssertTrue(AppErrorText.plain(URLError(.timedOut)).contains("did not answer"))
        XCTAssertTrue(AppErrorText.plain(POSIXError(.ENOSPC)).contains("disk is full"))
    }

    func testUnknownErrorsGetAGenericSentenceNotATypeName() {
        let text = AppErrorText.plain(Mystery())
        XCTAssertEqual(text, AppErrorText.generic)
        XCTAssertFalse(text.contains("Mystery"))
    }

    // MARK: Secrets

    func testSecretsAreHiddenBeforeAnythingIsStored() throws {
        let (logger, _) = try makeLogger()

        logger.info("Calling with api_key=abc123SECRET and Bearer tok.en-1234 and sk-abcdefghijklmnopqrstuvwxyz")
        logger.flush()

        let message = try XCTUnwrap(logger.entriesFromFiles().last?.message)
        XCTAssertFalse(message.contains("abc123SECRET"))
        XCTAssertFalse(message.contains("tok.en-1234"))
        XCTAssertFalse(message.contains("sk-abcdefghijklmnopqrstuvwxyz"))
        XCTAssertTrue(message.contains("[hidden]"))
    }

    func testOrdinarySentencesAreNotChanged() {
        let text = "The token expired while reading the paper"
        XCTAssertEqual(AppErrorText.redact(text), text)
    }

    // MARK: Banner and viewer feed

    func testErrorCenterShowsDismissesAndRemembersTheLastFew() {
        let center = AppErrorCenter()

        center.show(title: "Could not add the paper", message: "The disk is full.")
        center.show(title: "Could not save", message: "Not allowed.")
        XCTAssertEqual(center.current?.title, "Could not save")
        XCTAssertEqual(center.recent.count, 2)

        center.dismiss()
        XCTAssertNil(center.current)
        XCTAssertEqual(center.recent.count, 2)

        for index in 0..<30 { center.show(title: "t\(index)", message: "m") }
        XCTAssertEqual(center.recent.count, 20)
        XCTAssertEqual(center.recent.first?.title, "t29")
    }

    func testLogFeedFiltersByLevel() {
        let feed = AppLogFeed()
        let now = Date()

        func entry(_ level: AppLogLevel, _ text: String) -> AppLogEntry {
            AppLogEntry(id: UUID(), date: now, level: level, category: "t", message: text, detail: nil)
        }

        feed.append(entry(.debug, "d"))
        feed.append(entry(.info, "i"))
        feed.append(entry(.error, "e"))

        XCTAssertEqual(feed.visibleEntries.map(\.message), ["i", "e"])
        feed.minimumLevel = .debug
        XCTAssertEqual(feed.visibleEntries.count, 3)
        feed.minimumLevel = .error
        XCTAssertEqual(feed.visibleEntries.map(\.message), ["e"])
    }
}