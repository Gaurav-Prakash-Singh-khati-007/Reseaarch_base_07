//
//  SwiftDataToLibraryMigratorTests.swift
//  ResearchBaseTests
//
//  Owner: Agent 28 · F-05. Tests only SwiftDataToLibraryMigrator.
//
//  The tests never touch SwiftData. They build a `WorkspaceSnapshot.Capture`
//  by hand (the plain copy the migrator reads) and a stand-in backup result,
//  then run the real copy / check / switch against a temporary library.
//

import XCTest
@testable import ResearchBase

@MainActor
final class SwiftDataToLibraryMigratorTests: XCTestCase {

    // MARK: - Builders

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func paper(
        _ id: UUID = UUID(), title: String = "Attention Is All You Need",
        authors: String = "Vaswani, Ashish; Shazeer, Noam", year: Int = 2017,
        key: String = "vaswani2017attention", tags: String = "nlp, transformers",
        type: String = "Conference Paper"
    ) -> PaperDTO {
        PaperDTO(
            id: id, title: title, authors: authors, venue: "NeurIPS", year: year, abstractText: "abs",
            doi: "10.5555/3295222", urlString: "", tagsText: tags, statusRawValue: "unread", rating: 3,
            addedAt: t0, lastOpenedAt: nil, citationKey: key, publicationTypeRawValue: type,
            publisher: "", volume: "", issue: "", pages: "", edition: "", month: "", updatedAt: t0,
            pdfFileName: nil, pdfState: "none")
    }

    private func note(_ id: UUID = UUID(), papers: [UUID] = []) -> ResearchNoteDTO {
        ResearchNoteDTO(id: id, title: "A note", content: "body", typeRawValue: "General",
                        tagsText: "x", createdAt: t0, updatedAt: t0, paperIDs: papers)
    }

    private func annotation(paper: UUID?) -> PDFAnnotationDTO {
        PDFAnnotationDTO(id: UUID(), paperID: paper, text: "quoted", note: "my note", pageNumber: 2,
                         boundsX: 1, boundsY: 2, boundsWidth: 3, boundsHeight: 4,
                         createdAt: t0, updatedAt: t0)
    }

    private func experiment(_ id: UUID = UUID(), best: UUID? = nil) -> ExperimentDTO {
        ExperimentDTO(
            id: id, name: "Baseline sweep", statusRawValue: "Running", objective: "o", hypothesis: "h",
            descriptionText: "d", dataset: "CIFAR", datasetVersion: "1", model: "resnet", framework: "torch",
            hardware: "gpu", operatingEnvironment: "linux", codeRepository: "", trainValidationTestSplit: "80/10/10",
            seed: 7, batchSize: 32, learningRate: "0.1", epochs: 10, optimizer: "sgd", bestRunID: best,
            resultsInterpretation: "", resultsConclusion: "", createdAt: t0, updatedAt: t0,
            ideaIDs: [], problemIDs: [], gapIDs: [], paperIDs: [], noteIDs: [])
    }

    private func run(_ id: UUID = UUID(), experiment: UUID?, number: Int = 1) -> ExperimentRunDTO {
        ExperimentRunDTO(id: id, runNumber: number, statusRawValue: "Completed", startedAt: t0,
                         completedAt: t0, seed: 1, configuration: "lr=0.1", notes: "", createdAt: t0,
                         updatedAt: t0, experimentID: experiment)
    }

    private func metric(run: UUID?) -> RunMetricDTO {
        RunMetricDTO(id: UUID(), name: "accuracy", value: 0.91, unit: "", higherIsBetter: true, runID: run)
    }

    private func project(papers: [UUID] = []) -> ResearchProjectDTO {
        ResearchProjectDTO(
            id: UUID(), name: "Thesis", descriptionText: "", statusRawValue: "Active", createdAt: t0,
            updatedAt: t0, paperIDs: papers, noteIDs: [], findingIDs: [], gapIDs: [], problemIDs: [],
            ideaIDs: [], experimentIDs: [], writingDocumentIDs: [])
    }

