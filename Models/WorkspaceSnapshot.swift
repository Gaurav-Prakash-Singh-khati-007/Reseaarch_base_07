//
//  WorkspaceSnapshot.swift
//  ResearchBase
//
//  Phase 13 — Backup format
//
//  A plain, Codable picture of the whole research workspace, built
//  from the live SwiftData records. Backup, export, import and restore
//  all work on this type, so none of them ever touches the SwiftData
//  SQLite store directly.
//
//  Design rules:
//  - One DTO per @Model type. Every stored field is copied.
//  - Relationships are stored as ids. Each relationship is written on
//    exactly ONE side (the side that owns the array or the optional
//    reference); the inverse is implied. For SwiftData pairs that have
//    an inverse (for example `ResearchGap.papers` and
//    `PaperRecord.linkedResearchGaps`) the side is noted below, because
//    restoring one side makes SwiftData fill in the other.
//  - PDFs are not embedded in the JSON. A paper only records the file
//    name of its PDF inside the package (`Papers/<paperID>.pdf`).
//    Absolute paths are never stored.
//  - Reading a snapshot creates nothing and changes nothing.
//
//  Relationship sides used by this format:
//    ResearchNote            -> paperIDs
//    LiteratureReview        -> paperIDs
//    LiteratureTheme         -> reviewID, paperIDs
//    LiteratureFinding       -> reviewID, supportingPaperIDs, gapIDs
//    LiteratureComparisonEntry -> reviewID, paperID
//    LiteratureSynthesis     -> reviewID
//    ResearchGap             -> paperIDs
//    ResearchProblem         -> gapIDs, paperIDs
//    ResearchIdea            -> problemIDs, gapIDs, paperIDs, noteIDs
//    Experiment              -> ideaIDs, problemIDs, gapIDs, paperIDs, noteIDs
//    ExperimentRun           -> experimentID
//    RunMetric               -> runID
//    BaselineMetric          -> experimentID
//    WritingDocument         -> problem/idea/gap/experiment/paper/note/finding ids
//    WritingSection          -> documentID
//    ResearchProject         -> paper/note/finding/gap/problem/idea/experiment/writing ids
//    ResearchTask            -> projectID, paper/problem/idea/experiment/writing ids
//    PDFAnnotationRecord     -> paperID
//

import Foundation
import SwiftData

// MARK: - Format Version

nonisolated enum WorkspaceFormat {

    /// Version of the package layout and of `WorkspaceSnapshot`.
    static let currentVersion = 1

    /// Oldest version this build of the app can still read.
    static let oldestReadableVersion = 1

    static let packageExtension = "researchbase"

    static let manifestFileName = "manifest.json"
    static let workspaceFileName = "workspace.json"
    static let settingsFileName = "settings.json"
    static let papersFolderName = "Papers"
}

// MARK: - Snapshot

nonisolated struct WorkspaceSnapshot: Codable, Sendable {

    var papers: [PaperDTO] = []
    var annotations: [PDFAnnotationDTO] = []
    var notes: [ResearchNoteDTO] = []

    var reviews: [LiteratureReviewDTO] = []
    var themes: [LiteratureThemeDTO] = []
    var findings: [LiteratureFindingDTO] = []
    var comparisonEntries: [LiteratureComparisonEntryDTO] = []
    var syntheses: [LiteratureSynthesisDTO] = []

    var gaps: [ResearchGapDTO] = []
    var problems: [ResearchProblemDTO] = []
    var ideas: [ResearchIdeaDTO] = []

    var experiments: [ExperimentDTO] = []
    var runs: [ExperimentRunDTO] = []
    var metrics: [RunMetricDTO] = []
    var baselineMetrics: [BaselineMetricDTO] = []

    var writingDocuments: [WritingDocumentDTO] = []
    var writingSections: [WritingSectionDTO] = []

    var projects: [ResearchProjectDTO] = []
    var tasks: [ResearchTaskDTO] = []

    /// Human-readable record counts, used in the manifest and in
    /// previews. Keys are stable, display-ready names.
    var entityCounts: [String: Int] {
        [
            "Papers": papers.count,
            "PDF Annotations": annotations.count,
            "Research Notes": notes.count,
            "Literature Reviews": reviews.count,
            "Literature Themes": themes.count,
            "Findings": findings.count,
            "Comparison Entries": comparisonEntries.count,
            "Syntheses": syntheses.count,
            "Research Gaps": gaps.count,
            "Research Problems": problems.count,
            "Research Ideas": ideas.count,
            "Experiments": experiments.count,
            "Experiment Runs": runs.count,
            "Run Metrics": metrics.count,
            "Baseline Metrics": baselineMetrics.count,
            "Writing Documents": writingDocuments.count,
            "Writing Sections": writingSections.count,
            "Projects": projects.count,
            "Tasks": tasks.count
        ]
    }

    var totalRecordCount: Int {
        entityCounts.values.reduce(0, +)
    }
}

