//
//  ExperimentModelsTests.swift
//  ResearchBaseTests
//
//  Owner: Agent 51 · Features: F-41 (reproducibility record)
//  Uses an in-memory database. Nothing touches the real library or disk.
//

import XCTest
import SwiftData
@testable import ResearchBase

@MainActor
final class ExperimentModelsTests: XCTestCase {

    // MARK: Helpers

    private let commit = "a41f9c2"
    private let fingerprint = String(repeating: "9b1c", count: 16)      // 64 hex characters

    private func makeExperiment(
        _ context: ModelContext,
        commit: String = "",
        sha: String = "",
        environment: String = ""
    ) -> Experiment {
        let experiment = Experiment(
            name: "Drift under Dirichlet splits",
            codeCommit: commit,
            datasetSHA256: sha,
            environmentSnapshot: environment
        )
        context.insert(experiment)
        return experiment
    }

    @discardableResult
    private func addRun(
        _ context: ModelContext,
        to experiment: Experiment,
        number: Int,
        status: ExperimentRunStatus = .completed,
        seed: Int? = nil,
        more: [Int] = [],
        commit: String = "",
        dirty: Bool = false
    ) -> ExperimentRun {
        let run = ExperimentRun(
            runNumber: number,
            statusRawValue: status.rawValue,
            seed: seed,
            experiment: experiment,
            additionalSeeds: more,
            codeCommit: commit,
            codeHasUncommittedChanges: dirty
        )
        context.insert(run)
        if !experiment.runs.contains(where: { $0.id == run.id }) { experiment.runs.append(run) }
        return run
    }

    private func check(_ experiment: Experiment, _ id: ReproducibilityCheck.ID) throws -> ReproducibilityCheck {
        try XCTUnwrap(experiment.reproducibilityChecklist.first { $0.id == id })
    }

    // MARK: Defaults (old code keeps working)

    func testNewFieldsDefaultToNotRecorded() throws {
        let context = try TestSupport.makeContext()
        let experiment = Experiment(name: "Old style call")          // no new arguments, as existing code calls it
        let run = ExperimentRun(runNumber: 1)

        XCTAssertEqual(experiment.codeCommit, "")
        XCTAssertFalse(experiment.codeHasUncommittedChanges)
        XCTAssertEqual(experiment.datasetSHA256, "")
        XCTAssertEqual(experiment.environmentSnapshot, "")
        XCTAssertNil(experiment.environmentCapturedAt)
        XCTAssertEqual(run.additionalSeeds, [])
        XCTAssertEqual(run.codeCommit, "")
        XCTAssertFalse(run.codeHasUncommittedChanges)
        _ = context
    }

    func testRecordIsSavedAndReadBack() throws {
        let context = try TestSupport.makeContext()
        let experiment = makeExperiment(context, commit: commit, sha: fingerprint, environment: "macOS 15 · Python 3.12")
        experiment.codeHasUncommittedChanges = true
        addRun(context, to: experiment, number: 1, seed: 7, more: [8, 9], commit: commit, dirty: true)
        try context.save()

        let loaded = try XCTUnwrap(try context.fetch(FetchDescriptor<Experiment>()).first)
        XCTAssertEqual(loaded.codeCommit, commit)
        XCTAssertTrue(loaded.codeHasUncommittedChanges)
        XCTAssertEqual(loaded.datasetSHA256, fingerprint)
        XCTAssertEqual(loaded.environmentSnapshot, "macOS 15 · Python 3.12")
        let run = try XCTUnwrap(loaded.runs.first)
        XCTAssertEqual(run.additionalSeeds, [8, 9])
        XCTAssertEqual(run.codeCommit, commit)
        XCTAssertTrue(run.codeHasUncommittedChanges)
    }

    // MARK: Format checks

