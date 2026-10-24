//
//  LibraryStorageTests.swift
//  ResearchBaseTests
//
//  Phase 1, Step 1A (F-04, F-07, F-14): the new SQLite library.
//
//  Every test builds its library in a temporary folder that is removed
//  afterwards. They never touch the real library, the old SwiftData
//  store or the real backups folder.
//

import XCTest
@testable import ResearchBase

@MainActor
final class LibraryStorageTests: XCTestCase {

    // MARK: Helpers

    /// A path for a library that does not exist yet.
    private func newLibraryFolder() throws -> URL {
        try TestSupport.makeTempDirectory(self)
            .appendingPathComponent(Library.folderName, isDirectory: true)
    }

    private func snapshot(_ database: LibraryDatabase) throws -> [String] {
        try database.rows("SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name")
            .map { row in
                [row.text("type"), row.text("name"), row.text("tbl_name"), row.text("sql")]
                    .map { $0 ?? "NULL" }
                    .joined(separator: "|")
            }
    }

    private func insertItem(
        _ database: LibraryDatabase,
        id: String = UUID().uuidString,
        type: String = "article",
        key: String = "smith2024",
        extra: String = "",
        extraValues: [SQLValue] = []
    ) throws {
        let now = Library.nowISO()
        let columns = "id, item_type, title, citation_key, added_at, updated_at" + (extra.isEmpty ? "" : ", " + extra)
        let marks = String(repeating: "?, ", count: 5 + extraValues.count) + "?"
        try database.run(
            "INSERT INTO items (\(columns)) VALUES (\(marks))",
            [.text(id), .text(type), .text("A title"), .text(key), .text(now), .text(now)] + extraValues
        )
    }

    // MARK: Folder and database creation

