//
//  StorageBreakdown.swift
//  ResearchBase
//
//  Owner: Agent 29 · Features: X-04 (library location and storage breakdown)
//
//  Measures the library folder and splits its size by kind, for the
//  Settings "Library and storage" card: the folder path, a size bar, and
//  chips such as "PDFs and files 4.2 GB". Read-only: it never writes,
//  moves or deletes anything, and it does not open the database.
//
//  PUBLIC API
//    enum StorageCategory            filesAndPDFs, database, drafts, backups,
//                                    inbox, exports, other
//      .displayName  .barOrder  .rawValue
//      static forTopLevelName(_:) -> StorageCategory
//    struct StorageBreakdown
//      let root: URL                 the library folder shown to the person
//      let exists: Bool              false when the folder is not there
//      let entries: [Entry]          one per category, always all seven, in bar order
//      let freeBytes: Int64?         free space on the library's disk
//      var totalBytes: Int64
//      var totalFiles: Int
//      func bytes(_ c) -> Int64
//      func fileCount(_ c) -> Int
//      func fraction(_ c) -> Double  share of the total, 0...1 (0 when empty)
//      var segments: [Segment]       non-empty categories only, for the bar
//      var displayPath: String       "~/Documents/ResearchBase Library"
//      func chipText(_ c) -> String  "Database 86 MB"
//      static func measure(root:, mode:) -> StorageBreakdown
//      static func measure(library:, mode:) -> StorageBreakdown
//      static func format(_ bytes: Int64) -> String        "4.2 GB"
//    enum StorageSizeMode            .onDisk (default), .logical
//    enum StorageReveal
//      static func reveal(_ url: URL) -> Bool              Reveal in Finder
//
//  How files are sorted into kinds (by the top-level item in the folder):
//    files/            -> PDFs and files
//    library.sqlite and its -wal, -shm, -journal files -> Database
//    drafts/           -> Drafts
//    backups/          -> Backups
//    inbox/            -> Inbox
//    exports/          -> Exports
//    anything else     -> Other
//  Symbolic links are counted as the small link itself and never followed,
//  so a link cannot make the total wrong or loop.
//

import Foundation
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Categories

enum StorageCategory: String, CaseIterable, Equatable {

    case filesAndPDFs = "files"
    case database
    case drafts
    case backups
    case inbox
    case exports
    case other

    /// The label on the chip.
    var displayName: String {
        switch self {
        case .filesAndPDFs: return "PDFs and files"
        case .database: return "Database"
        case .drafts: return "Drafts"
        case .backups: return "Backups"
        case .inbox: return "Inbox"
        case .exports: return "Exports"
        case .other: return "Other"
        }
    }

    /// Left-to-right order in the bar and the chips.
    var barOrder: Int {
        Self.allCases.firstIndex(of: self) ?? Self.allCases.count
    }

    /// Which kind a top-level name in the library folder belongs to.
    static func forTopLevelName(_ name: String) -> StorageCategory {
        switch name {
        case "files": return .filesAndPDFs
        case "drafts": return .drafts
        case "backups": return .backups
        case "inbox": return .inbox
        case "exports": return .exports
        case Library.databaseFileName,
             Library.databaseFileName + "-wal",
             Library.databaseFileName + "-shm",
             Library.databaseFileName + "-journal":
            return .database
        default: return .other
        }
    }
}

enum StorageSizeMode {
    /// Space the files take on the disk (rounded up to blocks), what Finder calls "size on disk".
    case onDisk
    /// Sum of file lengths. Exact and predictable, used by tests.
    case logical
}

// MARK: - Breakdown

struct StorageBreakdown: Equatable {

    struct Entry: Equatable {
        let category: StorageCategory
        let bytes: Int64
        let fileCount: Int
    }

    /// One piece of the size bar.
    struct Segment: Equatable {
        let category: StorageCategory
        let bytes: Int64
        let fraction: Double
    }

    let root: URL
    let exists: Bool
    let entries: [Entry]
    let freeBytes: Int64?

    // MARK: Totals

    var totalBytes: Int64 { entries.reduce(0) { $0 + $1.bytes } }

    var totalFiles: Int { entries.reduce(0) { $0 + $1.fileCount } }

    func bytes(_ category: StorageCategory) -> Int64 {
        entries.first { $0.category == category }?.bytes ?? 0
    }

    func fileCount(_ category: StorageCategory) -> Int {
        entries.first { $0.category == category }?.fileCount ?? 0
    }

    /// Share of the whole, 0 through 1. Zero for everything when the library is empty.
    func fraction(_ category: StorageCategory) -> Double {
        let total = totalBytes
        guard total > 0 else { return 0 }
        return Double(bytes(category)) / Double(total)
    }