    func testCommitAndFingerprintFormats() {
        XCTAssertTrue(Experiment.isValidCommit("a41f9c2"))
        XCTAssertTrue(Experiment.isValidCommit("  A41F9C2D  "), "spaces and capitals are tidied")
        XCTAssertTrue(Experiment.isValidCommit(String(repeating: "a", count: 40)))
        XCTAssertFalse(Experiment.isValidCommit("a41f9c"), "too short")
        XCTAssertFalse(Experiment.isValidCommit(String(repeating: "a", count: 41)))
        XCTAssertFalse(Experiment.isValidCommit("a41f9cz"))
        XCTAssertFalse(Experiment.isValidCommit(""))

        XCTAssertTrue(Experiment.isValidSHA256(fingerprint))
        XCTAssertTrue(Experiment.isValidSHA256(fingerprint.uppercased()))
        XCTAssertFalse(Experiment.isValidSHA256("9b1c…e07d"), "a shortened display value is not a fingerprint")
        XCTAssertFalse(Experiment.isValidSHA256(String(fingerprint.dropLast())))

        XCTAssertEqual(Experiment.normalisedHash("  AbC123 \n"), "abc123")
    }

    // MARK: Checklist

    func testEmptyExperimentFailsEveryCheck() throws {
        let context = try TestSupport.makeContext()
        let experiment = makeExperiment(context)

        let checks = experiment.reproducibilityChecklist
        XCTAssertEqual(checks.map(\.id), ReproducibilityCheck.ID.allCases)
        XCTAssertTrue(checks.allSatisfy { !$0.passed })
        XCTAssertEqual(try check(experiment, .seeds).detail, "No runs yet.")
        XCTAssertEqual(experiment.reproducibilityProgress.passed, 0)
        XCTAssertEqual(experiment.reproducibilityProgress.total, 5)
        XCTAssertFalse(experiment.isFullyReproducible)
    }

    func testFullyRecordedExperimentPassesEveryCheck() throws {
        let context = try TestSupport.makeContext()
        let experiment = makeExperiment(context, commit: commit, sha: fingerprint, environment: "macOS 15 · Python 3.12 · torch 2.4")
        addRun(context, to: experiment, number: 1, seed: 1)
        addRun(context, to: experiment, number: 2, seed: 2, more: [3, 1])
        addRun(context, to: experiment, number: 3, status: .planned)       // not started: needs no seed yet

        XCTAssertTrue(experiment.isFullyReproducible, "\(experiment.reproducibilityChecklist)")
        XCTAssertEqual(experiment.recordedSeeds, [1, 2, 3])
        XCTAssertEqual(try check(experiment, .seeds).detail, "Seeds: 1, 2, 3.")
        XCTAssertEqual(experiment.reproducibilityProgress.passed, 5)
    }

    func testUncommittedChangesFailOnlyTheCleanCheck() throws {
        let context = try TestSupport.makeContext()
        let experiment = makeExperiment(context, commit: commit, sha: fingerprint, environment: "macOS 15")
        experiment.codeHasUncommittedChanges = true
        addRun(context, to: experiment, number: 1, seed: 1)

        XCTAssertTrue(try check(experiment, .codeCommit).passed)
        let clean = try check(experiment, .cleanCode)
        XCTAssertFalse(clean.passed)
        XCTAssertTrue(clean.detail.contains("cannot be reproduced exactly"))
        XCTAssertEqual(experiment.reproducibilityProgress.passed, 4)
    }

    func testRunWithUncommittedChangesIsNamed() throws {
        let context = try TestSupport.makeContext()
        let experiment = makeExperiment(context, commit: commit)
        addRun(context, to: experiment, number: 1, seed: 1)
        addRun(context, to: experiment, number: 2, seed: 2, dirty: true)

        let clean = try check(experiment, .cleanCode)
        XCTAssertFalse(clean.passed)
        XCTAssertEqual(clean.detail, "Run 2 used uncommitted changes.")
        XCTAssertEqual(experiment.runsWithUncommittedChanges.map(\.runNumber), [2])
    }

    func testCleanCheckNeedsACommitFirst() throws {
        let context = try TestSupport.makeContext()
        let experiment = makeExperiment(context)

        let clean = try check(experiment, .cleanCode)
        XCTAssertFalse(clean.passed, "nothing recorded is not the same as clean")
        XCTAssertEqual(clean.detail, "Record the commit first.")
    }

