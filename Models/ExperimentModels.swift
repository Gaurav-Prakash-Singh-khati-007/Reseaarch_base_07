//
//  ExperimentModels.swift
//  ResearchBase
//
//  Phase 9 — Experiments & Results
//
//  Introduces Experiment, ExperimentRun, RunMetric and
//  BaselineMetric. These are the four model types that
//  ResearchDataStore.swift, ExperimentDetailTab.swift and
//  ExperimentsView.swift already reference — every property and
//  initializer parameter here matches exactly how those files
//  already call it.
//
//  An Experiment links to existing ResearchIdea / ResearchProblem /
//  ResearchGap / PaperRecord / ResearchNote objects, but never
//  duplicates them and never deletes them when the experiment is
//  deleted (plain, unidirectional relationship arrays — same
//  "never owns the other side" pattern used throughout Phase 7/8).
//
//  An Experiment DOES own its Runs and its Baseline Metrics
//  (cascade delete), and a Run DOES own its Metrics (cascade
//  delete) — deleting an experiment removes its own runs/metrics,
//  but never touches any linked research object.
//
 
import Foundation
import SwiftData
 
// MARK: - Experiment Status
 
enum ExperimentStatus: String, CaseIterable, Codable, Identifiable {
 
    case draft = "Draft"
    case planned = "Planned"
    case running = "Running"
    case completed = "Completed"
    case analyzing = "Analyzing"
    case archived = "Archived"
 
    var id: String { rawValue }
}
 
 
// MARK: - Experiment Run Status
 
enum ExperimentRunStatus: String, CaseIterable, Codable, Identifiable {
 
    case planned = "Planned"
    case running = "Running"
    case completed = "Completed"
    case failed = "Failed"
 
    var id: String { rawValue }
}
 
 
// MARK: - Experiment
 
@Model
final class Experiment {
 
    var id: UUID
 
    var name: String
    var statusRawValue: String
 
    var objective: String
    var hypothesis: String
    var descriptionText: String
 
    // ---------------------------------------------------------
    // Setup
    // ---------------------------------------------------------
 
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

    // ---------------------------------------------------------
    // Reproducibility record (F-41)
    // ---------------------------------------------------------
    //
    // Every property has a default here, so existing databases open
    // as they are (lightweight migration) and old records simply
    // show "not recorded yet".

    /// Git commit the experiment's code was at (7 to 40 hex characters).
    var codeCommit: String = ""
    /// True when the code had uncommitted changes, so it cannot be reproduced exactly.
    var codeHasUncommittedChanges: Bool = false
    /// SHA-256 fingerprint of the dataset (64 hex characters).
    var datasetSHA256: String = ""
    /// Captured environment: OS, language, packages, GPU. Plain text.
    var environmentSnapshot: String = ""
    var environmentCapturedAt: Date?
 
    // ---------------------------------------------------------
    // Results
    // ---------------------------------------------------------
 
    /// The run the researcher has chosen as "best". ResearchBase
    /// never picks this automatically — it only stores the choice.
    var bestRunID: UUID?
 
    /// Researcher-authored text. Never generated or inferred by
    /// ResearchBase.
    var resultsInterpretation: String
    var resultsConclusion: String
 
    var createdAt: Date
    var updatedAt: Date
 
    // ---------------------------------------------------------
    // Research Links (Phase 8 → Phase 9)
    // ---------------------------------------------------------
    //
    // Plain, unidirectional arrays — same pattern as the rest of
    // the app for "references but never owns". No @Relationship
    // macro here, so nothing on ResearchIdea/Problem/Gap/
    // PaperRecord/ResearchNote needs to change.
 
    var ideas: [ResearchIdea] = []
    var problems: [ResearchProblem] = []
    var gaps: [ResearchGap] = []
    var papers: [PaperRecord] = []
    var notes: [ResearchNote] = []
 
    // ---------------------------------------------------------
    // Owned Children
    // ---------------------------------------------------------
 
    @Relationship(deleteRule: .cascade, inverse: \ExperimentRun.experiment)
    var runs: [ExperimentRun] = []
 
    @Relationship(deleteRule: .cascade, inverse: \BaselineMetric.experiment)
    var baselineMetrics: [BaselineMetric] = []
 
 
    // MARK: - Initializer
 
