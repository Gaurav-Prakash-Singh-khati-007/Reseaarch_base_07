//it game //
//  WorkspaceExportService.swift
//  ResearchBase
//
//  Phase 13 — Export
//
//  Owner: Agent 54 · Features: F-40 (draft export hook), F-50 (open-format export everything)
//
//  PUBLIC API (existing, unchanged)
//    WorkspaceExportFormat, WorkspaceExportError, WorkspaceExportResult, BibTeXExport
//    WorkspaceExportService.suggestedFileName(for:date:)
//    WorkspaceExportService.export(format:context:to:profile:)
//    WorkspaceExportService.jsonData / bibTeX / papersCSV / markdownSummary
//  PUBLIC API (added by Agent 54, bottom of file)
//    WorkspaceDraftExportResult
//    WorkspaceExportService.suggestedDraftFileName(title:format:)
//    WorkspaceExportService.exportDraft(draftID:model:format:to:overwrite:citations:)
//    WorkspaceOpenExportResult
//    WorkspaceExportService.suggestedEverythingFolderName(date:)
//    WorkspaceExportService.exportEverything(context:model:to:)
//    WorkspaceExportService.verifyOpenExport(at:expectedCounts:)
//
//  Writes the workspace out in five real formats:
//
//    Full workspace (.researchbase)  the complete backup package. This
//                                    calls WorkspaceBackupService; there
//                                    is no second backup implementation.
//    JSON (.json)                    the whole WorkspaceSnapshot, no PDFs.
//    BibTeX (.bib)                   papers only.
//    CSV (.csv)                      papers only.
//    Markdown (.md)                  a readable research summary.
//
//  Rules:
//  - Read-only. Nothing here inserts, changes or deletes a record.
//  - Everything is built from real stored data. Nothing is invented:
//    a BibTeX field that is empty in the app is left out of the entry,
//    and the Markdown summary only lists what exists.
//  - A file is reported as exported only after it has been written and
//    read back. JSON is also decoded again and its record counts are
//    compared with what was exported.
//  - An export with nothing to export (for example BibTeX with no
//    papers) throws instead of writing an empty file.
//  - Problems that do not stop an export but that the person should
//    know about (a PDF file that was missing, citation keys that had
//    to be changed, authors that could be read two ways) are returned
//    as `warnings`, not hidden.
//  - Whole-workspace formats stay as above. Draft export (Word, PDF,
//    .tex project, Markdown, plain text) is a separate hook,
//    `exportDraft`, because it works on one draft folder, not on the
//    workspace snapshot. It calls DocumentExporter; nothing is
//    converted here.
//
//  The text generators (`bibTeX`, `papersCSV`, `markdownSummary`,
//  `jsonData`) are pure functions of a WorkspaceSnapshot, so they can be
//  called and tested without a database.
//

import Foundation
import SwiftData

// MARK: - Formats

enum WorkspaceExportFormat: String, CaseIterable, Identifiable {

    case workspacePackage
    case json
    case bibtex
    case csv
    case markdown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .workspacePackage: return "Full Workspace (.researchbase)"
        case .json: return "JSON"
        case .bibtex: return "BibTeX"
        case .csv: return "CSV"
        case .markdown: return "Markdown Summary"
        }
    }

    var detail: String {
        switch self {
        case .workspacePackage:
            return "Every record plus the PDF files. Can be imported or restored."
        case .json:
            return "Every record as JSON. PDF files are not included."
        case .bibtex:
            return "Papers as BibTeX entries."
        case .csv:
            return "Papers as a spreadsheet-friendly CSV file."
        case .markdown:
            return "A readable summary of your research."
        }
    }

    var fileExtension: String {
        switch self {
        case .workspacePackage: return WorkspaceFormat.packageExtension
        case .json: return "json"
        case .bibtex: return "bib"
        case .csv: return "csv"
        case .markdown: return "md"
        }
    }

    var systemImage: String {
        switch self {
        case .workspacePackage: return "shippingbox"
        case .json: return "curlybraces"
        case .bibtex: return "text.book.closed"
        case .csv: return "tablecells"
        case .markdown: return "doc.plaintext"
        }
    }

    /// True when the export is a folder package rather than one file.
    var isPackage: Bool { self == .workspacePackage }

    fileprivate var fileNameStem: String {
        switch self {
        case .workspacePackage: return "ResearchBase Workspace"
        case .json: return "ResearchBase Workspace"
        case .bibtex: return "ResearchBase References"
        case .csv: return "ResearchBase Papers"
        case .markdown: return "ResearchBase Summary"
        }
    }
}

// MARK: - Errors

enum WorkspaceExportError: LocalizedError {

    case nothingToExport(String)
    case writeFailed(String)
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {

        case .nothingToExport(let detail):
            return "There is nothing to export. \(detail)"

        case .writeFailed(let detail):
            return "The export could not be written. \(detail)"

        case .verificationFailed(let detail):
            return "The export was written but failed verification. \(detail)"
        }
    }
}

// MARK: - Result

struct WorkspaceExportResult {

    let format: WorkspaceExportFormat

    /// Where the export now lives.
    let url: URL

    let byteCount: Int64

    /// One line for the UI, e.g. "42 BibTeX entries".
    let summary: String

    /// Things that did not stop the export but that the person should
    /// know about. Empty when everything was clean.
    let warnings: [String]
}

/// Output of the BibTeX generator.
nonisolated struct BibTeXExport {
    let text: String
    let entryCount: Int
    let warnings: [String]
}

// MARK: - Service

enum WorkspaceExportService {

    // MARK: File names

    /// A readable default file name, e.g.
    /// "ResearchBase References 2026-09-28 14-05-09.bib".
    static func suggestedFileName(
        for format: WorkspaceExportFormat,
        date: Date = Date()
    ) -> String {

        if format.isPackage {
            return WorkspaceBackupService.suggestedFileName(
                prefix: format.fileNameStem,
                date: date
            )
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"

        return "\(format.fileNameStem) \(formatter.string(from: date)).\(format.fileExtension)"
    }

    // MARK: Export

    /// Exports the workspace in `format` to `destination`.
    ///
    /// `destination` is the file the person chose (for the package
    /// format, the package folder). The right extension is added if it
    /// is missing. An existing file at the destination is replaced
    /// atomically, so a failed export never leaves half a file.
    @MainActor
    static func export(
        format: WorkspaceExportFormat,
        context: ModelContext,
        to destination: URL,
        profile: ProfileStore? = nil
    ) async throws -> WorkspaceExportResult {

        // Full workspace: the existing backup service does all the work.

        if format == .workspacePackage {
            return try await exportPackage(
                context: context,
                destination: destination,
                profile: profile
            )
        }

        // Single-file formats are built from a read-only snapshot.

        let capture = try WorkspaceSnapshot.capture(from: context)
        let snapshot = capture.snapshot

        guard snapshot.totalRecordCount > 0 else {
            throw WorkspaceExportError.nothingToExport(
                "The workspace has no records yet."
            )
        }

        let exportedAt = Date()

        let data: Data
        let summary: String
        var warnings: [String] = []

        switch format {

        case .workspacePackage:
            // Handled above. Kept so the switch stays exhaustive.
            return try await exportPackage(
                context: context,
                destination: destination,
                profile: profile
            )
        case .json:
            data = try jsonData(from: snapshot)
            summary = "\(snapshot.totalRecordCount) records (PDF files not included)"

        case .bibtex:
            guard !snapshot.papers.isEmpty else {
                throw WorkspaceExportError.nothingToExport(
                    "There are no papers to write as BibTeX."
                )
            }

            let bib = bibTeX(from: snapshot, exportedAt: exportedAt)
            data = Data(bib.text.utf8)
            summary = "\(bib.entryCount) BibTeX entries"
            warnings = bib.warnings

        case .csv:
            guard !snapshot.papers.isEmpty else {
                throw WorkspaceExportError.nothingToExport(
                    "There are no papers to write as CSV."
                )
            }

            data = Data(papersCSV(from: snapshot).utf8)
            summary = "\(snapshot.papers.count) papers"

        case .markdown:
            let text = markdownSummary(from: snapshot, exportedAt: exportedAt)
            data = Data(text.utf8)
            summary = "\(snapshot.totalRecordCount) records summarised"
        }

        let target = normalizedDestination(
            destination,
            fileExtension: format.fileExtension
        )

        // JSON is decoded again after writing and its counts compared,
        // so "exported" means "can be read back", not just "was written".

        let expectedCounts = snapshot.entityCounts

        try write(data, to: target) { written in

            guard format == .json else { return }

            let decoded: WorkspaceSnapshot

            do {
                decoded = try WorkspaceJSON.makeDecoder()
                    .decode(WorkspaceSnapshot.self, from: written)
            } catch {
                throw WorkspaceExportError.verificationFailed(
                    "The JSON could not be read back (\(error.localizedDescription))."
                )
            }

            if decoded.entityCounts != expectedCounts {
                throw WorkspaceExportError.verificationFailed(
                    "The record counts in the file do not match the workspace."
                )
            }
        }

        return WorkspaceExportResult(
            format: format,
            url: target,
            byteCount: Int64(data.count),
            summary: summary,
            warnings: warnings
        )
    }

    // MARK: Full workspace

    private static func exportPackage(
        context: ModelContext,
        destination: URL,
        profile: ProfileStore?
    ) async throws -> WorkspaceExportResult {

        let backup = try await WorkspaceBackupService.createBackup(
            context: context,
            to: destination,
            profile: profile
        )

        var warnings: [String] = []

        let missing = backup.papersWithMissingPDF

        if !missing.isEmpty {

            let shown = missing.prefix(5).joined(separator: ", ")
            let more = missing.count > 5 ? " and more" : ""

            warnings.append(
                "The PDF file could not be found for \(missing.count) paper(s), so no PDF was saved for: \(shown)\(more)."
            )
        }

        let total = backup.manifest.entityCounts.values.reduce(0, +)

        return WorkspaceExportResult(
            format: .workspacePackage,
            url: backup.packageURL,
            byteCount: backup.totalBytes,
            summary: "\(total) records and \(backup.pdfCount) PDF files",
            warnings: warnings
        )
    }

    // MARK: Writing

    private static func normalizedDestination(
        _ url: URL,
        fileExtension: String
    ) -> URL {

        if url.pathExtension.lowercased() == fileExtension {
            return url
        }

        return url.appendingPathExtension(fileExtension)
    }

    /// Writes atomically, reads the file back, and runs `verify` on
    /// what was read. Throws if anything differs.
    private static func write(
        _ data: Data,
        to url: URL,
        verify: (Data) throws -> Void
    ) throws {

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw WorkspaceExportError.writeFailed(error.localizedDescription)
        }

        let readBack: Data

        do {
            readBack = try Data(contentsOf: url)
        } catch {
            throw WorkspaceExportError.verificationFailed(
                "The file could not be read back (\(error.localizedDescription))."
            )
        }

        guard readBack == data else {
            throw WorkspaceExportError.verificationFailed(
                "The file on disk does not match what was exported."
            )
        }

        try verify(readBack)
    }