    private func task(project: UUID?) -> ResearchTaskDTO {
        ResearchTaskDTO(
            id: UUID(), title: "Read more", descriptionText: "", statusRawValue: "In Progress",
            priorityRawValue: "High", dueDate: nil, createdAt: t0, updatedAt: t0, completedDate: nil,
            projectID: project, paperIDs: [], problemIDs: [], ideaIDs: [], experimentIDs: [],
            writingDocumentIDs: [])
    }

    private func draft(_ id: UUID = UUID(), papers: [UUID] = []) -> WritingDocumentDTO {
        WritingDocumentDTO(
            id: id, title: "My Paper", documentTypeRawValue: "Research Paper", statusRawValue: "Draft",
            createdAt: t0, updatedAt: t0, problemIDs: [], ideaIDs: [], gapIDs: [], experimentIDs: [],
            paperIDs: papers, noteIDs: [], findingIDs: [])
    }

    private func section(doc: UUID?, title: String, content: String, order: Int) -> WritingSectionDTO {
        WritingSectionDTO(id: UUID(), title: title, sectionTypeRawValue: "Body", content: content,
                          order: order, createdAt: t0, updatedAt: t0, documentID: doc)
    }

    /// A real PDF-like file in a temp folder (the migrator only needs bytes).
    private func pdfFile(_ text: String = "%PDF-1.4 fake") throws -> URL {
        let url = try TestSupport.makeTempDirectory(self).appendingPathComponent("\(UUID().uuidString).pdf")
        try Data(text.utf8).write(to: url)
        return url
    }

    private func capture(_ snapshot: WorkspaceSnapshot, pdfs: [(UUID, URL)] = []) -> WorkspaceSnapshot.Capture {
        WorkspaceSnapshot.Capture(
            snapshot: snapshot,
            pdfSources: pdfs.map { .init(paperID: $0.0, sourceURL: $0.1, packageFileName: $0.1.lastPathComponent) },
            missingPDFTitles: [])
    }

    /// A stand-in for the real safety backup: a folder that exists and counts that match.
    private func backup(for capture: WorkspaceSnapshot.Capture) throws -> PreChangeBackupResult {
        PreChangeBackupResult(
            packageURL: try TestSupport.makeTempDirectory(self),
            entityCounts: capture.snapshot.entityCounts,
            pdfCount: capture.pdfSources.count,
            papersWithMissingPDF: [])
    }

    private func migrator(_ model: LibraryModel, now: Date? = nil) -> SwiftDataToLibraryMigrator {
        SwiftDataToLibraryMigrator(model: model, clock: { now ?? Date() })
    }

    /// A small but complete old workspace.
    private func fullCapture() throws -> (WorkspaceSnapshot.Capture, paperID: UUID, draftID: UUID) {
        let p = UUID(), d = UUID(), e = UUID(), r = UUID(), pr = UUID()
        var s = WorkspaceSnapshot()
        s.papers = [paper(p), paper(title: "BERT", authors: "Devlin, Jacob", year: 2019, key: "devlin2019bert", tags: "nlp")]
        s.notes = [note(papers: [p])]
        s.annotations = [annotation(paper: p)]
        s.experiments = [experiment(e, best: r)]
        s.runs = [run(r, experiment: e)]
        s.metrics = [metric(run: r)]
        s.projects = [{ var x = project(papers: [p]); x.id = pr; return x }()]
        s.tasks = [task(project: pr)]
        s.writingDocuments = [draft(d, papers: [p])]
        s.writingSections = [
            section(doc: d, title: "Intro", content: "Costs 50% & more_", order: 0),
            section(doc: d, title: "Method", content: "We use \\emph{attention}.", order: 1)
        ]
        return (capture(s, pdfs: [(p, try pdfFile())]), p, d)
    }

    // MARK: - Pure helpers

    func testParseAuthorsFormats() {
        func family(_ s: String) -> [String] { SwiftDataToLibraryMigrator.parseAuthors(s).creators.map(\.family) }

        XCTAssertEqual(family("Vaswani, Ashish; Shazeer, Noam"), ["Vaswani", "Shazeer"])
        XCTAssertEqual(family("Ashish Vaswani and Noam Shazeer"), ["Vaswani", "Shazeer"])
        XCTAssertEqual(family("Vaswani, Ashish"), ["Vaswani"])
        XCTAssertEqual(family("Smith, J., Lee, K."), ["Smith", "Lee"], "initials after each surname mean two people")
        XCTAssertEqual(family("Ludwig van der Berg"), ["van der Berg"], "lower-case particles stay with the family name")
        XCTAssertEqual(family(""), [])

        let given = SwiftDataToLibraryMigrator.parseAuthors("Ludwig van der Berg").creators[0].given
        XCTAssertEqual(given, "Ludwig")
    }

