//
//  PDFTextIndexer.swift
//  ResearchBase
//
//  Owner: Agent 50 · Features: F-22 (indexing side), F-23 (OCR runs through here), F-24 (background, visible progress)
//
//  Puts the text of the PDFs in the library into the full-text index, so that
//  Search can find words INSIDE papers. It reads the text with OCRService
//  (Agent 13: embedded text where there is some, macOS Vision where a page is a
//  picture of text) and stores it with SearchService.indexPDF (Agent 14).
//
//  WHAT IT DOES, per PDF attachment
//    1. Finds PDFs that are not indexed yet (attachments.indexed_at is empty),
//       skipping Trash and deleted attachments.
//    2. Checks free disk space first (DiskGuard). Low disk stops the run and says so.
//    3. Reads the pages in the background, one PDF at a time, with progress.
//    4. Stores the text and, in the SAME all-or-nothing save, writes the bookkeeping
//       columns that already exist: pages, has_text, ocr_state, indexed_at.
//
//  OCR SWITCH ("Recognise text in scanned PDFs", Settings)
//    ON   scanned pages are read with Vision as part of indexing (ocr_state 'done').
//    OFF  only pages that already have text are indexed. A PDF with scanned pages gets
//         ocr_state 'queued' ("Scanned · OCR queued"). When the switch is turned on
//         later, `run()` reads just those pages. Pages are never indexed twice.
//
//  RULES THIS FILE FOLLOWS
//    - The index is ADD-ONLY (contentless FTS5, see SearchService). So a PDF is
//      indexed once, and a run that is cancelled or fails part-way stores NOTHING for
//      that PDF. It is picked up again next run. No half-indexed PDFs, no duplicates.
//    - Reads PDFs only. Never changes, moves or deletes a PDF or any other file.
//    - The only library writes are fts_pdf (through SearchService) and the four
//      bookkeeping columns above. No schema change.
//    - A PDF that cannot be opened (damaged, password-protected) is marked
//      ocr_state 'failed' with indexed_at set, so it is not retried on every launch.
//      `rebuildAll()` tries it again. A PDF whose FILE IS MISSING is left pending
//      (the file may come back, for example after a restore).
//    - One bad PDF never stops the others.
//    - Nothing starts on its own: the app calls `start()` (background) or `run()`.
//
//  KNOWN LIMIT
//    - Index rows of a PDF that is deleted later are not removed (a contentless index
//      cannot delete without the old text). Search already hides deleted attachments
//      and Trash, so nothing wrong is shown. `rebuildAll()` cleans them out.
//
//  PUBLIC API
//    enum PDFIndexingSettings            keys + defaults: indexInBackground, recogniseScanned (both on)
//    enum PDFIndexStatus                 .indexed(pages:ocrPages:) .waitingForOCR(indexedPages:) .noTextFound
//                                        .alreadyIndexed .missingFile .unreadable(_) .failed(_) .cancelled .busy
//    struct PDFIndexOutcome              attachmentID, title, status, warnings
//    struct PDFIndexSummary              outcomes, wasCancelled, wasBusy, stoppedReason, headline
//    struct PDFIndexProgress             attachmentsDone/Total, title, pagesDone/Total, fraction
//    struct PDFIndexBacklog              unindexed, waitingForOCR, isEmpty
//    @MainActor @Observable final class PDFTextIndexer
//        init(model:search:ocr:diskGuard:defaults:)
//        isRunning, progress, lastSummary, backlog, statusText
//        refreshBacklog()
//        run(includeOCRQueue:) async -> PDFIndexSummary         everything pending
//        indexNow(attachmentID:) async -> PDFIndexOutcome       one PDF, for right after an import
//        rebuildAll() async -> PDFIndexSummary                  clears fts_pdf, re-reads every PDF (slow with OCR)
//        start(force:) / cancel() / waitUntilIdle()             background run
//

import Foundation
import Observation

// MARK: - Settings

enum PDFIndexingSettings {

    static let indexInBackgroundKey = "search.indexInBackground"
    static let recogniseScannedKey = "search.recogniseScannedPDFs"

    /// "Index in the background". On by default.
    static var indexInBackground: Bool {
        value(forKey: indexInBackgroundKey, default: true, in: .standard)
    }