    // MARK: - JSON

    /// The complete WorkspaceSnapshot, encoded with the shared
    /// workspace encoder (ISO-8601 dates).
    ///
    /// PDFs are not part of this export, so the references to package
    /// files are removed: `pdfFileName` is cleared and a PDF that a
    /// backup would have included is marked "excluded". Everything else
    /// is exactly what the snapshot holds.
    nonisolated static func jsonData(from snapshot: WorkspaceSnapshot) throws -> Data {

        var copy = snapshot

        for index in copy.papers.indices {

            copy.papers[index].pdfFileName = nil

            if copy.papers[index].pdfState == "included" {
                copy.papers[index].pdfState = "excluded"
            }
        }

        do {
            return try WorkspaceJSON.makeEncoder().encode(copy)
        } catch {
            throw WorkspaceExportError.writeFailed(error.localizedDescription)
        }
    }

    // MARK: - BibTeX

    /// BibTeX for every paper.
    ///
    /// - Entry type comes from the paper's `PublicationType`.
    /// - Keys: the stored `citationKey` when there is one, otherwise a
    ///   key generated by `CitationFormatter.suggestedCitationKey`.
    ///   Keys are made unique (BibTeX keys ignore letter case) with
    ///   `CitationFormatter.uniqueCitationKey`. Stored keys are never
    ///   changed in the app; only the exported text differs.
    /// - Empty fields are omitted. Nothing is invented.
    nonisolated static func bibTeX(
        from snapshot: WorkspaceSnapshot,
        exportedAt: Date = Date()
    ) -> BibTeXExport {

        let dates = ExportDates()

        // A fixed order, so the same workspace always exports the same
        // keys: oldest paper first.
        let papers = snapshot.papers.sorted { a, b in
            if a.addedAt != b.addedAt { return a.addedAt < b.addedAt }
            return a.id.uuidString < b.id.uuidString
        }

        // ---- Keys ----

        var used = Set<String>()          // lower-cased
        var keyByID: [UUID: String] = [:]

        var changedKeys = 0
        var generatedKeys = 0

        func claim(_ base: String) -> String {

            let lower = base.lowercased()

            if !used.contains(lower) {
                used.insert(lower)
                return base
            }

            let unique = CitationFormatter.uniqueCitationKey(
                base: lower,
                existingKeys: used
            )

            used.insert(unique)
            return unique
        }

        // Papers that already have a key claim it first, so a
        // generated key can never take a key someone typed.

        for paper in papers {

            let stored = paper.citationKey
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let cleaned = ExportText.bibKey(stored)

            guard !cleaned.isEmpty else { continue }

            let key = claim(cleaned)

            if key != stored { changedKeys += 1 }

            keyByID[paper.id] = key
        }

        for paper in papers where keyByID[paper.id] == nil {

            let base = CitationFormatter.suggestedCitationKey(
                authors: paper.authors,
                year: paper.year,
                title: paper.title
            )

            keyByID[paper.id] = claim(base)
            generatedKeys += 1
        }

        // ---- Entries ----

        var entries: [(key: String, text: String)] = []

        var ambiguousAuthors = 0
        var missingAuthors = 0
        var missingYear = 0
        var missingTitle = 0

        for paper in papers {

            guard let key = keyByID[paper.id] else { continue }

            let entry = bibEntry(for: paper, key: key)

            entries.append((key: key, text: entry.text))

            if entry.ambiguousAuthors { ambiguousAuthors += 1 }

            if ExportText.collapse(paper.authors).isEmpty { missingAuthors += 1 }
            if paper.year <= 0 { missingYear += 1 }
            if ExportText.collapse(paper.title).isEmpty { missingTitle += 1 }
        }

        entries.sort { a, b in
            let left = a.key.lowercased()
            let right = b.key.lowercased()
            if left != right { return left < right }
            return a.key < b.key
        }

        // ---- Warnings ----

        var warnings: [String] = []

        if generatedKeys > 0 {
            warnings.append(
                "\(generatedKeys) paper(s) had no citation key, so keys were generated for this file. The keys stored in ResearchBase were not changed."
            )
        }

        if changedKeys > 0 {
            warnings.append(
                "\(changedKeys) citation key(s) were changed in this file because they were already used by another paper or contained characters BibTeX does not allow. The keys stored in ResearchBase were not changed."
            )
        }

        if ambiguousAuthors > 0 {
            warnings.append(
                "\(ambiguousAuthors) paper(s) list authors separated only by commas, which can be read more than one way. Separate authors with semicolons in ResearchBase for exact BibTeX names."
            )
        }

        var missing: [String] = []
        if missingAuthors > 0 { missing.append("\(missingAuthors) without authors") }
        if missingYear > 0 { missing.append("\(missingYear) without a year") }
        if missingTitle > 0 { missing.append("\(missingTitle) without a title") }

        if !missing.isEmpty {
            let joined = missing.joined(separator: ", ")
            warnings.append(
                "Some entries are incomplete because the paper has no such data: \(joined). These fields were left out rather than guessed."
            )
        }

        // ---- File text ----

        var lines: [String] = [
            "% ResearchBase BibTeX export",
            "% Exported: \(dates.iso(exportedAt))",
            "% Entries: \(entries.count)",
            ""
        ]

        for entry in entries {
            lines.append(entry.text)
            lines.append("")
        }

        return BibTeXExport(
            text: lines.joined(separator: "\n"),
            entryCount: entries.count,
            warnings: warnings
        )
    }