    func testParseAuthorsFlagsGuesses() {
        XCTAssertTrue(SwiftDataToLibraryMigrator.parseAuthors("Alice Smith, Bob Jones, Carol Wu").ambiguous)
        XCTAssertFalse(SwiftDataToLibraryMigrator.parseAuthors("Smith, Alice; Jones, Bob").ambiguous)
    }

    func testOrganisationAndSuffixAndEtAl() {
        let org = SwiftDataToLibraryMigrator.parseAuthors("Stanford University Group").creators
        XCTAssertEqual(org.count, 1)
        XCTAssertTrue(org[0].isOrganisation)

        let jr = SwiftDataToLibraryMigrator.parseAuthors("Martin Luther King Jr").creators[0]
        XCTAssertEqual(jr.suffix, "Jr")
        XCTAssertEqual(jr.family, "King")

        XCTAssertEqual(SwiftDataToLibraryMigrator.parseAuthors("Smith, Anna; et al.").creators.last?.family, "others")
    }

    func testStableIDIsAValidAndRepeatableUUID() {
        let a = SwiftDataToLibraryMigrator.stableID("link|x")
        XCTAssertEqual(a, SwiftDataToLibraryMigrator.stableID("link|x"))
        XCTAssertNotEqual(a, SwiftDataToLibraryMigrator.stableID("link|y"))
        XCTAssertNotNil(UUID(uuidString: a))
    }

    func testLatexEscapingKeepsRealLatex() {
        XCTAssertEqual(SwiftDataToLibraryMigrator.latexEscaped("50% & a_b #1"), "50\\% \\& a\\_b \\#1")
        XCTAssertEqual(SwiftDataToLibraryMigrator.latexBody("plain 100%"), "plain 100\\%")
        XCTAssertEqual(SwiftDataToLibraryMigrator.latexBody("\\emph{x} 100%"), "\\emph{x} 100%",
                       "text that already has LaTeX commands is left alone")
    }

    func testSummaryAndNeedsMigration() throws {
        let (cap, _, _) = try fullCapture()
        let summary = SwiftDataToLibraryMigrator.summarize(cap)
        XCTAssertEqual(summary.papers, 2)
        XCTAssertEqual(summary.notes, 1)
        XCTAssertEqual(summary.pdfFiles, 1)
        XCTAssertTrue(summary.sentence.hasPrefix("2 papers, 1 note"), summary.sentence)
        XCTAssertFalse(summary.isEmpty)

        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let status = try migrator(model).status()
        XCTAssertEqual(status.state, .notStarted)
        XCTAssertTrue(SwiftDataToLibraryMigrator.needsMigration(summary: summary, status: status))

        let empty = SwiftDataToLibraryMigrator.summarize(capture(WorkspaceSnapshot()))
        XCTAssertTrue(empty.isEmpty)
        XCTAssertFalse(SwiftDataToLibraryMigrator.needsMigration(summary: empty, status: status))
    }

    // MARK: - Copy

    func testCopyWritesEverythingAndKeepsOldIDs() async throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let (cap, paperID, draftID) = try fullCapture()

        let result = try await migrator(model).copy(cap, backup: try backup(for: cap))

        XCTAssertEqual(result.inserted["paper"], 2)
        XCTAssertEqual(result.inserted["note"], 1)
        XCTAssertEqual(result.inserted["annotation"], 1)
        XCTAssertEqual(result.inserted["experiment"], 1)
        XCTAssertEqual(result.inserted["run"], 1)
        XCTAssertEqual(result.inserted["metric"], 1)
        XCTAssertEqual(result.inserted["project"], 1)
        XCTAssertEqual(result.inserted["task"], 1)
        XCTAssertEqual(result.inserted["draft"], 1)
        XCTAssertEqual(result.inserted["pdf"], 1)
        XCTAssertEqual(result.pdfFilesStored, 1)

