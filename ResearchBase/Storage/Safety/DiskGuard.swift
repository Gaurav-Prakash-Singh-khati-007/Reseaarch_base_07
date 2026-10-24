//
//  DiskGuard.swift
//  ResearchBase
//
//  Owner: Agent 3 · Features: F-53 (low-disk and crash safety)
//
//  Two promises:
//  1. Writes are all-or-nothing. A file is written to a temporary file in the
//     same folder, flushed to disk, then swapped in. If the app crashes, the
//     disk fills, or the Mac loses power half way, the old file is still intact.
//  2. A banner appears before the disk fills, not after a save has failed.
//
//  PUBLIC API
//  ----------
//  DiskSpaceLevel                 ok < low < critical
//  DiskSpaceStatus                availableBytes, level, availableText, message (nil when ok)
//  DiskGuard                      value type, safe to use from any thread
//    .status(for: url)            free space on the disk that holds `url` (the path may not exist yet)
//    .ensureRoom(for: bytes, at: url, reserve:)   throws DiskGuardError.notEnoughSpace
//    .writeAtomically(_ data:, to:)               check space, temp file, flush, swap in
//    .copyAtomically(from:, to:)                  same for copying a file (PDFs, backups)
//    .removeStaleTemporaryFiles(in:olderThan:recursive:) -> Int   clean up after a crash
//    DiskGuard.formatBytes(_:)    "1.8 GB"
//  DiskGuardError                 plain-language LocalizedError
//  DiskSpaceMonitor               @MainActor @Observable, for the banner:
//    .status, .showsBanner, .bannerMessage, .refresh(), .start(every:), .stop(),
//    .dismissBanner(), .watch(_ url:)
//
//  Notes
//  - If the free space cannot be measured, the guard lets the write go ahead
//    (it never blocks saving just because it could not measure).
//  - Call `stop()` on a monitor you no longer need.
//  - This file does not log. Callers decide what to do with a thrown error.
//

import Foundation
import Observation

// MARK: - Status

nonisolated enum DiskSpaceLevel: Int, Comparable, Sendable {
    case ok = 0
    case low
    case critical

    static func < (lhs: DiskSpaceLevel, rhs: DiskSpaceLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

nonisolated struct DiskSpaceStatus: Equatable, Sendable {

    /// Free space in bytes, or nil when it could not be measured.
    let availableBytes: Int64?
    let level: DiskSpaceLevel

    var availableText: String {
        availableBytes.map(DiskGuard.formatBytes) ?? "unknown"
    }

    /// Plain words for a banner. nil when there is nothing to warn about.
    var message: String? {
        switch level {
        case .ok:
            return nil
        case .low:
            return "Your disk is getting full (\(availableText) left). Free up some space soon so ResearchBase can keep saving your work."
        case .critical:
            return "Your disk is almost full (\(availableText) left). ResearchBase may not be able to save. Free up space now."
        }
    }
}

// MARK: - Errors

nonisolated enum DiskGuardError: LocalizedError, Equatable {

    case notEnoughSpace(needed: Int64, available: Int64)
    case diskFull
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .notEnoughSpace(let needed, let available):
            return "There is not enough disk space to save this. It needs about \(DiskGuard.formatBytes(needed)) and only \(DiskGuard.formatBytes(available)) is free. Nothing was changed."
        case .diskFull:
            return "The disk filled up while saving. Nothing was changed. Free up some space and try again."
        case .writeFailed(let reason):
            return "Saving failed and nothing was changed. \(reason)"
        }
    }
}

// MARK: - The guard