    nonisolated private static func bibEntry(
        for paper: PaperDTO,
        key: String
    ) -> (text: String, ambiguousAuthors: Bool) {

        let kind = ExportText.bibKind(for: paper.publicationTypeRawValue)

        var fields: [(name: String, value: String)] = []
        var noteParts: [String] = []

        if let note = kind.note { noteParts.append(note) }

        // author

        let authors = ExportText.splitAuthors(paper.authors)

        if !authors.names.isEmpty {
            let joined = authors.names
                .map { ExportText.bibName($0) }
                .joined(separator: " and ")

            fields.append((name: "author", value: joined))
        }

        // title (double braces keep the capitalisation as typed)

        let title = ExportText.collapse(paper.title)

        if !title.isEmpty {
            fields.append((name: "title", value: "{" + ExportText.bibEscape(title) + "}"))
        }

        // venue / publisher, placed by entry type

        let venue = ExportText.collapse(paper.venue)
        let publisher = ExportText.collapse(paper.publisher)

        if !venue.isEmpty {

            switch kind.entryType {

            case "article":
                fields.append((name: "journal", value: ExportText.bibEscape(venue)))

            case "inproceedings", "incollection":
                fields.append((name: "booktitle", value: ExportText.bibEscape(venue)))

            case "misc":
                fields.append((name: "howpublished", value: ExportText.bibEscape(venue)))

            case "techreport":
                break   // handled with the publisher below

            default:
                // No natural field for it on this entry type. Keep it
                // in the note so it is not lost.
                noteParts.append(venue)
            }
        }

        if kind.entryType == "techreport" {

            let institution = publisher.isEmpty ? venue : publisher

            if !institution.isEmpty {
                fields.append((name: "institution", value: ExportText.bibEscape(institution)))
            }

            if !venue.isEmpty && !publisher.isEmpty {
                noteParts.append(venue)
            }

        } else if !publisher.isEmpty {
            fields.append((name: "publisher", value: ExportText.bibEscape(publisher)))
        }

        // year / month

        if paper.year > 0 {
            fields.append((name: "year", value: String(paper.year)))
        }

        let month = ExportText.collapse(paper.month)

        if !month.isEmpty {
            fields.append((name: "month", value: ExportText.bibEscape(month)))
        }

        // volume / number / pages / edition

        let volume = ExportText.collapse(paper.volume)

        if !volume.isEmpty {
            fields.append((name: "volume", value: ExportText.bibEscape(volume)))
        }

        let issue = ExportText.collapse(paper.issue)

        if !issue.isEmpty {
            fields.append((name: "number", value: ExportText.bibEscape(issue)))
        }

        let pages = ExportText.collapse(paper.pages)

        if !pages.isEmpty {
            let normalized = ExportText.bibPages(pages)
            fields.append((name: "pages", value: ExportText.bibEscape(normalized)))
        }

        let edition = ExportText.collapse(paper.edition)

        if !edition.isEmpty {
            fields.append((name: "edition", value: ExportText.bibEscape(edition)))
        }

        // doi / url (written as typed, minus whitespace and braces)

        let doi = ExportText.bibRaw(paper.doi)

        if !doi.isEmpty {
            fields.append((name: "doi", value: doi))
        }

        let url = ExportText.bibRaw(paper.urlString)

        if !url.isEmpty {
            fields.append((name: "url", value: url))
        }

        // abstract / keywords

        let abstractText = ExportText.collapse(paper.abstractText)

        if !abstractText.isEmpty {
            fields.append((name: "abstract", value: ExportText.bibEscape(abstractText)))
        }

        let tags = paper.tagsText
            .split(separator: ",")
            .map { ExportText.collapse(String($0)) }
            .filter { !$0.isEmpty }

        if !tags.isEmpty {
            let joined = tags
                .map { ExportText.bibEscape($0) }
                .joined(separator: ", ")

            fields.append((name: "keywords", value: joined))
        }

        // note

        if !noteParts.isEmpty {
            let joined = noteParts
                .map { ExportText.bibEscape($0) }
                .joined(separator: "; ")

            fields.append((name: "note", value: joined))
        }

        // text

        var lines: [String] = ["@\(kind.entryType){\(key),"]

        for field in fields {
            lines.append("  \(field.name) = {\(field.value)},")
        }

        lines.append("}")

        return (
            text: lines.joined(separator: "\n"),
            ambiguousAuthors: authors.ambiguous
        )
    }

    // MARK: - CSV

    /// One row per paper, RFC 4180 quoting, CRLF line endings, UTF-8
    /// with a byte-order mark (so Excel opens accented text correctly).
    ///
    /// Text that starts with = + - or @ gets a leading apostrophe so a
    /// spreadsheet never runs it as a formula.
    nonisolated static func papersCSV(from snapshot: WorkspaceSnapshot) -> String {

        let dates = ExportDates()

        let header: [String] = [
            "id", "citation_key", "title", "authors", "year",
            "publication_type", "venue", "publisher", "volume", "issue",
            "pages", "edition", "month", "doi", "url", "tags",
            "reading_status", "rating", "added_at", "last_opened_at",
            "updated_at", "pdf", "abstract"
        ]

        var rows: [String] = [
            header
                .map { ExportText.csvField($0, guardFormula: false) }
                .joined(separator: ",")
        ]

        let papers = snapshot.papers.sorted { a, b in
            if a.addedAt != b.addedAt { return a.addedAt < b.addedAt }
            return a.id.uuidString < b.id.uuidString
        }

        for paper in papers {

            let pdfLabel: String

            switch paper.pdfState {
            case "included": pdfLabel = "attached"
            case "missing": pdfLabel = "file missing"
            default: pdfLabel = "none"
            }

            let yearText = paper.year > 0 ? String(paper.year) : ""
            let ratingText = paper.rating > 0 ? String(paper.rating) : ""

            var lastOpened = ""
            if let date = paper.lastOpenedAt { lastOpened = dates.iso(date) }

            var updated = ""
            if let date = paper.updatedAt { updated = dates.iso(date) }

            // (value, isFreeText). Free text is protected against
            // formula injection; ids, numbers and dates are not.
            var cells: [(String, Bool)] = []

            cells.append((paper.id.uuidString, false))
            cells.append((paper.citationKey, true))
            cells.append((paper.title, true))
            cells.append((paper.authors, true))
            cells.append((yearText, false))
            cells.append((paper.publicationTypeRawValue, true))
            cells.append((paper.venue, true))
            cells.append((paper.publisher, true))
            cells.append((paper.volume, true))
            cells.append((paper.issue, true))
            cells.append((paper.pages, true))
            cells.append((paper.edition, true))
            cells.append((paper.month, true))
            cells.append((paper.doi, true))
            cells.append((paper.urlString, true))
            cells.append((paper.tagsText, true))
            cells.append((paper.statusRawValue, true))
            cells.append((ratingText, false))
            cells.append((dates.iso(paper.addedAt), false))
            cells.append((lastOpened, false))
            cells.append((updated, false))
            cells.append((pdfLabel, false))
            cells.append((paper.abstractText, true))

            let row = cells
                .map { ExportText.csvField($0.0, guardFormula: $0.1) }
                .joined(separator: ",")

            rows.append(row)
        }

        return "\u{FEFF}" + rows.joined(separator: "\r\n") + "\r\n"
    }

    // MARK: - Markdown

    /// A readable summary built only from stored records.
    /// Sections with no records are left out.
    nonisolated static func markdownSummary(
        from snapshot: WorkspaceSnapshot,
        exportedAt: Date = Date()
    ) -> String {

        let dates = ExportDates()
        let refs = ExportRefs(snapshot)

        var md = MarkdownBuilder()

        md.heading(1, "ResearchBase Research Summary")

        md.paragraph(
            "Exported on \(dates.day(exportedAt)). This summary lists the records stored in ResearchBase. Counts are tallies of those records; nothing has been added or estimated."
        )

        writeOverview(&md, snapshot)
        writeProjects(&md, snapshot, refs, dates)
        writePapers(&md, snapshot)
        writeNotes(&md, snapshot, refs)
        writeReviews(&md, snapshot, refs)
        writeGaps(&md, snapshot, refs)
        writeProblems(&md, snapshot, refs)
        writeIdeas(&md, snapshot, refs)
        writeExperiments(&md, snapshot, refs, dates)
        writeWriting(&md, snapshot)
        writeTasks(&md, snapshot, refs, dates)

        return md.text
    }

    // MARK: Markdown sections

    nonisolated private static func writeOverview(
        _ md: inout MarkdownBuilder,
        _ s: WorkspaceSnapshot
    ) {

        md.heading(2, "Overview")

        let counts: [(String, Int)] = [
            ("Papers", s.papers.count),
            ("PDF annotations", s.annotations.count),
            ("Research notes", s.notes.count),
            ("Literature reviews", s.reviews.count),
            ("Literature themes", s.themes.count),
            ("Findings", s.findings.count),
            ("Comparison entries", s.comparisonEntries.count),
            ("Syntheses", s.syntheses.count),
            ("Research gaps", s.gaps.count),
            ("Research problems", s.problems.count),
            ("Research ideas", s.ideas.count),
            ("Experiments", s.experiments.count),
            ("Experiment runs", s.runs.count),
            ("Writing documents", s.writingDocuments.count),
            ("Writing sections", s.writingSections.count),
            ("Projects", s.projects.count),
            ("Tasks", s.tasks.count)
        ]

        for (label, count) in counts where count > 0 {
            md.line("- \(label): \(count)")
        }

        let breakdowns: [(String, [String])] = [
            ("Reading status", s.papers.map { $0.statusRawValue }),
            ("Task status", s.tasks.map { $0.statusRawValue }),
            ("Experiment status", s.experiments.map { $0.statusRawValue })
        ]

        for (label, values) in breakdowns where !values.isEmpty {
            md.line("- \(label): \(ExportText.statusLine(values))")
        }
    }

    nonisolated private static func writeProjects(
        _ md: inout MarkdownBuilder,
        _ s: WorkspaceSnapshot,
        _ refs: ExportRefs,
        _ dates: ExportDates
    ) {

        guard !s.projects.isEmpty else { return }

        md.heading(2, "Projects")

        let projects = s.projects.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        for project in projects {

            let name = ExportText.label(project.name, "Untitled project")

            md.heading(3, ExportText.inline(name))

            md.field("Status", project.statusRawValue)
            md.field("Created", dates.day(project.createdAt))
            md.field("Description", project.descriptionText)

            md.linked("Papers", project.paperIDs, refs.papers)
            md.linked("Notes", project.noteIDs, refs.notes)
            md.linked("Findings", project.findingIDs, refs.findings)
            md.linked("Gaps", project.gapIDs, refs.gaps)
            md.linked("Problems", project.problemIDs, refs.problems)
            md.linked("Ideas", project.ideaIDs, refs.ideas)
            md.linked("Experiments", project.experimentIDs, refs.experiments)
            md.linked("Writing", project.writingDocumentIDs, refs.writing)
        }
    }