    init(
        id: UUID = UUID(),
        name: String,
        statusRawValue: String = ExperimentStatus.draft.rawValue,
        objective: String = "",
        hypothesis: String = "",
        descriptionText: String = "",
        dataset: String = "",
        datasetVersion: String = "",
        model: String = "",
        framework: String = "",
        hardware: String = "",
        operatingEnvironment: String = "",
        codeRepository: String = "",
        trainValidationTestSplit: String = "",
        seed: Int? = nil,
        batchSize: Int? = nil,
        learningRate: String = "",
        epochs: Int? = nil,
        optimizer: String = "",
        bestRunID: UUID? = nil,
        resultsInterpretation: String = "",
        resultsConclusion: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        ideas: [ResearchIdea] = [],
        problems: [ResearchProblem] = [],
        gaps: [ResearchGap] = [],
        papers: [PaperRecord] = [],
        notes: [ResearchNote] = [],
        codeCommit: String = "",
        codeHasUncommittedChanges: Bool = false,
        datasetSHA256: String = "",
        environmentSnapshot: String = "",
        environmentCapturedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.statusRawValue = statusRawValue
        self.objective = objective
        self.hypothesis = hypothesis
        self.descriptionText = descriptionText
        self.dataset = dataset
        self.datasetVersion = datasetVersion
        self.model = model
        self.framework = framework
        self.hardware = hardware
        self.operatingEnvironment = operatingEnvironment
        self.codeRepository = codeRepository
        self.trainValidationTestSplit = trainValidationTestSplit
        self.seed = seed
        self.batchSize = batchSize
        self.learningRate = learningRate
        self.epochs = epochs
        self.optimizer = optimizer
        self.bestRunID = bestRunID
        self.resultsInterpretation = resultsInterpretation
        self.resultsConclusion = resultsConclusion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.ideas = ideas
        self.problems = problems
        self.gaps = gaps
        self.papers = papers
        self.notes = notes
        self.codeCommit = codeCommit
        self.codeHasUncommittedChanges = codeHasUncommittedChanges
        self.datasetSHA256 = datasetSHA256
        self.environmentSnapshot = environmentSnapshot
        self.environmentCapturedAt = environmentCapturedAt
    }
 
 
    // MARK: - Status
 
    var status: ExperimentStatus {
        get { ExperimentStatus(rawValue: statusRawValue) ?? .draft }
        set { statusRawValue = newValue.rawValue }
    }
 
 
    // MARK: - Best Run
 
    var bestRun: ExperimentRun? {
        guard let bestRunID else { return nil }
        return runs.first { $0.id == bestRunID }
    }
 
 
    // MARK: - Metric Helpers (used by the Experiments list row)
 
    /// Every distinct metric name recorded across all runs, in the
    /// order it was first seen.
    var allMetricNames: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for run in runs {
            for metric in run.metrics where !seen.contains(metric.name) {
                seen.insert(metric.name)
                result.append(metric.name)
            }
        }
        return result
    }
 
    /// The numerically best recorded value for a given metric name,
    /// across all runs — purely arithmetic, using each metric's own
    /// higher-is-better flag. This never implies the result is
    /// scientifically significant.
    func bestValue(forMetricNamed name: String) -> RunMetric? {
        let candidates = runs
            .flatMap { $0.metrics }
            .filter { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
 
        guard let first = candidates.first else { return nil }
 
        if first.higherIsBetter {
            return candidates.max { $0.value < $1.value }
        } else {
            return candidates.min { $0.value < $1.value }
        }
    }
}
 
 
// MARK: - Experiment Run
 
@Model
final class ExperimentRun {
 
    var id: UUID
 
    var runNumber: Int
    var statusRawValue: String
 
    var startedAt: Date?
    var completedAt: Date?
 
    var seed: Int?
    /// Further seeds this run used (data split, weight initialisation, ...). `seed` stays the main one.
    var additionalSeeds: [Int] = []
    /// Code version this particular run used (F-41).
    var codeCommit: String = ""
    var codeHasUncommittedChanges: Bool = false
    var configuration: String
    var notes: String
 
    var createdAt: Date
    var updatedAt: Date
 
    // Owning side (cascade) is declared on Experiment.runs above.
    var experiment: Experiment?
 
    @Relationship(deleteRule: .cascade, inverse: \RunMetric.run)
    var metrics: [RunMetric] = []
 