// MARK: - Settings

/// Settings that really exist in the app. Today that is only the
/// selected theme; nothing else is persisted, so nothing else is
/// listed here.
/// Settings that really exist in the app: the selected theme and
/// (Phase 14) the profile name, text size and custom accent.
///
/// Every field is optional and defaults to nil, so backups made before
/// Phase 14 still decode. A nil value means "not in this backup", and
/// restore leaves the current value alone.
nonisolated struct WorkspaceSettingsDTO: Codable, Sendable {
    var theme: String?

    // Phase 14
    var displayName: String?
    var textScale: Double?
    var accentOverrideHex: String?

    init(
        theme: String? = nil,
        displayName: String? = nil,
        textScale: Double? = nil,
        accentOverrideHex: String? = nil
    ) {
        self.theme = theme
        self.displayName = displayName
        self.textScale = textScale
        self.accentOverrideHex = accentOverrideHex
    }
}
// MARK: - Manifest

nonisolated struct WorkspaceManifest: Codable, Sendable {

    var formatVersion: Int
    var oldestReadableVersion: Int
    var appName: String
    var appVersion: String
    var createdAt: Date

    /// Counts per record type, for previews without decoding
    /// workspace.json.
    var entityCounts: [String: Int]

    /// SHA-256 (hex) of workspace.json, to detect damage or edits.
    var workspaceSHA256: String

    /// One entry per PDF stored in `Papers/`.
    var pdfFiles: [PDFFileEntry]

    /// Titles of papers that had a PDF path but whose file could not
    /// be found when the backup was made. Their PDFs are NOT in the
    /// package.
    var papersWithMissingPDF: [String]

    nonisolated struct PDFFileEntry: Codable, Sendable {
        var paperID: UUID
        var fileName: String
        var byteCount: Int64
        var sha256: String
    }
}

// MARK: - DTOs: Papers

nonisolated struct PaperDTO: Codable, Sendable {

    var id: UUID

    var title: String
    var authors: String
    var venue: String
    var year: Int
    var abstractText: String
    var doi: String
    var urlString: String
    var tagsText: String
    var statusRawValue: String
    var rating: Int
    var addedAt: Date
    var lastOpenedAt: Date?

    var citationKey: String
    var publicationTypeRawValue: String
    var publisher: String
    var volume: String
    var issue: String
    var pages: String
    var edition: String
    var month: String
    var updatedAt: Date?

    /// File name inside `Papers/` in the package, or nil when the
    /// backup contains no PDF for this paper.
    var pdfFileName: String?

    /// "included", "missing" (a path was stored but the file was not
    /// found) or "none" (no PDF was ever attached).
    var pdfState: String
}

nonisolated struct PDFAnnotationDTO: Codable, Sendable {

    var id: UUID
    var paperID: UUID?

    var text: String
    var note: String
    var pageNumber: Int

    var boundsX: Double
    var boundsY: Double
    var boundsWidth: Double
    var boundsHeight: Double

    var createdAt: Date
    var updatedAt: Date
}

nonisolated struct ResearchNoteDTO: Codable, Sendable {

    var id: UUID
    var title: String
    var content: String
    var typeRawValue: String
    var tagsText: String
    var createdAt: Date
    var updatedAt: Date

    var paperIDs: [UUID]
}