    nonisolated private static func writePapers(
        _ md: inout MarkdownBuilder,
        _ s: WorkspaceSnapshot
    ) {

        guard !s.papers.isEmpty else { return }

        md.heading(2, "Papers")

        var annotationCounts: [UUID: Int] = [:]

        for annotation in s.annotations {
            if let paperID = annotation.paperID {
                annotationCounts[paperID, default: 0] += 1
            }
        }

        let papers = s.papers.sorted { a, b in
            if a.year != b.year { return a.year > b.year }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }

        for paper in papers {

            let title = ExportText.label(paper.title, "Untitled paper")

            var head = "**" + ExportText.inline(title) + "**"

            let authors = ExportText.collapse(paper.authors)
            if !authors.isEmpty { head += " — " + ExportText.inline(authors) }

            if paper.year > 0 { head += " (\(paper.year))" }

            let venue = ExportText.collapse(paper.venue)
            if !venue.isEmpty { head += ". " + ExportText.inline(venue) }

            var details: [String] = []

            let status = ExportText.collapse(paper.statusRawValue)
            if !status.isEmpty { details.append("Status: " + ExportText.inline(status)) }

            if paper.rating > 0 { details.append("Rating: \(paper.rating)/5") }

            let tags = ExportText.collapse(paper.tagsText)
            if !tags.isEmpty { details.append("Tags: " + ExportText.inline(tags)) }

            let key = ExportText.collapse(paper.citationKey)
            if !key.isEmpty { details.append("Key: " + ExportText.inline(key)) }

            let doi = ExportText.collapse(paper.doi)
            if !doi.isEmpty { details.append("DOI: " + ExportText.inline(doi)) }

            let url = ExportText.collapse(paper.urlString)
            if !url.isEmpty { details.append("URL: " + ExportText.inline(url)) }

            if let count = annotationCounts[paper.id], count > 0 {
                details.append("Annotations: \(count)")
            }

            if details.isEmpty {
                md.line("- " + head)
            } else {
                md.line("- " + head + "  ")
                md.line("  " + details.joined(separator: " · "))
            }
        }
    }

    nonisolated private static func writeNotes(
        _ md: inout MarkdownBuilder,
        _ s: WorkspaceSnapshot,
        _ refs: ExportRefs
    ) {

        guard !s.notes.isEmpty else { return }

        md.heading(2, "Research Notes")

        let notes = s.notes.sorted { $0.createdAt < $1.createdAt }

        for note in notes {

            let title = ExportText.label(note.title, "Untitled note")

            md.heading(3, ExportText.inline(title))

            md.field("Type", note.typeRawValue)
            md.field("Tags", note.tagsText)
            md.linked("Papers", note.paperIDs, refs.papers)
            md.body(note.content)
        }
    }

    nonisolated private static func writeReviews(
        _ md: inout MarkdownBuilder,
        _ s: WorkspaceSnapshot,
        _ refs: ExportRefs
    ) {

        var hasAny = !s.reviews.isEmpty
        if !s.themes.isEmpty { hasAny = true }
        if !s.findings.isEmpty { hasAny = true }
        if !s.comparisonEntries.isEmpty { hasAny = true }
        if !s.syntheses.isEmpty { hasAny = true }

        guard hasAny else { return }

        md.heading(2, "Literature Reviews")

        let themesByReview = ExportText.group(s.themes) { $0.reviewID }
        let findingsByReview = ExportText.group(s.findings) { $0.reviewID }
        let comparisonsByReview = ExportText.group(s.comparisonEntries) { $0.reviewID }
        let synthesesByReview = ExportText.group(s.syntheses) { $0.reviewID }

        let reviews = s.reviews.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }

        for review in reviews {

            let title = ExportText.label(review.title, "Untitled review")

            md.heading(3, ExportText.inline(title))

            md.field("Research question", review.researchQuestion)
            md.field("Description", review.descriptionText)
            md.linked("Papers", review.paperIDs, refs.papers)

            writeReviewBody(
                &md,
                refs: refs,
                themes: themesByReview[review.id] ?? [],
                findings: findingsByReview[review.id] ?? [],
                comparisons: comparisonsByReview[review.id] ?? [],
                syntheses: synthesesByReview[review.id] ?? []
            )
        }

        // Records whose review is missing are still real data, so
        // they are listed instead of dropped.

        let reviewIDs = Set(s.reviews.map { $0.id })

        func unattached(_ id: UUID?) -> Bool {
            guard let id = id else { return true }
            return !reviewIDs.contains(id)
        }

        let looseThemes = s.themes.filter { unattached($0.reviewID) }
        let looseFindings = s.findings.filter { unattached($0.reviewID) }
        let looseComparisons = s.comparisonEntries.filter { unattached($0.reviewID) }
        let looseSyntheses = s.syntheses.filter { unattached($0.reviewID) }

        var hasLoose = !looseThemes.isEmpty
        if !looseFindings.isEmpty { hasLoose = true }
        if !looseComparisons.isEmpty { hasLoose = true }
        if !looseSyntheses.isEmpty { hasLoose = true }

