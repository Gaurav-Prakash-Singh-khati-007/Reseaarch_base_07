//
//  TestSupport.swift
//  ResearchBaseTests
//
//  Shared helpers. Every test uses an in-memory database and a
//  temporary folder, so running the tests never touches the real
//  library, the real backups folder or the real PDF storage.
//

import XCTest
import SwiftData
@testable import ResearchBase

enum TestSupport {

    /// Mirrors the model list in ResearchBaseApp.swift. When a model
    /// is added to the app, add it here too, otherwise the backup
    /// tests would silently skip it.
    static let allModels: [any PersistentModel.Type] = [
        PaperRecord.self,
        PDFNoteRecord.self,
        ResearchNote.self,
        LiteratureReview.self,
        LiteratureTheme.self,
        LiteratureFinding.self,
        LiteratureComparisonEntry.self,
        LiteratureSynthesis.self,
        ResearchGap.self,
        ResearchProblem.self,
        ResearchIdea.self,
        Experiment.self,
        ExperimentRun.self,
        RunMetric.self,
        BaselineMetric.self,
        WritingDocument.self,
        WritingSection.self,
        ResearchProject.self,
        ResearchTask.self
    ]

    /// A fresh, empty, in-memory database.
    @MainActor
    static func makeContext() throws -> ModelContext {

        let schema = Schema(allModels)

        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true
        )

        let container = try ModelContainer(
            for: schema,
            configurations: [configuration]
        )

        // Keep the container alive as long as the context is used.
        containers.append(container)

        return ModelContext(container)
    }

    /// Containers are kept for the whole test run (they are small).
    @MainActor
    private static var containers: [ModelContainer] = []

    /// A new empty folder that is removed when the test ends.
    static func makeTempDirectory(_ testCase: XCTestCase) throws -> URL {

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RBTests-\(UUID().uuidString)", isDirectory: true)

        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )

        testCase.addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }

        return url
    }

    /// A small file that stands in for a PDF. The backup copies bytes
    /// and checks checksums; it does not parse the PDF.
    static func makeFakePDF(in folder: URL, name: String = "paper.pdf") throws -> URL {

        let url = folder.appendingPathComponent(name)
        let bytes = Data("%PDF-1.4\n% ResearchBase test file\n".utf8)
        try bytes.write(to: url)
        return url
    }

    /// Adds a small, known set of records. Returns what was added.
    @MainActor
    @discardableResult
    static func addSampleData(
        to context: ModelContext,
        pdfPath: String = ""
    ) throws -> (papers: Int, notes: Int, tasks: Int, highlights: Int) {

        let paperA = PaperRecord(
            pdfFilePath: pdfPath,
            title: "Communication-Efficient Learning of Deep Networks from Decentralized Data",
            authors: "McMahan, Moore, Ramage",
            venue: "AISTATS",
            year: 2017
        )

        let paperB = PaperRecord(
            pdfFilePath: "",
            title: "Federated Optimization in Heterogeneous Networks",
            authors: "Li, Sahu, Zaheer",
            venue: "MLSys",
            year: 2020
        )

        context.insert(paperA)
        context.insert(paperB)

        let note = ResearchNote(
            title: "FedAvg baseline",
            content: "Use as the baseline in chapter 4.",
            typeRawValue: "General"
        )
        context.insert(note)

        let task = ResearchTask(title: "Read SCAFFOLD")
        context.insert(task)

        let highlight = PDFNoteRecord(
            text: "keeps the training data distributed",
            note: "key idea",
            pageNumber: 1,
            boundsX: 10,
            boundsY: 10,
            boundsWidth: 100,
            boundsHeight: 12,
            paper: paperA
        )
        context.insert(highlight)

        try context.save()

        return (papers: 2, notes: 1, tasks: 1, highlights: 1)
    }

    @MainActor
    static func counts(_ context: ModelContext) throws -> [String: Int] {
        try WorkspaceSnapshot.capture(from: context).snapshot.entityCounts
    }
}
