//
//  InboxFolderWatcher.swift
//  ResearchBase
//
//  Owner: Agent 31 · Features: F-20 (files dropped into the inbox folder are
//  added to the Inbox, even if they were dropped while the app was closed)
//
//  Watches `ResearchBase Library/inbox/`. Every PDF in it becomes an Inbox
//  paper (review_state = 'inbox', source_kind = 'inbox_folder') with the PDF
//  attached, and one `capture_log` row says what happened.
//
//  What happens to the dropped file
//    * Nothing is ever deleted. After a successful add, the original is MOVED to
//      inbox/Imported/. A PDF that is already in the library is moved to
//      inbox/Duplicates/. Names that clash get " 2", " 3" ... added.
//    * A file that is still being written or downloaded (hidden name, .crdownload,
//      .part ... or changed in the last few seconds) is left alone and tried again.
//    * Anything that is not a usable PDF stays where it is. It is counted in the
//      scan result and, if it looked like a PDF, logged once as "failed".
//    * Sub-folders (including Imported and Duplicates) are never scanned.
//
//  PUBLIC API
//    struct InboxScanResult             what one scan did
//    struct InboxWatcherConfig          settle time, rescan delay, folder names
//    @MainActor final class InboxFolderWatcher
//      init(model: LibraryModel, config: InboxWatcherConfig = .init())
//      var folderURL: URL                     the inbox folder being watched
//      private(set) var isWatching: Bool
//      var onScan: ((InboxScanResult) -> Void)?   called after a scan that did something
//      func start()                           scans once now (the "app was closed" case), then watches
//      func stop()
//      func scanNow() -> InboxScanResult      one pass, also usable without start()
//      static func title(fromFileName:) -> String
//      static func isPartialDownload(_ name: String) -> Bool
//    Folder names: InboxWatcherConfig.importedFolderName, .duplicatesFolderName
//
//  Rules this file follows
//    * Schema is frozen: it writes through ItemStore / AttachmentStore and inserts
//      into capture_log (via 'inbox_folder'). No other tables.
//    * Item and PDF are added in ONE transaction, so a failed attach leaves no half-made paper.
//    * Metadata lookup (F-15 / F-16) is not done here. The Inbox screen and the metadata
//      services enrich the paper afterwards; this file only gives it a readable title.
//    * The OCR check (F-23) belongs to OCRService; this file does not read PDF text.
//

import Foundation
#if canImport(PDFKit)
import PDFKit
#endif

// MARK: - Configuration and results

nonisolated struct InboxWatcherConfig: Equatable {

    /// A file must not have changed for this long before it is picked up.
    var settleSeconds: TimeInterval = 3

    /// Delay between a change in the folder and the scan it triggers (several events become one scan).
    var debounceSeconds: TimeInterval = 0.5

    /// Folder (inside inbox/) that receives files after they were added.
    var importedFolderName = "Imported"

    /// Folder (inside inbox/) that receives files whose PDF was already in the library.
    var duplicatesFolderName = "Duplicates"
}

struct InboxScanResult: Equatable {

    struct Added: Equatable {
        let itemID: String
        let fileName: String
    }

    struct Duplicate: Equatable {
        let existingItemID: String
        let fileName: String
    }

    struct Failure: Equatable {
        let fileName: String
        let reason: String
    }

    var added: [Added] = []
    var duplicates: [Duplicate] = []
    var failed: [Failure] = []

    /// Files that are probably still being written. They are tried again.
    var waiting = 0

    /// Files that are not PDFs. They stay where they are.
    var unsupported = 0

    /// True when the scan changed the library or logged a problem.
    var didSomething: Bool { !added.isEmpty || !duplicates.isEmpty || !failed.isEmpty }
}

// MARK: - Watcher

@MainActor
final class InboxFolderWatcher {

    // MARK: State

    let model: LibraryModel
    let config: InboxWatcherConfig

    private(set) var isWatching = false

    var onScan: ((InboxScanResult) -> Void)?

    var folderURL: URL { model.library.inboxURL }

    private var source: DispatchSourceFileSystemObject?
    private var descriptor: Int32 = -1
    private var pendingScan: DispatchWorkItem?
    private let queue = DispatchQueue(label: "researchbase.inbox-watcher", qos: .utility)

    /// Files already reported as failed in this run, so the same problem is logged once.
    private var reportedFailures = Set<String>()