        if hasLoose {

            md.heading(3, "Not attached to a review")

            writeReviewBody(
                &md,
                refs: refs,
                themes: looseThemes,
                findings: looseFindings,
                comparisons: looseComparisons,
                syntheses: looseSyntheses
            )
        }
    }

    nonisolated private static func writeReviewBody(
        _ md: inout MarkdownBuilder,
        refs: ExportRefs,
        themes: [LiteratureThemeDTO],
        findings: [LiteratureFindingDTO],
        comparisons: [LiteratureComparisonEntryDTO],
        syntheses: [LiteratureSynthesisDTO]
    ) {

        if !themes.isEmpty {

            md.heading(4, "Themes")

            let sorted = themes.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }

            for theme in sorted {

                let name = ExportText.label(theme.name, "Untitled theme")

                md.line("- **" + ExportText.inline(name) + "**")
                md.field("Description", theme.descriptionText)
                md.linked("Papers", theme.paperIDs, refs.papers)
            }
        }

        if !findings.isEmpty {

            md.heading(4, "Findings")

            let sorted = findings.sorted { $0.createdAt < $1.createdAt }

            for finding in sorted {

                let title = ExportText.label(finding.title, "Untitled finding")

                md.line("- **" + ExportText.inline(title) + "**")
                md.body(finding.content)
                md.linked("Supporting papers", finding.supportingPaperIDs, refs.papers)
                md.linked("Related gaps", finding.gapIDs, refs.gaps)
            }
        }

        if !comparisons.isEmpty {

            md.heading(4, "Comparison")

            let sorted = comparisons.sorted { $0.createdAt < $1.createdAt }

            for entry in sorted {

                var name = "Unlinked paper"

                if let paperID = entry.paperID, let title = refs.papers[paperID] {
                    name = title
                }

                md.line("- **" + ExportText.inline(name) + "**")
                md.field("Method", entry.method)
                md.field("Dataset", entry.dataset)
                md.field("Main finding", entry.mainFinding)
                md.field("Notes", entry.notes)
            }
        }

        let sortedSyntheses = syntheses.sorted { $0.createdAt < $1.createdAt }

        for synthesis in sortedSyntheses {

            md.heading(4, "Synthesis")

            md.field("Common approaches", synthesis.commonApproaches)
            md.field("Major findings", synthesis.majorFindings)
            md.field("Areas of agreement", synthesis.areasOfAgreement)
            md.field("Areas of disagreement", synthesis.areasOfDisagreement)
            md.field("Methodological differences", synthesis.methodologicalDifferences)
            md.field("Limitations across the literature", synthesis.limitationsAcrossLiterature)
            md.field("Overall summary", synthesis.overallSummary)
        }
    }

    nonisolated private static func writeGaps(
        _ md: inout MarkdownBuilder,
        _ s: WorkspaceSnapshot,
        _ refs: ExportRefs
    ) {

        guard !s.gaps.isEmpty else { return }

        md.heading(2, "Research Gaps")

        let gaps = s.gaps.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }

        for gap in gaps {

            let title = ExportText.label(gap.title, "Untitled gap")

            md.heading(3, ExportText.inline(title))

            md.field("Type", gap.gapTypeRawValue)
            md.field("Status", gap.statusRawValue)
            md.field("Description", gap.descriptionText)
            md.field("Evidence", gap.evidence)
            md.field("Significance", gap.significance)
            md.linked("Supporting papers", gap.paperIDs, refs.papers)
        }
    }

    nonisolated private static func writeProblems(
        _ md: inout MarkdownBuilder,
        _ s: WorkspaceSnapshot,
        _ refs: ExportRefs
    ) {

        guard !s.problems.isEmpty else { return }

        md.heading(2, "Research Problems")

        let problems = s.problems.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }

        for problem in problems {

            let title = ExportText.label(problem.title, "Untitled problem")

            md.heading(3, ExportText.inline(title))

            md.field("Status", problem.statusRawValue)
            md.field("Problem statement", problem.problemStatement)
            md.field("Research question", problem.researchQuestion)
            md.field("Background", problem.background)
            md.field("Motivation", problem.motivation)
            md.field("Significance", problem.significance)
            md.field("Objectives", problem.objectives)
            md.field("Hypotheses", problem.hypotheses)
            md.linked("Related gaps", problem.gapIDs, refs.gaps)
            md.linked("Papers", problem.paperIDs, refs.papers)
        }
    }

    nonisolated private static func writeIdeas(
        _ md: inout MarkdownBuilder,
        _ s: WorkspaceSnapshot,
        _ refs: ExportRefs
    ) {

        guard !s.ideas.isEmpty else { return }

        md.heading(2, "Research Ideas")

        let ideas = s.ideas.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }

        for idea in ideas {

            let title = ExportText.label(idea.title, "Untitled idea")

            md.heading(3, ExportText.inline(title))

            md.field("Status", idea.statusRawValue)
            md.field("Summary", idea.summary)
            md.field("Description", idea.descriptionText)
            md.field("Proposed approach", idea.proposedApproach)
            md.field("Expected contribution", idea.expectedContribution)
            md.field("Novelty", idea.novelty)
            md.field("Assumptions", idea.assumptions)
            md.field("Limitations", idea.limitations)
            md.linked("Related problems", idea.problemIDs, refs.problems)
            md.linked("Related gaps", idea.gapIDs, refs.gaps)
            md.linked("Papers", idea.paperIDs, refs.papers)
            md.linked("Notes", idea.noteIDs, refs.notes)
        }
    }

    nonisolated private static func writeExperiments(
        _ md: inout MarkdownBuilder,
        _ s: WorkspaceSnapshot,
        _ refs: ExportRefs,
        _ dates: ExportDates
    ) {

        guard !s.experiments.isEmpty else { return }

        md.heading(2, "Experiments")

        let runsByExperiment = ExportText.group(s.runs) { $0.experimentID }
        let metricsByRun = ExportText.group(s.metrics) { $0.runID }
        let baselinesByExperiment = ExportText.group(s.baselineMetrics) { $0.experimentID }

        let experiments = s.experiments.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        for experiment in experiments {

            let name = ExportText.label(experiment.name, "Untitled experiment")

            md.heading(3, ExportText.inline(name))

            md.field("Status", experiment.statusRawValue)
            md.field("Objective", experiment.objective)
            md.field("Hypothesis", experiment.hypothesis)
            md.field("Description", experiment.descriptionText)

            md.field("Dataset", experiment.dataset)
            md.field("Dataset version", experiment.datasetVersion)
            md.field("Model", experiment.model)
            md.field("Framework", experiment.framework)
            md.field("Hardware", experiment.hardware)
            md.field("Environment", experiment.operatingEnvironment)
            md.field("Code repository", experiment.codeRepository)
            md.field("Train/validation/test split", experiment.trainValidationTestSplit)
            md.field("Optimizer", experiment.optimizer)
            md.field("Learning rate", experiment.learningRate)

            if let seed = experiment.seed { md.field("Seed", String(seed)) }
            if let batch = experiment.batchSize { md.field("Batch size", String(batch)) }
            if let epochs = experiment.epochs { md.field("Epochs", String(epochs)) }

            md.linked("Related ideas", experiment.ideaIDs, refs.ideas)
            md.linked("Related problems", experiment.problemIDs, refs.problems)
            md.linked("Related gaps", experiment.gapIDs, refs.gaps)
            md.linked("Papers", experiment.paperIDs, refs.papers)
            md.linked("Notes", experiment.noteIDs, refs.notes)

            // Baselines

            let baselines = (baselinesByExperiment[experiment.id] ?? [])
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            if !baselines.isEmpty {

                md.heading(4, "Baselines")

                for baseline in baselines {

                    let text = ExportText.metricText(
                        name: baseline.name,
                        value: baseline.value,
                        unit: baseline.unit,
                        higherIsBetter: baseline.higherIsBetter
                    )

                    md.line("- " + ExportText.inline(text))
                }
            }

            // Runs

            let runs = (runsByExperiment[experiment.id] ?? [])
                .sorted { $0.runNumber < $1.runNumber }

            if !runs.isEmpty {

                md.heading(4, "Runs")

                for run in runs {

                    var title = "Run \(run.runNumber)"

                    let status = ExportText.collapse(run.statusRawValue)
                    if !status.isEmpty { title += " — " + status }

                    if experiment.bestRunID == run.id { title += " (best run)" }

                    md.line("- **" + ExportText.inline(title) + "**")

                    if let started = run.startedAt { md.field("Started", dates.day(started)) }
                    if let completed = run.completedAt { md.field("Completed", dates.day(completed)) }
                    if let seed = run.seed { md.field("Seed", String(seed)) }

                    let metrics = (metricsByRun[run.id] ?? [])
                        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

                    for metric in metrics {

                        let text = ExportText.metricText(
                            name: metric.name,
                            value: metric.value,
                            unit: metric.unit,
                            higherIsBetter: metric.higherIsBetter
                        )

                        md.line("  - " + ExportText.inline(text))
                    }

                    md.field("Configuration", run.configuration)
                    md.field("Notes", run.notes)
                }
            }

            md.field("Results interpretation", experiment.resultsInterpretation)
            md.field("Results conclusion", experiment.resultsConclusion)
        }
    }

    nonisolated private static func writeWriting(
        _ md: inout MarkdownBuilder,
        _ s: WorkspaceSnapshot
    ) {

        guard !s.writingDocuments.isEmpty else { return }

        md.heading(2, "Writing")

        let sectionsByDocument = ExportText.group(s.writingSections) { $0.documentID }

        let documents = s.writingDocuments.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }

        for document in documents {

            let title = ExportText.label(document.title, "Untitled document")

            md.heading(3, ExportText.inline(title))

            md.field("Type", document.documentTypeRawValue)
            md.field("Status", document.statusRawValue)
            md.field("Stage", document.stageRawValue ?? "")
            md.field("Format", document.formatRawValue ?? "")
            md.field("Venue", document.venue ?? "")
            md.field("Submission note", document.submissionNote ?? "")

            if let progress = document.progressPercent {
                md.field("Progress", "\(progress)%")
            }

            if document.archivedFlag == true {
                md.field("Archived", "Yes")
            }

            let sections = (sectionsByDocument[document.id] ?? [])
                .sorted { $0.order < $1.order }

            if sections.isEmpty { continue }

            var totalWords = 0

            md.line("**Outline**")
            md.blank()

            for (index, section) in sections.enumerated() {

                let words = ExportText.wordCount(section.content)
                totalWords += words

                let name = ExportText.label(section.title, "Untitled section")
                let type = ExportText.collapse(section.sectionTypeRawValue)

                var line = "\(index + 1). " + ExportText.inline(name)

                if !type.isEmpty { line += " (" + ExportText.inline(type) + ")" }

                line += " — \(words) words"

                md.line(line)
            }

            md.blank()
            md.line("Total: \(totalWords) words")
        }
    }

    nonisolated private static func writeTasks(
        _ md: inout MarkdownBuilder,
        _ s: WorkspaceSnapshot,
        _ refs: ExportRefs,
        _ dates: ExportDates
    ) {

        guard !s.tasks.isEmpty else { return }

        md.heading(2, "Tasks")

        let completedRaw = ResearchTaskStatus.completed.rawValue

        func priorityRank(_ raw: String) -> Int {
            if raw == ResearchTaskPriority.high.rawValue { return 2 }
            if raw == ResearchTaskPriority.medium.rawValue { return 1 }
            return 0
        }

        func openOrder(_ a: ResearchTaskDTO, _ b: ResearchTaskDTO) -> Bool {

            // Earlier due dates first; tasks without a due date last.

            if let left = a.dueDate, let right = b.dueDate {
                if left != right { return left < right }
            } else if a.dueDate != nil {
                return true
            } else if b.dueDate != nil {
                return false
            }

            let leftRank = priorityRank(a.priorityRawValue)
            let rightRank = priorityRank(b.priorityRawValue)

            if leftRank != rightRank { return leftRank > rightRank }

            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }

        let open = s.tasks
            .filter { $0.statusRawValue != completedRaw }
            .sorted(by: openOrder)

        let done = s.tasks
            .filter { $0.statusRawValue == completedRaw }
            .sorted { a, b in
                (a.completedDate ?? a.updatedAt) > (b.completedDate ?? b.updatedAt)
            }

        func taskLines(_ task: ResearchTaskDTO, isDone: Bool) {

            let box = isDone ? "- [x] " : "- [ ] "
            let title = ExportText.label(task.title, "Untitled task")

            md.line(box + ExportText.inline(title))

            var details: [String] = []

            if !isDone {
                let status = ExportText.collapse(task.statusRawValue)
                if !status.isEmpty { details.append("Status: " + ExportText.inline(status)) }
            }

            let priority = ExportText.collapse(task.priorityRawValue)
            if !priority.isEmpty { details.append("Priority: " + ExportText.inline(priority)) }

            if let due = task.dueDate { details.append("Due: " + dates.day(due)) }

            if isDone, let completed = task.completedDate {
                details.append("Completed: " + dates.day(completed))
            }

            if let projectID = task.projectID, let name = refs.projects[projectID] {
                details.append("Project: " + ExportText.inline(name))
            }

            if !details.isEmpty {
                md.line("  " + details.joined(separator: " · "))
            }

            let description = ExportText.collapse(task.descriptionText)

            if !description.isEmpty {
                md.line("  " + ExportText.inline(description))
            }
        }

        if !open.isEmpty {
            md.heading(3, "Open")
            for task in open { taskLines(task, isDone: false) }
        }

        if !done.isEmpty {
            md.heading(3, "Completed")
            for task in done { taskLines(task, isDone: true) }
        }
    }
}

// MARK: - Dates

