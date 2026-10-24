//
//  WorkspaceImportService.swift
//  ResearchBase
//
//  Phase 13 — Import
//
//  Owner: Agent 53 · Features: F-19 (and F-43 log import wiring)
//
//  PUBLIC API (existing, unchanged)
//    WorkspaceImportService.preview(packageAt:context:) / performImport(preview:context:)
//  PUBLIC API (added, F-19)
//    enum   LibraryImportSource / LibraryImportError
//    struct LibraryImportRow / LibraryImportPreview / LibraryImportResult / LibraryImportAttachmentHint
//    struct LogImportPreview
//    WorkspaceImportService.detectLibrarySource(fileAt:) throws -> LibraryImportSource
//    WorkspaceImportService.previewLibraryFile(at:source:reviewState:checkingAgainst:) throws -> LibraryImportPreview
//    WorkspaceImportService.importLibraryFile(_:selecting:into:applyTags:) throws -> LibraryImportResult
//    WorkspaceImportService.previewLogImport(fileAt:options:) throws -> LogImportPreview
//    WorkspaceImportService.commitLogImport(_:toExperiment:into:allowRepeat:) throws -> LogImportResult
//
//  Adds the contents of a `.researchbase` package to the CURRENT
//  workspace. This is not Restore: nothing is replaced or deleted.
//
//  Flow:  Select → Validate → Preview → Import
//
//    preview(packageAt:context:)   reads and verifies the package
//                                  (WorkspaceBackupService.loadPackage)
//                                  and works out what an import would
//                                  do. It changes nothing.
//    performImport(preview:context:) does the import.
//
//  Import rules:
//  - Pass 1 creates records. A record whose id already exists in the
//    workspace is SKIPPED. An existing record is never overwritten.
//  - Pass 2 resolves relationships by id. A link to an id that is in
//    neither the package nor the workspace is reported and skipped.
//    Nothing is ever matched by title, DOI or any other guess.
//  - Records that cannot exist without an owner (PDF annotations,
//    experiment runs, run metrics, baselines, writing sections) are
//    not imported when their owner cannot be found. They are listed in
//    the result, not hidden.
//  - PDFs are copied into ResearchBase's managed Papers folder before
//    any record is created, and each copy is size-checked. The new
//    paper's `pdfFilePath` points at that copy. Absolute paths from
//    the backup machine are never used.
//  - The database is saved once, at the end. If anything fails, the
//    context is rolled back and the copied PDFs are removed, so a
//    failed import leaves the workspace as it was.
//  - The theme in settings.json is NOT applied. Only Restore does that.
//
//  Existing records are not edited. The one unavoidable exception:
//  where SwiftData keeps both sides of a link in sync, a new record
//  linked to an existing one also shows up on the existing record's
//  side of that link.
//

import Foundation
import SwiftData

// MARK: - Errors

enum WorkspaceImportError: LocalizedError {

    case nothingToImport
    case couldNotSavePendingChanges(String)
    case saveFailed(String)

    var errorDescription: String? {
        switch self {

        case .nothingToImport:
            return "There is nothing new to import. Every record in this package is already in your workspace."

        case .couldNotSavePendingChanges(let detail):
            return "Your unsaved changes could not be saved before importing, so nothing was imported. \(detail)"

        case .saveFailed(let detail):
            return "The import could not be saved, so nothing was imported and your workspace was left as it was. \(detail)"
        }
    }
}

// MARK: - Preview

/// One line of the preview table.
struct WorkspaceImportRow: Identifiable {

    let label: String

    /// Records of this type in the package.
    let inPackage: Int

    /// Would be created.
    let newCount: Int

    /// Already in the workspace (same id) and therefore skipped.
    let existingCount: Int

    var id: String { label }
}

/// What an import would do. Built without changing anything.
struct WorkspaceImportPreview {

    let package: LoadedWorkspacePackage

    let rows: [WorkspaceImportRow]

    /// PDF files that would be copied into the workspace.
    let pdfsToCopy: Int

    /// PDF problems found while verifying the package.
    let pdfProblems: [String]

    /// Links that would be skipped (first ones only) and how many in
    /// total.
    let referenceProblems: [String]
    let referenceProblemCount: Int

    /// Things to know that do not stop the import.
    let warnings: [String]

    var newRecordCount: Int {
        rows.reduce(0) { $0 + $1.newCount }
    }

    var existingRecordCount: Int {
        rows.reduce(0) { $0 + $1.existingCount }
    }

    var canImport: Bool {
        newRecordCount > 0
    }

    var createdAt: Date {
        package.manifest.createdAt
    }

    var appVersion: String {
        package.manifest.appVersion
    }
}

// MARK: - Result

struct WorkspaceImportResultRow: Identifiable {

    let label: String
    let created: Int
    let skippedExisting: Int

    var id: String { label }
}

struct WorkspaceImportResult {

    let rows: [WorkspaceImportResultRow]

    let createdTotal: Int
    let skippedExistingTotal: Int

    /// Number of relationships that were set.
    let relationshipsLinked: Int

    /// Links that were skipped (first ones only) and how many in total.
    let skippedRelationships: [String]
    let skippedRelationshipCount: Int

    /// Records that were not imported because their owner is missing
    /// (first ones only) and how many in total.
    let droppedRecords: [String]
    let droppedRecordCount: Int

    let pdfsCopied: Int

    /// Everything else the person should know about.
    let warnings: [String]

    /// One line for the UI.
    var summary: String {

        var text = "Imported \(createdTotal) record"
        if createdTotal != 1 { text += "s" }

        text += " and \(pdfsCopied) PDF file"
        if pdfsCopied != 1 { text += "s" }

        text += "."

        if skippedExistingTotal > 0 {
            text += " \(skippedExistingTotal) already in your workspace and kept as they were."
        }

        return text
    }
}

// MARK: - Service

enum WorkspaceImportService {

    /// Longest list of problem messages kept. The counts stay exact.
    fileprivate static let maxListedProblems = 100

    // MARK: Preview

    /// Reads and verifies the package and works out what importing it
    /// would do. Read-only.
    ///
    /// Throws `WorkspaceBackupError` when the package cannot be used.
    @MainActor
    static func preview(
        packageAt url: URL,
        context: ModelContext
    ) async throws -> WorkspaceImportPreview {

        let package = try await loadVerified(url)

        let existing = try ExistingRecords.fetch(from: context)
        let snapshot = package.snapshot
        let plan = makePlan(snapshot: snapshot, existing: existing)

        let rows = makeRows(plan)

        // PDFs that would be copied

        var pdfsToCopy = 0

        for paper in plan.papers.fresh {
            if package.pdfURL(for: paper) != nil { pdfsToCopy += 1 }
        }

        // Links that would be skipped

        let references = findReferenceProblems(
            snapshot: snapshot,
            plan: plan,
            existing: existing
        )

        // Warnings

        var warnings: [String] = []

        if plan.duplicateCount > 0 {
            warnings.append(
                "\(plan.duplicateCount) record(s) appear more than once in the package. Only the first copy of each will be used."
            )
        }

        let collisions = citationKeyCollisions(plan: plan, existing: existing)

        if collisions > 0 {
            warnings.append(
                "\(collisions) paper(s) to import have the same citation key as another paper. Nothing is changed automatically; you can edit the keys in References afterwards."
            )
        }

        let missingAtBackup = package.manifest.papersWithMissingPDF.count

        if missingAtBackup > 0 {
            warnings.append(
                "\(missingAtBackup) paper(s) had no PDF file when this backup was made, so they will come back without a PDF."
            )
        }

        return WorkspaceImportPreview(
            package: package,
            rows: rows,
            pdfsToCopy: pdfsToCopy,
            pdfProblems: package.pdfProblems,
            referenceProblems: references.messages,
            referenceProblemCount: references.count,
            warnings: warnings
        )
    }

    // MARK: Import