nonisolated struct DiskGuard: Sendable {

    static let defaultLowBytes: Int64 = 2 * 1_000_000_000
    static let defaultCriticalBytes: Int64 = 500 * 1_000_000
    static let temporaryPrefix = ".rbtmp-"

    /// Below this much free space the banner says "getting full".
    let lowBytes: Int64
    /// Below this much free space the banner says "almost full", and
    /// writes keep this much room free for the system.
    let criticalBytes: Int64

    /// Free bytes on the disk that holds a path that exists. Replaceable for tests.
    let capacity: @Sendable (URL) -> Int64?

    init(
        lowBytes: Int64 = DiskGuard.defaultLowBytes,
        criticalBytes: Int64 = DiskGuard.defaultCriticalBytes,
        capacity: @escaping @Sendable (URL) -> Int64? = DiskGuard.systemCapacity
    ) {
        self.lowBytes = max(lowBytes, criticalBytes)
        self.criticalBytes = criticalBytes
        self.capacity = capacity
    }

    /// What the system says is free (counts space macOS can reclaim by itself).
    static let systemCapacity: @Sendable (URL) -> Int64? = { url in
        let values = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ])
        if let important = values?.volumeAvailableCapacityForImportantUsage {
            return important
        }
        return values?.volumeAvailableCapacity.map { Int64($0) }
    }

    static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: Space

    func status(for url: URL) -> DiskSpaceStatus {
        guard let free = capacity(existingAncestor(of: url)) else {
            return DiskSpaceStatus(availableBytes: nil, level: .ok)
        }
        let level: DiskSpaceLevel
        if free < criticalBytes {
            level = .critical
        } else if free < lowBytes {
            level = .low
        } else {
            level = .ok
        }
        return DiskSpaceStatus(availableBytes: free, level: level)
    }

    /// Throws when writing `bytes` would leave less than `reserve` free.
    /// Default reserve is the critical threshold, so the disk is never filled to the brim.
    func ensureRoom(for bytes: Int64, at url: URL, reserve: Int64? = nil) throws {
        guard let free = capacity(existingAncestor(of: url)) else { return }
        let needed = max(0, bytes)
        if free - needed < (reserve ?? criticalBytes) {
            throw DiskGuardError.notEnoughSpace(needed: needed, available: free)
        }
    }

    // MARK: All-or-nothing writes

    /// Writes `data` to `destination`. Either the whole new file is there afterwards,
    /// or the old file (or no file) is exactly as it was.
    func writeAtomically(_ data: Data, to destination: URL) throws {
        try ensureRoom(for: Int64(data.count), at: destination)

        let fileManager = FileManager.default
        let temp = temporaryURL(for: destination)

        do {
            guard fileManager.createFile(atPath: temp.path, contents: nil) else {
                throw DiskGuardError.writeFailed("A temporary file could not be created.")
            }
            let handle = try FileHandle(forWritingTo: temp)
            do {
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            try commit(temp, to: destination)
        } catch {
            try? fileManager.removeItem(at: temp)
            throw Self.mapped(error)
        }
    }

    /// Copies a file the same all-or-nothing way (stored PDFs, backups, exports).
    func copyAtomically(from source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        let attributes = try? fileManager.attributesOfItem(atPath: source.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        try ensureRoom(for: size, at: destination)

        let temp = temporaryURL(for: destination)
        do {
            try fileManager.copyItem(at: source, to: temp)
            try commit(temp, to: destination)
        } catch {
            try? fileManager.removeItem(at: temp)
            throw Self.mapped(error)
        }
    }

    // MARK: Crash leftovers

    /// Deletes temporary files an interrupted write left behind. Returns how many were removed.
    @discardableResult
    func removeStaleTemporaryFiles(
        in directory: URL,
        olderThan age: TimeInterval = 24 * 60 * 60,
        recursive: Bool = true
    ) -> Int {
        let fileManager = FileManager.default
        let cutoff = Date().addingTimeInterval(-age)
        var removed = 0

        func consider(_ url: URL) {
            guard url.lastPathComponent.hasPrefix(Self.temporaryPrefix) else { return }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard let modified, modified < cutoff else { return }
            if (try? fileManager.removeItem(at: url)) != nil { removed += 1 }
        }

        if recursive {
            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: []
            ) else { return 0 }
            for case let url as URL in enumerator { consider(url) }
        } else {
            let urls = (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: []
            )) ?? []
            urls.forEach(consider)
        }
        return removed
    }

    // MARK: Private

    private func temporaryURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent("\(Self.temporaryPrefix)\(UUID().uuidString)-\(destination.lastPathComponent)")
    }

    private func commit(_ temp: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temp)
        } else {
            try fileManager.moveItem(at: temp, to: destination)
        }
    }

    private func existingAncestor(of url: URL) -> URL {
        var current = url
        while !FileManager.default.fileExists(atPath: current.path), current.pathComponents.count > 1 {
            current.deleteLastPathComponent()
        }
        return current
    }

    private static func mapped(_ error: Error) -> DiskGuardError {
        if let known = error as? DiskGuardError { return known }

        let ns = error as NSError
        let isOutOfSpace =
            (ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError)
            || (ns.domain == NSPOSIXErrorDomain && (ns.code == Int(ENOSPC) || ns.code == Int(EDQUOT)))
        if isOutOfSpace { return .diskFull }

        return .writeFailed(ns.localizedDescription)
    }
}

// MARK: - Banner source

@MainActor
@Observable
final class DiskSpaceMonitor {

    private(set) var status: DiskSpaceStatus

    private let diskGuard: DiskGuard
    private var watched: URL
    private var dismissedLevel: DiskSpaceLevel?
    private var task: Task<Void, Never>?

    init(guard diskGuard: DiskGuard = DiskGuard(), watching url: URL) {
        self.diskGuard = diskGuard
        self.watched = url
        self.status = diskGuard.status(for: url)
    }

    /// True while a banner should be on screen. A dismissed "low" banner stays away
    /// until the disk gets worse ("critical") or recovers and fills up again.
    var showsBanner: Bool {
        guard status.level > .ok else { return false }
        guard let dismissedLevel else { return true }
        return status.level > dismissedLevel
    }

    var bannerMessage: String? {
        showsBanner ? status.message : nil
    }

    func refresh() {
        status = diskGuard.status(for: watched)
        if status.level == .ok { dismissedLevel = nil }
    }

    func watch(_ url: URL) {
        watched = url
        refresh()
    }

    func dismissBanner() {
        dismissedLevel = status.level
    }

    /// Checks now, then every `seconds` (default one minute) until `stop()`.
    func start(every seconds: TimeInterval = 60) {
        stop()
        refresh()
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(seconds))
                guard let self else { return }
                self.refresh()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