private nonisolated struct ExportDates {

    private let dayFormatter: DateFormatter
    private let isoFormatter: ISO8601DateFormatter

    init() {

        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        dayFormatter = day

        isoFormatter = ISO8601DateFormatter()
    }

    /// yyyy-MM-dd in the current time zone.
    func day(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    /// Full ISO-8601 timestamp in UTC.
    func iso(_ date: Date) -> String {
        isoFormatter.string(from: date)
    }
}

// MARK: - Title lookups (for Markdown links between records)

private nonisolated struct ExportRefs {

    let papers: [UUID: String]
    let notes: [UUID: String]
    let findings: [UUID: String]
    let gaps: [UUID: String]
    let problems: [UUID: String]
    let ideas: [UUID: String]
    let experiments: [UUID: String]
    let writing: [UUID: String]
    let projects: [UUID: String]

    init(_ s: WorkspaceSnapshot) {

        papers = ExportRefs.table(s.papers.map { ($0.id, $0.title) }, "Untitled paper")
        notes = ExportRefs.table(s.notes.map { ($0.id, $0.title) }, "Untitled note")
        findings = ExportRefs.table(s.findings.map { ($0.id, $0.title) }, "Untitled finding")
        gaps = ExportRefs.table(s.gaps.map { ($0.id, $0.title) }, "Untitled gap")
        problems = ExportRefs.table(s.problems.map { ($0.id, $0.title) }, "Untitled problem")
        ideas = ExportRefs.table(s.ideas.map { ($0.id, $0.title) }, "Untitled idea")
        experiments = ExportRefs.table(s.experiments.map { ($0.id, $0.name) }, "Untitled experiment")
        writing = ExportRefs.table(s.writingDocuments.map { ($0.id, $0.title) }, "Untitled document")
        projects = ExportRefs.table(s.projects.map { ($0.id, $0.name) }, "Untitled project")
    }

    /// id -> readable title. If an id appears twice, the first wins.
    private static func table(
        _ pairs: [(UUID, String)],
        _ fallback: String
    ) -> [UUID: String] {

        var result: [UUID: String] = [:]

        for (id, title) in pairs where result[id] == nil {
            result[id] = ExportText.label(title, fallback)
        }

        return result
    }
}

// MARK: - Markdown builder

private nonisolated struct MarkdownBuilder {

    private(set) var lines: [String] = []

    var text: String {
        lines.joined(separator: "\n") + "\n"
    }

    /// Adds one empty line, unless the last line is already empty.
    mutating func blank() {
        if let last = lines.last, !last.isEmpty {
            lines.append("")
        }
    }

    mutating func line(_ text: String) {
        lines.append(text)
    }

    mutating func heading(_ level: Int, _ text: String) {
        blank()
        lines.append(String(repeating: "#", count: level) + " " + text)
        blank()
    }

    mutating func paragraph(_ text: String) {
        blank()
        lines.append(text)
        blank()
    }

    /// "- **Label:** value" for short values; a labelled quote block
    /// for long or multi-line values. Empty values are skipped.
    mutating func field(_ label: String, _ value: String) {

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else { return }

        let hasNewline = trimmed.contains(where: { $0.isNewline })
        let isLong = trimmed.count > 140 || hasNewline

        if isLong {
            blank()
            lines.append("**\(label):**")
            blank()
            appendQuote(trimmed)
            blank()
        } else {
            lines.append("- **\(label):** " + ExportText.inline(trimmed))
        }
    }

    /// Body text as a quote block, so headings or lists typed inside
    /// a note cannot break the structure of the summary.
    mutating func body(_ value: String) {

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else { return }

        blank()
        appendQuote(trimmed)
        blank()
    }

    /// "- **Label (n):** title; title; ..." for linked records.
    mutating func linked(_ label: String, _ ids: [UUID], _ titles: [UUID: String]) {

        let names = ids.compactMap { titles[$0] }

        guard !names.isEmpty else { return }

        let joined = names
            .map { ExportText.inline($0) }
            .joined(separator: "; ")

        lines.append("- **\(label) (\(names.count)):** \(joined)")
    }

    private mutating func appendQuote(_ text: String) {

        let rows = text.split(
            omittingEmptySubsequences: false,
            whereSeparator: { $0.isNewline }
        )

        for row in rows {

            let cleaned = String(row)
                .trimmingCharacters(in: .whitespaces)

            lines.append(cleaned.isEmpty ? ">" : "> " + cleaned)
        }
    }
}

// MARK: - Text helpers

private nonisolated enum ExportText {

    // MARK: General

    /// Trims and turns any run of whitespace or newlines into one space.
    static func collapse(_ text: String) -> String {
        text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// The text, or `fallback` when it is empty.
    static func label(_ text: String, _ fallback: String) -> String {
        let cleaned = collapse(text)
        return cleaned.isEmpty ? fallback : cleaned
    }

    /// Same rule as WritingSection.wordCount.
    static func wordCount(_ text: String) -> Int {
        text
            .split { $0.isWhitespace || $0.isNewline }
            .count
    }

    /// "Draft 2 · Running 1", most common first.
    static func statusLine(_ values: [String]) -> String {

        var counts: [String: Int] = [:]

        for value in values {
            let key = collapse(value)
            let name = key.isEmpty ? "Unspecified" : key
            counts[name, default: 0] += 1
        }

        let ordered = counts.sorted { a, b in
            if a.value != b.value { return a.value > b.value }
            return a.key < b.key
        }

        return ordered
            .map { "\($0.key) \($0.value)" }
            .joined(separator: " · ")
    }

    static func group<T>(
        _ items: [T],
        by key: (T) -> UUID?
    ) -> [UUID: [T]] {

        var result: [UUID: [T]] = [:]

        for item in items {
            if let id = key(item) {
                result[id, default: []].append(item)
            }
        }

        return result
    }

    static func metricText(
        name: String,
        value: Double,
        unit: String,
        higherIsBetter: Bool
    ) -> String {

        var text = label(name, "Metric") + ": \(value)"

        let unitText = collapse(unit)
        if !unitText.isEmpty { text += " " + unitText }

        text += higherIsBetter ? " (higher is better)" : " (lower is better)"

        return text
    }

    // MARK: Markdown

    /// Escapes characters that would change the meaning of a single
    /// line of text in Markdown.
    static func inline(_ text: String) -> String {

        var out = ""

        for character in collapse(text) {

            switch character {
            case "\\", "`", "*", "_", "[", "]", "<", ">":
                out.append("\\")
                out.append(character)
            default:
                out.append(character)
            }
        }

        return out
    }

    // MARK: CSV

    static func csvField(_ value: String, guardFormula: Bool) -> String {

        var text = value

        if guardFormula, let first = text.first, "=+-@\t\r".contains(first) {
            text = "'" + text
        }

        let needsQuotes = text.unicodeScalars.contains { scalar in
            scalar == "," || scalar == "\"" || scalar == "\n" || scalar == "\r"
        }

        guard needsQuotes else { return text }

        let doubled = text.replacingOccurrences(of: "\"", with: "\"\"")

        return "\"" + doubled + "\""
    }

    // MARK: BibTeX

    /// Escapes text for use inside a braced BibTeX value. Braces are
    /// written as \textbraceleft{} and \textbraceright{} because BibTeX
    /// counts every brace, even one after a backslash.
    static func bibEscape(_ text: String) -> String {

        var out = ""

        for character in collapse(text) {

            switch character {
            case "\\": out += "\\textbackslash{}"
            case "{": out += "\\textbraceleft{}"
            case "}": out += "\\textbraceright{}"
            case "&": out += "\\&"
            case "%": out += "\\%"
            case "$": out += "\\$"
            case "#": out += "\\#"
            case "_": out += "\\_"
            case "~": out += "\\textasciitilde{}"
            case "^": out += "\\textasciicircum{}"
            default: out.append(character)
            }
        }

        return out
    }

    /// For doi and url: written as typed, without whitespace or braces.
    static func bibRaw(_ text: String) -> String {
        text.filter { !$0.isWhitespace && $0 != "{" && $0 != "}" }
    }

    /// Keeps only characters that are safe in a BibTeX key.
    static func bibKey(_ text: String) -> String {

        let allowed = Set(
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-:.+/"
        )

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        return String(trimmed.filter { allowed.contains($0) })
    }

    /// "12-34" or "12 – 34" becomes "12--34". Anything else is kept.
    static func bibPages(_ text: String) -> String {

        let pattern = #"^(\w+)\s*[-–—]{1,2}\s*(\w+)$"#

        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
        }

        let range = NSRange(text.startIndex..., in: text)

        guard let match = regex.firstMatch(in: text, range: range),
              let first = Range(match.range(at: 1), in: text),
              let second = Range(match.range(at: 2), in: text)
        else { return text }

        return "\(text[first])--\(text[second])"
    }

    /// One author in BibTeX form. "et al." becomes "others".
    static func bibName(_ name: String) -> String {

        let bare = name
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))

        if bare == "et al" || bare == "others" {
            return "others"
        }

        return bibEscape(name)
    }

    /// Splits the free-text authors field into names.
    ///
    /// Semicolons are the reliable separator. Without them, " and " and
    /// " & " split authors. Otherwise commas are used:
    ///   - "Surname, Given"               -> one author
    ///   - "Given Surname, Given Surname" -> two authors
    ///   - three or more comma parts      -> split on commas, but flagged
    ///     `ambiguous`, because "Smith, J., Lee, K." cannot be told
    ///     apart from a plain comma list.
    static func splitAuthors(_ raw: String) -> (names: [String], ambiguous: Bool) {

        var text = collapse(raw)

        guard !text.isEmpty else { return ([], false) }

        func clean(_ parts: [Substring]) -> [String] {
            parts
                .map { collapse(String($0)) }
                .filter { !$0.isEmpty }
        }

        if !text.contains(";") {
            text = text.replacingOccurrences(
                of: " and ",
                with: ";",
                options: .caseInsensitive
            )
            text = text.replacingOccurrences(of: " & ", with: ";")
        }

        if text.contains(";") {
            return (clean(text.split(separator: ";")), false)
        }

        let commaParts = clean(text.split(separator: ","))

        if commaParts.count <= 1 {
            return (commaParts, false)
        }

        if commaParts.count == 2 {

            if !commaParts[0].contains(" ") {
                return (["\(commaParts[0]), \(commaParts[1])"], false)
            }

            return (commaParts, false)
        }

        return (commaParts, true)
    }

    /// Maps a stored publication type to a BibTeX entry type.
    /// `note` is written into the entry when BibTeX has no exact type,
    /// so the distinction is not lost.
    static func bibKind(for rawValue: String) -> (entryType: String, note: String?) {

        switch PublicationType(rawValue: rawValue) ?? .other {

        case .journalArticle: return ("article", nil)
        case .conferencePaper: return ("inproceedings", nil)
        case .workshopPaper: return ("inproceedings", "Workshop paper")
        case .book: return ("book", nil)
        case .bookChapter: return ("incollection", nil)
        case .thesis: return ("misc", "Thesis")
        case .technicalReport: return ("techreport", nil)
        case .preprint: return ("misc", "Preprint")
        case .website: return ("misc", nil)
        case .other: return ("misc", nil)
        }
    }
}