    /// Imports the package described by `preview`.
    ///
    /// The package is read and verified again first, and what already
    /// exists is looked at again, so the result is based on the
    /// workspace as it is now, not as it was when the preview was made.
    @MainActor
    static func performImport(
        preview: WorkspaceImportPreview,
        context: ModelContext
    ) async throws -> WorkspaceImportResult {

        let url = preview.package.url

        // 1. Read and verify the package again.

        let package = try await loadVerified(url)

        // 2. Save pending edits, so a rollback can never discard them.

        if context.hasChanges {
            do {
                try context.save()
            } catch {
                throw WorkspaceImportError.couldNotSavePendingChanges(
                    error.localizedDescription
                )
            }
        }

        // 3. Look at the workspace as it is now.

        let existing = try ExistingRecords.fetch(from: context)
        let plan = makePlan(snapshot: package.snapshot, existing: existing)

        guard plan.newRecordCount > 0 else {
            throw WorkspaceImportError.nothingToImport
        }

        // 4. Copy PDFs into managed storage.

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let staged = await stagePDFs(for: plan.papers.fresh, package: package)

        // 5. Create records, link them, save once.

        let session = ImportSession(context: context, existing: existing)

        apply(plan: plan, existing: existing, staged: staged, session: session)

        do {
            try context.save()
        } catch {

            context.rollback()

            for copy in staged.urls.values {
                try? PaperStorage.shared.deletePDF(at: copy)
            }

            throw WorkspaceImportError.saveFailed(error.localizedDescription)
        }

        // 6. Report.

        var warnings = staged.warnings

        if plan.duplicateCount > 0 {
            warnings.append(
                "\(plan.duplicateCount) record(s) appeared more than once in the package. Only the first copy of each was used."
            )
        }

        if session.annotationsOnExistingPapers > 0 {
            warnings.append(
                "\(session.annotationsOnExistingPapers) PDF annotation(s) were added to papers that were already in your workspace. Those papers' PDF files were not replaced."
            )
        }

        let collisions = citationKeyCollisions(plan: plan, existing: existing)

        if collisions > 0 {
            warnings.append(
                "\(collisions) imported paper(s) have the same citation key as another paper. Nothing was changed automatically."
            )
        }

        let labeledRows = makeRows(plan)

        var resultRows: [WorkspaceImportResultRow] = []

        for row in labeledRows {

            let created = max(0, session.created[row.label] ?? 0)

            resultRows.append(
                WorkspaceImportResultRow(
                    label: row.label,
                    created: created,
                    skippedExisting: row.existingCount
                )
            )
        }

        let createdTotal = resultRows.reduce(0) { $0 + $1.created }
        let skippedTotal = resultRows.reduce(0) { $0 + $1.skippedExisting }

        return WorkspaceImportResult(
            rows: resultRows,
            createdTotal: createdTotal,
            skippedExistingTotal: skippedTotal,
            relationshipsLinked: session.linkCount,
            skippedRelationships: session.issues,
            skippedRelationshipCount: session.issueCount,
            droppedRecords: session.dropped,
            droppedRecordCount: session.droppedCount,
            pdfsCopied: staged.urls.count,
            warnings: warnings
        )
    }

    // MARK: Loading

    /// Same pattern the backup service uses: hashing PDFs runs off the
    /// main actor.
    private static func loadVerified(
        _ url: URL
    ) async throws -> LoadedWorkspacePackage {

        try await Task.detached(priority: .userInitiated) {
            try WorkspaceBackupService.loadPackage(at: url, verifyPDFs: true)
        }.value
    }

    // MARK: PDFs

    private struct StagedPDFs {
        var urls: [UUID: URL] = [:]
        var warnings: [String] = []
    }

    /// Copies each new paper's PDF into managed storage and checks the
    /// copy's size. A paper whose PDF cannot be copied is still
    /// imported, without a PDF, and a warning says so.
    @MainActor
    private static func stagePDFs(
        for papers: [PaperDTO],
        package: LoadedWorkspacePackage
    ) async -> StagedPDFs {

        var staged = StagedPDFs()

        for paper in papers {

            guard paper.pdfFileName != nil else { continue }

            let title = displayName(paper.title, fallback: "Untitled paper")

            guard let source = package.pdfURL(for: paper) else {
                staged.warnings.append(
                    "\"\(title)\": its PDF was missing or damaged in the backup, so the paper was imported without a PDF."
                )
                continue
            }

            do {
                let copy = try PaperStorage.shared.importPDF(from: source)

                let sourceSize = byteCount(of: source)
                let copySize = byteCount(of: copy)

                if sourceSize == nil || sourceSize != copySize {

                    try? PaperStorage.shared.deletePDF(at: copy)

                    staged.warnings.append(
                        "\"\(title)\": its PDF was copied but the copy did not match, so the paper was imported without a PDF."
                    )
                    continue
                }

                staged.urls[paper.id] = copy

            } catch {
                staged.warnings.append(
                    "\"\(title)\": its PDF could not be copied (\(error.localizedDescription)), so the paper was imported without a PDF."
                )
            }

            // Let the interface update between large copies.
            await Task.yield()
        }

        return staged
    }

    private static func byteCount(of url: URL) -> Int64? {

        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: url.path
        ) else { return nil }