    init(
        id: UUID = UUID(),
        runNumber: Int,
        statusRawValue: String = ExperimentRunStatus.planned.rawValue,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        seed: Int? = nil,
        configuration: String = "",
        notes: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        experiment: Experiment? = nil,
        additionalSeeds: [Int] = [],
        codeCommit: String = "",
        codeHasUncommittedChanges: Bool = false
    ) {
        self.additionalSeeds = additionalSeeds
        self.codeCommit = codeCommit
        self.codeHasUncommittedChanges = codeHasUncommittedChanges
        self.id = id
        self.runNumber = runNumber
        self.statusRawValue = statusRawValue
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.seed = seed
        self.configuration = configuration
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.experiment = experiment
    }
 
    var status: ExperimentRunStatus {
        get { ExperimentRunStatus(rawValue: statusRawValue) ?? .planned }
        set { statusRawValue = newValue.rawValue }
    }
}
 
 
// MARK: - Run Metric
 
@Model
final class RunMetric {
 
    var id: UUID
 
    var name: String
    var value: Double
    var unit: String
    var higherIsBetter: Bool
 
    // Owning side (cascade) is declared on ExperimentRun.metrics above.
    var run: ExperimentRun?
 
    init(
        id: UUID = UUID(),
        name: String,
        value: Double,
        unit: String = "",
        higherIsBetter: Bool = true,
        run: ExperimentRun? = nil
    ) {
        self.id = id
        self.name = name
        self.value = value
        self.unit = unit
        self.higherIsBetter = higherIsBetter
        self.run = run
    }
}
 
 
// MARK: - Baseline Metric
 
@Model
final class BaselineMetric {
 
    var id: UUID
 
    var name: String
    var value: Double
    var unit: String
    var higherIsBetter: Bool
 
    // Owning side (cascade) is declared on Experiment.baselineMetrics above.
    var experiment: Experiment?
 
    init(
        id: UUID = UUID(),
        name: String,
        value: Double,
        unit: String = "",
        higherIsBetter: Bool = true,
        experiment: Experiment? = nil
    ) {
        self.id = id
        self.name = name
        self.value = value
        self.unit = unit
        self.higherIsBetter = higherIsBetter
        self.experiment = experiment
    }
}

 
// MARK: - Reproducibility record (F-41)
//
//  Pure helpers over the fields above. Nothing here is saved or computed behind
//  the researcher's back: it only reads what they recorded and says what is missing.
 
/// One line of the "Reproducibility" checklist.
struct ReproducibilityCheck: Identifiable, Equatable {
 
    enum ID: String, CaseIterable {
        case codeCommit
        case cleanCode
        case datasetFingerprint
        case environment
        case seeds
    }
 
    let id: ID
    let title: String
    let passed: Bool
    /// Plain words about what is missing, or what was found.
    let detail: String
}
 
extension Experiment {
 
    // MARK: Format checks
 