    /// "Recognise text in scanned PDFs". On by default.
    static var recogniseScanned: Bool {
        value(forKey: recogniseScannedKey, default: true, in: .standard)
    }

    static func value(forKey key: String, default fallback: Bool, in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }
}

// MARK: - Results

enum PDFIndexStatus: Equatable {
    /// Text stored. `ocrPages` of the pages were read with OCR.
    case indexed(pages: Int, ocrPages: Int)
    /// Text pages stored; scanned pages wait because OCR is switched off.
    case waitingForOCR(indexedPages: Int)
    /// The PDF opened fine but no words could be read from it.
    case noTextFound
    case alreadyIndexed
    case missingFile
    /// Damaged or password-protected. Not retried until `rebuildAll()`.
    case unreadable(String)
    /// A save problem. Nothing was stored; it is retried next run.
    case failed(String)
    case cancelled
    /// Another indexing run is in progress.
    case busy

    var isProblem: Bool {
        switch self {
        case .missingFile, .unreadable, .failed: return true
        default: return false
        }
    }
}

struct PDFIndexOutcome: Equatable {
    let attachmentID: String
    let title: String
    let status: PDFIndexStatus
    /// Plain-words notes, for example pages that could not be read.
    var warnings: [String] = []
}

struct PDFIndexSummary: Equatable {
    var outcomes: [PDFIndexOutcome] = []
    var wasCancelled = false
    var wasBusy = false
    /// Why the run stopped early (low disk, or the library could not be read).
    var stoppedReason: String?

    var indexedCount: Int {
        outcomes.filter { outcome in
            if case .indexed = outcome.status { return true }
            return false
        }.count
    }

    var waitingForOCRCount: Int {
        outcomes.filter { outcome in
            if case .waitingForOCR = outcome.status { return true }
            return false
        }.count
    }

    var problemCount: Int { outcomes.filter { $0.status.isProblem }.count }

    var headline: String {
        if wasBusy { return "Indexing is already running." }
        var parts: [String] = []
        if indexedCount > 0 { parts.append("Indexed \(Self.pdfs(indexedCount))") }
        if waitingForOCRCount > 0 { parts.append("\(Self.pdfs(waitingForOCRCount)) with scanned pages waiting for text recognition") }
        if problemCount > 0 { parts.append("\(Self.pdfs(problemCount)) could not be indexed") }
        if wasCancelled { parts.append("Stopped early") }
        if let stoppedReason { parts.append(stoppedReason) }
        if parts.isEmpty { return "Nothing to index." }
        return parts.joined(separator: ". ") + "."
    }

    private static func pdfs(_ count: Int) -> String {
        "\(count) \(count == 1 ? "PDF" : "PDFs")"
    }
}

struct PDFIndexProgress: Equatable {
    var attachmentsDone: Int
    var attachmentsTotal: Int
    /// Title of the paper being read.
    var title: String
    var pagesDone = 0
    var pagesTotal = 0

    /// 0 to 1 across the whole run.
    var fraction: Double {
        guard attachmentsTotal > 0 else { return 1 }
        let current = pagesTotal > 0 ? Double(pagesDone) / Double(pagesTotal) : 0
        return min(1, (Double(attachmentsDone) + current) / Double(attachmentsTotal))
    }
}

struct PDFIndexBacklog: Equatable {
    /// PDFs never indexed.
    var unindexed = 0
    /// Indexed, but with scanned pages still waiting for OCR.
    var waitingForOCR = 0

    var isEmpty: Bool { unindexed == 0 && waitingForOCR == 0 }
}

// MARK: - Indexer

@MainActor
@Observable
final class PDFTextIndexer {

    /// Room asked of DiskGuard before each PDF: a generous guess for the index rows of one big book.
    static let roomNeededPerPDF: Int64 = 32_000_000

    private(set) var isRunning = false
    private(set) var progress: PDFIndexProgress?
    private(set) var lastSummary: PDFIndexSummary?
    private(set) var backlog = PDFIndexBacklog()