        return (attributes[.size] as? NSNumber)?.int64Value
    }

    // MARK: Plan

    /// Which records of one type are new, which already exist, and how
    /// many are repeats inside the package.
    private struct Partition<D> {
        var total: Int
        var fresh: [D]
        var existingCount: Int
        var duplicateCount: Int
    }

    private static func partition<D>(
        _ items: [D],
        existing: Set<UUID>,
        id: (D) -> UUID
    ) -> Partition<D> {

        var seen = Set<UUID>()
        var fresh: [D] = []
        var existingCount = 0
        var duplicates = 0

        for item in items {

            let itemID = id(item)

            if !seen.insert(itemID).inserted {
                duplicates += 1
                continue
            }

            if existing.contains(itemID) {
                existingCount += 1
                continue
            }

            fresh.append(item)
        }

        return Partition(
            total: items.count,
            fresh: fresh,
            existingCount: existingCount,
            duplicateCount: duplicates
        )
    }

    private struct ImportPlan {

        var papers: Partition<PaperDTO>
        var annotations: Partition<PDFAnnotationDTO>
        var notes: Partition<ResearchNoteDTO>

        var reviews: Partition<LiteratureReviewDTO>
        var themes: Partition<LiteratureThemeDTO>
        var findings: Partition<LiteratureFindingDTO>
        var comparisons: Partition<LiteratureComparisonEntryDTO>
        var syntheses: Partition<LiteratureSynthesisDTO>

        var gaps: Partition<ResearchGapDTO>
        var problems: Partition<ResearchProblemDTO>
        var ideas: Partition<ResearchIdeaDTO>

        var experiments: Partition<ExperimentDTO>
        var runs: Partition<ExperimentRunDTO>
        var metrics: Partition<RunMetricDTO>
        var baselines: Partition<BaselineMetricDTO>

        var documents: Partition<WritingDocumentDTO>
        var sections: Partition<WritingSectionDTO>

        var projects: Partition<ResearchProjectDTO>
        var tasks: Partition<ResearchTaskDTO>

        var newRecordCount: Int {
            papers.fresh.count
                + annotations.fresh.count
                + notes.fresh.count
                + reviews.fresh.count
                + themes.fresh.count
                + findings.fresh.count
                + comparisons.fresh.count
                + syntheses.fresh.count
                + gaps.fresh.count
                + problems.fresh.count
                + ideas.fresh.count
                + experiments.fresh.count
                + runs.fresh.count
                + metrics.fresh.count
                + baselines.fresh.count
                + documents.fresh.count
                + sections.fresh.count
                + projects.fresh.count
                + tasks.fresh.count
        }

        var duplicateCount: Int {
            papers.duplicateCount
                + annotations.duplicateCount
                + notes.duplicateCount
                + reviews.duplicateCount
                + themes.duplicateCount
                + findings.duplicateCount
                + comparisons.duplicateCount
                + syntheses.duplicateCount
                + gaps.duplicateCount
                + problems.duplicateCount
                + ideas.duplicateCount
                + experiments.duplicateCount
                + runs.duplicateCount
                + metrics.duplicateCount
                + baselines.duplicateCount
                + documents.duplicateCount
                + sections.duplicateCount
                + projects.duplicateCount
                + tasks.duplicateCount
        }
    }

    private static func makePlan(
        snapshot s: WorkspaceSnapshot,
        existing e: ExistingRecords
    ) -> ImportPlan {

        ImportPlan(
            papers: partition(s.papers, existing: Set(e.papers.keys), id: { $0.id }),
            annotations: partition(s.annotations, existing: Set(e.annotations.keys), id: { $0.id }),
            notes: partition(s.notes, existing: Set(e.notes.keys), id: { $0.id }),

            reviews: partition(s.reviews, existing: Set(e.reviews.keys), id: { $0.id }),
            themes: partition(s.themes, existing: Set(e.themes.keys), id: { $0.id }),
            findings: partition(s.findings, existing: Set(e.findings.keys), id: { $0.id }),
            comparisons: partition(s.comparisonEntries, existing: Set(e.comparisons.keys), id: { $0.id }),
            syntheses: partition(s.syntheses, existing: Set(e.syntheses.keys), id: { $0.id }),

            gaps: partition(s.gaps, existing: Set(e.gaps.keys), id: { $0.id }),
            problems: partition(s.problems, existing: Set(e.problems.keys), id: { $0.id }),
            ideas: partition(s.ideas, existing: Set(e.ideas.keys), id: { $0.id }),

            experiments: partition(s.experiments, existing: Set(e.experiments.keys), id: { $0.id }),
            runs: partition(s.runs, existing: Set(e.runs.keys), id: { $0.id }),
            metrics: partition(s.metrics, existing: Set(e.metrics.keys), id: { $0.id }),
            baselines: partition(s.baselineMetrics, existing: Set(e.baselines.keys), id: { $0.id }),

            documents: partition(s.writingDocuments, existing: Set(e.documents.keys), id: { $0.id }),
            sections: partition(s.writingSections, existing: Set(e.sections.keys), id: { $0.id }),

            projects: partition(s.projects, existing: Set(e.projects.keys), id: { $0.id }),
            tasks: partition(s.tasks, existing: Set(e.tasks.keys), id: { $0.id })
        )
    }

    // MARK: Labels and rows

    /// Same display names the backup uses for record counts.
    private enum Label {
        static let papers = "Papers"
        static let annotations = "PDF Annotations"
        static let notes = "Research Notes"
        static let reviews = "Literature Reviews"
        static let themes = "Literature Themes"
        static let findings = "Findings"
        static let comparisons = "Comparison Entries"
        static let syntheses = "Syntheses"
        static let gaps = "Research Gaps"
        static let problems = "Research Problems"
        static let ideas = "Research Ideas"
        static let experiments = "Experiments"
        static let runs = "Experiment Runs"
        static let metrics = "Run Metrics"
        static let baselines = "Baseline Metrics"
        static let documents = "Writing Documents"
        static let sections = "Writing Sections"
        static let projects = "Projects"
        static let tasks = "Tasks"
    }

    private static func row<D>(
        _ label: String,
        _ part: Partition<D>
    ) -> WorkspaceImportRow {

        WorkspaceImportRow(
            label: label,
            inPackage: part.total,
            newCount: part.fresh.count,
            existingCount: part.existingCount
        )
    }

    /// Only types that have records in the package get a row.
    private static func makeRows(_ plan: ImportPlan) -> [WorkspaceImportRow] {

        let all: [WorkspaceImportRow] = [
            row(Label.papers, plan.papers),
            row(Label.annotations, plan.annotations),
            row(Label.notes, plan.notes),
            row(Label.reviews, plan.reviews),
            row(Label.themes, plan.themes),
            row(Label.findings, plan.findings),
            row(Label.comparisons, plan.comparisons),
            row(Label.syntheses, plan.syntheses),
            row(Label.gaps, plan.gaps),
            row(Label.problems, plan.problems),
            row(Label.ideas, plan.ideas),
            row(Label.experiments, plan.experiments),
            row(Label.runs, plan.runs),
            row(Label.metrics, plan.metrics),
            row(Label.baselines, plan.baselines),
            row(Label.documents, plan.documents),
            row(Label.sections, plan.sections),
            row(Label.projects, plan.projects),
            row(Label.tasks, plan.tasks)
        ]

        return all.filter { $0.inPackage > 0 }
    }

    // MARK: Text helpers

    private static func displayName(_ text: String, fallback: String) -> String {

        let cleaned = text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")

        if cleaned.isEmpty { return fallback }

        return String(cleaned.prefix(60))
    }

    /// e.g. Note "Attention is all you need"
    fileprivate static func owner(
        _ kind: String,
        _ text: String,
        fallback: String
    ) -> String {

        "\(kind) \"\(displayName(text, fallback: fallback))\""
    }

    // MARK: Citation keys

    /// New papers whose key matches another paper's key (case does not
    /// matter). Only counted, never changed.
    private static func citationKeyCollisions(
        plan: ImportPlan,
        existing: ExistingRecords
    ) -> Int {

        var used = Set<String>()

        for paper in existing.papers.values {
            let key = paper.citationKey
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if !key.isEmpty { used.insert(key) }
        }

        var collisions = 0

        for paper in plan.papers.fresh {

            let key = paper.citationKey
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()

            if key.isEmpty { continue }

            if used.contains(key) {
                collisions += 1
            } else {
                used.insert(key)
            }
        }

        return collisions
    }

    // MARK: Reference check (for the preview)

    /// Works out, without creating anything, which links an import
    /// would skip. The import itself resolves the same links against
    /// real records and reports what it actually did.
    private static func findReferenceProblems(
        snapshot s: WorkspaceSnapshot,
        plan: ImportPlan,
        existing e: ExistingRecords
    ) -> (messages: [String], count: Int) {

        var messages: [String] = []
        var count = 0

        func report(_ text: String) {
            count += 1
            if messages.count < maxListedProblems { messages.append(text) }
        }

        // Every id that will exist after the import.

        let papers = Set(e.papers.keys).union(s.papers.map { $0.id })
        let notes = Set(e.notes.keys).union(s.notes.map { $0.id })
        let reviews = Set(e.reviews.keys).union(s.reviews.map { $0.id })
        let findings = Set(e.findings.keys).union(s.findings.map { $0.id })
        let gaps = Set(e.gaps.keys).union(s.gaps.map { $0.id })
        let problems = Set(e.problems.keys).union(s.problems.map { $0.id })
        let ideas = Set(e.ideas.keys).union(s.ideas.map { $0.id })
        let experiments = Set(e.experiments.keys).union(s.experiments.map { $0.id })
        let documents = Set(e.documents.keys).union(s.writingDocuments.map { $0.id })
        let projects = Set(e.projects.keys).union(s.projects.map { $0.id })

        // A run only exists after the import if its experiment does.

        var runs = Set(e.runs.keys)

        for run in s.runs {
            if let experimentID = run.experimentID, experiments.contains(experimentID) {
                runs.insert(run.id)
            }
        }

        func checkLinks(
            _ ownerText: String,
            _ kind: String,
            _ ids: [UUID],
            _ known: Set<UUID>
        ) {
            var seen = Set<UUID>()

            for id in ids {
                if !seen.insert(id).inserted { continue }

                if !known.contains(id) {
                    report("\(ownerText): a linked \(kind) is not in the package or your workspace, so that link would be skipped.")
                }
            }
        }

        func checkOwner(
            _ ownerText: String,
            _ kind: String,
            _ id: UUID?,
            _ known: Set<UUID>
        ) {
            if let id = id, known.contains(id) { return }

            report("\(ownerText): its \(kind) was not found, so it would not be imported.")
        }

        func checkOptional(
            _ ownerText: String,
            _ kind: String,
            _ id: UUID?,
            _ known: Set<UUID>
        ) {
            guard let id = id else { return }

            if !known.contains(id) {
                report("\(ownerText): its \(kind) is not in the package or your workspace, so that link would be skipped.")
            }
        }

        for a in plan.annotations.fresh {
            checkOwner("PDF annotation", "paper", a.paperID, papers)
        }

        for n in plan.notes.fresh {
            checkLinks(owner("Note", n.title, fallback: "Untitled note"), "paper", n.paperIDs, papers)
        }

        for r in plan.reviews.fresh {
            checkLinks(owner("Review", r.title, fallback: "Untitled review"), "paper", r.paperIDs, papers)
        }

        for t in plan.themes.fresh {
            let name = owner("Theme", t.name, fallback: "Untitled theme")
            checkOptional(name, "review", t.reviewID, reviews)
            checkLinks(name, "paper", t.paperIDs, papers)
        }

        for f in plan.findings.fresh {
            let name = owner("Finding", f.title, fallback: "Untitled finding")
            checkOptional(name, "review", f.reviewID, reviews)
            checkLinks(name, "paper", f.supportingPaperIDs, papers)
            checkLinks(name, "gap", f.gapIDs, gaps)
        }

        for c in plan.comparisons.fresh {
            let name = "Comparison entry"
            checkOptional(name, "review", c.reviewID, reviews)
            checkOptional(name, "paper", c.paperID, papers)
        }

        for x in plan.syntheses.fresh {
            checkOptional("Synthesis", "review", x.reviewID, reviews)
        }

        for g in plan.gaps.fresh {
            checkLinks(owner("Gap", g.title, fallback: "Untitled gap"), "paper", g.paperIDs, papers)
        }

        for p in plan.problems.fresh {
            let name = owner("Problem", p.title, fallback: "Untitled problem")
            checkLinks(name, "gap", p.gapIDs, gaps)
            checkLinks(name, "paper", p.paperIDs, papers)
        }

        for i in plan.ideas.fresh {
            let name = owner("Idea", i.title, fallback: "Untitled idea")
            checkLinks(name, "problem", i.problemIDs, problems)
            checkLinks(name, "gap", i.gapIDs, gaps)
            checkLinks(name, "paper", i.paperIDs, papers)
            checkLinks(name, "note", i.noteIDs, notes)
        }

        for x in plan.experiments.fresh {
            let name = owner("Experiment", x.name, fallback: "Untitled experiment")
            checkLinks(name, "idea", x.ideaIDs, ideas)
            checkLinks(name, "problem", x.problemIDs, problems)
            checkLinks(name, "gap", x.gapIDs, gaps)
            checkLinks(name, "paper", x.paperIDs, papers)
            checkLinks(name, "note", x.noteIDs, notes)
        }

        for r in plan.runs.fresh {
            checkOwner("Run \(r.runNumber)", "experiment", r.experimentID, experiments)
        }

        for m in plan.metrics.fresh {
            checkOwner(owner("Metric", m.name, fallback: "Unnamed"), "run", m.runID, runs)
        }

        for b in plan.baselines.fresh {
            checkOwner(owner("Baseline", b.name, fallback: "Unnamed"), "experiment", b.experimentID, experiments)
        }

        for d in plan.documents.fresh {
            let name = owner("Writing document", d.title, fallback: "Untitled document")
            checkLinks(name, "problem", d.problemIDs, problems)
            checkLinks(name, "idea", d.ideaIDs, ideas)
            checkLinks(name, "gap", d.gapIDs, gaps)
            checkLinks(name, "experiment", d.experimentIDs, experiments)
            checkLinks(name, "paper", d.paperIDs, papers)
            checkLinks(name, "note", d.noteIDs, notes)
            checkLinks(name, "finding", d.findingIDs, findings)
        }

        for x in plan.sections.fresh {
            checkOwner(owner("Section", x.title, fallback: "Untitled section"), "document", x.documentID, documents)
        }

        for p in plan.projects.fresh {
            let name = owner("Project", p.name, fallback: "Untitled project")
            checkLinks(name, "paper", p.paperIDs, papers)
            checkLinks(name, "note", p.noteIDs, notes)
            checkLinks(name, "finding", p.findingIDs, findings)
            checkLinks(name, "gap", p.gapIDs, gaps)
            checkLinks(name, "problem", p.problemIDs, problems)
            checkLinks(name, "idea", p.ideaIDs, ideas)
            checkLinks(name, "experiment", p.experimentIDs, experiments)
            checkLinks(name, "writing document", p.writingDocumentIDs, documents)
        }

        for t in plan.tasks.fresh {
            let name = owner("Task", t.title, fallback: "Untitled task")
            checkOptional(name, "project", t.projectID, projects)
            checkLinks(name, "paper", t.paperIDs, papers)
            checkLinks(name, "problem", t.problemIDs, problems)
            checkLinks(name, "idea", t.ideaIDs, ideas)
            checkLinks(name, "experiment", t.experimentIDs, experiments)
            checkLinks(name, "writing document", t.writingDocumentIDs, documents)
        }

        return (messages, count)
    }

    // MARK: Apply (pass 1 + pass 2)

    /// Creates every new record, then links them. Does not save.
    @MainActor
    private static func apply(
        plan: ImportPlan,
        existing: ExistingRecords,
        staged: StagedPDFs,
        session: ImportSession
    ) {

        // =====================================================
        // PASS 1 — create records. Nothing is linked yet.
        // =====================================================

        // Papers

        for dto in plan.papers.fresh {

            var path = ""
            if let copy = staged.urls[dto.id] { path = copy.path }

            let record = PaperRecord(
                id: dto.id,
                pdfFilePath: path,
                title: dto.title,
                authors: dto.authors,
                venue: dto.venue,
                year: dto.year,
                abstractText: dto.abstractText,
                doi: dto.doi,
                urlString: dto.urlString,
                tagsText: dto.tagsText,
                statusRawValue: dto.statusRawValue,
                rating: dto.rating,
                addedAt: dto.addedAt,
                lastOpenedAt: dto.lastOpenedAt,
                citationKey: dto.citationKey,
                publicationTypeRawValue: dto.publicationTypeRawValue,
                publisher: dto.publisher,
                volume: dto.volume,
                issue: dto.issue,
                pages: dto.pages,
                edition: dto.edition,
                month: dto.month,
                updatedAt: dto.updatedAt
            )

            session.context.insert(record)
            session.papers[dto.id] = record
        }

        session.created[Label.papers] = plan.papers.fresh.count

        // PDF annotations

        var annotationRecords: [(PDFAnnotationDTO, PDFNoteRecord)] = []

        for dto in plan.annotations.fresh {

            let record = PDFNoteRecord(
                id: dto.id,
                text: dto.text,
                note: dto.note,
                pageNumber: dto.pageNumber,
                boundsX: dto.boundsX,
                boundsY: dto.boundsY,
                boundsWidth: dto.boundsWidth,
                boundsHeight: dto.boundsHeight,
                createdAt: dto.createdAt,
                updatedAt: dto.updatedAt
            )

            session.context.insert(record)
            annotationRecords.append((dto, record))
        }

        session.created[Label.annotations] = plan.annotations.fresh.count

        // Research notes

        var noteRecords: [(ResearchNoteDTO, ResearchNote)] = []

        for dto in plan.notes.fresh {

            let record = ResearchNote(
                id: dto.id,
                title: dto.title,
                content: dto.content,
                typeRawValue: dto.typeRawValue,
                tagsText: dto.tagsText,
                createdAt: dto.createdAt,
                updatedAt: dto.updatedAt
            )

            session.context.insert(record)
            session.notes[dto.id] = record
            noteRecords.append((dto, record))
        }

        session.created[Label.notes] = plan.notes.fresh.count

        // Literature reviews

        var reviewRecords: [(LiteratureReviewDTO, LiteratureReview)] = []

        for dto in plan.reviews.fresh {

            let record = LiteratureReview(
                id: dto.id,
                title: dto.title,
                descriptionText: dto.descriptionText,
                researchQuestion: dto.researchQuestion,
                createdAt: dto.createdAt,
                updatedAt: dto.updatedAt
            )

            session.context.insert(record)
            session.reviews[dto.id] = record
            reviewRecords.append((dto, record))
        }

        session.created[Label.reviews] = plan.reviews.fresh.count

        var themeRecords: [(LiteratureThemeDTO, LiteratureTheme)] = []

        for dto in plan.themes.fresh {

            let record = LiteratureTheme(
                id: dto.id,
                name: dto.name,
                descriptionText: dto.descriptionText,
                createdAt: dto.createdAt,
                updatedAt: dto.updatedAt
            )

            session.context.insert(record)
            themeRecords.append((dto, record))
        }

        session.created[Label.themes] = plan.themes.fresh.count

        var findingRecords: [(LiteratureFindingDTO, LiteratureFinding)] = []

        for dto in plan.findings.fresh {

            let record = LiteratureFinding(
                id: dto.id,
                title: dto.title,
                content: dto.content,
                createdAt: dto.createdAt,
                updatedAt: dto.updatedAt
            )

            session.context.insert(record)
            session.findings[dto.id] = record
            findingRecords.append((dto, record))
        }

        session.created[Label.findings] = plan.findings.fresh.count

        var comparisonRecords: [(LiteratureComparisonEntryDTO, LiteratureComparisonEntry)] = []

        for dto in plan.comparisons.fresh {

            let record = LiteratureComparisonEntry(
                id: dto.id,
                method: dto.method,
                dataset: dto.dataset,
                mainFinding: dto.mainFinding,
                notes: dto.notes,
                createdAt: dto.createdAt,
                updatedAt: dto.updatedAt
            )

            session.context.insert(record)
            comparisonRecords.append((dto, record))
        }

        session.created[Label.comparisons] = plan.comparisons.fresh.count

        var synthesisRecords: [(LiteratureSynthesisDTO, LiteratureSynthesis)] = []

        for dto in plan.syntheses.fresh {

            let record = LiteratureSynthesis(
                id: dto.id,
                commonApproaches: dto.commonApproaches,
                majorFindings: dto.majorFindings,
                areasOfAgreement: dto.areasOfAgreement,
                areasOfDisagreement: dto.areasOfDisagreement,
                methodologicalDifferences: dto.methodologicalDifferences,
                limitationsAcrossLiterature: dto.limitationsAcrossLiterature,
                overallSummary: dto.overallSummary,
                createdAt: dto.createdAt,
                updatedAt: dto.updatedAt
            )

            session.context.insert(record)
            synthesisRecords.append((dto, record))
        }

        session.created[Label.syntheses] = plan.syntheses.fresh.count

        // Gaps, problems, ideas

        var gapRecords: [(ResearchGapDTO, ResearchGap)] = []

        for dto in plan.gaps.fresh {

            let record = ResearchGap(
                id: dto.id,
                title: dto.title,
                descriptionText: dto.descriptionText,
                gapTypeRawValue: dto.gapTypeRawValue,
                statusRawValue: dto.statusRawValue,
                evidence: dto.evidence,
                significance: dto.significance,
                createdAt: dto.createdAt,
                updatedAt: dto.updatedAt
            )

            session.context.insert(record)
            session.gaps[dto.id] = record
            gapRecords.append((dto, record))
        }

        session.created[Label.gaps] = plan.gaps.fresh.count

        var problemRecords: [(ResearchProblemDTO, ResearchProblem)] = []

        for dto in plan.problems.fresh {

            let record = ResearchProblem(
                id: dto.id,
                title: dto.title,
                problemStatement: dto.problemStatement,
                background: dto.background,
                motivation: dto.motivation,
                significance: dto.significance,
                researchQuestion: dto.researchQuestion,
                objectives: dto.objectives,
                hypotheses: dto.hypotheses,
                statusRawValue: dto.statusRawValue,
                createdAt: dto.createdAt,
                updatedAt: dto.updatedAt
            )

            session.context.insert(record)
            session.problems[dto.id] = record
            problemRecords.append((dto, record))
        }

        session.created[Label.problems] = plan.problems.fresh.count

        var ideaRecords: [(ResearchIdeaDTO, ResearchIdea)] = []

        for dto in plan.ideas.fresh {

            let record = ResearchIdea(
                id: dto.id,
                title: dto.title,
                summary: dto.summary,
                descriptionText: dto.descriptionText,
                proposedApproach: dto.proposedApproach,
                expectedContribution: dto.expectedContribution,
                novelty: dto.novelty,
                assumptions: dto.assumptions,
                limitations: dto.limitations,
                statusRawValue: dto.statusRawValue,
                createdAt: dto.createdAt,
                updatedAt: dto.updatedAt
            )

            session.context.insert(record)
            session.ideas[dto.id] = record
            ideaRecords.append((dto, record))
        }

        session.created[Label.ideas] = plan.ideas.fresh.count

        // Experiments

        var experimentRecords: [(ExperimentDTO, Experiment)] = []

        for dto in plan.experiments.fresh {

            let record = Experiment(
                id: dto.id,
                name: dto.name,
                statusRawValue: dto.statusRawValue,
                objective: dto.objective,
                hypothesis: dto.hypothesis,
                descriptionText: dto.descriptionText,
                dataset: dto.dataset,
                datasetVersion: dto.datasetVersion,
                model: dto.model,
                framework: dto.framework,
                hardware: dto.hardware,
                operatingEnvironment: dto.operatingEnvironment,
                codeRepository: dto.codeRepository,
                trainValidationTestSplit: dto.trainValidationTestSplit,
                seed: dto.seed,
                batchSize: dto.batchSize,
                learningRate: dto.learningRate,
                epochs: dto.epochs,
                optimizer: dto.optimizer,
                bestRunID: dto.bestRunID,
                resultsInterpretation: dto.resultsInterpretation,
                resultsConclusion: dto.resultsConclusion,
                createdAt: dto.createdAt,
                updatedAt: dto.updatedAt
            )

            session.context.insert(record)
            session.experiments[dto.id] = record
            experimentRecords.append((dto, record))
        }

        session.created[Label.experiments] = plan.experiments.fresh.count

        var runRecords: [(ExperimentRunDTO, ExperimentRun)] = []

        for dto in plan.runs.fresh {

            let record = ExperimentRun(
                id: dto.id,
                runNumber: dto.runNumber,
                statusRawValue: dto.statusRawValue,
                startedAt: dto.startedAt,
                completedAt: dto.completedAt,
                seed: dto.seed,
                configuration: dto.configuration,
                notes: dto.notes,
                createdAt: dto.createdAt,
                updatedAt: dto.updatedAt
            )

            session.context.insert(record)
            session.runs[dto.id] = record
            runRecords.append((dto, record))
        }

        session.created[Label.runs] = plan.runs.fresh.count

        var metricRecords: [(RunMetricDTO, RunMetric)] = []

        for dto in plan.metrics.fresh {

            let record = RunMetric(
                id: dto.id,
                name: dto.name,
                value: dto.value,
                unit: dto.unit,
                higherIsBetter: dto.higherIsBetter
            )

            session.context.insert(record)
            metricRecords.append((dto, record))
        }

        session.created[Label.metrics] = plan.metrics.fresh.count

        var baselineRecords: [(BaselineMetricDTO, BaselineMetric)] = []

        for dto in plan.baselines.fresh {

            let record = BaselineMetric(
                id: dto.id,
                name: dto.name,
                value: dto.value,
                unit: dto.unit,
                higherIsBetter: dto.higherIsBetter
            )

            session.context.insert(record)
            baselineRecords.append((dto, record))
        }

        session.created[Label.baselines] = plan.baselines.fresh.count

        // Writing

        var documentRecords: [(WritingDocumentDTO, WritingDocument)] = []

        for dto in plan.documents.fresh {

            let record = WritingDocument(
                id: dto.id,
                title: dto.title,
                documentTypeRawValue: dto.documentTypeRawValue,
                statusRawValue: dto.statusRawValue,
                createdAt: dto.createdAt,
                updatedAt: dto.updatedAt
            )

            // Copy the writing lifecycle fields. Old backups have none of
            // these, so they stay nil and the app derives them on read.
            record.stageRawValue = dto.stageRawValue
            record.formatRawValue = dto.formatRawValue
            record.venue = dto.venue
            record.submissionNote = dto.submissionNote
            record.progressPercent = dto.progressPercent
            record.archivedFlag = dto.archivedFlag

            session.context.insert(record)
            session.documents[dto.id] = record
            documentRecords.append((dto, record))
        }

        session.created[Label.documents] = plan.documents.fresh.count

        var sectionRecords: [(WritingSectionDTO, WritingSection)] = []

        for dto in plan.sections.fresh {

            let record = WritingSection(
                id: dto.id,
                title: dto.title,
                sectionTypeRawValue: dto.sectionTypeRawValue,
                content: dto.content,
                order: dto.order,
                createdAt: dto.createdAt,
                updatedAt: dto.updatedAt
            )

            session.context.insert(record)
            sectionRecords.append((dto, record))
        }

        session.created[Label.sections] = plan.sections.fresh.count

        // Projects and tasks

        var projectRecords: [(ResearchProjectDTO, ResearchProject)] = []

        for dto in plan.projects.fresh {

            let record = ResearchProject(
                id: dto.id,
                name: dto.name,
                descriptionText: dto.descriptionText,
                statusRawValue: dto.statusRawValue,
                createdAt: dto.createdAt,
                updatedAt: dto.updatedAt
            )

            session.context.insert(record)
            session.projects[dto.id] = record
            projectRecords.append((dto, record))
        }

        session.created[Label.projects] = plan.projects.fresh.count

        var taskRecords: [(ResearchTaskDTO, ResearchTask)] = []

        for dto in plan.tasks.fresh {

            let record = ResearchTask(
                id: dto.id,
                title: dto.title,
                descriptionText: dto.descriptionText,
                statusRawValue: dto.statusRawValue,
                priorityRawValue: dto.priorityRawValue,
                dueDate: dto.dueDate,
                createdAt: dto.createdAt,
                updatedAt: dto.updatedAt,
                completedDate: dto.completedDate
            )

            session.context.insert(record)
            taskRecords.append((dto, record))
        }

        session.created[Label.tasks] = plan.tasks.fresh.count

        // =====================================================
        // PASS 2 — resolve relationships by id.
        //
        // Only NEW records get their links set. Existing records
        // are never edited directly.
        // =====================================================

        // PDF annotations belong to a paper.

        for (dto, record) in annotationRecords {

            let description = "PDF annotation"

            guard let paperID = dto.paperID else {
                session.drop(
                    record,
                    label: Label.annotations,
                    text: "\(description): it was not attached to a paper, so it was not imported."
                )
                continue
            }

            guard let paper = session.papers[paperID] else {
                session.drop(
                    record,
                    label: Label.annotations,
                    text: "\(description): its paper is not in the package or your workspace, so it was not imported."
                )
                continue
            }

            record.paper = paper
            session.linkCount += 1

            if existing.papers[paperID] != nil {
                session.annotationsOnExistingPapers += 1
            }
        }

        // Research notes

        for (dto, record) in noteRecords {

            let name = owner("Note", dto.title, fallback: "Untitled note")

            record.linkedPapers = session.resolve(
                dto.paperIDs, in: session.papers, owner: name, kind: "paper"
            )
        }

        // Literature reviews

        for (dto, record) in reviewRecords {

            let name = owner("Review", dto.title, fallback: "Untitled review")

            record.papers = session.resolve(
                dto.paperIDs, in: session.papers, owner: name, kind: "paper"
            )
        }

        for (dto, record) in themeRecords {

            let name = owner("Theme", dto.name, fallback: "Untitled theme")

            record.review = session.resolveOptional(
                dto.reviewID, in: session.reviews, owner: name, kind: "review"
            )

            record.papers = session.resolve(
                dto.paperIDs, in: session.papers, owner: name, kind: "paper"
            )
        }

        for (dto, record) in findingRecords {

            let name = owner("Finding", dto.title, fallback: "Untitled finding")

            record.review = session.resolveOptional(
                dto.reviewID, in: session.reviews, owner: name, kind: "review"
            )

            record.supportingPapers = session.resolve(
                dto.supportingPaperIDs, in: session.papers, owner: name, kind: "paper"
            )

            record.researchGaps = session.resolve(
                dto.gapIDs, in: session.gaps, owner: name, kind: "gap"
            )
        }

        for (dto, record) in comparisonRecords {

            let name = "Comparison entry"

            record.review = session.resolveOptional(
                dto.reviewID, in: session.reviews, owner: name, kind: "review"
            )

            record.paper = session.resolveOptional(
                dto.paperID, in: session.papers, owner: name, kind: "paper"
            )
        }

        // A review holds at most one synthesis. Never replace one.

        var reviewsGivenSynthesis = Set<UUID>()

        for (dto, record) in synthesisRecords {

            guard let reviewID = dto.reviewID else { continue }

            guard let review = session.resolveOptional(
                reviewID, in: session.reviews, owner: "Synthesis", kind: "review"
            ) else { continue }

            if review.synthesis != nil || reviewsGivenSynthesis.contains(reviewID) {
                session.report(
                    "Synthesis: its review already has a synthesis, so this one was imported without being attached to it."
                )
                continue
            }

            record.review = review
            reviewsGivenSynthesis.insert(reviewID)
        }

        // Gaps, problems, ideas

        for (dto, record) in gapRecords {

            let name = owner("Gap", dto.title, fallback: "Untitled gap")

            record.papers = session.resolve(
                dto.paperIDs, in: session.papers, owner: name, kind: "paper"
            )
        }

        for (dto, record) in problemRecords {

            let name = owner("Problem", dto.title, fallback: "Untitled problem")

            record.gaps = session.resolve(
                dto.gapIDs, in: session.gaps, owner: name, kind: "gap"
            )

            record.papers = session.resolve(
                dto.paperIDs, in: session.papers, owner: name, kind: "paper"
            )
        }

        for (dto, record) in ideaRecords {

            let name = owner("Idea", dto.title, fallback: "Untitled idea")

            record.problems = session.resolve(
                dto.problemIDs, in: session.problems, owner: name, kind: "problem"
            )

            record.gaps = session.resolve(
                dto.gapIDs, in: session.gaps, owner: name, kind: "gap"
            )

            record.papers = session.resolve(
                dto.paperIDs, in: session.papers, owner: name, kind: "paper"
            )

            record.notes = session.resolve(
                dto.noteIDs, in: session.notes, owner: name, kind: "note"
            )
        }

        // Experiments

        for (dto, record) in experimentRecords {

            let name = owner("Experiment", dto.name, fallback: "Untitled experiment")

            record.ideas = session.resolve(
                dto.ideaIDs, in: session.ideas, owner: name, kind: "idea"
            )

            record.problems = session.resolve(
                dto.problemIDs, in: session.problems, owner: name, kind: "problem"
            )

            record.gaps = session.resolve(
                dto.gapIDs, in: session.gaps, owner: name, kind: "gap"
            )

            record.papers = session.resolve(
                dto.paperIDs, in: session.papers, owner: name, kind: "paper"
            )

            record.notes = session.resolve(
                dto.noteIDs, in: session.notes, owner: name, kind: "note"
            )
        }

        // Runs belong to an experiment.

        for (dto, record) in runRecords {

            let description = "Run \(dto.runNumber)"

            guard let experimentID = dto.experimentID else {
                session.drop(
                    record,
                    label: Label.runs,
                    text: "\(description): it was not attached to an experiment, so it was not imported."
                )
                session.runs[dto.id] = nil
                continue
            }

            guard let experiment = session.experiments[experimentID] else {
                session.drop(
                    record,
                    label: Label.runs,
                    text: "\(description): its experiment is not in the package or your workspace, so it was not imported."
                )
                session.runs[dto.id] = nil
                continue
            }

            record.experiment = experiment
            session.linkCount += 1
        }

        // Metrics belong to a run that is still present.

        for (dto, record) in metricRecords {

            let description = owner("Metric", dto.name, fallback: "Unnamed")

            guard let runID = dto.runID else {
                session.drop(
                    record,
                    label: Label.metrics,
                    text: "\(description): it was not attached to a run, so it was not imported."
                )
                continue
            }

            guard let run = session.runs[runID] else {
                session.drop(
                    record,
                    label: Label.metrics,
                    text: "\(description): its run is not available, so it was not imported."
                )
                continue
            }

            record.run = run
            session.linkCount += 1
        }

        // Baselines belong to an experiment.

        for (dto, record) in baselineRecords {

            let description = owner("Baseline", dto.name, fallback: "Unnamed")

            guard let experimentID = dto.experimentID else {
                session.drop(
                    record,
                    label: Label.baselines,
                    text: "\(description): it was not attached to an experiment, so it was not imported."
                )
                continue
            }

            guard let experiment = session.experiments[experimentID] else {
                session.drop(
                    record,
                    label: Label.baselines,
                    text: "\(description): its experiment is not in the package or your workspace, so it was not imported."
                )
                continue
            }

            record.experiment = experiment
            session.linkCount += 1
        }

        // The best run is stored as an id. Keep it only if that run
        // exists; never point at something that is not there.

        for (dto, record) in experimentRecords {

            guard let bestID = record.bestRunID else { continue }

            if session.runs[bestID] == nil {

                record.bestRunID = nil

                session.report(
                    "\(owner("Experiment", dto.name, fallback: "Untitled experiment")): its best run is not available, so no best run is set."
                )
            }
        }

        // Writing

        for (dto, record) in documentRecords {

            let name = owner("Writing document", dto.title, fallback: "Untitled document")

            record.problems = session.resolve(
                dto.problemIDs, in: session.problems, owner: name, kind: "problem"
            )

            record.ideas = session.resolve(
                dto.ideaIDs, in: session.ideas, owner: name, kind: "idea"
            )

            record.gaps = session.resolve(
                dto.gapIDs, in: session.gaps, owner: name, kind: "gap"
            )

            record.experiments = session.resolve(
                dto.experimentIDs, in: session.experiments, owner: name, kind: "experiment"
            )

            record.papers = session.resolve(
                dto.paperIDs, in: session.papers, owner: name, kind: "paper"
            )

            record.notes = session.resolve(
                dto.noteIDs, in: session.notes, owner: name, kind: "note"
            )

            record.findings = session.resolve(
                dto.findingIDs, in: session.findings, owner: name, kind: "finding"
            )
        }

        for (dto, record) in sectionRecords {

            let description = owner("Section", dto.title, fallback: "Untitled section")

            guard let documentID = dto.documentID else {
                session.drop(
                    record,
                    label: Label.sections,
                    text: "\(description): it was not attached to a document, so it was not imported."
                )
                continue
            }

            guard let document = session.documents[documentID] else {
                session.drop(
                    record,
                    label: Label.sections,
                    text: "\(description): its document is not in the package or your workspace, so it was not imported."
                )
                continue
            }

            record.document = document
            session.linkCount += 1
        }

        // Projects

        for (dto, record) in projectRecords {

            let name = owner("Project", dto.name, fallback: "Untitled project")

            record.papers = session.resolve(
                dto.paperIDs, in: session.papers, owner: name, kind: "paper"
            )

            record.notes = session.resolve(
                dto.noteIDs, in: session.notes, owner: name, kind: "note"
            )

            record.findings = session.resolve(
                dto.findingIDs, in: session.findings, owner: name, kind: "finding"
            )

            record.gaps = session.resolve(
                dto.gapIDs, in: session.gaps, owner: name, kind: "gap"
            )

            record.problems = session.resolve(
                dto.problemIDs, in: session.problems, owner: name, kind: "problem"
            )

            record.ideas = session.resolve(
                dto.ideaIDs, in: session.ideas, owner: name, kind: "idea"
            )

            record.experiments = session.resolve(
                dto.experimentIDs, in: session.experiments, owner: name, kind: "experiment"
            )

            record.writingDocuments = session.resolve(
                dto.writingDocumentIDs, in: session.documents, owner: name, kind: "writing document"
            )
        }

        // Tasks

        for (dto, record) in taskRecords {

            let name = owner("Task", dto.title, fallback: "Untitled task")

            record.project = session.resolveOptional(
                dto.projectID, in: session.projects, owner: name, kind: "project"
            )

            record.papers = session.resolve(
                dto.paperIDs, in: session.papers, owner: name, kind: "paper"
            )

            record.problems = session.resolve(
                dto.problemIDs, in: session.problems, owner: name, kind: "problem"
            )

            record.ideas = session.resolve(
                dto.ideaIDs, in: session.ideas, owner: name, kind: "idea"
            )

            record.experiments = session.resolve(
                dto.experimentIDs, in: session.experiments, owner: name, kind: "experiment"
            )

            record.writingDocuments = session.resolve(
                dto.writingDocumentIDs, in: session.documents, owner: name, kind: "writing document"
            )
        }
    }
}