    /// Trims spaces and lower-cases a commit hash or fingerprint typed or pasted by the person.
    static func normalisedHash(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
 
    /// A git commit: 7 to 40 hexadecimal characters.
    static func isValidCommit(_ text: String) -> Bool {
        let value = normalisedHash(text)
        return (7...40).contains(value.count) && value.allSatisfy(\.isHexDigit)
    }
 
    /// A SHA-256 fingerprint: exactly 64 hexadecimal characters.
    static func isValidSHA256(_ text: String) -> Bool {
        let value = normalisedHash(text)
        return value.count == 64 && value.allSatisfy(\.isHexDigit)
    }
 
    /// A short description of this Mac for the environment record, for example
    /// "macOS 15.1.0 · arm64 · 16 GB memory". Python, packages and GPU are added by the person or the importer.
    static func describeThisMac() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif
        let gigabytes = Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())
        return "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion) · \(architecture) · \(gigabytes) GB memory"
    }
 
    // MARK: Recording
 
    /// Stores a captured environment description and the time it was captured.
    func recordEnvironment(_ text: String, at date: Date = Date()) {
        environmentSnapshot = text.trimmingCharacters(in: .whitespacesAndNewlines)
        environmentCapturedAt = environmentSnapshot.isEmpty ? nil : date
        updatedAt = date
    }
 
    // MARK: Seeds
 
    /// Every distinct seed recorded for this experiment and its runs, smallest first.
    var recordedSeeds: [Int] {
        var all = Set<Int>()
        if let seed { all.insert(seed) }
        for run in runs { all.formUnion(run.allSeeds) }
        return all.sorted()
    }
 
    /// Runs that already started (anything but Planned) and have no seed.
    var runsMissingSeed: [ExperimentRun] {
        runs
            .filter { $0.status != .planned && $0.allSeeds.isEmpty }
            .sorted { $0.runNumber < $1.runNumber }
    }
 
    /// Runs that used code with uncommitted changes.
    var runsWithUncommittedChanges: [ExperimentRun] {
        runs
            .filter { $0.codeHasUncommittedChanges }
            .sorted { $0.runNumber < $1.runNumber }
    }
 
    // MARK: Checklist
 
    /// The five checks of the Reproducibility tab, in order.
    var reproducibilityChecklist: [ReproducibilityCheck] {
 
        let startedRuns = runs.filter { $0.status != .planned }
        let everyRunHasCommit = !startedRuns.isEmpty && startedRuns.allSatisfy { Experiment.isValidCommit($0.codeCommit) }
        let commitRecorded = Experiment.isValidCommit(codeCommit) || everyRunHasCommit
 
        let dirtyRuns = runsWithUncommittedChanges
        let isClean = commitRecorded && !codeHasUncommittedChanges && dirtyRuns.isEmpty
 
        let cleanDetail: String
        if !commitRecorded {
            cleanDetail = "Record the commit first."
        } else if codeHasUncommittedChanges {
            cleanDetail = "The code had uncommitted changes, so this cannot be reproduced exactly. Commit first next time."
        } else if !dirtyRuns.isEmpty {
            cleanDetail = "Run \(dirtyRuns.map { String($0.runNumber) }.joined(separator: ", ")) used uncommitted changes."
        } else {
            cleanDetail = "No uncommitted changes."
        }
 
        let fingerprintRecorded = Experiment.isValidSHA256(datasetSHA256)
 
        let environmentRecorded = !environmentSnapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !operatingEnvironment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
 
        let missing = runsMissingSeed
        let seedsDetail: String
        let seedsPassed: Bool
        if runs.isEmpty {
            seedsPassed = false
            seedsDetail = "No runs yet."
        } else if !missing.isEmpty {
            seedsPassed = false
            seedsDetail = "Run \(missing.map { String($0.runNumber) }.joined(separator: ", ")) has no seed."
        } else if recordedSeeds.isEmpty {
            seedsPassed = false
            seedsDetail = "No seed recorded yet."
        } else {
            seedsPassed = true
            seedsDetail = "Seeds: \(recordedSeeds.map(String.init).joined(separator: ", "))."
        }
 
        return [
            ReproducibilityCheck(
                id: .codeCommit, title: "Code commit recorded", passed: commitRecorded,
                detail: commitRecorded ? "Commit recorded." : "No valid commit hash recorded."),
            ReproducibilityCheck(
                id: .cleanCode, title: "No uncommitted changes", passed: isClean, detail: cleanDetail),
            ReproducibilityCheck(
                id: .datasetFingerprint, title: "Dataset fingerprint recorded", passed: fingerprintRecorded,
                detail: fingerprintRecorded ? "SHA-256 recorded." : "No valid SHA-256 fingerprint recorded."),
            ReproducibilityCheck(
                id: .environment, title: "Environment captured", passed: environmentRecorded,
                detail: environmentRecorded ? "Environment recorded." : "Not captured yet."),
            ReproducibilityCheck(
                id: .seeds, title: "All seeds recorded", passed: seedsPassed, detail: seedsDetail)
        ]
    }
 
    /// How many of the five checks pass.
    var reproducibilityProgress: (passed: Int, total: Int) {
        let checks = reproducibilityChecklist
        return (checks.filter(\.passed).count, checks.count)
    }
 
    var isFullyReproducible: Bool {
        reproducibilityChecklist.allSatisfy(\.passed)
    }
}
 
extension ExperimentRun {
 
    /// The main seed first, then the additional ones, without repeats.
    var allSeeds: [Int] {
        var seen = Set<Int>()
        var result: [Int] = []
        for value in ([seed].compactMap { $0 } + additionalSeeds) where seen.insert(value).inserted {
            result.append(value)
        }
        return result
    }
}
