//
//  LibraryError.swift
//  ResearchBase
//
//  Phase 1, Step 1A (F-04)
//
//  Everything that can go wrong when opening or migrating the library.
//  Each case says what happened in plain words; nothing here is shown
//  in a screen yet (the screens come in Step 1E).
//

import Foundation

enum LibraryError: LocalizedError, Equatable {

    /// The folder has no library.sqlite and the caller did not ask to create one.
    case libraryNotFound(String)

    /// library.sqlite exists but is not a ResearchBase library
    /// (another SQLite file, or not a database at all). Nothing was changed.
    case notALibrary(String)

    /// The library was written by a newer version of the app.
    /// Nothing was changed; the app must not open it.
    case newerSchema(found: Int, supported: Int)

    /// The list of migrations is wrong (a programming error).
    case invalidMigrations(String)

    /// A migration failed. It was rolled back, so the library is
    /// still exactly at the previous version.
    case migrationFailed(version: Int, message: String)

    /// A SQLite call failed.
    case sqlite(code: Int32, message: String)

    case couldNotCreateFolder(String)

    /// The database would not switch to WAL mode.
    case walNotEnabled(String)

    /// A relative path tried to leave the library folder (or was absolute).
    case pathEscapesLibrary(String)

    /// The database was already closed.
    case closed

    var errorDescription: String? {
        switch self {
        case .libraryNotFound(let path):
            return "There is no library at \(path)."
        case .notALibrary(let path):
            return "\(path) is not a ResearchBase library. It was left unchanged."
        case .newerSchema(let found, let supported):
            return "This library was made by a newer version of ResearchBase (format \(found); this version understands up to \(supported)). It was left unchanged."
        case .invalidMigrations(let reason):
            return "The list of library migrations is invalid: \(reason)"
        case .migrationFailed(let version, let message):
            return "Updating the library to format \(version) failed and was undone: \(message)"
        case .sqlite(let code, let message):
            return "Database error \(code): \(message)"
        case .couldNotCreateFolder(let path):
            return "Could not create the folder \(path)."
        case .walNotEnabled(let mode):
            return "The library database could not use write-ahead logging (mode is \(mode))."
        case .pathEscapesLibrary(let path):
            return "The path \(path) is not inside the library folder."
        case .closed:
            return "The library database is closed."
        }
    }
}