// MARK: - Existing records

/// The records already in the workspace, by id. Used to skip
/// duplicates and as link targets.
private struct ExistingRecords {

    var papers: [UUID: PaperRecord] = [:]
    var annotations: [UUID: PDFNoteRecord] = [:]
    var notes: [UUID: ResearchNote] = [:]

    var reviews: [UUID: LiteratureReview] = [:]
    var themes: [UUID: LiteratureTheme] = [:]
    var findings: [UUID: LiteratureFinding] = [:]
    var comparisons: [UUID: LiteratureComparisonEntry] = [:]
    var syntheses: [UUID: LiteratureSynthesis] = [:]

    var gaps: [UUID: ResearchGap] = [:]
    var problems: [UUID: ResearchProblem] = [:]
    var ideas: [UUID: ResearchIdea] = [:]

    var experiments: [UUID: Experiment] = [:]
    var runs: [UUID: ExperimentRun] = [:]
    var metrics: [UUID: RunMetric] = [:]
    var baselines: [UUID: BaselineMetric] = [:]

    var documents: [UUID: WritingDocument] = [:]
    var sections: [UUID: WritingSection] = [:]

    var projects: [UUID: ResearchProject] = [:]
    var tasks: [UUID: ResearchTask] = [:]

    static func fetch(from context: ModelContext) throws -> ExistingRecords {

        var result = ExistingRecords()

        result.papers = try table(PaperRecord.self, \.id, context)
        result.annotations = try table(PDFNoteRecord.self, \.id, context)
        result.notes = try table(ResearchNote.self, \.id, context)

        result.reviews = try table(LiteratureReview.self, \.id, context)
        result.themes = try table(LiteratureTheme.self, \.id, context)
        result.findings = try table(LiteratureFinding.self, \.id, context)
        result.comparisons = try table(LiteratureComparisonEntry.self, \.id, context)
        result.syntheses = try table(LiteratureSynthesis.self, \.id, context)

        result.gaps = try table(ResearchGap.self, \.id, context)
        result.problems = try table(ResearchProblem.self, \.id, context)
        result.ideas = try table(ResearchIdea.self, \.id, context)

        result.experiments = try table(Experiment.self, \.id, context)
        result.runs = try table(ExperimentRun.self, \.id, context)
        result.metrics = try table(RunMetric.self, \.id, context)
        result.baselines = try table(BaselineMetric.self, \.id, context)

        result.documents = try table(WritingDocument.self, \.id, context)
        result.sections = try table(WritingSection.self, \.id, context)

        result.projects = try table(ResearchProject.self, \.id, context)
        result.tasks = try table(ResearchTask.self, \.id, context)

        return result
    }