// MARK: - DTOs: Literature Review

nonisolated struct LiteratureReviewDTO: Codable, Sendable {

    var id: UUID
    var title: String
    var descriptionText: String
    var researchQuestion: String
    var createdAt: Date
    var updatedAt: Date

    var paperIDs: [UUID]
}

nonisolated struct LiteratureThemeDTO: Codable, Sendable {

    var id: UUID
    var name: String
    var descriptionText: String
    var createdAt: Date
    var updatedAt: Date

    var reviewID: UUID?
    var paperIDs: [UUID]
}

nonisolated struct LiteratureFindingDTO: Codable, Sendable {

    var id: UUID
    var title: String
    var content: String
    var createdAt: Date
    var updatedAt: Date

    var reviewID: UUID?
    var supportingPaperIDs: [UUID]
    var gapIDs: [UUID]
}

nonisolated struct LiteratureComparisonEntryDTO: Codable, Sendable {

    var id: UUID
    var method: String
    var dataset: String
    var mainFinding: String
    var notes: String
    var createdAt: Date
    var updatedAt: Date

    var reviewID: UUID?
    var paperID: UUID?
}

nonisolated struct LiteratureSynthesisDTO: Codable, Sendable {

    var id: UUID
    var commonApproaches: String
    var majorFindings: String
    var areasOfAgreement: String
    var areasOfDisagreement: String
    var methodologicalDifferences: String
    var limitationsAcrossLiterature: String
    var overallSummary: String
    var createdAt: Date
    var updatedAt: Date

    var reviewID: UUID?
}

// MARK: - DTOs: Gaps / Problems / Ideas

nonisolated struct ResearchGapDTO: Codable, Sendable {

    var id: UUID
    var title: String
    var descriptionText: String
    var gapTypeRawValue: String
    var statusRawValue: String
    var evidence: String
    var significance: String
    var createdAt: Date
    var updatedAt: Date

    var paperIDs: [UUID]
}

nonisolated struct ResearchProblemDTO: Codable, Sendable {

    var id: UUID
    var title: String
    var problemStatement: String
    var background: String
    var motivation: String
    var significance: String
    var researchQuestion: String
    var objectives: String
    var hypotheses: String
    var statusRawValue: String
    var createdAt: Date
    var updatedAt: Date

    var gapIDs: [UUID]
    var paperIDs: [UUID]
}

nonisolated struct ResearchIdeaDTO: Codable, Sendable {

    var id: UUID
    var title: String
    var summary: String
    var descriptionText: String
    var proposedApproach: String
    var expectedContribution: String
    var novelty: String
    var assumptions: String
    var limitations: String
    var statusRawValue: String
    var createdAt: Date
    var updatedAt: Date

    var problemIDs: [UUID]
    var gapIDs: [UUID]
    var paperIDs: [UUID]
    var noteIDs: [UUID]
}

// MARK: - DTOs: Experiments

nonisolated struct ExperimentDTO: Codable, Sendable {

    var id: UUID
    var name: String
    var statusRawValue: String
    var objective: String
    var hypothesis: String
    var descriptionText: String
    var dataset: String
    var datasetVersion: String
    var model: String
    var framework: String
    var hardware: String
    var operatingEnvironment: String
    var codeRepository: String
    var trainValidationTestSplit: String
    var seed: Int?
    var batchSize: Int?
    var learningRate: String
    var epochs: Int?
    var optimizer: String
    var bestRunID: UUID?
    var resultsInterpretation: String
    var resultsConclusion: String
    var createdAt: Date
    var updatedAt: Date

    var ideaIDs: [UUID]
    var problemIDs: [UUID]
    var gapIDs: [UUID]
    var paperIDs: [UUID]
    var noteIDs: [UUID]
}

nonisolated struct ExperimentRunDTO: Codable, Sendable {

    var id: UUID
    var runNumber: Int
    var statusRawValue: String
    var startedAt: Date?
    var completedAt: Date?
    var seed: Int?
    var configuration: String
    var notes: String
    var createdAt: Date
    var updatedAt: Date

    var experimentID: UUID?
}