    @ObservationIgnored private let model: LibraryModel
    @ObservationIgnored private let search: SearchService
    @ObservationIgnored private let ocr: OCRService
    @ObservationIgnored private let diskGuard: DiskGuard
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var cancelRequested = false

    init(
        model: LibraryModel,
        search: SearchService? = nil,
        ocr: OCRService? = nil,
        diskGuard: DiskGuard = DiskGuard(),
        defaults: UserDefaults = .standard
    ) {
        self.model = model
        self.search = search ?? SearchService(model: model)
        self.ocr = ocr ?? OCRService()
        self.diskGuard = diskGuard
        self.defaults = defaults
        refreshBacklog()
    }

    private var recogniseScanned: Bool {
        PDFIndexingSettings.value(forKey: PDFIndexingSettings.recogniseScannedKey, default: true, in: defaults)
    }

    // MARK: Status

    /// One plain line for the Settings screen ("Search index").
    var statusText: String {
        if let progress {
            return "Indexing PDF \(min(progress.attachmentsDone + 1, progress.attachmentsTotal)) of \(progress.attachmentsTotal)…"
        }
        var waiting = backlog.unindexed
        if recogniseScanned { waiting += backlog.waitingForOCR }
        if waiting == 0 {
            if backlog.waitingForOCR > 0 {
                return "Search index is up to date. \(backlog.waitingForOCR) scanned \(backlog.waitingForOCR == 1 ? "PDF is" : "PDFs are") waiting for text recognition."
            }
            return "Search index is up to date."
        }
        return "\(waiting) \(waiting == 1 ? "PDF is" : "PDFs are") waiting to be indexed."
    }

    func refreshBacklog() {
        let unindexed = (try? model.database.scalarInt(
            """
            SELECT COUNT(*) FROM attachments a JOIN items i ON i.id = a.item_id
            WHERE a.kind = 'pdf' AND a.deleted_at IS NULL AND i.deleted_at IS NULL AND a.indexed_at IS NULL
            """)) ?? 0
        let waiting = (try? model.database.scalarInt(
            """
            SELECT COUNT(*) FROM attachments a JOIN items i ON i.id = a.item_id
            WHERE a.kind = 'pdf' AND a.deleted_at IS NULL AND i.deleted_at IS NULL
              AND a.indexed_at IS NOT NULL AND a.ocr_state = 'queued'
            """)) ?? 0
        backlog = PDFIndexBacklog(unindexed: Int(unindexed), waitingForOCR: Int(waiting))
    }

    // MARK: Running

    /// Indexes every PDF that is pending. With OCR on it also reads the scanned pages of PDFs that were queued.
    /// Stops early (and says why) when the disk is low or when `cancel()` is called.
    @discardableResult
    func run(includeOCRQueue: Bool = true) async -> PDFIndexSummary {
        await runPending(includeOCRQueue: includeOCRQueue, only: nil)
    }

    /// Indexes one PDF now, for example right after it was imported.
    func indexNow(attachmentID: String) async -> PDFIndexOutcome {
        let summary = await runPending(includeOCRQueue: true, only: attachmentID)
        if summary.wasBusy {
            return PDFIndexOutcome(attachmentID: attachmentID, title: "", status: .busy)
        }
        if let first = summary.outcomes.first { return first }
        return PDFIndexOutcome(attachmentID: attachmentID, title: "", status: .alreadyIndexed)
    }

    /// Empties the PDF part of the search index and reads every PDF again. With OCR on this
    /// can take a long time. The person should be asked before this is called.
    @discardableResult
    func rebuildAll() async -> PDFIndexSummary {
        guard !isRunning else { return PDFIndexSummary(wasBusy: true) }
        do {
            try model.atomically {
                try search.resetPDFIndex()
                try model.database.run("UPDATE attachments SET indexed_at = NULL, ocr_state = 'none' WHERE kind = 'pdf'")
            }
        } catch {
            AppLogger.shared.error("Could not clear the PDF search index: \(AppErrorText.plain(error))", category: "search")
            var summary = PDFIndexSummary()
            summary.stoppedReason = "The search index could not be cleared. Nothing was changed"
            lastSummary = summary
            return summary
        }
        return await runPending(includeOCRQueue: true, only: nil)
    }

    // MARK: Background