    /// id -> record. If an id somehow appears twice, the first wins.
    private static func table<T: PersistentModel>(
        _ type: T.Type,
        _ key: KeyPath<T, UUID>,
        _ context: ModelContext
    ) throws -> [UUID: T] {

        let items = try context.fetch(FetchDescriptor<T>())

        var result: [UUID: T] = [:]

        for item in items {

            let id = item[keyPath: key]

            if result[id] == nil {
                result[id] = item
            }
        }

        return result
    }
}

// MARK: - Import session

/// Working state of one import: the link targets (existing records
/// plus the records created so far), counters, and the messages that
/// end up in the result.
private final class ImportSession {

    let context: ModelContext

    // Link targets: existing records first, new ones added as they
    // are created.

    var papers: [UUID: PaperRecord]
    var notes: [UUID: ResearchNote]
    var reviews: [UUID: LiteratureReview]
    var findings: [UUID: LiteratureFinding]
    var gaps: [UUID: ResearchGap]
    var problems: [UUID: ResearchProblem]
    var ideas: [UUID: ResearchIdea]
    var experiments: [UUID: Experiment]
    var runs: [UUID: ExperimentRun]
    var documents: [UUID: WritingDocument]
    var projects: [UUID: ResearchProject]

    // Results

    var created: [String: Int] = [:]