// MARK: - F-40: draft export hook (Agent 54)

/// What `exportDraft` reports. Same idea as WorkspaceExportResult, but
/// the format is DocumentExporter's `ExportFormat`.
struct WorkspaceDraftExportResult {

    let format: ExportFormat
    let url: URL
    let byteCount: Int64

    /// One line for the UI, e.g. "Word (.docx), 3 citations".
    let summary: String

    /// Things that could not be converted exactly. Show them.
    let warnings: [String]

    /// Citation keys used in the draft, in order of first use.
    let citedKeys: [String]
}

extension WorkspaceExportService {

    /// A safe default file name for a draft, e.g. "My Paper.docx".
    static func suggestedDraftFileName(title: String, format: ExportFormat) -> String {
        DocumentExporter.suggestedFileName(title: title, format: format)
    }

    /// Exports one draft (a real folder of LaTeX files) as `format`.
    ///
    /// - Read-only for the draft and the library: only `destination`
    ///   is written, and DocumentExporter writes it atomically.
    /// - `citations` formats citations and the reference list. Without
    ///   one, a plain "Author, Year" fallback read from the library is
    ///   used, and a warning says so (Word and Markdown only).
    /// - "Exported" means the file exists, is not empty and starts with
    ///   the bytes its format requires.
    /// - A PDF export with no successful build throws `nothingToExport`.
    @discardableResult
    static func exportDraft(
        draftID: String,
        model: LibraryModel,
        format: ExportFormat,
        to destination: URL,
        overwrite: Bool = false,
        citations: CitationProvider? = nil
    ) throws -> WorkspaceDraftExportResult {

        let target = rbA54_normalized(destination, fileExtension: format.fileExtension)

        let scoped = target.startAccessingSecurityScopedResource()
        defer { if scoped { target.stopAccessingSecurityScopedResource() } }

        let provider = citations ?? DocumentExporter.libraryCitations(model: model)
        let exporter = DocumentExporter(citations: provider)

        let report: ExportReport

        do {
            report = try exporter.export(
                draftID: draftID,
                model: model,
                format: format,
                to: target,
                overwrite: overwrite
            )
        } catch DocumentExportError.noBuild {
            throw WorkspaceExportError.nothingToExport(
                "There is no successful PDF build for this draft yet. Build it first."
            )
        } catch let error as DocumentExportError {
            throw WorkspaceExportError.writeFailed(
                error.errorDescription ?? error.localizedDescription
            )
        } catch {
            throw WorkspaceExportError.writeFailed(error.localizedDescription)
        }

        let size = try rbA54_verifyDraftFile(report.outputURL, format: format)

        var warnings = report.warnings

        if citations == nil, !report.citedKeys.isEmpty,
           format == .docx || format == .markdown {
            warnings.append(
                "No citation style was given, so citations use a plain Author, Year form. Choose a style for this draft to format them."
            )
        }

        var summary = format.title

        if !report.citedKeys.isEmpty {
            summary += ", \(report.citedKeys.count) citation(s)"
        }

        return WorkspaceDraftExportResult(
            format: format,
            url: report.outputURL,
            byteCount: size,
            summary: summary,
            warnings: warnings,
            citedKeys: report.citedKeys
        )
    }

    private static func rbA54_normalized(_ url: URL, fileExtension: String) -> URL {
        url.pathExtension.lowercased() == fileExtension
            ? url
            : url.appendingPathExtension(fileExtension)
    }

    /// Checks the written file and returns its size in bytes.
    private static func rbA54_verifyDraftFile(
        _ url: URL,
        format: ExportFormat
    ) throws -> Int64 {

        let data: Data

        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw WorkspaceExportError.verificationFailed(
                "The file could not be read back (\(error.localizedDescription))."
            )
        }

        guard !data.isEmpty else {
            throw WorkspaceExportError.verificationFailed("The exported file is empty.")
        }

        let prefix: [UInt8]?

        switch format {
        case .latexZip, .docx: prefix = [0x50, 0x4B]               // "PK"
        case .pdf: prefix = [0x25, 0x50, 0x44, 0x46]               // "%PDF"
        case .markdown, .plainText: prefix = nil
        }

        if let prefix = prefix, !data.starts(with: prefix) {
            throw WorkspaceExportError.verificationFailed(
                "The file does not look like a valid \(format.title) file."
            )
        }

        return Int64(data.count)
    }
}

// MARK: - F-50: open-format "export everything" (Agent 54)

/// What `exportEverything` reports.
struct WorkspaceOpenExportResult {

    /// The folder that was written.
    let folderURL: URL

    let byteCount: Int64

    /// One line for the UI, e.g. "42 papers, 12 notes, 3 drafts, 40 PDF files".
    let summary: String

    /// Paths (relative to `folderURL`) of everything written.
    let files: [String]

    /// Things that did not stop the export but that the person should know.
    let warnings: [String]
}

extension WorkspaceExportService {

    /// "ResearchBase Export 2026-10-15", the name the folder gets.
    static func suggestedEverythingFolderName(date: Date = Date()) -> String {

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"

        return "ResearchBase Export \(formatter.string(from: date))"
    }

    /// Writes an open-format copy of the whole library into a new
    /// folder at `destination`. It is readable without this app.
    ///
    ///     library.json        every record (same format as the backup)
    ///     references.bib      all papers, only when there are papers
    ///     summary.md          the readable research summary
    ///     notes/*.md          one Markdown file per research note
    ///     drafts/<name>/      each draft as the real folder it is
    ///     Papers/*.pdf        every PDF that exists on disk
    ///     README.txt          what is where
    ///
    /// `model` is the SQLite library. Pass it to include drafts; without
    /// it the drafts folder is left out and a warning says so.
    ///
    /// Everything is built in a temporary folder, checked, then moved
    /// into place, so a failed export never leaves a half folder.
    /// `destination` must not exist yet. Read-only for the workspace.
    @MainActor
    static func exportEverything(
        context: ModelContext,
        model: LibraryModel? = nil,
        to destination: URL
    ) async throws -> WorkspaceOpenExportResult {

        let capture = try WorkspaceSnapshot.capture(from: context)
        let snapshot = capture.snapshot
        let sources = capture.pdfSources
        let missingTitles = capture.missingPDFTitles

        var warnings: [String] = []

        // Drafts: (folder name, folder on disk), read on the main actor.

        var drafts: [(name: String, url: URL)] = []

        if let model = model {

            do {
                let store = DraftFolderStore(model: model)

                for draft in try store.all(includeArchived: true) {
                    let stem = rbA54_stem(draft.title, fallback: "Draft")
                    let name = "\(stem) \(draft.id.prefix(8))"
                    drafts.append((name: name, url: store.folderURL(for: draft)))
                }
            } catch {
                warnings.append(
                    "The drafts could not be listed, so none were exported (\(error.localizedDescription))."
                )
            }

        } else {
            warnings.append(
                "The library with drafts was not available, so no drafts were exported."
            )
        }

        guard snapshot.totalRecordCount > 0 || !drafts.isEmpty else {
            throw WorkspaceExportError.nothingToExport(
                "The workspace has no records yet."
            )
        }

        let fm = FileManager.default

        if fm.fileExists(atPath: destination.path) {
            throw WorkspaceExportError.writeFailed(
                "\(destination.lastPathComponent) already exists. Choose a new name."
            )
        }

        let exportedAt = Date()
        let draftList = drafts

        let scoped = destination.startAccessingSecurityScopedResource()
        defer { if scoped { destination.stopAccessingSecurityScopedResource() } }

        let outcome = try await Task.detached(priority: .userInitiated) {
            try rbA54_writeOpenExport(
                snapshot: snapshot,
                pdfSources: sources,
                drafts: draftList,
                exportedAt: exportedAt,
                destination: destination
            )
        }.value

        warnings.append(contentsOf: outcome.warnings)

        if !missingTitles.isEmpty {

            let shown = missingTitles.prefix(5).joined(separator: ", ")
            let more = missingTitles.count > 5 ? " and more" : ""

            warnings.append(
                "The PDF file could not be found for \(missingTitles.count) paper(s), so no PDF was saved for: \(shown)\(more)."
            )
        }

        var parts: [String] = []

        if !snapshot.papers.isEmpty { parts.append("\(snapshot.papers.count) papers") }
        if !snapshot.notes.isEmpty { parts.append("\(snapshot.notes.count) notes") }
        if outcome.draftCount > 0 { parts.append("\(outcome.draftCount) drafts") }
        if outcome.pdfCount > 0 { parts.append("\(outcome.pdfCount) PDF files") }

        let summary = parts.isEmpty
            ? "\(snapshot.totalRecordCount) records"
            : parts.joined(separator: ", ")

        return WorkspaceOpenExportResult(
            folderURL: destination,
            byteCount: outcome.byteCount,
            summary: summary,
            files: outcome.files,
            warnings: warnings
        )
    }