    /// Starts a run in the background. Does nothing when "Index in the background" is off,
    /// unless `force` is true, or when a run is already going.
    func start(force: Bool = false) {
        guard task == nil, !isRunning else { return }
        let allowed = PDFIndexingSettings.value(forKey: PDFIndexingSettings.indexInBackgroundKey, default: true, in: defaults)
        guard force || allowed else { return }
        task = Task { [weak self] in
            guard let self else { return }
            await self.run()
            self.task = nil
        }
    }

    /// Stops after the PDF being read. Nothing is stored for a PDF that was cut short.
    func cancel() {
        guard task != nil || isRunning else { return }
        cancelRequested = true
        task?.cancel()
    }

    func waitUntilIdle() async {
        let running = task
        await running?.value
    }

    // MARK: The run

    private struct Pending {
        let id: String
        let relativePath: String
        let title: String
        /// True for a PDF whose text pages are already in the index and whose scanned pages were queued.
        let alreadyIndexed: Bool
    }

    private func runPending(includeOCRQueue: Bool, only attachmentID: String?) async -> PDFIndexSummary {
        guard !isRunning else { return PDFIndexSummary(wasBusy: true) }
        isRunning = true
        defer {
            isRunning = false
            progress = nil
            cancelRequested = false
            refreshBacklog()
        }

        var summary = PDFIndexSummary()
        let recognise = recogniseScanned

        let list: [Pending]
        do {
            list = try pending(includeOCRQueue: includeOCRQueue && recognise, only: attachmentID)
        } catch {
            summary.stoppedReason = "The library could not be read"
            AppLogger.shared.error("PDF indexing could not list the pending PDFs: \(AppErrorText.plain(error))", category: "search")
            lastSummary = summary
            return summary
        }

        for (position, item) in list.enumerated() {
            if cancelRequested || Task.isCancelled {
                summary.wasCancelled = true
                break
            }

            do {
                try diskGuard.ensureRoom(for: Self.roomNeededPerPDF, at: model.library.root)
            } catch {
                summary.stoppedReason = "Stopped because the disk is almost full. Free up some space and indexing will continue"
                AppLogger.shared.warning("PDF indexing stopped: low disk space.", category: "search")
                break
            }

            progress = PDFIndexProgress(attachmentsDone: position, attachmentsTotal: list.count, title: item.title)
            let outcome = await process(item, recognise: recognise)
            summary.outcomes.append(outcome)

            if outcome.status == .cancelled {
                summary.wasCancelled = true
                break
            }
            if outcome.status.isProblem {
                AppLogger.shared.warning("A PDF could not be indexed (\(outcome.status)).", category: "search")
            }
            await Task.yield()
        }

        if !summary.outcomes.isEmpty || summary.wasCancelled || summary.stoppedReason != nil {
            AppLogger.shared.info("PDF indexing: \(summary.headline)", category: "search")
        }
        lastSummary = summary
        return summary
    }

    private func pending(includeOCRQueue: Bool, only attachmentID: String?) throws -> [Pending] {
        let condition = includeOCRQueue
            ? "(a.indexed_at IS NULL OR a.ocr_state = 'queued')"
            : "a.indexed_at IS NULL"
        var sql = """
            SELECT a.id AS id, a.rel_path AS rel_path, i.title AS title, a.indexed_at AS indexed_at
            FROM attachments a JOIN items i ON i.id = a.item_id
            WHERE a.kind = 'pdf' AND a.deleted_at IS NULL AND i.deleted_at IS NULL AND \(condition)
            """
        var params: [SQLValue] = []
        if let attachmentID {
            sql += " AND a.id = ?"
            params.append(.text(attachmentID))
        }
        sql += " ORDER BY a.added_at, a.rowid"

        return try model.database.rows(sql, params).map { row in
            Pending(
                id: row.text("id") ?? "",
                relativePath: row.text("rel_path") ?? "",
                title: row.text("title") ?? "",
                alreadyIndexed: row.text("indexed_at") != nil
            )
        }
    }

    // MARK: One PDF