    func testRunMissingASeedIsNamedButPlannedRunsAreNot() throws {
        let context = try TestSupport.makeContext()
        let experiment = makeExperiment(context)
        addRun(context, to: experiment, number: 1, seed: 1)
        addRun(context, to: experiment, number: 2, status: .completed, seed: nil)
        addRun(context, to: experiment, number: 3, status: .planned, seed: nil)

        let seeds = try check(experiment, .seeds)
        XCTAssertFalse(seeds.passed)
        XCTAssertEqual(seeds.detail, "Run 2 has no seed.")
        XCTAssertEqual(experiment.runsMissingSeed.map(\.runNumber), [2])
    }

    func testCommitsRecordedOnEveryRunCountWhenTheExperimentHasNone() throws {
        let context = try TestSupport.makeContext()
        let experiment = makeExperiment(context)
        addRun(context, to: experiment, number: 1, seed: 1, commit: commit)
        addRun(context, to: experiment, number: 2, seed: 2, commit: "b52e0d3")

        XCTAssertTrue(try check(experiment, .codeCommit).passed)

        addRun(context, to: experiment, number: 3, seed: 3, commit: "")
        XCTAssertFalse(try check(experiment, .codeCommit).passed, "one run without a commit breaks it")
    }

    func testInvalidValuesDoNotCount() throws {
        let context = try TestSupport.makeContext()
        let experiment = makeExperiment(context, commit: "not-a-commit", sha: "9b1c…e07d")

        XCTAssertFalse(try check(experiment, .codeCommit).passed)
        XCTAssertFalse(try check(experiment, .datasetFingerprint).passed)
    }

    // MARK: Environment

    func testRecordEnvironmentStoresTextAndTime() throws {
        let context = try TestSupport.makeContext()
        let experiment = makeExperiment(context)
        let when = Date(timeIntervalSince1970: 1_800_000_000)

        experiment.recordEnvironment("  macOS 15 · Python 3.12  \n", at: when)

        XCTAssertEqual(experiment.environmentSnapshot, "macOS 15 · Python 3.12")
        XCTAssertEqual(experiment.environmentCapturedAt, when)
        XCTAssertEqual(experiment.updatedAt, when)
        XCTAssertTrue(try check(experiment, .environment).passed)

        experiment.recordEnvironment("   ", at: when)
        XCTAssertNil(experiment.environmentCapturedAt)
        XCTAssertFalse(try check(experiment, .environment).passed)
    }

    func testExistingOperatingEnvironmentFieldAlsoCounts() throws {
        let context = try TestSupport.makeContext()
        let experiment = makeExperiment(context)
        experiment.operatingEnvironment = "Ubuntu 24.04, CUDA 12.4"

        XCTAssertTrue(try check(experiment, .environment).passed)
    }

    func testDescribeThisMacNamesTheSystem() {
        let text = Experiment.describeThisMac()
        XCTAssertTrue(text.hasPrefix("macOS "))
        XCTAssertTrue(text.contains("GB memory"))
    }

    // MARK: Seeds

    func testAllSeedsKeepsTheMainSeedFirstWithoutRepeats() {
        let run = ExperimentRun(runNumber: 1, seed: 42, additionalSeeds: [7, 42, 7, 9])
        XCTAssertEqual(run.allSeeds, [42, 7, 9])

        XCTAssertEqual(ExperimentRun(runNumber: 2).allSeeds, [])
        XCTAssertEqual(ExperimentRun(runNumber: 3, additionalSeeds: [5]).allSeeds, [5])
    }

    func testExperimentLevelSeedIsPartOfTheRecordedSeeds() throws {
        let context = try TestSupport.makeContext()
        let experiment = makeExperiment(context)
        experiment.seed = 100
        addRun(context, to: experiment, number: 1, seed: 3)

        XCTAssertEqual(experiment.recordedSeeds, [3, 100])
    }
}
