//
//  AppLogger.swift
//  ResearchBase
//
//  Owner: Agent 1 · Features: F-52 (logging and visible errors)
//
//  One place to log from, instead of print() and silent failures.
//
//  PUBLIC API
//  ----------
//  AppLogLevel                    debug < info < warning < error
//  AppLogEntry                    one log line (id, date, level, category, message, detail)
//  AppErrorText.plain(_:)         any Error -> short plain-language sentence for the user
//  AppErrorText.technical(_:)     any Error -> technical text for the log
//  AppErrorText.redact(_:)        hides API keys, tokens and passwords in text
//  AppLogger.shared               the app-wide logger (thread-safe, call from anywhere)
//    .log(_ level:, _ category:, _ message:, detail:)
//    .debug / .info / .warning (_ message:, category:)
//    .error(_ message:, category:)            logs a text at error level
//    .error(_ error:, context:, category:, show:)
//                                              logs an Error and, if `show`, raises a banner
//    .recentEntries(minimumLevel:limit:)       this session, oldest first
//    .entriesFromFiles(minimumLevel:limit:)    this and earlier sessions (rotated files)
//    .logFileURL / .logFileURLs / .logDirectory   for "Show in Finder"
//    .configure(logDirectory:), .setMinimumFileLevel(_:)
//    .clearRecent(), .deleteLogFiles(), .flush(), .setObserver(_:)
//  AppErrorCenter.shared          @MainActor @Observable: `current` is the error a banner shows,
//                                 `recent` the last few; `dismiss()` clears the banner
//  AppLogFeed.shared              @MainActor @Observable: `entries` / `visibleEntries` for a
//                                 log viewer screen; call `attach()` once at launch
//
//  Log files: ~/Library/Logs/ResearchBase/researchbase.log (JSON, one entry per line),
//  rotated at 1 MB, three files kept. Nothing here touches the library folder or database.
//  Secrets are redacted before anything is written.
//

import Foundation
import os
import Observation

// MARK: - Levels and entries