    private func process(_ item: Pending, recognise: Bool) async -> PDFIndexOutcome {

        func outcome(_ status: PDFIndexStatus, _ warnings: [String] = []) -> PDFIndexOutcome {
            PDFIndexOutcome(attachmentID: item.id, title: item.title, status: status, warnings: warnings)
        }

        let url: URL
        do {
            url = try model.library.url(forRelativePath: item.relativePath)
        } catch {
            return markUnreadable(item, reason: AppErrorText.plain(error), outcome)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return outcome(.missingFile)
        }

        let analysis: OCRDocumentAnalysis
        do {
            analysis = try ocr.analyse(pdfAt: url)
        } catch {
            return markUnreadable(item, reason: error.localizedDescription, outcome)
        }

        // Which pages to read this time.
        let pagesToRead: [Int]
        if item.alreadyIndexed {
            pagesToRead = analysis.pagesWithoutText                      // OCR queue: only the scanned pages
        } else if recognise {
            pagesToRead = analysis.pageCount > 0 ? Array(1...analysis.pageCount) : []
        } else {
            pagesToRead = analysis.pagesWithText                         // OCR off: only pages with text
        }

        var result = OCRDocumentResult(pageCount: analysis.pageCount, pages: [], wasCancelled: false)
        if !pagesToRead.isEmpty {
            do {
                result = try await ocr.readPages(
                    pdfAt: url,
                    pages: pagesToRead,
                    progress: { [weak self] update in
                        Task { @MainActor [weak self] in self?.notePages(update) }
                    }
                )
            } catch {
                if Task.isCancelled { return outcome(.cancelled) }
                return markUnreadable(item, reason: error.localizedDescription, outcome)
            }
        }

        // Cut short: store nothing, so the PDF is read in full next time (the index is add-only).
        if result.wasCancelled || Task.isCancelled || cancelRequested {
            return outcome(.cancelled)
        }

        let pages: [(page: Int, text: String)] = result.pages.compactMap { page in
            page.text.isEmpty ? nil : (page: page.pageNumber, text: page.text)
        }
        let recognisedPages = result.recognisedPageCount
        let failedPages = result.failedPages
        let warnings = Array(Set(result.pages.compactMap { $0.failure })).sorted()

        let needsOCR = analysis.needsOCR
        let ocrState: String
        if !needsOCR {
            ocrState = "none"
        } else if !recognise && !item.alreadyIndexed {
            ocrState = "queued"
        } else if recognisedPages > 0 || failedPages.isEmpty {
            ocrState = "done"
        } else {
            ocrState = "failed"
        }

        do {
            try model.atomically {
                try search.indexPDF(attachmentID: item.id, pages: pages)
                try model.database.run(
                    "UPDATE attachments SET pages = ?, has_text = ?, ocr_state = ?, indexed_at = ? WHERE id = ?",
                    [.int(Int64(analysis.pageCount)),
                     .int(analysis.pagesWithText.isEmpty ? 0 : 1),
                     .text(ocrState),
                     .text(model.now()),
                     .text(item.id)]
                )
            }
        } catch {
            return outcome(.failed(AppErrorText.plain(error)))
        }

        if ocrState == "queued" { return outcome(.waitingForOCR(indexedPages: pages.count), warnings) }
        if pages.isEmpty {
            if ocrState == "failed" { return outcome(.unreadable("The scanned pages could not be read."), warnings) }
            return outcome(.noTextFound, warnings)
        }
        return outcome(.indexed(pages: pages.count, ocrPages: recognisedPages), warnings)
    }

    /// Marks a PDF that cannot be opened so it is not retried on every run.
    private func markUnreadable(
        _ item: Pending,
        reason: String,
        _ outcome: (PDFIndexStatus, [String]) -> PDFIndexOutcome
    ) -> PDFIndexOutcome {
        _ = try? model.database.run(
            "UPDATE attachments SET ocr_state = 'failed', indexed_at = COALESCE(indexed_at, ?) WHERE id = ?",
            [.text(model.now()), .text(item.id)]
        )
        return outcome(.unreadable(reason), [])
    }

    private func notePages(_ update: OCRProgress) {
        guard var current = progress else { return }
        current.pagesDone = update.pagesDone
        current.pagesTotal = update.pagesTotal
        progress = current
    }
}