        XCTAssertEqual(try ModelTestSupport.count(model, "items", where: "id = '\(paperID.uuidString)'"), 1,
                       "old UUIDs are kept")
        XCTAssertEqual(try ModelTestSupport.count(model, "item_creators"), 3)
        XCTAssertEqual(try ModelTestSupport.count(model, "attachments", where: "kind = 'pdf' AND is_primary = 1"), 1)
        XCTAssertEqual(try ModelTestSupport.count(model, "annotations"), 1)
        XCTAssertEqual(try ModelTestSupport.count(model, "drafts", where: "id = '\(draftID.uuidString)'"), 1)
        XCTAssertGreaterThan(try ModelTestSupport.count(model, "links"), 0)

        let key = try model.database.scalarText("SELECT citation_key FROM items WHERE id = ?", [.text(paperID.uuidString)])
        XCTAssertEqual(key, "vaswani2017attention", "a valid old citation key survives")

        let status = try migrator(model).status()
        XCTAssertEqual(status.state, .copied)
        XCTAssertFalse(status.legacyIsReadOnly)
        XCTAssertNotNil(status.copiedAt)
    }

    func testDraftBecomesRealFilesWithEscapedText() async throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let (cap, paperID, draftID) = try fullCapture()
        _ = try await migrator(model).copy(cap, backup: try backup(for: cap))

        let folder = try model.library.url(forRelativePath: "drafts/\(draftID.uuidString)")
        let tex = try String(contentsOf: folder.appendingPathComponent("main.tex"), encoding: .utf8)
        XCTAssertTrue(tex.contains("\\section{Intro}"))
        XCTAssertTrue(tex.contains("Costs 50\\% \\& more\\_"), tex)
        XCTAssertTrue(tex.contains("\\emph{attention}"), "existing LaTeX is not double-escaped")
        XCTAssertTrue(tex.contains("\\nocite{vaswani2017attention}"))

        let bib = try String(contentsOf: folder.appendingPathComponent("refs.bib"), encoding: .utf8)
        XCTAssertTrue(bib.contains("@inproceedings{vaswani2017attention"), bib)
        _ = paperID
    }

    func testCopyTwiceAddsNothingNew() async throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let (cap, _, _) = try fullCapture()
        let m = migrator(model)
        let b = try backup(for: cap)

        _ = try await m.copy(cap, backup: b)
        let before = try ModelTestSupport.count(model, "items")
        let again = try await m.copy(cap, backup: b)

        XCTAssertEqual(again.totalInserted, 0)
        XCTAssertGreaterThan(again.alreadyPresent, 0)
        XCTAssertEqual(again.pdfFilesStored, 0)
        XCTAssertEqual(try ModelTestSupport.count(model, "items"), before)
    }

    func testClashingCitationKeyIsChangedAndReported() async throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        var s = WorkspaceSnapshot()
        let first = paper(title: "One", key: "same2020key")
        let second = paper(title: "Two", key: "same2020key")
        s.papers = [first, second]
        let cap = capture(s)

        let result = try await migrator(model).copy(cap, backup: try backup(for: cap))

        XCTAssertEqual(result.keyChanges.count, 1)
        XCTAssertEqual(result.keyChanges[0].oldKey, "same2020key")
        XCTAssertNotEqual(result.keyChanges[0].newKey, "same2020key")
        XCTAssertEqual(try ModelTestSupport.count(model, "items"), 2)
        XCTAssertEqual(try model.database.scalarInt("SELECT COUNT(DISTINCT lower(citation_key)) FROM items"), 2)
    }

    func testInvalidOldKeyGetsAGeneratedOne() async throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        var s = WorkspaceSnapshot()
        s.papers = [paper(key: "has space!")]
        let cap = capture(s)

        let result = try await migrator(model).copy(cap, backup: try backup(for: cap))

        XCTAssertEqual(result.keyChanges.count, 1)
        XCTAssertTrue(CitationKeyGenerator.isValid(result.keyChanges[0].newKey))
    }

    func testBrokenReferencesAreSkippedWithAWarningNotACrash() async throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        var s = WorkspaceSnapshot()
        let p = UUID()
        s.papers = [paper(p)]
        s.annotations = [annotation(paper: nil), annotation(paper: UUID())]   // owner missing
        s.metrics = [metric(run: UUID())]                                      // run missing
        s.notes = [note(papers: [UUID()])]                                     // link to nothing
        let cap = capture(s)

        let result = try await migrator(model).copy(cap, backup: try backup(for: cap))

        XCTAssertEqual(try ModelTestSupport.count(model, "annotations"), 0)
        XCTAssertEqual(try ModelTestSupport.count(model, "metrics"), 0)
        XCTAssertEqual(try ModelTestSupport.count(model, "links"), 0)
        XCTAssertFalse(result.warnings.isEmpty)

        // The check explains the difference instead of calling it a mismatch.
        let report = try migrator(model).check(cap)
        XCTAssertTrue(report.isSafeToSwitch, report.blockingReason ?? "")
        let annotations = try XCTUnwrap(report.rows.first { $0.label == "PDF highlights" })
        XCTAssertEqual(annotations.old, 2)
        XCTAssertEqual(annotations.status, .explained)
    }

    // MARK: - Copy refuses, and leaves nothing behind

    func testCopyRefusesWhenBackupIsMissing() async throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let (cap, _, _) = try fullCapture()
        let gone = PreChangeBackupResult(
            packageURL: FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString)"),
            entityCounts: cap.snapshot.entityCounts, pdfCount: 0, papersWithMissingPDF: [])

        do {
            _ = try await migrator(model).copy(cap, backup: gone)
            XCTFail("should have thrown")
        } catch {
            XCTAssertEqual(error as? SwiftDataToLibraryMigrator.MigrationError, .backupMissing)
        }
        XCTAssertEqual(try ModelTestSupport.count(model, "items"), 0)
    }

    func testCopyRefusesWhenDataChangedAfterBackup() async throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let (cap, _, _) = try fullCapture()
        let stale = PreChangeBackupResult(
            packageURL: try TestSupport.makeTempDirectory(self),
            entityCounts: ["Papers": 99], pdfCount: 0, papersWithMissingPDF: [])

        do {
            _ = try await migrator(model).copy(cap, backup: stale)
            XCTFail("should have thrown")
        } catch {
            XCTAssertEqual(error as? SwiftDataToLibraryMigrator.MigrationError, .backupOutOfDate)
        }
        XCTAssertEqual(try ModelTestSupport.count(model, "items"), 0)
    }

    func testUnreadablePDFStopsEverythingAndChangesNothing() async throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let p = UUID()
        var s = WorkspaceSnapshot()
        s.papers = [paper(p, title: "Lost PDF")]
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("gone-\(UUID().uuidString).pdf")
        let cap = capture(s, pdfs: [(p, missing)])

        do {
            _ = try await migrator(model).copy(cap, backup: try backup(for: cap))
            XCTFail("should have thrown")
        } catch {
            XCTAssertEqual(error as? SwiftDataToLibraryMigrator.MigrationError, .pdfUnreadable("Lost PDF"))
        }
        XCTAssertEqual(try ModelTestSupport.count(model, "items"), 0)
        XCTAssertEqual(try migrator(model).status().state, .notStarted)
    }

    func testFailedRecordWriteRollsBackAndRemovesNewFiles() async throws {
        // The change sink fails on its 2nd call (after the paper row is written), inside the
        // same transaction. The migrator skips rows that already exist, so a duplicate id
        // cannot be used to force a failure.
        let model = try ModelTestSupport.makeModel(self, sink: FailingChangeSink(failOnCall: 1))
        defer { model.library.close() }
        let p = UUID()
        var s = WorkspaceSnapshot()
        s.papers = [paper(p)]
        s.writingDocuments = [draft(UUID())]
        let url = try pdfFile("%PDF unique-bytes-for-rollback")
        let cap = capture(s, pdfs: [(p, url)])

        do {
            _ = try await migrator(model).copy(cap, backup: try backup(for: cap))
            XCTFail("should have thrown")
        } catch {
            // any database error is fine; what matters is the state afterwards
        }

        XCTAssertEqual(try ModelTestSupport.count(model, "items"), 0, "database unchanged")
        XCTAssertEqual(try ModelTestSupport.count(model, "drafts"), 0)
        XCTAssertEqual(try migrator(model).status().state, .notStarted)

        let sha = try AttachmentStore.sha256Hex(of: url)
        let stored = try model.library.url(
            forRelativePath: AttachmentStore.relativePath(sha256: sha, fileExtension: "pdf"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stored.path), "file made by this run is removed")
    }

    // MARK: - Check

    func testCheckPassesAndMarksVerified() async throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let (cap, _, _) = try fullCapture()
        let m = migrator(model)
        _ = try await m.copy(cap, backup: try backup(for: cap))

        let report = try m.check(cap)

        XCTAssertTrue(report.isSafeToSwitch, report.blockingReason ?? "")
        XCTAssertNil(report.blockingReason)
        XCTAssertEqual(report.pdfSampleSize, 1)
        XCTAssertEqual(report.pdfSampleMatched, 1)
        XCTAssertTrue(report.rows.allSatisfy { $0.status != .mismatch })
        XCTAssertEqual(try m.status().state, .verified)
        XCTAssertNotNil(try m.status().verifiedAt)
    }

    func testCheckDetectsAChangedValue() async throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let (cap, paperID, _) = try fullCapture()
        let m = migrator(model)
        _ = try await m.copy(cap, backup: try backup(for: cap))

        try model.database.run(
            "UPDATE items SET title = 'Tampered' WHERE id = ?", [.text(paperID.uuidString)])
        let report = try m.check(cap)

        XCTAssertFalse(report.isSafeToSwitch)
        XCTAssertTrue(report.contentProblems.contains { $0.contains("title") }, "\(report.contentProblems)")
        XCTAssertEqual(try m.status().state, .copied, "a failed check does not mark verified")
    }

    func testCheckDetectsAMissingRowAsMismatch() async throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let (cap, _, _) = try fullCapture()
        let m = migrator(model)
        _ = try await m.copy(cap, backup: try backup(for: cap))

        // Hard-deleting here only simulates damage; the migrator itself never deletes.
        try model.database.run("DELETE FROM tasks")
        let report = try m.check(cap)

        let tasks = try XCTUnwrap(report.rows.first { $0.label == "Tasks" })
        XCTAssertEqual(tasks.status, .mismatch)
        XCTAssertFalse(report.isSafeToSwitch)
        XCTAssertNotNil(report.blockingReason)
    }

    func testCheckDetectsDamagedStoredPDF() async throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let (cap, _, _) = try fullCapture()
        let m = migrator(model)
        _ = try await m.copy(cap, backup: try backup(for: cap))

        let relative = try XCTUnwrap(try model.database.scalarText("SELECT rel_path FROM attachments LIMIT 1"))
        try Data("corrupted".utf8).write(to: try model.library.url(forRelativePath: relative))
        let report = try m.check(cap)

        XCTAssertEqual(report.pdfSampleMatched, 0)
        XCTAssertFalse(report.isSafeToSwitch)
    }

    // MARK: - Switch

    func testSwitchNeedsACopyAndACheckFirst() async throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let (cap, _, _) = try fullCapture()
        let m = migrator(model)

        let report = try m.check(cap)   // nothing copied yet
        XCTAssertThrowsError(try m.switchToNewLibrary(report: report)) {
            XCTAssertEqual($0 as? SwiftDataToLibraryMigrator.MigrationError, .nothingCopied)
        }

        _ = try await m.copy(cap, backup: try backup(for: cap))
        try model.database.run("DELETE FROM tasks")
        let bad = try m.check(cap)
        XCTAssertThrowsError(try m.switchToNewLibrary(report: bad)) {
            guard case .notSafeToSwitch = $0 as? SwiftDataToLibraryMigrator.MigrationError else {
                return XCTFail("wrong error \($0)")
            }
        }
        XCTAssertEqual(try m.status().state, .copied)
    }

    func testSwitchStartsTheNinetyDayReadOnlyWindow() async throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let (cap, _, _) = try fullCapture()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let m = migrator(model, now: now)
        _ = try await m.copy(cap, backup: try backup(for: cap))
        let report = try m.check(cap)

        try m.switchToNewLibrary(report: report)

        let status = try m.status()
        XCTAssertEqual(status.state, .switched)
        XCTAssertTrue(status.legacyIsReadOnly)
        XCTAssertEqual(status.legacyDaysLeft(now: now), 90)
        XCTAssertEqual(status.legacyDaysLeft(now: now.addingTimeInterval(89 * 86_400)), 1)
        XCTAssertEqual(status.legacyDaysLeft(now: now.addingTimeInterval(200 * 86_400)), 0)
        XCTAssertFalse(SwiftDataToLibraryMigrator.needsMigration(
            summary: SwiftDataToLibraryMigrator.summarize(cap), status: status))

        // Doing it again is harmless.
        XCTAssertNoThrow(try m.switchToNewLibrary(report: report))
        XCTAssertEqual(try m.status().switchedAt, status.switchedAt)
    }

    func testCopyIsRefusedAfterTheSwitch() async throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let (cap, _, _) = try fullCapture()
        let m = migrator(model)
        let b = try backup(for: cap)
        _ = try await m.copy(cap, backup: b)
        try m.switchToNewLibrary(report: try m.check(cap))

        do {
            _ = try await m.copy(cap, backup: b)
            XCTFail("should have thrown")
        } catch {
            XCTAssertEqual(error as? SwiftDataToLibraryMigrator.MigrationError, .alreadySwitched)
        }
    }

    // MARK: - Never deletes or overwrites

    func testExistingRowsAreNeverOverwritten() async throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let (cap, paperID, _) = try fullCapture()
        let m = migrator(model)
        let b = try backup(for: cap)
        _ = try await m.copy(cap, backup: b)

        // The person edits the new library, then the copy runs again.
        try model.database.run(
            "UPDATE items SET title = 'Edited in the new library' WHERE id = ?", [.text(paperID.uuidString)])
        _ = try await m.copy(cap, backup: b)

        XCTAssertEqual(
            try model.database.scalarText("SELECT title FROM items WHERE id = ?", [.text(paperID.uuidString)]),
            "Edited in the new library")
    }

    func testEveryCopiedRecordIsInTheChangeHistory() async throws {
        let sink = RecordingChangeSink()
        let model = try ModelTestSupport.makeModel(self, sink: sink)
        defer { model.library.close() }
        let (cap, _, _) = try fullCapture()
        _ = try await migrator(model).copy(cap, backup: try backup(for: cap))

        XCTAssertEqual(sink.entries(type: "item", action: .importRecord, field: "legacy").count, 2)
        XCTAssertEqual(sink.entries(type: "draft", action: .importRecord).count, 1)
    }

    // MARK: - Mapping

    func testStatusesAndTypesAreMapped() async throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let e = UUID()
        var s = WorkspaceSnapshot()
        s.papers = [paper(title: "Book", key: "b1", type: "Book"), paper(title: "Site", key: "b2", type: "Website")]
        s.experiments = [experiment(e)]
        s.tasks = [task(project: nil)]
        let cap = capture(s)

        _ = try await migrator(model).copy(cap, backup: try backup(for: cap))

        XCTAssertEqual(try model.database.scalarText("SELECT item_type FROM items WHERE title = 'Book'"), "book")
        XCTAssertEqual(try model.database.scalarText("SELECT item_type FROM items WHERE title = 'Site'"), "webpage")
        XCTAssertEqual(try model.database.scalarText("SELECT status FROM experiments"), "running")
        XCTAssertEqual(try model.database.scalarText("SELECT status FROM tasks"), "doing")
        XCTAssertEqual(try model.database.scalarText("SELECT priority FROM tasks"), "high")
    }

    func testEmptyTitleBecomesUntitledWithAWarning() async throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        var s = WorkspaceSnapshot()
        s.papers = [paper(title: "   ", key: "x1")]
        let cap = capture(s)

        let result = try await migrator(model).copy(cap, backup: try backup(for: cap))

        XCTAssertEqual(try model.database.scalarText("SELECT title FROM items"), "Untitled paper")
        XCTAssertTrue(result.warnings.contains { $0.contains("Untitled paper") })
    }
}