nonisolated struct RunMetricDTO: Codable, Sendable {

    var id: UUID
    var name: String
    var value: Double
    var unit: String
    var higherIsBetter: Bool

    var runID: UUID?
}

nonisolated struct BaselineMetricDTO: Codable, Sendable {

    var id: UUID
    var name: String
    var value: Double
    var unit: String
    var higherIsBetter: Bool

    var experimentID: UUID?
}

// MARK: - DTOs: Writing

nonisolated struct WritingDocumentDTO: Codable, Sendable {

    var id: UUID
    var title: String
    var documentTypeRawValue: String
    var statusRawValue: String
    var createdAt: Date
    var updatedAt: Date

    var problemIDs: [UUID]
    var ideaIDs: [UUID]
    var gapIDs: [UUID]
    var experimentIDs: [UUID]
    var paperIDs: [UUID]
    var noteIDs: [UUID]
    var findingIDs: [UUID]

    // Phase 14 additions. All optional, so a backup made before they
    // existed still loads: the missing keys simply read as nil.
    // They hold the RAW stored values, so a restore is exact.
    var stageRawValue: String? = nil
    var formatRawValue: String? = nil
    var venue: String? = nil
    var submissionNote: String? = nil
    var progressPercent: Int? = nil
    var archivedFlag: Bool? = nil
}

nonisolated struct WritingSectionDTO: Codable, Sendable {

    var id: UUID
    var title: String
    var sectionTypeRawValue: String
    var content: String
    var order: Int
    var createdAt: Date
    var updatedAt: Date

    var documentID: UUID?
}

// MARK: - DTOs: Projects / Tasks

nonisolated struct ResearchProjectDTO: Codable, Sendable {

    var id: UUID
    var name: String
    var descriptionText: String
    var statusRawValue: String
    var createdAt: Date
    var updatedAt: Date

    var paperIDs: [UUID]
    var noteIDs: [UUID]
    var findingIDs: [UUID]
    var gapIDs: [UUID]
    var problemIDs: [UUID]
    var ideaIDs: [UUID]
    var experimentIDs: [UUID]
    var writingDocumentIDs: [UUID]
}

nonisolated struct ResearchTaskDTO: Codable, Sendable {

    var id: UUID
    var title: String
    var descriptionText: String
    var statusRawValue: String
    var priorityRawValue: String
    var dueDate: Date?
    var createdAt: Date
    var updatedAt: Date
    var completedDate: Date?

    var projectID: UUID?
    var paperIDs: [UUID]
    var problemIDs: [UUID]
    var ideaIDs: [UUID]
    var experimentIDs: [UUID]
    var writingDocumentIDs: [UUID]
}

// MARK: - JSON Coding

/// One shared encoder/decoder configuration, so a file written by
/// backup or export is always readable by import and restore.
/// Dates use ISO-8601 with milliseconds.
nonisolated enum WorkspaceJSON {

    private static func makeFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]
        return formatter
    }

    static func makeEncoder() -> JSONEncoder {

        // ISO8601DateFormatter is thread-safe; it is only not marked Sendable.
        nonisolated(unsafe) let formatter = makeFormatter()
        let encoder = JSONEncoder()

        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys
        ]

        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }

        return encoder
    }

    static func makeDecoder() -> JSONDecoder {

        // ISO8601DateFormatter is thread-safe; it is only not marked Sendable.
        nonisolated(unsafe) let formatter = makeFormatter()
        nonisolated(unsafe) let plain = ISO8601DateFormatter()
        let decoder = JSONDecoder()

        decoder.dateDecodingStrategy = .custom { decoder in

            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)

            if let date = formatter.date(from: text)
                ?? plain.date(from: text) {
                return date
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid date: \(text)"
            )
        }

        return decoder
    }
}

// MARK: - Capture

extension WorkspaceSnapshot {