    var linkCount = 0

    var issues: [String] = []
    var issueCount = 0

    var dropped: [String] = []
    var droppedCount = 0

    var annotationsOnExistingPapers = 0

    init(context: ModelContext, existing: ExistingRecords) {

        self.context = context

        papers = existing.papers
        notes = existing.notes
        reviews = existing.reviews
        findings = existing.findings
        gaps = existing.gaps
        problems = existing.problems
        ideas = existing.ideas
        experiments = existing.experiments
        runs = existing.runs
        documents = existing.documents
        projects = existing.projects
    }

    /// A skipped link.
    func report(_ text: String) {

        issueCount += 1

        if issues.count < WorkspaceImportService.maxListedProblems {
            issues.append(text)
        }
    }

    /// Removes a record that was created in this import but cannot
    /// exist without its owner, and says so.
    func drop<M: PersistentModel>(_ model: M, label: String, text: String) {

        context.delete(model)

        created[label, default: 0] -= 1

        droppedCount += 1

        if dropped.count < WorkspaceImportService.maxListedProblems {
            dropped.append(text)
        }
    }

    /// Looks up a list of ids. Ids that are not found are reported and
    /// left out. Repeated ids are used once.
    func resolve<T>(
        _ ids: [UUID],
        in table: [UUID: T],
        owner: String,
        kind: String
    ) -> [T] {

        var seen = Set<UUID>()
        var result: [T] = []

        for id in ids {

            if !seen.insert(id).inserted { continue }

            if let item = table[id] {
                result.append(item)
                linkCount += 1
            } else {
                report("\(owner): a linked \(kind) is not in the package or your workspace, so that link was skipped.")
            }
        }

        return result
    }