nonisolated enum AppLogLevel: Int, Codable, CaseIterable, Comparable, Sendable {
    case debug = 0
    case info
    case warning
    case error

    var label: String {
        switch self {
        case .debug: return "Debug"
        case .info: return "Info"
        case .warning: return "Warning"
        case .error: return "Error"
        }
    }

    var osLogType: OSLogType {
        switch self {
        case .debug: return .debug
        case .info: return .info
        case .warning: return .default
        case .error: return .error
        }
    }

    static func < (lhs: AppLogLevel, rhs: AppLogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

nonisolated struct AppLogEntry: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let date: Date
    let level: AppLogLevel
    let category: String
    let message: String
    /// Technical detail (for errors). Not meant for the user's eyes by default.
    let detail: String?
}

// MARK: - Error text

nonisolated enum AppErrorText {

    static let generic = "Something went wrong. The details were saved in the log."

    /// A short sentence a researcher can understand. Never a type name or an error code.
    static func plain(_ error: Error) -> String {
        let ns = error as NSError

        switch ns.domain {
        case NSCocoaErrorDomain:
            if let text = cocoaMessage(CocoaError.Code(rawValue: ns.code)) { return text }
        case NSURLErrorDomain:
            if let text = urlMessage(URLError.Code(rawValue: ns.code)) { return text }
        case NSPOSIXErrorDomain:
            if let text = posixMessage(Int32(truncatingIfNeeded: ns.code)) { return text }
        default:
            break
        }

        // The app's own errors (LibraryError, ModelError, ...) already carry plain words.
        if let described = (error as? LocalizedError)?.errorDescription, !described.isEmpty {
            return described
        }
        return generic
    }

    /// What goes into the log: the Swift description plus domain and code.
    static func technical(_ error: Error) -> String {
        let ns = error as NSError
        return "\(String(reflecting: error)) [\(ns.domain) \(ns.code)]"
    }

    // MARK: Redaction

    nonisolated private static let redactionRules: [(NSRegularExpression, String)] = {
        let specs: [(String, String)] = [
            (#"(?i)\b(api[_-]?key|access[_-]?token|token|secret|password|passwd|authorization)\b(\s*[:=]\s*)[^\s,;"']+"#,
             "$1$2[hidden]"),
            (#"(?i)\bBearer\s+[A-Za-z0-9._~+/-]+=*"#, "Bearer [hidden]"),
            (#"\bsk-[A-Za-z0-9_-]{16,}"#, "[hidden]")
        ]
        return specs.compactMap { spec in
            (try? NSRegularExpression(pattern: spec.0)).map { ($0, spec.1) }
        }
    }()

    /// Hides API keys, bearer tokens and `password=...` style values.
    static func redact(_ text: String) -> String {
        var result = text
        for (regex, template) in redactionRules {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: template)
        }
        return result
    }

    // MARK: Private mapping

    private static func cocoaMessage(_ code: CocoaError.Code) -> String? {
        switch code {
        case .fileNoSuchFile, .fileReadNoSuchFile:
            return "A file could not be found. It may have been moved or deleted."
        case .fileWriteOutOfSpace:
            return "The disk is full, so nothing more could be saved. Free up some space and try again."
        case .fileWriteNoPermission, .fileReadNoPermission:
            return "ResearchBase is not allowed to use that file or folder."
        case .fileReadCorruptFile:
            return "That file looks damaged and could not be read."
        case .fileWriteVolumeReadOnly:
            return "The disk is read-only, so nothing could be saved."
        case .userCancelled:
            return "The action was cancelled."
        default:
            return nil
        }
    }

    private static func urlMessage(_ code: URLError.Code) -> String? {
        switch code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
            return "There is no internet connection. Try again when you are online."
        case .timedOut:
            return "The website did not answer in time. Try again in a moment."
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return "The website could not be reached."
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate:
            return "A secure connection to the website could not be made."
        case .cancelled:
            return "The request was cancelled."
        default:
            return nil
        }
    }

    private static func posixMessage(_ code: Int32) -> String? {
        switch code {
        case ENOSPC, EDQUOT:
            return "The disk is full, so nothing more could be saved. Free up some space and try again."
        case EACCES, EPERM:
            return "ResearchBase is not allowed to use that file or folder."
        case ENOENT:
            return "A file could not be found. It may have been moved or deleted."
        case EROFS:
            return "The disk is read-only, so nothing could be saved."
        default:
            return nil
        }
    }
}

// MARK: - The logger

nonisolated final class AppLogger: @unchecked Sendable {

    static let shared = AppLogger()

    /// ~/Library/Logs/ResearchBase
    static var defaultLogDirectory: URL {
        FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("ResearchBase", isDirectory: true)
    }

    private static let baseFileName = "researchbase"

    // All mutable state below is only touched on `queue`.
    private let queue = DispatchQueue(label: "ResearchBase.AppLogger")
    private var directory: URL?
    private var fileLevel: AppLogLevel = .info
    private var recent: [AppLogEntry] = []
    private var observer: (@Sendable (AppLogEntry) -> Void)?

    private let maxFileBytes: Int
    private let maxFiles: Int
    private let maxRecent: Int
    private let subsystem: String

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init(
        logDirectory: URL? = AppLogger.defaultLogDirectory,
        maxFileBytes: Int = 1_000_000,
        maxFiles: Int = 3,
        maxRecent: Int = 1000,
        subsystem: String = Bundle.main.bundleIdentifier ?? "ResearchBase"
    ) {
        self.directory = logDirectory
        self.maxFileBytes = max(200, maxFileBytes)
        self.maxFiles = max(1, maxFiles)
        self.maxRecent = max(1, maxRecent)
        self.subsystem = subsystem
    }

    // MARK: Configuration

    /// Where the log files live. `nil` turns file logging off (the system log still gets entries).
    func configure(logDirectory: URL?) {
        queue.sync { self.directory = logDirectory }
    }

    /// Entries below this level are kept in memory only, not written to the file. Default: info.
    func setMinimumFileLevel(_ level: AppLogLevel) {
        queue.sync { self.fileLevel = level }
    }

    /// Called (on a background queue) after every entry. Used by `AppLogFeed`.
    func setObserver(_ observer: (@Sendable (AppLogEntry) -> Void)?) {
        queue.sync { self.observer = observer }
    }

    // MARK: Logging

    func log(_ level: AppLogLevel, _ category: String = "app", _ message: String, detail: String? = nil) {
        let entry = AppLogEntry(
            id: UUID(),
            date: Date(),
            level: level,
            category: category,
            message: AppErrorText.redact(message),
            detail: detail.map { AppErrorText.redact($0) }
        )

        os.Logger(subsystem: subsystem, category: category)
            .log(level: level.osLogType, "\(entry.message, privacy: .public)")

        queue.async { [self] in
            append(entry)
        }
    }

    func debug(_ message: String, category: String = "app") { log(.debug, category, message) }
    func info(_ message: String, category: String = "app") { log(.info, category, message) }
    func warning(_ message: String, category: String = "app") { log(.warning, category, message) }
    func error(_ message: String, category: String = "app") { log(.error, category, message) }

    /// Logs an Error (technical detail goes to the log) and, when `show` is true,
    /// raises a plain-language banner through `AppErrorCenter`.
    /// `context` says what the user was doing, e.g. "Could not add the paper".
    func error(_ error: Error, context: String, category: String = "app", show: Bool = true) {
        let plain = AppErrorText.plain(error)
        log(.error, category, "\(context): \(plain)", detail: AppErrorText.technical(error))

        if show {
            let redactedContext = AppErrorText.redact(context)
            let redactedPlain = AppErrorText.redact(plain)
            Task { @MainActor in
                AppErrorCenter.shared.show(title: redactedContext, message: redactedPlain)
            }
        }
    }

    // MARK: Reading

    /// This session's entries, oldest first.
    func recentEntries(minimumLevel: AppLogLevel = .debug, limit: Int = 500) -> [AppLogEntry] {
        queue.sync {
            Array(recent.filter { $0.level >= minimumLevel }.suffix(max(0, limit)))
        }
    }

    /// Entries from the log files (this and earlier sessions), oldest first.
    func entriesFromFiles(minimumLevel: AppLogLevel = .debug, limit: Int = 500) -> [AppLogEntry] {
        queue.sync {
            guard let directory else { return [] }
            var all: [AppLogEntry] = []

            for index in (0..<maxFiles).reversed() {
                let url = fileURL(index, in: directory)
                guard let data = try? Data(contentsOf: url) else { continue }
                for line in data.split(separator: 0x0A) {
                    if let entry = try? decoder.decode(AppLogEntry.self, from: Data(line)) {
                        all.append(entry)
                    }
                }
            }
            return Array(all.filter { $0.level >= minimumLevel }.suffix(max(0, limit)))
        }
    }

    var logDirectory: URL? {
        queue.sync { directory }
    }

    /// The file being written now.
    var logFileURL: URL? {
        queue.sync { directory.map { fileURL(0, in: $0) } }
    }

    /// All log files that exist, newest first.
    var logFileURLs: [URL] {
        queue.sync {
            guard let directory else { return [] }
            return (0..<maxFiles)
                .map { fileURL($0, in: directory) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
        }
    }

    // MARK: Housekeeping

    func clearRecent() {
        queue.sync { recent.removeAll() }
    }

    /// Deletes the log files on disk (not the in-memory entries).
    func deleteLogFiles() {
        queue.sync {
            guard let directory else { return }
            for index in 0..<maxFiles {
                try? FileManager.default.removeItem(at: fileURL(index, in: directory))
            }
        }
    }

    /// Waits until every entry logged so far has been written. For tests and for quitting.
    func flush() {
        queue.sync {}
    }

    // MARK: Private (always on `queue`)

    private func append(_ entry: AppLogEntry) {
        recent.append(entry)
        if recent.count > maxRecent {
            recent.removeFirst(recent.count - maxRecent)
        }

        if entry.level >= fileLevel {
            write(entry)
        }

        observer?(entry)
    }

    private func fileURL(_ index: Int, in directory: URL) -> URL {
        let name = index == 0
            ? "\(Self.baseFileName).log"
            : "\(Self.baseFileName).\(index).log"
        return directory.appendingPathComponent(name)
    }

    private func write(_ entry: AppLogEntry) {
        guard let directory else { return }
        let fileManager = FileManager.default

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = fileURL(0, in: directory)
            rotateIfNeeded(url, in: directory)

            var data = try encoder.encode(entry)
            data.append(0x0A)

            if !fileManager.fileExists(atPath: url.path) {
                fileManager.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // Logging must never crash or loop. The system log still has the entry.
            os.Logger(subsystem: subsystem, category: "logger")
                .error("Could not write the log file: \(String(describing: error), privacy: .public)")
        }
    }

    private func rotateIfNeeded(_ current: URL, in directory: URL) {
        let fileManager = FileManager.default
        guard let attributes = try? fileManager.attributesOfItem(atPath: current.path),
              let size = attributes[.size] as? Int,
              size >= maxFileBytes
        else { return }

        let last = maxFiles - 1
        if last == 0 {
            try? fileManager.removeItem(at: current)
            return
        }

        try? fileManager.removeItem(at: fileURL(last, in: directory))
        for index in (0..<last).reversed() {
            let from = fileURL(index, in: directory)
            if fileManager.fileExists(atPath: from.path) {
                try? fileManager.moveItem(at: from, to: fileURL(index + 1, in: directory))
            }
        }
    }
}

// MARK: - Visible errors (banner)

struct VisibleAppError: Identifiable, Equatable, Sendable {
    let id = UUID()
    let date = Date()
    /// What the user was doing, e.g. "Could not add the paper".
    let title: String
    /// Plain-language reason.
    let message: String
}

@MainActor
@Observable
final class AppErrorCenter {

    static let shared = AppErrorCenter()

    /// The error a banner should show right now. `nil` when there is nothing to show.
    private(set) var current: VisibleAppError?

    /// The last few errors, newest first.
    private(set) var recent: [VisibleAppError] = []

    private let maxRecent = 20

    init() {}

    func show(title: String, message: String) {
        let error = VisibleAppError(title: title, message: message)
        current = error
        recent.insert(error, at: 0)
        if recent.count > maxRecent {
            recent.removeLast(recent.count - maxRecent)
        }
    }

    func dismiss() {
        current = nil
    }

    func clearHistory() {
        current = nil
        recent.removeAll()
    }
}

// MARK: - Feed for a log viewer screen

@MainActor
@Observable
final class AppLogFeed {

    static let shared = AppLogFeed()

    private(set) var entries: [AppLogEntry] = []

    /// The viewer's filter. Entries below this level are hidden in `visibleEntries`.
    var minimumLevel: AppLogLevel = .info

    private let maxEntries = 1000

    init() {}

    var visibleEntries: [AppLogEntry] {
        entries.filter { $0.level >= minimumLevel }
    }

    /// Call once at launch. Loads earlier entries from the files, then follows new ones.
    func attach(to logger: AppLogger = .shared, history: Int = 200) {
        entries = logger.entriesFromFiles(limit: history)
        logger.setObserver { [weak self] entry in
            Task { @MainActor [weak self] in
                self?.append(entry)
            }
        }
    }

    func append(_ entry: AppLogEntry) {
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    func clear() {
        entries.removeAll()
    }
}