    /// The categories that have something in them, in bar order. Fractions add up to 1.
    var segments: [Segment] {
        entries
            .filter { $0.bytes > 0 }
            .sorted { $0.category.barOrder < $1.category.barOrder }
            .map { Segment(category: $0.category, bytes: $0.bytes, fraction: fraction($0.category)) }
    }

    // MARK: Text for the screen

    /// The path as the person knows it: the home folder is written as "~".
    var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let path = root.standardizedFileURL.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// "Database 86 MB"
    func chipText(_ category: StorageCategory) -> String {
        "\(category.displayName) \(Self.format(bytes(category)))"
    }

    /// "4.2 GB" (decimal units, like Finder). Zero is spelled out because Foundation says "Zero KB".
    static func format(_ bytes: Int64) -> String {
        if bytes <= 0 { return "0 KB" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: bytes)
    }

    // MARK: Measuring

    static func measure(library: Library, mode: StorageSizeMode = .onDisk) -> StorageBreakdown {
        measure(root: library.root, mode: mode)
    }

    /// Walks the folder once and adds up each file under its kind.
    /// Never throws: a file that cannot be read is skipped, and a missing folder gives `exists == false`.
    static func measure(root: URL, mode: StorageSizeMode = .onDisk) -> StorageBreakdown {

        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory) && isDirectory.boolValue

        var bytes: [StorageCategory: Int64] = [:]
        var counts: [StorageCategory: Int] = [:]

        if exists {
            let keys = resourceKeys
            let top = (try? fileManager.contentsOfDirectory(
                at: root, includingPropertiesForKeys: keys, options: [])) ?? []

            for item in top {
                let category = StorageCategory.forTopLevelName(item.lastPathComponent)
                let measured = measureItem(item, mode: mode, fileManager: fileManager)
                bytes[category, default: 0] += measured.bytes
                counts[category, default: 0] += measured.files
            }
        }

        let entries = StorageCategory.allCases
            .sorted { $0.barOrder < $1.barOrder }
            .map { Entry(category: $0, bytes: bytes[$0] ?? 0, fileCount: counts[$0] ?? 0) }

        return StorageBreakdown(
            root: root, exists: exists, entries: entries,
            freeBytes: exists ? freeSpace(at: root) : nil)
    }

    // MARK: Private

    private static let resourceKeys: [URLResourceKey] = [
        .isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey,
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey
    ]

    /// Size and file count of one top-level item (a file, or a whole folder).
    private static func measureItem(
        _ url: URL, mode: StorageSizeMode, fileManager: FileManager
    ) -> (bytes: Int64, files: Int) {

        let keySet = Set(resourceKeys)
        guard let values = try? url.resourceValues(forKeys: keySet) else { return (0, 0) }

        // A link counts as the link, never as what it points at.
        if values.isSymbolicLink == true { return (fileSize(values, mode), 1) }
        if values.isRegularFile == true { return (fileSize(values, mode), 1) }
        guard values.isDirectory == true else { return (0, 0) }

        var total: Int64 = 0
        var files = 0

        // Only files are counted, not the folders themselves. That is what the person sees
        // as "size", and it keeps the numbers the same on every disk format.
        guard let walker = fileManager.enumerator(
            at: url, includingPropertiesForKeys: resourceKeys, options: [],
            errorHandler: { _, _ in true }
        ) else { return (0, 0) }

        for case let child as URL in walker {
            guard let childValues = try? child.resourceValues(forKeys: keySet) else { continue }
            if childValues.isSymbolicLink == true {
                total += fileSize(childValues, mode)
                files += 1
                walker.skipDescendants()
            } else if childValues.isRegularFile == true {
                total += fileSize(childValues, mode)
                files += 1
            }
        }
        return (total, files)
    }

    private static func fileSize(_ values: URLResourceValues, _ mode: StorageSizeMode) -> Int64 {
        switch mode {
        case .logical:
            return Int64(values.fileSize ?? 0)
        case .onDisk:
            if let allocated = values.totalFileAllocatedSize { return Int64(allocated) }
            if let allocated = values.fileAllocatedSize { return Int64(allocated) }
            return Int64(values.fileSize ?? 0)
        }
    }

    private static func freeSpace(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage { return important }
        if let attributes = try? FileManager.default.attributesOfFileSystem(forPath: url.path),
           let free = attributes[.systemFreeSize] as? NSNumber {
            return free.int64Value
        }
        return nil
    }
}

// MARK: - Reveal in Finder

enum StorageReveal {

    /// Shows the folder in Finder. Returns false when there is nothing to show
    /// (the folder is missing, or this is not a Mac build).
    @discardableResult
    static func reveal(_ url: URL) -> Bool {
        #if canImport(AppKit)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return true
        #else
        return false
        #endif
    }
}