    /// Looks up one optional id. `nil` means there was no link to
    /// begin with. A missing target is reported.
    func resolveOptional<T>(
        _ id: UUID?,
        in table: [UUID: T],
        owner: String,
        kind: String
    ) -> T? {

        guard let id = id else { return nil }

        if let item = table[id] {
            linkCount += 1
            return item
        }

        report("\(owner): its \(kind) is not in the package or your workspace, so that link was skipped.")

        return nil
    }
}

// MARK: - Library file import (F-19)
//
// Owner: Agent 53. Brings an existing library across from a BibTeX, RIS or CSV
// file, a Zotero or Mendeley export, and (F-43) a training log.
//
//   Select -> previewLibraryFile -> person unticks rows -> importLibraryFile
//
// The importers (agents 9-12, 27) only parse. This section adds what they leave
// to the caller: format detection, duplicate flags, the single transaction that
// saves, and tags. Nothing is saved before `importLibraryFile` / `commitLogImport`.

// MARK: Vocabulary

enum LibraryImportSource: String, Equatable, CaseIterable {

    case bibtex, ris, csv
    case zoteroLibrary, zoteroRDF, cslJSON, mendeleyLibrary

    var displayName: String {
        switch self {
        case .bibtex: return "BibTeX"
        case .ris: return "RIS"
        case .csv: return "CSV"
        case .zoteroLibrary: return "Zotero library"
        case .zoteroRDF: return "Zotero RDF"
        case .cslJSON: return "CSL JSON"
        case .mendeleyLibrary: return "Mendeley library"
        }
    }

    fileprivate init(_ format: ZoteroMendeleyFormat) {
        switch format {
        case .zoteroLibrary: self = .zoteroLibrary
        case .zoteroRDF: self = .zoteroRDF
        case .cslJSON: self = .cslJSON
        case .mendeleyLibrary: self = .mendeleyLibrary
        }
    }
}

enum LibraryImportError: LocalizedError, Equatable {

    case unrecognisedFile
    case fileNotReadable(String)
    case nothingSelected
    case alreadyImported(runs: Int, file: String)

    var errorDescription: String? {
        switch self {
        case .unrecognisedFile:
            return "This file is not a BibTeX, RIS, CSV, Zotero or Mendeley export."
        case .fileNotReadable(let detail):
            return "The file could not be read. \(detail)"
        case .nothingSelected:
            return "Nothing was selected, so nothing was imported."
        case .alreadyImported(let runs, let file):
            return "\(runs) run\(runs == 1 ? "" : "s") from \"\(file)\" are already in this experiment."
        }
    }
}

// MARK: Preview types

/// One line of the import preview. `id` is its 1-based position in the preview.
struct LibraryImportRow: Identifiable {

    var id: Int
    /// "Entry 3 (smith2020)", "Row 5" ...
    var label: String
    /// Ready for `ItemStore.create`.
    var item: NewItem
    var warnings: [String] = []
    /// Tags from the source app. Saved as tags on the new item.
    var tags: [String] = []
    /// Files the source app had for this item. Never copied here; returned in the result.
    var attachmentHints: [String] = []
    /// Items already in the library that look like this one.
    var libraryMatches: [DuplicateMatch] = []
    /// An earlier row of the same file that looks like this one.
    var repeatsRowID: Int?

    var isLikelyDuplicate: Bool {
        repeatsRowID != nil || libraryMatches.contains { $0.confidence >= .likely }
    }
}

struct LibraryImportPreview {

    let source: LibraryImportSource
    let fileName: String
    let reviewState: ReviewState
    var rows: [LibraryImportRow]
    /// Entries the importer could not read, each with a short reason.
    let skipped: [String]
    /// CSV columns that were not used.
    let ignoredColumns: [String]

    /// Rows ticked at first: every row that is not a likely duplicate.
    var defaultSelection: Set<Int> {
        Set(rows.filter { !$0.isLikelyDuplicate }.map(\.id))
    }

    var duplicateCount: Int { rows.filter { $0.isLikelyDuplicate }.count }
    var warningCount: Int { rows.reduce(0) { $0 + $1.warnings.count } }
    var canImport: Bool { !rows.isEmpty }

    /// "BibTeX: 12 entries, 2 with warnings, 1 possible duplicate, 1 skipped"
    var summary: String {
        var parts = ["\(rows.count) \(rows.count == 1 ? "entry" : "entries")"]
        let withWarnings = rows.filter { !$0.warnings.isEmpty }.count
        if withWarnings > 0 { parts.append("\(withWarnings) with warnings") }
        if duplicateCount > 0 { parts.append("\(duplicateCount) possible duplicate\(duplicateCount == 1 ? "" : "s")") }
        if !skipped.isEmpty { parts.append("\(skipped.count) skipped") }
        return "\(source.displayName): " + parts.joined(separator: ", ")
    }
}

struct LibraryImportAttachmentHint: Equatable {
    let itemID: String
    let paths: [String]
}

struct LibraryImportResult {

    let createdItemIDs: [String]
    /// Selected rows that could not be saved, each with the reason.
    let skippedRows: [String]
    let tagsAssigned: Int
    let attachmentHints: [LibraryImportAttachmentHint]

    var summary: String {
        var text = "Imported \(createdItemIDs.count) paper\(createdItemIDs.count == 1 ? "" : "s")."
        if !skippedRows.isEmpty { text += " \(skippedRows.count) skipped." }
        return text
    }
}

/// A training log, read and planned, waiting for the person to check the mapping.
struct LogImportPreview {

    let parsed: ParsedLog
    var mapping: [ColumnMapping]
    var options: ImportOptions
    var plan: LogImportPlan

    /// "Detected: MLflow CSV export"
    var detectedText: String { "Detected: \(parsed.format.displayName)" }

    /// The plan again, after the person changed a column or an option.
    func replanned(mapping: [ColumnMapping], options: ImportOptions) -> LogImportPreview {
        LogImportPreview(
            parsed: parsed, mapping: mapping, options: options,
            plan: LogMetricParser.makePlan(from: parsed, mapping: mapping, options: options)
        )
    }
}

// MARK: Service

extension WorkspaceImportService {

    // MARK: Detect

