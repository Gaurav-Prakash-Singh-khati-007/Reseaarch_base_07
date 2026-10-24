//
//  LibraryDatabase.swift
//  ResearchBase
//
//  Phase 1, Step 1A (F-04)
//
//  A thin wrapper over the system SQLite (`import SQLite3`, no new
//  dependency). It does only what the library needs: run SQL, bind
//  values, read rows, and run a block inside a transaction.
//
//  Not thread-safe by design: the app uses one connection from the
//  main actor (the project default isolation).
//
//  Call `close()` when you are done. (There is deliberately no deinit
//  that closes the handle, to stay clear of actor-isolation rules.)
//

import Foundation
import SQLite3

/// SQLITE_TRANSIENT is a C macro Swift does not import. It tells SQLite to copy
/// the bound bytes straight away, so the Swift value may go away afterwards.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - Values and rows

enum SQLValue: Equatable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)

    var intValue: Int64? {
        if case .int(let v) = self { return v }
        return nil
    }

    var textValue: String? {
        if case .text(let v) = self { return v }
        return nil
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

struct SQLRow {

    let columns: [String: SQLValue]

    subscript(name: String) -> SQLValue {
        columns[name] ?? .null
    }

    func int(_ name: String) -> Int64? { self[name].intValue }
    func text(_ name: String) -> String? { self[name].textValue }
}

// MARK: - Database

final class LibraryDatabase {

    let path: String
    private var handle: OpaquePointer?

    /// Opens (and by default creates) a database file.
    /// `path` may be ":memory:" for tests.
    init(path: String, readOnly: Bool = false, create: Bool = true) throws {

        self.path = path

        var flags: Int32 = SQLITE_OPEN_FULLMUTEX
        if readOnly {
            flags |= SQLITE_OPEN_READONLY
        } else {
            flags |= SQLITE_OPEN_READWRITE
            if create { flags |= SQLITE_OPEN_CREATE }
        }

        var opened: OpaquePointer?
        let code = sqlite3_open_v2(path, &opened, flags, nil)

        guard code == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "could not open"
            if let opened { sqlite3_close_v2(opened) }
            throw LibraryError.sqlite(code: code, message: message)
        }

        self.handle = opened
    }

    static func inMemory() throws -> LibraryDatabase {
        try LibraryDatabase(path: ":memory:")
    }

    var isOpen: Bool { handle != nil }

    func close() {
        if let handle {
            sqlite3_close_v2(handle)
        }
        handle = nil
    }

    // MARK: Running SQL

    /// Runs one or more statements separated by semicolons. No parameters, no rows back.
    func exec(_ sql: String) throws {

        let db = try requireHandle()
        var errorPointer: UnsafeMutablePointer<CChar>?

        let code = sqlite3_exec(db, sql, nil, nil, &errorPointer)

        if code != SQLITE_OK {
            let message = errorPointer.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errorPointer)
            throw LibraryError.sqlite(code: code, message: message)
        }
    }

    /// Runs ONE statement with `?` parameters. Returns the number of rows it changed.
    @discardableResult
    func run(_ sql: String, _ params: [SQLValue] = []) throws -> Int {

        let db = try requireHandle()
        let statement = try prepare(sql, params, db: db)
        defer { sqlite3_finalize(statement) }

        var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            code = sqlite3_step(statement)
        }

        guard code == SQLITE_DONE else {
            throw error(code, db: db)
        }

        return Int(sqlite3_changes(db))
    }

    /// Runs ONE statement and returns every row.
    func rows(_ sql: String, _ params: [SQLValue] = []) throws -> [SQLRow] {

        let db = try requireHandle()
        let statement = try prepare(sql, params, db: db)
        defer { sqlite3_finalize(statement) }

        var result: [SQLRow] = []
        let columnCount = sqlite3_column_count(statement)

        while true {
            let code = sqlite3_step(statement)

            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw error(code, db: db) }

            var columns: [String: SQLValue] = [:]

            for index in 0..<columnCount {
                let name = String(cString: sqlite3_column_name(statement, index))
                columns[name] = value(at: index, in: statement)
            }

            result.append(SQLRow(columns: columns))
        }

        return result
    }

    /// First column of the first row, as an integer.
    func scalarInt(_ sql: String, _ params: [SQLValue] = []) throws -> Int64? {
        guard let row = try rowsFirstColumn(sql, params) else { return nil }
        return row.intValue
    }

    /// First column of the first row, as text.
    func scalarText(_ sql: String, _ params: [SQLValue] = []) throws -> String? {
        guard let row = try rowsFirstColumn(sql, params) else { return nil }
        return row.textValue
    }

    // MARK: Transactions

    /// Runs `body` in one transaction. If `body` throws, everything it did is undone.
    /// Transactions do not nest.
    func transaction<T>(_ body: () throws -> T) throws -> T {

        try exec("BEGIN IMMEDIATE")

        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            _ = try? exec("ROLLBACK")
            throw error
        }
    }

    // MARK: Schema version

    var userVersion: Int {
        get throws {
            Int(try scalarInt("PRAGMA user_version") ?? 0)
        }
    }

    func setUserVersion(_ version: Int) throws {
        try exec("PRAGMA user_version = \(version)")
    }

    // MARK: Private

    private func requireHandle() throws -> OpaquePointer {
        guard let handle else { throw LibraryError.closed }
        return handle
    }

    private func error(_ code: Int32, db: OpaquePointer) -> LibraryError {
        .sqlite(code: code, message: String(cString: sqlite3_errmsg(db)))
    }

    private func prepare(
        _ sql: String,
        _ params: [SQLValue],
        db: OpaquePointer
    ) throws -> OpaquePointer {

        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(db, sql, -1, &statement, nil)

        guard code == SQLITE_OK, let statement else {
            if let statement { sqlite3_finalize(statement) }
            throw error(code, db: db)
        }

        for (offset, param) in params.enumerated() {

            let index = Int32(offset + 1)
            let bindCode: Int32

            switch param {
            case .null:
                bindCode = sqlite3_bind_null(statement, index)
            case .int(let v):
                bindCode = sqlite3_bind_int64(statement, index, v)
            case .double(let v):
                bindCode = sqlite3_bind_double(statement, index, v)
            case .text(let v):
                bindCode = sqlite3_bind_text(statement, index, v, -1, sqliteTransient)
            case .blob(let v):
                if v.isEmpty {
                    bindCode = sqlite3_bind_zeroblob(statement, index, 0)
                } else {
                    bindCode = v.withUnsafeBytes { buffer in
                        sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), sqliteTransient)
                    }
                }
            }

            guard bindCode == SQLITE_OK else {
                sqlite3_finalize(statement)
                throw error(bindCode, db: db)
            }
        }

        return statement
    }

    private func value(at index: Int32, in statement: OpaquePointer) -> SQLValue {

        switch sqlite3_column_type(statement, index) {

        case SQLITE_INTEGER:
            return .int(sqlite3_column_int64(statement, index))

        case SQLITE_FLOAT:
            return .double(sqlite3_column_double(statement, index))

        case SQLITE_TEXT:
            guard let text = sqlite3_column_text(statement, index) else { return .text("") }
            return .text(String(cString: text))

        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, index))
            guard count > 0, let bytes = sqlite3_column_blob(statement, index) else {
                return .blob(Data())
            }
            return .blob(Data(bytes: bytes, count: count))

        default:
            return .null
        }
    }

    private func rowsFirstColumn(_ sql: String, _ params: [SQLValue]) throws -> SQLValue? {

        let db = try requireHandle()
        let statement = try prepare(sql, params, db: db)
        defer { sqlite3_finalize(statement) }

        let code = sqlite3_step(statement)

        if code == SQLITE_DONE { return nil }
        guard code == SQLITE_ROW else { throw error(code, db: db) }

        return value(at: 0, in: statement)
    }
}
