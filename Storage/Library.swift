//
//  Library.swift
//  ResearchBase
//
//  Phase 1, Step 1A (F-04, F-07, F-14)
//
//  The new library: one visible folder with one SQLite file.
//
//      ResearchBase Library/
//      ├── library.sqlite   database (WAL mode), version in PRAGMA user_version
//      ├── files/           attachments named by SHA-256 (used from Step 1B)
//      ├── inbox/           drop files here
//      ├── drafts/          one folder per draft
//      ├── backups/         rotating, verified backups
//      └── exports/         "export everything" output
//
//  STEP 1A ONLY: nothing in the app uses this yet. It does not touch
//  SwiftData, the old store or any existing screen.
//
//  Rules (AGENTS.md section 4):
//    * Paths stored in the database are relative to this folder.
//    * Times are UTC ISO-8601 text.
//    * A library that is newer than this app, or that is not a
//      ResearchBase library, is refused and left untouched.
//

import Foundation

final class Library {

    // MARK: Names

    static let folderName = "ResearchBase Library"
    static let databaseFileName = "library.sqlite"

    static let subfolderNames = ["files", "inbox", "drafts", "backups", "exports"]

    // MARK: State

    let root: URL
    let database: LibraryDatabase

    /// What the version was when this library was opened (before any migration).
    let versionOnOpen: Int

    /// True when this call created the library.
    let wasCreated: Bool

    private init(root: URL, database: LibraryDatabase, versionOnOpen: Int, wasCreated: Bool) {
        self.root = root
        self.database = database
        self.versionOnOpen = versionOnOpen
        self.wasCreated = wasCreated
    }

    // MARK: Folder layout

    var databaseURL: URL { root.appendingPathComponent(Self.databaseFileName) }
    var filesURL: URL { root.appendingPathComponent("files", isDirectory: true) }
    var inboxURL: URL { root.appendingPathComponent("inbox", isDirectory: true) }
    var draftsURL: URL { root.appendingPathComponent("drafts", isDirectory: true) }
    var backupsURL: URL { root.appendingPathComponent("backups", isDirectory: true) }
    var exportsURL: URL { root.appendingPathComponent("exports", isDirectory: true) }

    var schemaVersion: Int {
        get throws { try database.userVersion }
    }

    /// When the library was created (UTC ISO-8601), from the `meta` table.
    var createdAt: String? {
        get throws { try database.scalarText("SELECT value FROM meta WHERE key = 'created_at'") }
    }

    // MARK: Open

    /// Opens the library in `root`.
    ///
    /// - `createIfMissing`: make the folder, subfolders and database when
    ///   there is no library.sqlite yet. When false and none exists, throws `.libraryNotFound`.
    /// - `migrations`: normally `LibraryMigrations.all`. Tests pass their own.
    ///
    /// Order matters. The file is checked BEFORE anything is written, so
    /// a newer or foreign database is refused without a single change.
    static func open(
        at root: URL,
        createIfMissing: Bool = true,
        migrations: [LibraryMigration] = LibraryMigrations.all,
        appVersion: String? = nil
    ) throws -> Library {

        try LibraryMigrations.validate(migrations)

        let fileManager = FileManager.default
        let databaseURL = root.appendingPathComponent(databaseFileName)
        let existed = fileManager.fileExists(atPath: databaseURL.path)

        if !existed {
            guard createIfMissing else {
                throw LibraryError.libraryNotFound(root.path)
            }
            try makeFolder(root)
        }

        let database = try LibraryDatabase(path: databaseURL.path)

        do {
            // 1. Look before touching.
            let start = try preflight(database, supported: migrations.last?.version ?? 0, path: databaseURL.path)

            // 2. Folders.
            for name in subfolderNames {
                try makeFolder(root.appendingPathComponent(name, isDirectory: true))
            }

            // 3. Connection settings.
            try configure(database)

            // 4. Bring the schema up to date (each step is all-or-nothing).
            try LibraryMigrationRunner.migrate(database, using: migrations)

            // 5. Bookkeeping in `meta` (only writes what is missing or changed).
            try writeMeta(database, appVersion: appVersion ?? Self.currentAppVersion())

            return Library(
                root: root,
                database: database,
                versionOnOpen: start,
                wasCreated: start == 0
            )

        } catch {
            database.close()
            throw error
        }
    }

    func close() {
        database.close()
    }

    // MARK: Relative paths

    /// Turns a path stored in the database (relative) into a real URL inside this folder.
    /// Absolute paths and any ".." are refused.
    func url(forRelativePath relative: String) throws -> URL {

        guard
            !relative.isEmpty,
            !relative.hasPrefix("/"),
            !relative.hasPrefix("~"),
            !relative.contains("\\"),
            !relative.contains("\0")
        else {
            throw LibraryError.pathEscapesLibrary(relative)
        }

        var url = root

        for part in relative.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case "..": throw LibraryError.pathEscapesLibrary(relative)
            case ".": continue
            default: url.appendPathComponent(String(part))
            }
        }

        return url
    }

    // MARK: Time

    /// Now, in UTC, as ISO-8601 text with fractional seconds: 2026-10-18T09:30:00.123Z
    static func nowISO(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    // MARK: Private

    private static func makeFolder(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw LibraryError.couldNotCreateFolder(url.path)
        }
    }

    /// Reads only. Returns the version found.
    private static func preflight(
        _ database: LibraryDatabase,
        supported: Int,
        path: String
    ) throws -> Int {

        let version: Int
        let tableCount: Int64

        do {
            version = try database.userVersion
            tableCount = try database.scalarInt(
                "SELECT COUNT(*) FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'"
            ) ?? 0
        } catch LibraryError.sqlite(let code, _) where code == 26 /* SQLITE_NOTADB */ || code == 11 /* SQLITE_CORRUPT */ {
            throw LibraryError.notALibrary(path)
        }

        if version > supported {
            throw LibraryError.newerSchema(found: version, supported: supported)
        }

        // Version 0 with tables in it is somebody else's database.
        if version == 0 && tableCount > 0 {
            throw LibraryError.notALibrary(path)
        }

        return version
    }

    private static func configure(_ database: LibraryDatabase) throws {

        // Write-ahead log: readers never block the writer and a crash cannot
        // leave a half-written page. The setting is stored in the file.
        let mode = try database.scalarText("PRAGMA journal_mode = WAL") ?? ""
        guard mode.lowercased() == "wal" else {
            throw LibraryError.walNotEnabled(mode)
        }

        try database.exec("PRAGMA foreign_keys = ON")
        try database.exec("PRAGMA synchronous = FULL")
        try database.exec("PRAGMA busy_timeout = 5000")
    }

    private static func writeMeta(_ database: LibraryDatabase, appVersion: String) throws {

        let hasCreated = try database.scalarText(
            "SELECT value FROM meta WHERE key = 'created_at'"
        ) != nil

        if !hasCreated {
            try database.run(
                "INSERT OR IGNORE INTO meta (key, value) VALUES ('created_at', ?)",
                [.text(nowISO())]
            )
        }

        let storedVersion = try database.scalarText(
            "SELECT value FROM meta WHERE key = 'app_version'"
        )

        if storedVersion != appVersion {
            try database.run(
                "INSERT OR REPLACE INTO meta (key, value) VALUES ('app_version', ?)",
                [.text(appVersion)]
            )
        }
    }

    private static func currentAppVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }
}