    func testCreatesTheFolderLayoutAndDatabase() throws {

        let folder = try newLibraryFolder()
        let library = try Library.open(at: folder)
        defer { library.close() }

        XCTAssertTrue(library.wasCreated)
        XCTAssertEqual(library.versionOnOpen, 0)

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.databaseURL.path))
        XCTAssertEqual(library.databaseURL.lastPathComponent, "library.sqlite")

        for name in ["files", "inbox", "drafts", "backups", "exports"] {
            let url = folder.appendingPathComponent(name)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue,
                "\(name)/ should exist"
            )
        }

        XCTAssertEqual(library.filesURL.lastPathComponent, "files")
        XCTAssertEqual(library.inboxURL.lastPathComponent, "inbox")
        XCTAssertEqual(library.draftsURL.lastPathComponent, "drafts")
        XCTAssertEqual(library.backupsURL.lastPathComponent, "backups")
    }

    func testDatabaseUsesWALAndForeignKeys() throws {

        let library = try Library.open(at: try newLibraryFolder())
        defer { library.close() }

        XCTAssertEqual(try library.database.scalarText("PRAGMA journal_mode")?.lowercased(), "wal")
        XCTAssertEqual(try library.database.scalarInt("PRAGMA foreign_keys"), 1)
    }

    func testNewLibraryIsAtSchemaVersionOneWithCreatedAtInUTC() throws {

        let library = try Library.open(at: try newLibraryFolder(), appVersion: "9.9.9")
        defer { library.close() }

        XCTAssertEqual(try library.schemaVersion, 1)
        XCTAssertEqual(LibraryMigrations.currentVersion, 1)

        let created = try XCTUnwrap(try library.createdAt)
        XCTAssertTrue(created.hasSuffix("Z"), "times are UTC ISO-8601: \(created)")
        XCTAssertNotNil(ISO8601DateFormatter.withFraction.date(from: created))

        XCTAssertEqual(
            try library.database.scalarText("SELECT value FROM meta WHERE key = 'app_version'"),
            "9.9.9"
        )
    }

    func testEmbeddedSchemaIsIdenticalToDocsSchemaSql() throws {

        // ResearchBaseTests/LibraryStorageTests.swift -> project root -> docs/schema.sql
        let schemaFile = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs/schema.sql")

        guard FileManager.default.fileExists(atPath: schemaFile.path) else {
            throw XCTSkip("docs/schema.sql not found next to the project")
        }

        let reference = try LibraryDatabase.inMemory()
        defer { reference.close() }
        try reference.exec(try String(contentsOf: schemaFile, encoding: .utf8))

        let mine = try LibraryDatabase.inMemory()
        defer { mine.close() }
        try mine.exec(LibrarySchemaV1.sql)

        let expected = try snapshot(reference)
        XCTAssertGreaterThan(expected.count, 30, "the reference schema should have been created")
        XCTAssertEqual(try snapshot(mine), expected)
    }

    func testAllSchemaTablesExist() throws {

        let library = try Library.open(at: try newLibraryFolder())
        defer { library.close() }

        let names = Set(
            try library.database.rows("SELECT name FROM sqlite_master WHERE type = 'table'")
                .compactMap { $0.text("name") }
        )

        for table in [
            "meta", "items", "creators", "item_creators", "tags", "item_tags", "collections",
            "collection_items", "saved_searches", "attachments", "annotations", "thoughts",
            "reviews", "review_themes", "review_columns", "review_cells", "links",
            "experiments", "runs", "metrics", "baselines", "drafts", "draft_citations",
            "draft_snapshots", "draft_comments", "templates", "submissions", "review_comments",
            "projects", "tasks", "changes", "capture_log", "lookup_cache",
            "fts_items", "fts_pdf", "fts_thought", "fts_draft"
        ] {
            XCTAssertTrue(names.contains(table), "missing table \(table)")
        }
    }

    // MARK: Reopen

    func testReopenKeepsTheDataAndChangesNothing() throws {

        let folder = try newLibraryFolder()

        let first = try Library.open(at: folder)
        let created = try XCTUnwrap(try first.createdAt)
        try insertItem(first.database, id: "item-1", key: "kept2024")
        let before = try snapshot(first.database)
        first.close()

        let second = try Library.open(at: folder)
        defer { second.close() }

        XCTAssertFalse(second.wasCreated)
        XCTAssertEqual(second.versionOnOpen, 1)
        XCTAssertEqual(try second.schemaVersion, 1)
        XCTAssertEqual(try second.createdAt, created, "created_at must not change on reopen")
        XCTAssertEqual(try snapshot(second.database), before, "opening again must not change the schema")
        XCTAssertEqual(
            try second.database.scalarText("SELECT citation_key FROM items WHERE id = 'item-1'"),
            "kept2024"
        )
    }

    func testOpeningWithoutCreateFailsWhenThereIsNoLibrary() throws {

        let folder = try newLibraryFolder()

        XCTAssertThrowsError(try Library.open(at: folder, createIfMissing: false)) { error in
            XCTAssertEqual(error as? LibraryError, .libraryNotFound(folder.path))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "nothing may be created")
    }

    // MARK: Refusing what it must not open

    func testRejectsALibraryFromANewerVersion() throws {

        let folder = try newLibraryFolder()

        let library = try Library.open(at: folder)
        try insertItem(library.database, id: "keep-me")
        library.close()

        // Pretend a future app moved it to version 99.
        let raw = try LibraryDatabase(path: folder.appendingPathComponent("library.sqlite").path)
        try raw.setUserVersion(99)
        let tablesBefore = try snapshot(raw)
        raw.close()

        XCTAssertThrowsError(try Library.open(at: folder)) { error in
            XCTAssertEqual(error as? LibraryError, .newerSchema(found: 99, supported: 1))
        }

        // Left exactly as it was.
        let check = try LibraryDatabase(path: folder.appendingPathComponent("library.sqlite").path)
        defer { check.close() }
        XCTAssertEqual(try check.userVersion, 99)
        XCTAssertEqual(try snapshot(check), tablesBefore)
        XCTAssertEqual(try check.scalarInt("SELECT COUNT(*) FROM items WHERE id = 'keep-me'"), 1)
    }

    func testRejectsAnotherSQLiteDatabase() throws {

        let folder = try newLibraryFolder()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent("library.sqlite").path

        let foreign = try LibraryDatabase(path: path)
        try foreign.exec("CREATE TABLE somebody_elses (x TEXT); INSERT INTO somebody_elses VALUES ('hi');")
        foreign.close()

        XCTAssertThrowsError(try Library.open(at: folder)) { error in
            XCTAssertEqual(error as? LibraryError, .notALibrary(path))
        }

        let check = try LibraryDatabase(path: path)
        defer { check.close() }
        XCTAssertEqual(try check.scalarInt("SELECT COUNT(*) FROM sqlite_master"), 1, "no tables may be added")
        XCTAssertEqual(try check.userVersion, 0)
    }

    func testRejectsAFileThatIsNotADatabase() throws {

        let folder = try newLibraryFolder()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("library.sqlite")
        let junk = Data(String(repeating: "this is not a database. ", count: 40).utf8)
        try junk.write(to: url)

        XCTAssertThrowsError(try Library.open(at: folder)) { error in
            XCTAssertEqual(error as? LibraryError, .notALibrary(url.path))
        }

        XCTAssertEqual(try Data(contentsOf: url), junk, "the file must be left untouched")
    }

    // MARK: Migration runner

    func testMigrationsRunInOrderAndSetTheVersion() throws {

        let folder = try newLibraryFolder()

        let v2 = LibraryMigration(version: 2, name: "test", sql: "CREATE TABLE test_v2 (x TEXT);")
        let v3 = LibraryMigration(version: 3, name: "test", sql: "CREATE TABLE test_v3 (x TEXT);")

        // A version-1 library first.
        try Library.open(at: folder).close()

        let library = try Library.open(at: folder, migrations: LibraryMigrations.all + [v2, v3])
        defer { library.close() }

        XCTAssertEqual(library.versionOnOpen, 1)
        XCTAssertEqual(try library.schemaVersion, 3)
        XCTAssertEqual(
            try library.database.scalarInt("SELECT COUNT(*) FROM sqlite_master WHERE name IN ('test_v2','test_v3')"),
            2
        )
    }

    func testAnAppThatKnowsOnlyOlderVersionsRefusesTheNewerLibrary() throws {

        let folder = try newLibraryFolder()
        let v2 = LibraryMigration(version: 2, name: "test", sql: "CREATE TABLE test_v2 (x TEXT);")

        try Library.open(at: folder, migrations: LibraryMigrations.all + [v2]).close()

        // The real app (only version 1) must refuse it.
        XCTAssertThrowsError(try Library.open(at: folder)) { error in
            XCTAssertEqual(error as? LibraryError, .newerSchema(found: 2, supported: 1))
        }
    }

    func testAFailingMigrationIsUndoneCompletely() throws {

        let folder = try newLibraryFolder()
        try Library.open(at: folder).close()

        // The first statement works, the second fails. Neither may stay.
        let bad = LibraryMigration(
            version: 2,
            name: "bad",
            sql: "CREATE TABLE half_done (x TEXT); CREATE TABLE half_done (x TEXT);"
        )

        XCTAssertThrowsError(try Library.open(at: folder, migrations: LibraryMigrations.all + [bad])) { error in
            guard case .migrationFailed(let version, _) = error as? LibraryError else {
                return XCTFail("expected migrationFailed, got \(error)")
            }
            XCTAssertEqual(version, 2)
        }

        let library = try Library.open(at: folder)
        defer { library.close() }

        XCTAssertEqual(try library.schemaVersion, 1, "version must not move")
        XCTAssertEqual(
            try library.database.scalarInt("SELECT COUNT(*) FROM sqlite_master WHERE name = 'half_done'"),
            0,
            "the half-done table must have been rolled back"
        )
    }

    func testBeforeEachCanStopAMigration() throws {

        let database = try LibraryDatabase.inMemory()
        defer { database.close() }

        struct Stop: Error {}

        XCTAssertThrowsError(
            try LibraryMigrationRunner.migrate(database, beforeEach: { _ in throw Stop() })
        )

        XCTAssertEqual(try database.userVersion, 0)
        XCTAssertEqual(try database.scalarInt("SELECT COUNT(*) FROM sqlite_master"), 0)
    }

    func testRunningTheRunnerTwiceChangesNothing() throws {

        let database = try LibraryDatabase.inMemory()
        defer { database.close() }

        let first = try LibraryMigrationRunner.migrate(database)
        XCTAssertEqual(first, .init(from: 0, to: 1))
        XCTAssertTrue(first.changed)

        let before = try snapshot(database)

        let second = try LibraryMigrationRunner.migrate(database)
        XCTAssertEqual(second, .init(from: 1, to: 1))
        XCTAssertFalse(second.changed)
        XCTAssertEqual(try snapshot(database), before)
    }

    func testMigrationListMustBeNumberedWithoutGaps() throws {

        let gap = LibraryMigration(version: 3, name: "gap", sql: "SELECT 1;")

        XCTAssertThrowsError(try LibraryMigrations.validate(LibraryMigrations.all + [gap])) { error in
            guard case .invalidMigrations = error as? LibraryError else {
                return XCTFail("expected invalidMigrations, got \(error)")
            }
        }
        XCTAssertNoThrow(try LibraryMigrations.validate(LibraryMigrations.all))
    }

    // MARK: Item types and capture fields (F-07, F-14)

    func testAllTenItemTypesAreAccepted() throws {

        let library = try Library.open(at: try newLibraryFolder())
        defer { library.close() }

        let types = ["article", "preprint", "conference", "book", "chapter",
                     "thesis", "report", "webpage", "dataset", "software"]

        for (index, type) in types.enumerated() {
            XCTAssertNoThrow(try insertItem(library.database, type: type, key: "key\(index)"), type)
        }

        XCTAssertEqual(try library.database.scalarInt("SELECT COUNT(*) FROM items"), 10)
    }

    func testUnknownItemTypeIsRefused() throws {

        let library = try Library.open(at: try newLibraryFolder())
        defer { library.close() }

        XCTAssertThrowsError(try insertItem(library.database, type: "podcast"))
        XCTAssertEqual(try library.database.scalarInt("SELECT COUNT(*) FROM items"), 0)
    }

    func testCaptureFieldsHaveSafeDefaultsAndAreChecked() throws {

        let library = try Library.open(at: try newLibraryFolder())
        defer { library.close() }

        try insertItem(library.database, id: "plain")

        let row = try XCTUnwrap(
            try library.database.rows(
                "SELECT source_kind, review_state, captured_at, source_url, reading_status, key_locked FROM items WHERE id = 'plain'"
            ).first
        )

        XCTAssertEqual(row.text("source_kind"), "manual")
        XCTAssertEqual(row.text("review_state"), "accepted")
        XCTAssertTrue(row["captured_at"].isNull)
        XCTAssertEqual(row.text("source_url"), "")
        XCTAssertEqual(row.text("reading_status"), "unread")
        XCTAssertEqual(row.int("key_locked"), 0)

        // Every way a paper can arrive, and the inbox state.
        let kinds = ["manual", "doi", "arxiv", "url", "pdf_drop", "import", "browser", "inbox_folder"]
        for (index, kind) in kinds.enumerated() {
            XCTAssertNoThrow(
                try insertItem(
                    library.database,
                    key: "cap\(index)",
                    extra: "source_kind, review_state, captured_at, source_url",
                    extraValues: [.text(kind), .text("inbox"), .text(Library.nowISO()), .text("https://example.org/\(index)")]
                ),
                kind
            )
        }

        XCTAssertThrowsError(
            try insertItem(library.database, key: "badkind", extra: "source_kind", extraValues: [.text("carrier_pigeon")])
        )
        XCTAssertThrowsError(
            try insertItem(library.database, key: "badstate", extra: "review_state", extraValues: [.text("limbo")])
        )
    }

    func testCitationKeyIsUniqueIgnoringCaseExceptForTrashedItems() throws {

        let library = try Library.open(at: try newLibraryFolder())
        defer { library.close() }

        try insertItem(library.database, id: "a", key: "Smith2024")
        XCTAssertThrowsError(try insertItem(library.database, id: "b", key: "smith2024"))

        // A trashed item no longer holds its key.
        try library.database.run(
            "UPDATE items SET deleted_at = ? WHERE id = 'a'",
            [.text(Library.nowISO())]
        )
        XCTAssertNoThrow(try insertItem(library.database, id: "c", key: "smith2024"))
    }

    func testFullTextSearchIsAvailable() throws {

        let library = try Library.open(at: try newLibraryFolder())
        defer { library.close() }

        try library.database.run(
            "INSERT INTO fts_items (rowid, title, authors, abstract, tags, venue) VALUES (1, ?, ?, ?, ?, ?)",
            [.text("Federated Optimization"), .text("Li, Tian"), .text("Heterogeneous networks"), .text("federated"), .text("MLSys")]
        )

        XCTAssertEqual(
            try library.database.scalarInt("SELECT rowid FROM fts_items WHERE fts_items MATCH 'heterogeneous'"),
            1
        )
        // Accents are folded (remove_diacritics).
        try library.database.run(
            "INSERT INTO fts_items (rowid, title, authors, abstract, tags, venue) VALUES (2, ?, '', '', '', '')",
            [.text("Réseaux de neurones")]
        )
        XCTAssertEqual(
            try library.database.scalarInt("SELECT rowid FROM fts_items WHERE fts_items MATCH 'reseaux'"),
            2
        )
    }

    // MARK: Crash safety

    func testCommittedDataSurvivesWithoutACleanClose() throws {

        let folder = try newLibraryFolder()

        let first = try Library.open(at: folder)
        try insertItem(first.database, id: "durable", key: "durable2024")

        // Do NOT close `first`. A second connection (like the app after a crash,
        // reading the WAL) must still see the committed row.
        let second = try LibraryDatabase(path: first.databaseURL.path)
        defer { second.close(); first.close() }

        XCTAssertEqual(try second.scalarInt("SELECT COUNT(*) FROM items WHERE id = 'durable'"), 1)
    }

    func testUncommittedWorkIsNeverKept() throws {

        let library = try Library.open(at: try newLibraryFolder())
        defer { library.close() }

        struct Boom: Error {}

        XCTAssertThrowsError(
            try library.database.transaction {
                try insertItem(library.database, id: "half", key: "half2024")
                throw Boom()
            }
        )

        XCTAssertEqual(try library.database.scalarInt("SELECT COUNT(*) FROM items"), 0)
    }

    // MARK: Relative paths

    func testRelativePathsStayInsideTheLibrary() throws {

        let folder = try newLibraryFolder()
        let library = try Library.open(at: folder)
        defer { library.close() }

        let inside = try library.url(forRelativePath: "files/ab/ab12cd.pdf")
        XCTAssertEqual(inside.path, folder.appendingPathComponent("files/ab/ab12cd.pdf").path)

        XCTAssertEqual(
            try library.url(forRelativePath: "./drafts//d1/main.tex").path,
            folder.appendingPathComponent("drafts/d1/main.tex").path
        )

        for bad in ["", "/etc/passwd", "../outside", "files/../../outside", "~/x", "a\\b"] {
            XCTAssertThrowsError(try library.url(forRelativePath: bad), "should refuse '\(bad)'") { error in
                XCTAssertEqual(error as? LibraryError, .pathEscapesLibrary(bad))
            }
        }
    }

    func testTimestampsAreUTCISO() {

        let date = Date(timeIntervalSince1970: 1_792_000_000.5)
        let text = Library.nowISO(date)

        XCTAssertTrue(text.hasSuffix("Z"))
        let parsed = ISO8601DateFormatter.withFraction.date(from: text)
        XCTAssertEqual(
            parsed?.timeIntervalSince1970 ?? 0,
            date.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    // MARK: Database wrapper

    func testWrapperBindsAndReadsEveryValueType() throws {

        let database = try LibraryDatabase.inMemory()
        defer { database.close() }

        try database.exec("CREATE TABLE t (i INTEGER, d REAL, s TEXT, b BLOB, n TEXT)")
        try database.run(
            "INSERT INTO t VALUES (?, ?, ?, ?, ?)",
            [.int(42), .double(2.5), .text("héllo ’ ✓"), .blob(Data([0, 1, 2, 255])), .null]
        )

        let row = try XCTUnwrap(try database.rows("SELECT * FROM t").first)

        XCTAssertEqual(row["i"], .int(42))
        XCTAssertEqual(row["d"], .double(2.5))
        XCTAssertEqual(row["s"], .text("héllo ’ ✓"))
        XCTAssertEqual(row["b"], .blob(Data([0, 1, 2, 255])))
        XCTAssertTrue(row["n"].isNull)
    }

    func testClosedDatabaseThrowsInsteadOfCrashing() throws {

        let database = try LibraryDatabase.inMemory()
        database.close()

        XCTAssertFalse(database.isOpen)
        XCTAssertThrowsError(try database.exec("SELECT 1")) { error in
            XCTAssertEqual(error as? LibraryError, .closed)
        }
    }
}

// MARK: - Test-only helper

private extension ISO8601DateFormatter {

    static var withFraction: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