    /// Everything a backup needs from the live database.
    nonisolated struct Capture {

        var snapshot: WorkspaceSnapshot

        /// Papers whose PDF file exists, with the file to copy.
        var pdfSources: [PDFSource]

        /// Titles of papers that have a stored PDF path but no file.
        var missingPDFTitles: [String]

        nonisolated struct PDFSource: Sendable {
            var paperID: UUID
            var sourceURL: URL
            var packageFileName: String
        }
    }

    /// Reads the whole workspace from `context`. Read-only: nothing is
    /// inserted, changed or saved. Call on the actor that owns the
    /// context (the main actor for the app's context).
    static func capture(from context: ModelContext) throws -> Capture {

        var snapshot = WorkspaceSnapshot()
        var pdfSources: [Capture.PDFSource] = []
        var missingTitles: [String] = []

        func all<T: PersistentModel>(_ type: T.Type) throws -> [T] {
            try context.fetch(FetchDescriptor<T>())
        }

        /// Ids of the given records, without duplicates, order kept.
        func ids<T>(_ items: [T], _ key: KeyPath<T, UUID>) -> [UUID] {
            var seen = Set<UUID>()
            var result: [UUID] = []
            for item in items {
                let id = item[keyPath: key]
                if seen.insert(id).inserted { result.append(id) }
            }
            return result
        }

        // Papers

        let papers = try all(PaperRecord.self)
            .sorted { $0.id.uuidString < $1.id.uuidString }

        for paper in papers {

            let path = paper.pdfFilePath
                .trimmingCharacters(in: .whitespacesAndNewlines)

            var fileName: String?
            var state = "none"

            if !path.isEmpty {

                if FileManager.default.fileExists(atPath: path) {

                    let name = "\(paper.id.uuidString).pdf"
                    fileName = name
                    state = "included"

                    pdfSources.append(
                        Capture.PDFSource(
                            paperID: paper.id,
                            sourceURL: URL(fileURLWithPath: path),
                            packageFileName: name
                        )
                    )

                } else {
                    state = "missing"
                    missingTitles.append(
                        paper.title.isEmpty ? "Untitled paper" : paper.title
                    )
                }
            }

            snapshot.papers.append(
                PaperDTO(
                    id: paper.id,
                    title: paper.title,
                    authors: paper.authors,
                    venue: paper.venue,
                    year: paper.year,
                    abstractText: paper.abstractText,
                    doi: paper.doi,
                    urlString: paper.urlString,
                    tagsText: paper.tagsText,
                    statusRawValue: paper.statusRawValue,
                    rating: paper.rating,
                    addedAt: paper.addedAt,
                    lastOpenedAt: paper.lastOpenedAt,
                    citationKey: paper.citationKey,
                    publicationTypeRawValue: paper.publicationTypeRawValue,
                    publisher: paper.publisher,
                    volume: paper.volume,
                    issue: paper.issue,
                    pages: paper.pages,
                    edition: paper.edition,
                    month: paper.month,
                    updatedAt: paper.updatedAt,
                    pdfFileName: fileName,
                    pdfState: state
                )
            )
        }

        // PDF annotations (highlights are also drawn inside the PDF
        // file itself, which the backup copies).

        for record in try all(PDFNoteRecord.self)
            .sorted(by: { $0.id.uuidString < $1.id.uuidString }) {

            snapshot.annotations.append(
                PDFAnnotationDTO(
                    id: record.id,
                    paperID: record.paper?.id,
                    text: record.text,
                    note: record.note,
                    pageNumber: record.pageNumber,
                    boundsX: record.boundsX,
                    boundsY: record.boundsY,
                    boundsWidth: record.boundsWidth,
                    boundsHeight: record.boundsHeight,
                    createdAt: record.createdAt,
                    updatedAt: record.updatedAt
                )
            )
        }

        // Research notes

        for note in try all(ResearchNote.self)
            .sorted(by: { $0.id.uuidString < $1.id.uuidString }) {

            snapshot.notes.append(
                ResearchNoteDTO(
                    id: note.id,
                    title: note.title,
                    content: note.content,
                    typeRawValue: note.typeRawValue,
                    tagsText: note.tagsText,
                    createdAt: note.createdAt,
                    updatedAt: note.updatedAt,
                    paperIDs: ids(note.linkedPapers, \.id)
                )
            )
        }

        // Literature reviews

        for review in try all(LiteratureReview.self)
            .sorted(by: { $0.id.uuidString < $1.id.uuidString }) {

            snapshot.reviews.append(
                LiteratureReviewDTO(
                    id: review.id,
                    title: review.title,
                    descriptionText: review.descriptionText,
                    researchQuestion: review.researchQuestion,
                    createdAt: review.createdAt,
                    updatedAt: review.updatedAt,
                    paperIDs: ids(review.papers, \.id)
                )
            )
        }

        for theme in try all(LiteratureTheme.self)
            .sorted(by: { $0.id.uuidString < $1.id.uuidString }) {

            snapshot.themes.append(
                LiteratureThemeDTO(
                    id: theme.id,
                    name: theme.name,
                    descriptionText: theme.descriptionText,
                    createdAt: theme.createdAt,
                    updatedAt: theme.updatedAt,
                    reviewID: theme.review?.id,
                    paperIDs: ids(theme.papers, \.id)
                )
            )
        }

        for finding in try all(LiteratureFinding.self)
            .sorted(by: { $0.id.uuidString < $1.id.uuidString }) {

            snapshot.findings.append(
                LiteratureFindingDTO(
                    id: finding.id,
                    title: finding.title,
                    content: finding.content,
                    createdAt: finding.createdAt,
                    updatedAt: finding.updatedAt,
                    reviewID: finding.review?.id,
                    supportingPaperIDs: ids(finding.supportingPapers, \.id),
                    gapIDs: ids(finding.researchGaps, \.id)
                )
            )
        }

        for entry in try all(LiteratureComparisonEntry.self)
            .sorted(by: { $0.id.uuidString < $1.id.uuidString }) {

            snapshot.comparisonEntries.append(
                LiteratureComparisonEntryDTO(
                    id: entry.id,
                    method: entry.method,
                    dataset: entry.dataset,
                    mainFinding: entry.mainFinding,
                    notes: entry.notes,
                    createdAt: entry.createdAt,
                    updatedAt: entry.updatedAt,
                    reviewID: entry.review?.id,
                    paperID: entry.paper?.id
                )
            )
        }

        for synthesis in try all(LiteratureSynthesis.self)
            .sorted(by: { $0.id.uuidString < $1.id.uuidString }) {

            snapshot.syntheses.append(
                LiteratureSynthesisDTO(
                    id: synthesis.id,
                    commonApproaches: synthesis.commonApproaches,
                    majorFindings: synthesis.majorFindings,
                    areasOfAgreement: synthesis.areasOfAgreement,
                    areasOfDisagreement: synthesis.areasOfDisagreement,
                    methodologicalDifferences: synthesis.methodologicalDifferences,
                    limitationsAcrossLiterature: synthesis.limitationsAcrossLiterature,
                    overallSummary: synthesis.overallSummary,
                    createdAt: synthesis.createdAt,
                    updatedAt: synthesis.updatedAt,
                    reviewID: synthesis.review?.id
                )
            )
        }

        // Gaps / problems / ideas

        for gap in try all(ResearchGap.self)
            .sorted(by: { $0.id.uuidString < $1.id.uuidString }) {

            snapshot.gaps.append(
                ResearchGapDTO(
                    id: gap.id,
                    title: gap.title,
                    descriptionText: gap.descriptionText,
                    gapTypeRawValue: gap.gapTypeRawValue,
                    statusRawValue: gap.statusRawValue,
                    evidence: gap.evidence,
                    significance: gap.significance,
                    createdAt: gap.createdAt,
                    updatedAt: gap.updatedAt,
                    paperIDs: ids(gap.papers, \.id)
                )
            )
        }

        for problem in try all(ResearchProblem.self)
            .sorted(by: { $0.id.uuidString < $1.id.uuidString }) {

            snapshot.problems.append(
                ResearchProblemDTO(
                    id: problem.id,
                    title: problem.title,
                    problemStatement: problem.problemStatement,
                    background: problem.background,
                    motivation: problem.motivation,
                    significance: problem.significance,
                    researchQuestion: problem.researchQuestion,
                    objectives: problem.objectives,
                    hypotheses: problem.hypotheses,
                    statusRawValue: problem.statusRawValue,
                    createdAt: problem.createdAt,
                    updatedAt: problem.updatedAt,
                    gapIDs: ids(problem.gaps, \.id),
                    paperIDs: ids(problem.papers, \.id)
                )
            )
        }

        for idea in try all(ResearchIdea.self)
            .sorted(by: { $0.id.uuidString < $1.id.uuidString }) {

            snapshot.ideas.append(
                ResearchIdeaDTO(
                    id: idea.id,
                    title: idea.title,
                    summary: idea.summary,
                    descriptionText: idea.descriptionText,
                    proposedApproach: idea.proposedApproach,
                    expectedContribution: idea.expectedContribution,
                    novelty: idea.novelty,
                    assumptions: idea.assumptions,
                    limitations: idea.limitations,
                    statusRawValue: idea.statusRawValue,
                    createdAt: idea.createdAt,
                    updatedAt: idea.updatedAt,
                    problemIDs: ids(idea.problems, \.id),
                    gapIDs: ids(idea.gaps, \.id),
                    paperIDs: ids(idea.papers, \.id),
                    noteIDs: ids(idea.notes, \.id)
                )
            )
        }

        // Experiments

        for experiment in try all(Experiment.self)
            .sorted(by: { $0.id.uuidString < $1.id.uuidString }) {

            snapshot.experiments.append(
                ExperimentDTO(
                    id: experiment.id,
                    name: experiment.name,
                    statusRawValue: experiment.statusRawValue,
                    objective: experiment.objective,
                    hypothesis: experiment.hypothesis,
                    descriptionText: experiment.descriptionText,
                    dataset: experiment.dataset,
                    datasetVersion: experiment.datasetVersion,
                    model: experiment.model,
                    framework: experiment.framework,
                    hardware: experiment.hardware,
                    operatingEnvironment: experiment.operatingEnvironment,
                    codeRepository: experiment.codeRepository,
                    trainValidationTestSplit: experiment.trainValidationTestSplit,
                    seed: experiment.seed,
                    batchSize: experiment.batchSize,
                    learningRate: experiment.learningRate,
                    epochs: experiment.epochs,
                    optimizer: experiment.optimizer,
                    bestRunID: experiment.bestRunID,
                    resultsInterpretation: experiment.resultsInterpretation,
                    resultsConclusion: experiment.resultsConclusion,
                    createdAt: experiment.createdAt,
                    updatedAt: experiment.updatedAt,
                    ideaIDs: ids(experiment.ideas, \.id),
                    problemIDs: ids(experiment.problems, \.id),
                    gapIDs: ids(experiment.gaps, \.id),
                    paperIDs: ids(experiment.papers, \.id),
                    noteIDs: ids(experiment.notes, \.id)
                )
            )
        }

        for run in try all(ExperimentRun.self)
            .sorted(by: { $0.id.uuidString < $1.id.uuidString }) {

            snapshot.runs.append(
                ExperimentRunDTO(
                    id: run.id,
                    runNumber: run.runNumber,
                    statusRawValue: run.statusRawValue,
                    startedAt: run.startedAt,
                    completedAt: run.completedAt,
                    seed: run.seed,
                    configuration: run.configuration,
                    notes: run.notes,
                    createdAt: run.createdAt,
                    updatedAt: run.updatedAt,
                    experimentID: run.experiment?.id
                )
            )
        }

        for metric in try all(RunMetric.self)
            .sorted(by: { $0.id.uuidString < $1.id.uuidString }) {

            snapshot.metrics.append(
                RunMetricDTO(
                    id: metric.id,
                    name: metric.name,
                    value: metric.value,
                    unit: metric.unit,
                    higherIsBetter: metric.higherIsBetter,
                    runID: metric.run?.id
                )
            )
        }

        for baseline in try all(BaselineMetric.self)
            .sorted(by: { $0.id.uuidString < $1.id.uuidString }) {

            snapshot.baselineMetrics.append(
                BaselineMetricDTO(
                    id: baseline.id,
                    name: baseline.name,
                    value: baseline.value,
                    unit: baseline.unit,
                    higherIsBetter: baseline.higherIsBetter,
                    experimentID: baseline.experiment?.id
                )
            )
        }

        // Writing

        for document in try all(WritingDocument.self)
            .sorted(by: { $0.id.uuidString < $1.id.uuidString }) {

            snapshot.writingDocuments.append(
                WritingDocumentDTO(
                    id: document.id,
                    title: document.title,
                    documentTypeRawValue: document.documentTypeRawValue,
                    statusRawValue: document.statusRawValue,
                    createdAt: document.createdAt,
                    updatedAt: document.updatedAt,
                    problemIDs: ids(document.problems, \.id),
                    ideaIDs: ids(document.ideas, \.id),
                    gapIDs: ids(document.gaps, \.id),
                    experimentIDs: ids(document.experiments, \.id),
                    paperIDs: ids(document.papers, \.id),
                    noteIDs: ids(document.notes, \.id),
                    findingIDs: ids(document.findings, \.id),
                    stageRawValue: document.stageRawValue,
                    formatRawValue: document.formatRawValue,
                    venue: document.venue,
                    submissionNote: document.submissionNote,
                    progressPercent: document.progressPercent,
                    archivedFlag: document.archivedFlag
                )
            )
        }

        for section in try all(WritingSection.self)
            .sorted(by: { $0.id.uuidString < $1.id.uuidString }) {

            snapshot.writingSections.append(
                WritingSectionDTO(
                    id: section.id,
                    title: section.title,
                    sectionTypeRawValue: section.sectionTypeRawValue,
                    content: section.content,
                    order: section.order,
                    createdAt: section.createdAt,
                    updatedAt: section.updatedAt,
                    documentID: section.document?.id
                )
            )
        }

        // Projects

        for project in try all(ResearchProject.self)
            .sorted(by: { $0.id.uuidString < $1.id.uuidString }) {

            snapshot.projects.append(
                ResearchProjectDTO(
                    id: project.id,
                    name: project.name,
                    descriptionText: project.descriptionText,
                    statusRawValue: project.statusRawValue,
                    createdAt: project.createdAt,
                    updatedAt: project.updatedAt,
                    paperIDs: ids(project.papers, \.id),
                    noteIDs: ids(project.notes, \.id),
                    findingIDs: ids(project.findings, \.id),
                    gapIDs: ids(project.gaps, \.id),
                    problemIDs: ids(project.problems, \.id),
                    ideaIDs: ids(project.ideas, \.id),
                    experimentIDs: ids(project.experiments, \.id),
                    writingDocumentIDs: ids(project.writingDocuments, \.id)
                )
            )
        }

        // Tasks

        for task in try all(ResearchTask.self)
            .sorted(by: { $0.id.uuidString < $1.id.uuidString }) {

            snapshot.tasks.append(
                ResearchTaskDTO(
                    id: task.id,
                    title: task.title,
                    descriptionText: task.descriptionText,
                    statusRawValue: task.statusRawValue,
                    priorityRawValue: task.priorityRawValue,
                    dueDate: task.dueDate,
                    createdAt: task.createdAt,
                    updatedAt: task.updatedAt,
                    completedDate: task.completedDate,
                    projectID: task.project?.id,
                    paperIDs: ids(task.papers, \.id),
                    problemIDs: ids(task.problems, \.id),
                    ideaIDs: ids(task.ideas, \.id),
                    experimentIDs: ids(task.experiments, \.id),
                    writingDocumentIDs: ids(task.writingDocuments, \.id)
                )
            )
        }

        return Capture(
            snapshot: snapshot,
            pdfSources: pdfSources,
            missingPDFTitles: missingTitles
        )
    }
}