    /// Works out what kind of library file this is, from its extension and then its first bytes.
    /// A Zotero data folder is accepted too.
    @MainActor
    static func detectLibrarySource(fileAt url: URL) throws -> LibraryImportSource {

        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else {
            throw LibraryImportError.fileNotReadable("The file does not exist.")
        }
        if isFolder.boolValue { return try rbA53_detectZoteroMendeley(url) }

        switch url.pathExtension.lowercased() {
        case "bib", "bibtex": return .bibtex
        case "ris": return .ris
        case "csv", "tsv": return .csv
        case "rdf", "json", "sqlite", "sqlite3", "db": return try rbA53_detectZoteroMendeley(url)
        default: break
        }

        let head = rbA53_head(of: url)
        let text = String(decoding: head, as: UTF8.self)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))

        if text.hasPrefix("@") || text.contains("\n@") { return .bibtex }
        if text.hasPrefix("TY  -") || text.contains("\nTY  - ") { return .ris }
        if head.starts(with: Array("SQLite format 3".utf8))
            || text.hasPrefix("[") || text.hasPrefix("{") || text.hasPrefix("<") {
            return try rbA53_detectZoteroMendeley(url)
        }
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        if firstLine.contains(",") || firstLine.contains(";") || firstLine.contains("\t") { return .csv }
        throw LibraryImportError.unrecognisedFile
    }

    // MARK: Preview

    /// Reads the file and lists what importing it would create. Saves nothing.
    /// Pass `model` to flag papers that are already in the library.
    @MainActor
    static func previewLibraryFile(
        at url: URL,
        source forcedSource: LibraryImportSource? = nil,
        reviewState: ReviewState = .inbox,
        checkingAgainst model: LibraryModel? = nil
    ) throws -> LibraryImportPreview {

        let source = try forcedSource ?? detectLibrarySource(fileAt: url)

        var rows: [LibraryImportRow] = []
        var skipped: [String] = []
        var ignored: [String] = []

        do {
            switch source {

            case .bibtex:
                let result = try BibTeXImporter.parse(fileAt: url, reviewState: reviewState)
                skipped = result.skipped
                rows = result.entries.map {
                    LibraryImportRow(
                        id: 0,
                        label: $0.originalKey.isEmpty ? "Entry \($0.index)" : "Entry \($0.index) (\($0.originalKey))",
                        item: $0.item, warnings: $0.warnings
                    )
                }

            case .ris:
                let result = try RISImporter.parse(fileAt: url, reviewState: reviewState)
                skipped = result.skipped
                rows = result.entries.map {
                    LibraryImportRow(id: 0, label: "Record \($0.index)", item: $0.item, warnings: $0.warnings)
                }

            case .csv:
                let result = try CSVImporter.parse(fileAt: url, reviewState: reviewState)
                skipped = result.skipped
                ignored = result.ignoredColumns
                rows = result.entries.map {
                    LibraryImportRow(id: 0, label: "Row \($0.row)", item: $0.item, warnings: $0.warnings)
                }

            case .zoteroLibrary, .zoteroRDF, .cslJSON, .mendeleyLibrary:
                let result = try ZoteroMendeleyImporter.parse(fileAt: url, reviewState: reviewState)
                skipped = result.skipped
                rows = result.entries.map {
                    LibraryImportRow(
                        id: 0, label: "Item \($0.index)", item: $0.item, warnings: $0.warnings,
                        tags: $0.tags, attachmentHints: $0.attachmentHints
                    )
                }
            }
        } catch let error as LibraryImportError {
            throw error
        } catch {
            throw LibraryImportError.fileNotReadable(error.localizedDescription)
        }

        for index in rows.indices { rows[index].id = index + 1 }

        rbA53_flagRepeats(&rows)
        if let model { try rbA53_flagLibraryMatches(&rows, model: model) }

        return LibraryImportPreview(
            source: source, fileName: url.lastPathComponent, reviewState: reviewState,
            rows: rows, skipped: skipped, ignoredColumns: ignored
        )
    }

    // MARK: Import

    /// Saves the chosen rows in ONE transaction: all of them, or none.
    /// `selecting` defaults to `preview.defaultSelection`. Tags from the source are
    /// created or reused and put on the new papers. Files named by the source are
    /// not copied; they come back in `attachmentHints`.
    @MainActor
    static func importLibraryFile(
        _ preview: LibraryImportPreview,
        selecting selection: Set<Int>? = nil,
        into model: LibraryModel,
        applyTags: Bool = true
    ) throws -> LibraryImportResult {

        let chosen = selection ?? preview.defaultSelection
        let wanted = preview.rows.filter { chosen.contains($0.id) }
        guard !wanted.isEmpty else { throw LibraryImportError.nothingSelected }

        // Rows the library would refuse are left out here, so one bad row
        // does not undo the good ones.
        var skippedRows: [String] = []
        var rows: [LibraryImportRow] = []
        for row in wanted {
            if row.item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                skippedRows.append("\(row.label): no title.")
            } else if let year = row.item.year, !(0...9999).contains(year) {
                skippedRows.append("\(row.label): the year \(year) is not valid.")
            } else {
                rows.append(row)
            }
        }
        guard !rows.isEmpty else { throw LibraryImportError.nothingSelected }

        return try model.atomically { () throws -> LibraryImportResult in

            var createdIDs: [String] = []
            var hints: [LibraryImportAttachmentHint] = []
            var tagsAssigned = 0
            var tagIDs: [String: String] = [:]

            for row in rows {
                let created = try model.items.create(row.item)
                createdIDs.append(created.id)

                if applyTags {
                    var seen = Set<String>()
                    for raw in row.tags {
                        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                        let key = name.lowercased()
                        guard !name.isEmpty, seen.insert(key).inserted else { continue }

                        let tagID: String
                        if let known = tagIDs[key] {
                            tagID = known
                        } else {
                            tagID = try model.tags.findOrCreate(name: name).id
                            tagIDs[key] = tagID
                        }
                        try model.tags.assign(tagID: tagID, to: created.id)
                        tagsAssigned += 1
                    }
                }

                if !row.attachmentHints.isEmpty {
                    hints.append(LibraryImportAttachmentHint(itemID: created.id, paths: row.attachmentHints))
                }
            }

            return LibraryImportResult(
                createdItemIDs: createdIDs, skippedRows: skippedRows,
                tagsAssigned: tagsAssigned, attachmentHints: hints
            )
        }
    }

    // MARK: Training logs (F-43)

    /// Reads a training log and plans the import with the suggested column mapping. Saves nothing.
    @MainActor
    static func previewLogImport(fileAt url: URL, options: ImportOptions = ImportOptions()) throws -> LogImportPreview {

        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw LogImportError.unreadable("The file could not be opened.")
        }
        let parsed = try LogMetricParser.parse(data: data, fileName: url.lastPathComponent)
        let mapping = LogMetricParser.suggestMapping(for: parsed)
        return LogImportPreview(
            parsed: parsed, mapping: mapping, options: options,
            plan: LogMetricParser.makePlan(from: parsed, mapping: mapping, options: options)
        )
    }

    /// Writes the planned runs and metrics to an experiment. Refuses a log whose file name is
    /// already on that experiment unless `allowRepeat` is true.
    @MainActor
    static func commitLogImport(
        _ preview: LogImportPreview,
        toExperiment experimentID: String,
        into model: LibraryModel,
        allowRepeat: Bool = false
    ) throws -> LogImportResult {

        let importer = LogMetricImporter(model: model)
        let existing = try importer.alreadyImportedRunCount(
            sourceFile: preview.plan.sourceFileName, experimentID: experimentID
        )
        if existing > 0 && !allowRepeat {
            throw LibraryImportError.alreadyImported(runs: existing, file: preview.plan.sourceFileName)
        }
        return try importer.commit(preview.plan, toExperiment: experimentID)
    }

    // MARK: Private helpers

    @MainActor
    private static func rbA53_detectZoteroMendeley(_ url: URL) throws -> LibraryImportSource {
        do {
            return LibraryImportSource(try ZoteroMendeleyImporter.detectFormat(fileAt: url))
        } catch ZMImportError.unrecognisedFormat {
            throw LibraryImportError.unrecognisedFile
        } catch {
            throw LibraryImportError.fileNotReadable(error.localizedDescription)
        }
    }

    private static func rbA53_head(of url: URL, bytes: Int = 4096) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: bytes)) ?? Data()
    }

    /// Marks rows that repeat an earlier row of the same file (same DOI, or same title and year).
    private static func rbA53_flagRepeats(_ rows: inout [LibraryImportRow]) {
        var firstByKey: [String: Int] = [:]
        for index in rows.indices {
            let item = rows[index].item
            var keys: [String] = []
            if let doi = DuplicateMatcher.normalizedDOI(item.doi) { keys.append("doi:" + doi) }
            let title = DuplicateMatcher.titleKey(item.title)
            if !title.isEmpty { keys.append("title:" + title + "|" + (item.year.map(String.init) ?? "")) }

            for key in keys {
                if let first = firstByKey[key] {
                    rows[index].repeatsRowID = first
                } else {
                    firstByKey[key] = rows[index].id
                }
            }
        }
    }

    @MainActor
    private static func rbA53_flagLibraryMatches(_ rows: inout [LibraryImportRow], model: LibraryModel) throws {
        let detector = DuplicateDetector(model: model)
        let index = try detector.buildIndex()
        for position in rows.indices {
            let item = rows[position].item
            let probe = DuplicateProbe(
                doi: item.doi, arxivID: item.arxivID, title: item.title, year: item.year,
                firstAuthorFamily: item.creators.first?.family
            )
            rows[position].libraryMatches = detector.matches(for: probe, in: index, limit: 3)
        }
    }
}