    init(model: LibraryModel, config: InboxWatcherConfig = InboxWatcherConfig()) {
        self.model = model
        self.config = config
    }

    deinit {
        source?.cancel()
    }

    // MARK: Start and stop

    /// Scans once right away, then watches the folder for changes.
    /// Safe to call twice.
    func start() {
        guard !isWatching else { return }

        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        isWatching = true
        publish(scanNow())
        attachSource()
    }

    func stop() {
        pendingScan?.cancel()
        pendingScan = nil
        source?.cancel()
        source = nil
        isWatching = false
    }

    private func attachSource() {

        let fd = open(folderURL.path, O_EVTONLY)
        guard fd >= 0 else { return }   // the periodic rescan below still covers us

        descriptor = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: queue)

        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.scheduleScan(after: self?.config.debounceSeconds ?? 0.5) }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    private func scheduleScan(after delay: TimeInterval) {
        guard isWatching else { return }
        pendingScan?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.isWatching else { return }
                let result = self.scanNow()
                self.publish(result)
                // Files that were still settling need another look.
                if result.waiting > 0 {
                    self.scheduleScan(after: max(self.config.settleSeconds, 1) + 0.5)
                }
            }
        }
        pendingScan = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func publish(_ result: InboxScanResult) {
        if result.didSomething { onScan?(result) }
        if result.waiting > 0, isWatching {
            scheduleScan(after: max(config.settleSeconds, 1) + 0.5)
        }
    }

    // MARK: - One scan

    /// Looks at every file directly inside the inbox folder and handles it. Never throws:
    /// a problem with one file is reported in the result and the rest carry on.
    @discardableResult
    func scanNow() -> InboxScanResult {

        var result = InboxScanResult()
        let fileManager = FileManager.default

        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let urls = try? fileManager.contentsOfDirectory(
            at: folderURL, includingPropertiesForKeys: keys, options: []
        ) else { return result }

        // Oldest first, so papers appear in the order they were dropped.
        let files = urls
            .compactMap { url -> (URL, Date)? in
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true else { return nil }
                return (url, values.contentModificationDate ?? .distantPast)
            }
            .sorted { $0.1 == $1.1 ? $0.0.lastPathComponent < $1.0.lastPathComponent : $0.1 < $1.1 }

        for (url, modified) in files {

            let name = url.lastPathComponent

            if Self.isPartialDownload(name) {
                result.waiting += 1
                continue
            }
            guard url.pathExtension.lowercased() == "pdf" else {
                result.unsupported += 1
                continue
            }
            if Date().timeIntervalSince(modified) < config.settleSeconds {
                result.waiting += 1
                continue
            }

            handle(url, into: &result)
        }

        return result
    }

    // MARK: One file

    private func handle(_ url: URL, into result: inout InboxScanResult) {

        let name = url.lastPathComponent

        // 1. Is it a PDF at all?
        guard Self.looksLikePDF(url) else {
            fail(url, "The file is not a readable PDF.", into: &result)
            return
        }

        do {
            // 2. Fingerprint. A PDF that is already in the library is a duplicate.
            let sha = try AttachmentStore.sha256Hex(of: url)
            if let existing = try existingItemID(sha256: sha) {
                try log(result: "duplicate", detail: "\(name) is already in the library.",
                        sourceURL: name, itemID: existing)
                // If the move fails the file stays in the inbox and is reported again next scan, harmlessly.
                move(url, toFolder: config.duplicatesFolderName)
                result.duplicates.append(.init(existingItemID: existing, fileName: name))
                return
            }

            // 3. Item, PDF and log row in one transaction.
            let itemID: String = try model.atomically {
                var new = NewItem(title: Self.title(forPDFAt: url))
                new.type = .article
                new.sourceKind = .inboxFolder
                new.sourceURL = "inbox/\(name)"
                new.reviewState = .inbox
                let item = try model.items.create(new)
                _ = try model.attachments.add(fileAt: url, to: item.id, kind: .pdf)
                try log(result: "added", detail: "", sourceURL: "inbox/\(name)", itemID: item.id)
                return item.id
            }

            // 4. Only now is the original moved out of the way.
            move(url, toFolder: config.importedFolderName)
            reportedFailures.remove(url.path)
            result.added.append(.init(itemID: itemID, fileName: name))

        } catch {
            fail(url, Self.plainReason(error), into: &result)
        }
    }

    private func existingItemID(sha256: String) throws -> String? {
        try model.database.scalarText(
            """
            SELECT a.item_id FROM attachments a
            JOIN items i ON i.id = a.item_id
            WHERE a.sha256 = ? AND a.deleted_at IS NULL AND i.deleted_at IS NULL
            ORDER BY a.added_at LIMIT 1
            """,
            [.text(sha256)])
    }

    private func fail(_ url: URL, _ reason: String, into result: inout InboxScanResult) {
        result.failed.append(.init(fileName: url.lastPathComponent, reason: reason))
        // Log each problem file once per run, not on every scan.
        if reportedFailures.insert(url.path).inserted {
            try? log(result: "failed", detail: reason, sourceURL: "inbox/\(url.lastPathComponent)", itemID: nil)
        }
    }

    // MARK: capture_log

    private func log(result: String, detail: String, sourceURL: String, itemID: String?) throws {
        try model.database.run(
            "INSERT INTO capture_log (id, at, via, source_url, item_id, result, detail) VALUES (?, ?, 'inbox_folder', ?, ?, ?, ?)",
            [.text(model.newID()), .text(model.now()), .text(sourceURL),
             LibraryModel.text(itemID), .text(result), .text(detail)]
        )
    }

    // MARK: Moving files (never deleting)

    /// Moves `url` into a sub-folder of the inbox, choosing a free name. Returns false if it could not.
    @discardableResult
    private func move(_ url: URL, toFolder folderName: String) -> Bool {

        let fileManager = FileManager.default
        let folder = folderURL.appendingPathComponent(folderName, isDirectory: true)

        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = Self.freeName(for: url.lastPathComponent, in: folder)
            try fileManager.moveItem(at: url, to: destination)
            return true
        } catch {
            return false
        }
    }

    /// "paper.pdf", then "paper 2.pdf", "paper 3.pdf" ...
    static func freeName(for fileName: String, in folder: URL) -> URL {
        let fileManager = FileManager.default
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension

        var candidate = folder.appendingPathComponent(fileName)
        var number = 2
        while fileManager.fileExists(atPath: candidate.path) {
            let numbered = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
            candidate = folder.appendingPathComponent(numbered)
            number += 1
        }
        return candidate
    }

    // MARK: - Pure helpers

    /// Names that mean "still being written": hidden files and the usual browser download suffixes.
    nonisolated static func isPartialDownload(_ name: String) -> Bool {
        if name.hasPrefix(".") || name.hasPrefix("~$") { return true }
        let lower = name.lowercased()
        let suffixes = [".crdownload", ".download", ".part", ".partial", ".tmp", ".opdownload", ".filepart"]
        return suffixes.contains { lower.hasSuffix($0) }
    }

    /// "scan_0042.pdf" becomes "scan 0042". Always returns something readable.
    nonisolated static func title(fromFileName fileName: String) -> String {
        var stem = (fileName as NSString).deletingPathExtension
        stem = stem.replacingOccurrences(of: "_", with: " ")
        stem = stem.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return stem.isEmpty ? "Untitled PDF" : stem
    }

    /// The title stored inside the PDF when it has a real one, otherwise the file name.
    static func title(forPDFAt url: URL) -> String {
        #if canImport(PDFKit)
        if let document = PDFDocument(url: url),
           let embedded = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String {
            let trimmed = embedded.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = trimmed.lowercased()
            // Word and print drivers leave titles like "Microsoft Word - draft.docx" or "untitled".
            let junk = lower.hasPrefix("microsoft word") || lower.hasPrefix("untitled")
                || lower.hasSuffix(".pdf") || lower.hasSuffix(".docx") || lower.hasSuffix(".tex")
            if trimmed.count >= 4, !junk { return trimmed }
        }
        #endif
        return title(fromFileName: url.lastPathComponent)
    }

    /// True when the first kilobyte contains the PDF marker.
    nonisolated static func looksLikePDF(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 1024)) ?? Data()
        return head.range(of: Data("%PDF-".utf8)) != nil
    }

    private static func plainReason(_ error: Error) -> String {
        if let model = error as? ModelError, let text = model.errorDescription { return text }
        return "The file could not be added: \(error.localizedDescription)"
    }
}