    /// Reads an export folder back and checks it: `library.json` must
    /// decode and its record counts must equal `expectedCounts`, and
    /// every PDF that library.json names must exist in the folder.
    /// Throws `verificationFailed` otherwise. Usable on its own, for
    /// example by a scheduled export that wants to confirm its result.
    nonisolated static func verifyOpenExport(
        at folder: URL,
        expectedCounts: [String: Int]
    ) throws {

        let json = folder.appendingPathComponent("library.json")

        let data: Data

        do {
            data = try Data(contentsOf: json)
        } catch {
            throw WorkspaceExportError.verificationFailed(
                "library.json could not be read back (\(error.localizedDescription))."
            )
        }

        let decoded: WorkspaceSnapshot

        do {
            decoded = try WorkspaceJSON.makeDecoder()
                .decode(WorkspaceSnapshot.self, from: data)
        } catch {
            throw WorkspaceExportError.verificationFailed(
                "library.json could not be decoded (\(error.localizedDescription))."
            )
        }

        if decoded.entityCounts != expectedCounts {
            throw WorkspaceExportError.verificationFailed(
                "The record counts in library.json do not match the workspace."
            )
        }

        for paper in decoded.papers where paper.pdfState == "included" {

            guard let name = paper.pdfFileName, !name.isEmpty else {
                throw WorkspaceExportError.verificationFailed(
                    "A paper marked as having a PDF names no file."
                )
            }

            let file = folder
                .appendingPathComponent(WorkspaceFormat.papersFolderName, isDirectory: true)
                .appendingPathComponent(name)

            if !FileManager.default.fileExists(atPath: file.path) {
                throw WorkspaceExportError.verificationFailed(
                    "The PDF \(name) is missing from the export."
                )
            }
        }
    }

    // MARK: Writing (off the main actor)

    nonisolated private struct RBA54Outcome {
        var files: [String]
        var warnings: [String]
        var byteCount: Int64
        var pdfCount: Int
        var draftCount: Int
    }

    nonisolated private static func rbA54_writeOpenExport(
        snapshot: WorkspaceSnapshot,
        pdfSources: [WorkspaceSnapshot.Capture.PDFSource],
        drafts: [(name: String, url: URL)],
        exportedAt: Date,
        destination: URL
    ) throws -> RBA54Outcome {

        let fm = FileManager.default

        let staging = fm.temporaryDirectory
            .appendingPathComponent("ResearchBase-OpenExport-\(UUID().uuidString)", isDirectory: true)

        let root = staging.appendingPathComponent("export", isDirectory: true)

        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            throw WorkspaceExportError.writeFailed(error.localizedDescription)
        }

        defer { try? fm.removeItem(at: staging) }

        var files: [String] = []
        var warnings: [String] = []

        func put(_ data: Data, _ relative: String) throws {

            let url = root.appendingPathComponent(relative)

            do {
                try fm.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: url, options: .atomic)
            } catch {
                throw WorkspaceExportError.writeFailed(error.localizedDescription)
            }

            files.append(relative)
        }

        // library.json: the snapshot as it is. Its PDF references point
        // at Papers/<file>, which are copied below.

        do {
            try put(try WorkspaceJSON.makeEncoder().encode(snapshot), "library.json")
        } catch let error as WorkspaceExportError {
            throw error
        } catch {
            throw WorkspaceExportError.writeFailed(error.localizedDescription)
        }

        // references.bib

        if !snapshot.papers.isEmpty {
            let bib = bibTeX(from: snapshot, exportedAt: exportedAt)
            try put(Data(bib.text.utf8), "references.bib")
            warnings.append(contentsOf: bib.warnings)
        }

        // summary.md

        try put(
            Data(markdownSummary(from: snapshot, exportedAt: exportedAt).utf8),
            "summary.md"
        )

        // notes/*.md

        var usedNames = Set<String>()

        for note in snapshot.notes.sorted(by: { $0.createdAt < $1.createdAt }) {

            let title = ExportText.label(note.title, "Untitled note")

            var name = rbA54_stem(title, fallback: "Note")

            if usedNames.contains(name.lowercased()) {
                name += " " + note.id.uuidString.prefix(8)
            }

            usedNames.insert(name.lowercased())

            var text = "# " + title + "\n\n"

            let type = ExportText.collapse(note.typeRawValue)
            if !type.isEmpty { text += "Type: " + type + "\n" }

            let tags = ExportText.collapse(note.tagsText)
            if !tags.isEmpty { text += "Tags: " + tags + "\n" }

            if !type.isEmpty || !tags.isEmpty { text += "\n" }

            text += note.content.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"

            try put(Data(text.utf8), "notes/\(name).md")
        }

        // Papers/

        var pdfCount = 0

        for source in pdfSources {

            let target = root
                .appendingPathComponent(WorkspaceFormat.papersFolderName, isDirectory: true)
                .appendingPathComponent(source.packageFileName)

            do {
                try fm.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fm.copyItem(at: source.sourceURL, to: target)
                pdfCount += 1
                files.append("\(WorkspaceFormat.papersFolderName)/\(source.packageFileName)")
            } catch {
                // Like the backup: a PDF that was there a moment ago
                // and cannot be copied must not pass silently.
                throw WorkspaceExportError.writeFailed(
                    "The PDF \(source.packageFileName) could not be copied (\(error.localizedDescription))."
                )
            }
        }

        // drafts/<name>/

        var draftCount = 0

        for draft in drafts {

            var isFolder: ObjCBool = false

            guard fm.fileExists(atPath: draft.url.path, isDirectory: &isFolder),
                  isFolder.boolValue
            else {
                warnings.append("The folder for the draft \"\(draft.name)\" was not found, so it was skipped.")
                continue
            }

            let target = root
                .appendingPathComponent("drafts", isDirectory: true)
                .appendingPathComponent(draft.name, isDirectory: true)

            do {
                try fm.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fm.copyItem(at: draft.url, to: target)
                draftCount += 1
                files.append("drafts/\(draft.name)/")
            } catch {
                throw WorkspaceExportError.writeFailed(
                    "The draft \"\(draft.name)\" could not be copied (\(error.localizedDescription))."
                )
            }
        }

        // README.txt

        let readme = """
        ResearchBase export

        library.json     every record, as JSON
        references.bib   papers as BibTeX
        summary.md       a readable summary of your research
        notes/           each research note as a Markdown file
        drafts/          each draft as a folder of LaTeX files
        Papers/          the PDF files

        Everything here opens without ResearchBase.
        """

        try put(Data((readme + "\n").utf8), "README.txt")

        // Check before moving into place.

        try verifyOpenExport(at: root, expectedCounts: snapshot.entityCounts)

        do {
            try fm.moveItem(at: root, to: destination)
        } catch {
            throw WorkspaceExportError.writeFailed(error.localizedDescription)
        }

        return RBA54Outcome(
            files: files,
            warnings: warnings,
            byteCount: rbA54_directorySize(destination),
            pdfCount: pdfCount,
            draftCount: draftCount
        )
    }

    /// A file-name-safe version of `text`, at most 80 characters.
    nonisolated private static func rbA54_stem(_ text: String, fallback: String) -> String {

        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|\0").union(.controlCharacters)

        var name = text.components(separatedBy: bad).joined(separator: " ")
        name = ExportText.collapse(name)
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: ". "))

        if name.isEmpty { name = fallback }
        if name.count > 80 {
            name = String(name.prefix(80)).trimmingCharacters(in: .whitespaces)
        }

        return name
    }

    nonisolated private static func rbA54_directorySize(_ url: URL) -> Int64 {

        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }

        var total: Int64 = 0

        for case let file as URL in enumerator {

            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])

            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }

        return total
    }
}
