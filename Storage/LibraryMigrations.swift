//
//  LibraryMigrations.swift
//  ResearchBase
//
//  Phase 1, Step 1A (F-04)
//
//  The schema version lives in `PRAGMA user_version`. Each migration
//  moves the database from version N-1 to N. Rules:
//
//    * A migration only adds or transforms. It never drops user data.
//    * Each migration runs in ONE transaction together with the
//      `user_version` change. If anything fails, everything is undone
//      and the library stays at the previous version.
//    * Never edit an existing migration. Add the next number.
//    * Every new migration needs a test that opens a saved
//      version-(N-1) library (see LibraryStorageTests).
//

import Foundation

struct LibraryMigration {

    /// The version the database has AFTER this migration.
    let version: Int
    let name: String
    /// One or more statements (no PRAGMAs, no BEGIN/COMMIT).
    let sql: String
}

enum LibraryMigrations {

    /// Every migration the app knows, in order. Versions must be 1, 2, 3, ... with no gaps.
    static let all: [LibraryMigration] = [
        LibraryMigration(
            version: 1,
            name: "Initial schema (docs/schema.sql)",
            sql: LibrarySchemaV1.sql
        )
    ]

    /// The newest version this build understands.
    static var currentVersion: Int { all.last?.version ?? 0 }

    /// Checks the list is 1, 2, 3, ... in order.
    static func validate(_ migrations: [LibraryMigration]) throws {

        for (offset, migration) in migrations.enumerated() {
            let expected = offset + 1
            guard migration.version == expected else {
                throw LibraryError.invalidMigrations(
                    "expected version \(expected) at position \(offset + 1), found \(migration.version)"
                )
            }
        }
    }
}

enum LibraryMigrationRunner {

    struct Outcome: Equatable {
        let from: Int
        let to: Int
        var changed: Bool { from != to }
    }

    /// Brings `database` up to the newest version in `migrations`.
    ///
    /// * Newer than the list  -> throws `.newerSchema`, changes nothing.
    /// * Already current      -> changes nothing.
    /// * Older                -> applies the missing migrations one by one.
    ///
    /// `beforeEach` runs before each migration starts (outside its transaction).
    /// It is the place to make a file backup when a future migration changes
    /// existing data. If it throws, the migration does not start.
    @discardableResult
    static func migrate(
        _ database: LibraryDatabase,
        using migrations: [LibraryMigration] = LibraryMigrations.all,
        beforeEach: ((LibraryMigration) throws -> Void)? = nil
    ) throws -> Outcome {

        try LibraryMigrations.validate(migrations)

        let supported = migrations.last?.version ?? 0
        let start = try database.userVersion

        guard start <= supported else {
            throw LibraryError.newerSchema(found: start, supported: supported)
        }

        for migration in migrations where migration.version > start {

            try beforeEach?(migration)

            do {
                try database.transaction {
                    try database.exec(migration.sql)
                    try database.setUserVersion(migration.version)
                }
            } catch {
                throw LibraryError.migrationFailed(
                    version: migration.version,
                    message: (error as? LocalizedError)?.errorDescription ?? "\(error)"
                )
            }

            // Belt and braces: the version must now be what we meant it to be.
            let now = try database.userVersion
            guard now == migration.version else {
                throw LibraryError.migrationFailed(
                    version: migration.version,
                    message: "version is \(now) after the migration"
                )
            }
        }

        return Outcome(from: start, to: max(start, supported))
    }
}
