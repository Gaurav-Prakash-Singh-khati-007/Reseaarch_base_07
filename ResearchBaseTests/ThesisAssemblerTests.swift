//
//  ThesisAssemblerTests.swift
//  ResearchBase
//
//  Created by Gaurav Khati on 21/10/26.
//


//
//  ThesisAssemblerTests.swift
//  ResearchBaseTests
//
//  Owner: Agent 36 · F-39
//

import XCTest
@testable import ResearchBase

final class ThesisAssemblerTests: XCTestCase {

    private var folder: URL!
    private let assembler = ThesisAssembler()

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("rbA36test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Helpers

    private func write(_ name: String, _ text: String) throws {
        let url = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ name: String) throws -> String {
        try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)
    }

    private func count(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    private func slots(_ ids: [String], appendix: Set<String> = []) -> [ThesisSlot] {
        ids.map { ThesisSlot(id: $0, inAppendix: appendix.contains($0)) }
    }

    /// A thesis written the way the template writes it: every chapter inside main.tex.
    private let inlineMain = """
    % ResearchBase template: University thesis (v1)
    \\documentclass[12pt,a4paper,oneside]{report}
    \\usepackage{graphicx}
    \\begin{document}
    \\begin{titlepage}
    Title page
    \\end{titlepage}
    \\pagenumbering{roman}
    \\chapter*{Declaration}
    This is my own work.
    \\tableofcontents
    \\clearpage
    \\pagenumbering{arabic}

    \\chapter{Introduction}
    \\label{ch:intro}
    Intro text.

    \\chapter{Method}
    \\label{ch:method}
    \\section{Setting}
    Method text.

    \\chapter{Results \\& Discussion}
    Results text.

    \\chapter{Conclusion}
    Done.

    \\appendix
    \\chapter{Proofs}
    Proof text.

    \\bibliographystyle{plainnat}
    \\bibliography{refs}
    \\end{document}

    """

    /// A thesis whose chapters are already files.
    private let fileMain = """
    \\documentclass{report}
    \\input{preamble}
    \\begin{document}
    \\frontmatter
    \\input{frontmatter/abstract}
    \\mainmatter
    % ---- chapters ----
    \\include{chapters/a}
    % second chapter
    \\include{chapters/b}
    \\input{chapters/c}   % keep this note
    \\include{chapters/d}
    \\backmatter
    \\bibliography{refs}
    \\end{document}

    """

    private func writeFileThesis() throws {
        try write("main.tex", fileMain)
        for (name, title) in [("a", "Alpha"), ("b", "Bravo"), ("c", "Charlie"), ("d", "Delta")] {
            try write("chapters/\(name).tex", "\\chapter{\(title)}\nText of \(name).\n")
        }
    }

    // MARK: Scanning

    func testScanFindsInlineChaptersAndLeavesFrontMatterAlone() throws {
        try write("main.tex", inlineMain)
        let layout = try assembler.scan(folder: folder)

        XCTAssertEqual(layout.chapters.map(\.title), ["Introduction", "Method", "Results & Discussion", "Conclusion", "Proofs"])
        XCTAssertEqual(layout.chapters.map(\.id), ["inline:1", "inline:2", "inline:3", "inline:4", "inline:5"])
        XCTAssertEqual(layout.chapters.map(\.inAppendix), [false, false, false, false, true])
        XCTAssertTrue(layout.chapters.allSatisfy { $0.command == .inline && $0.exists && $0.words > 0 })
        XCTAssertTrue(layout.hasInlineChapters)
        XCTAssertFalse(layout.usesMarkers)
        XCTAssertTrue(layout.canRearrange)
        XCTAssertTrue(layout.issues.contains { $0.severity == .info && $0.message.contains("5 chapters") })
        XCTAssertEqual(try read("main.tex"), inlineMain, "scan never writes")
    }

    func testScanOfFileThesisReadsTitlesCommandsAndUnlistedFiles() throws {
        try writeFileThesis()
        try write("chapters/spare.tex", "\\chapter{Spare part}\nUnused.\n")
        try write("chapters/notes.tex", "just notes, no chapter command\n")

        let layout = try assembler.scan(folder: folder)
        XCTAssertEqual(layout.chapters.map(\.id), ["chapters/a", "chapters/b", "chapters/c", "chapters/d"])
        XCTAssertEqual(layout.chapters.map(\.title), ["Alpha", "Bravo", "Charlie", "Delta"])
        XCTAssertEqual(layout.chapters.map(\.command), [.include, .include, .input, .include])
        XCTAssertEqual(layout.chapters[0].path, "chapters/a.tex")
        XCTAssertEqual(layout.unlisted.map(\.id), ["chapters/notes", "chapters/spare"])
        XCTAssertEqual(layout.unlisted.last?.title, "Spare part")
        XCTAssertEqual(layout.unlisted.first?.title, "Notes", "no \\chapter: the file name is used")
        XCTAssertFalse(layout.hasInlineChapters)
    }

    func testScanReportsProblems() throws {
        try write("main.tex", """
        \\documentclass{report}
        \\begin{document}
        \\include{chapters/missing}
        \\include{chapters/plain.tex}
        \\include{chapters/a}
        \\include{chapters/a}
        \\end{document}
        """)
        try write("chapters/plain.tex", "no chapter command here\n")
        try write("chapters/a.tex", "\\chapter{A}\n")

        let layout = try assembler.scan(folder: folder)
        XCTAssertFalse(layout.canRearrange, "the same chapter twice")
        XCTAssertTrue(layout.issues.contains { $0.severity == .problem && $0.message.contains("chapters/missing") })
        XCTAssertTrue(layout.issues.contains { $0.severity == .warning && $0.message.contains("no \\chapter") })
        XCTAssertTrue(layout.issues.contains { $0.severity == .warning && $0.message.contains(".tex ending") })
        XCTAssertTrue(layout.issues.contains { $0.severity == .problem && $0.message.contains("more than once") })
        XCTAssertFalse(layout.chapters[0].exists)
        XCTAssertEqual(Set(layout.chapters.map(\.id)).count, layout.chapters.count, "every id is unique")
    }

    // MARK: Moving inline chapters into files and reordering

    func testReorderMovesInlineChaptersIntoFilesWordForWord() throws {
        try write("main.tex", inlineMain)

        let order = slots(["inline:2", "inline:1", "inline:3", "inline:4", "inline:5"], appendix: ["inline:5"])
        let plan = try assembler.plan(folder: folder, order: order)

        XCTAssertTrue(plan.mainChanged)
        XCTAssertEqual(plan.newFiles.map(\.path), [
            "chapters/introduction.tex", "chapters/method.tex", "chapters/results-discussion.tex",
            "chapters/conclusion.tex", "chapters/proofs.tex"
        ])
        XCTAssertEqual(plan.newFiles[1].text, "\\chapter{Method}\n\\label{ch:method}\n\\section{Setting}\nMethod text.\n")
        XCTAssertEqual(plan.newFiles[4].text, "\\chapter{Proofs}\nProof text.\n")
        XCTAssertEqual(plan.idMap["inline:2"], "chapters/method")
        XCTAssertTrue(plan.summary.first?.contains("Moves 5 chapters") == true, "\(plan.summary)")

        // Front matter and back matter are untouched, the list is generated between markers.
        let expected = """
        % ResearchBase template: University thesis (v1)
        \\documentclass[12pt,a4paper,oneside]{report}
        \\usepackage{graphicx}
        \\begin{document}
        \\begin{titlepage}
        Title page
        \\end{titlepage}
        \\pagenumbering{roman}
        \\chapter*{Declaration}
        This is my own work.
        \\tableofcontents
        \\clearpage
        \\pagenumbering{arabic}

        % >>> ResearchBase thesis chapters (generated: change the order in the app, not here) >>>
        \\include{chapters/method}
        \\include{chapters/introduction}
        \\include{chapters/results-discussion}
        \\include{chapters/conclusion}
        \\appendix
        \\include{chapters/proofs}
        % <<< ResearchBase thesis chapters <<<

        \\bibliographystyle{plainnat}
        \\bibliography{refs}
        \\end{document}

        """
        XCTAssertEqual(plan.newMain, expected)
        XCTAssertEqual(try read("main.tex"), inlineMain, "a plan writes nothing")
        XCTAssertFalse(exists("chapters/method.tex"))

        let report = try assembler.commit(plan, folder: folder)
        XCTAssertEqual(report.createdFiles.count, 5)
        XCTAssertEqual(try read("main.tex"), expected)
        XCTAssertEqual(try read("chapters/results-discussion.tex"), "\\chapter{Results \\& Discussion}\nResults text.\n")

        // After the move the chapters are files, and the same order is a no-op.
        let layout = try assembler.scan(folder: folder)
        XCTAssertTrue(layout.usesMarkers)
        XCTAssertEqual(layout.chapters.map(\.id), [
            "chapters/method", "chapters/introduction", "chapters/results-discussion", "chapters/conclusion", "chapters/proofs"
        ])
        XCTAssertTrue(layout.chapters.allSatisfy { $0.command == .include && $0.exists })
        XCTAssertEqual(layout.chapters.last?.inAppendix, true)

        let again = try assembler.plan(folder: folder, order: layout.chapters.map { ThesisSlot(id: $0.id, inAppendix: $0.inAppendix) })
        XCTAssertFalse(again.mainChanged)
        XCTAssertTrue(again.newFiles.isEmpty)
    }

    func testChapterLeftOutKeepsItsFile() throws {
        try write("main.tex", inlineMain)
        let order = slots(["inline:1", "inline:2", "inline:4", "inline:5"], appendix: ["inline:5"])
        let plan = try assembler.plan(folder: folder, order: order)
        try assembler.commit(plan, folder: folder)

        let main = try read("main.tex")
        XCTAssertFalse(main.contains("results-discussion"))
        XCTAssertTrue(exists("chapters/results-discussion.tex"), "the text is never thrown away")
        XCTAssertTrue(plan.summary.contains { $0.contains("Takes 1 chapter out of the thesis") && $0.contains("Results & Discussion") })

        let layout = try assembler.scan(folder: folder)
        XCTAssertEqual(layout.unlisted.map(\.id), ["chapters/results-discussion"])

        // And it can be put back.
        let back = try assembler.plan(folder: folder, order: slots([
            "chapters/introduction", "chapters/method", "chapters/results-discussion", "chapters/conclusion", "chapters/proofs"
        ], appendix: ["chapters/proofs"]))
        XCTAssertTrue(back.newMain.contains("\\include{chapters/results-discussion}"))
    }

    // MARK: File-based theses

    func testReorderKeepsCommandsCommentsAndEverythingOutsideTheList() throws {
        try writeFileThesis()
        let plan = try assembler.plan(folder: folder, order: slots(["chapters/d", "chapters/c", "chapters/b", "chapters/a"]))

        let expected = """
        \\documentclass{report}
        \\input{preamble}
        \\begin{document}
        \\frontmatter
        \\input{frontmatter/abstract}
        \\mainmatter
        % ---- chapters ----
        % >>> ResearchBase thesis chapters (generated: change the order in the app, not here) >>>
        \\include{chapters/d}
        \\input{chapters/c}   % keep this note
        % second chapter
        \\include{chapters/b}
        \\include{chapters/a}
        % <<< ResearchBase thesis chapters <<<
        \\backmatter
        \\bibliography{refs}
        \\end{document}

        """
        XCTAssertEqual(plan.newMain, expected)
        XCTAssertTrue(plan.newFiles.isEmpty)
        XCTAssertEqual(plan.summary, ["Changes the order of the chapters."])
    }

    func testMovingAChapterIntoTheAppendixWritesOneAppendixLine() throws {
        try writeFileThesis()
        let plan = try assembler.plan(folder: folder, order: slots(
            ["chapters/a", "chapters/b", "chapters/c", "chapters/d"], appendix: ["chapters/c", "chapters/d"]))

        XCTAssertEqual(count("\\appendix", in: plan.newMain), 1)
        let lines = plan.newMain.components(separatedBy: "\n")
        let appendix = try XCTUnwrap(lines.firstIndex(of: "\\appendix"))
        XCTAssertEqual(lines[appendix + 1], "\\input{chapters/c}   % keep this note")
        XCTAssertTrue(plan.summary.contains("Changes which chapters are appendices."))
    }

    func testLinesBetweenChaptersStopEverythingAndChangeNothing() throws {
        try write("main.tex", """
        \\begin{document}
        \\include{chapters/a}
        \\cleardoublepage
        \\include{chapters/b}
        \\end{document}
        """)
        try write("chapters/a.tex", "\\chapter{A}\n")
        try write("chapters/b.tex", "\\chapter{B}\n")
        let before = try read("main.tex")

        let layout = try assembler.scan(folder: folder)
        XCTAssertFalse(layout.canRearrange)
        XCTAssertTrue(layout.issues.contains { $0.severity == .problem && $0.message.contains("cleardoublepage") })

        XCTAssertThrowsError(try assembler.plan(folder: folder, order: slots(["chapters/b", "chapters/a"]))) {
            guard case ThesisError.linesBetweenChapters(let lines) = $0 else { return XCTFail("\($0)") }
            XCTAssertEqual(lines, ["line 3: \\cleardoublepage"])
        }
        XCTAssertEqual(try read("main.tex"), before)
    }

    func testThesisWithNoChaptersYetGetsItsListBeforeTheBibliography() throws {
        try write("main.tex", """
        \\begin{document}
        \\maketitle
        \\bibliography{refs}
        \\end{document}
        """)
        try write("chapters/a.tex", "\\chapter{A}\n")

        let layout = try assembler.scan(folder: folder)
        XCTAssertTrue(layout.chapters.isEmpty)
        XCTAssertEqual(layout.unlisted.map(\.id), ["chapters/a"])

        let plan = try assembler.plan(folder: folder, order: slots(["chapters/a"]))
        XCTAssertEqual(plan.newMain, """
        \\begin{document}
        \\maketitle

        % >>> ResearchBase thesis chapters (generated: change the order in the app, not here) >>>
        \\include{chapters/a}
        % <<< ResearchBase thesis chapters <<<

        \\bibliography{refs}
        \\end{document}
        """)

        // Nothing to do for an empty list on a main file that has no list yet.
        let none = try assembler.plan(folder: folder, order: [])
        XCTAssertFalse(none.mainChanged)
    }

    // MARK: New chapters

    func testNewChapterIsAddedAfterTheMainChaptersWithAnEscapedTitleAndUniqueFile() throws {
        try writeFileThesis()
        try write("chapters/related-work-more.tex", "\\chapter{Taken}\n")

        let plan = try assembler.planNewChapter(title: "  Related   work & more ", folder: folder)
        XCTAssertEqual(plan.createdChapterID, "chapters/related-work-more-2")
        XCTAssertEqual(plan.newFiles, [ThesisNewFile(
            path: "chapters/related-work-more-2.tex",
            text: "\\chapter{Related work \\& more}\n\\label{ch:related-work-more}\n\n")])

        let main = plan.newMain
        let a = try XCTUnwrap(main.range(of: "\\include{chapters/a}"))
        let d = try XCTUnwrap(main.range(of: "\\include{chapters/d}"))
        let created = try XCTUnwrap(main.range(of: "\\include{chapters/related-work-more-2}"))
        XCTAssertTrue(a.lowerBound < d.lowerBound && d.lowerBound < created.lowerBound)

        try assembler.commit(plan, folder: folder)
        XCTAssertEqual(try assembler.scan(folder: folder).chapters.last?.title, "Related work & more")

        XCTAssertThrowsError(try assembler.planNewChapter(title: "   ", folder: folder)) {
            XCTAssertEqual($0 as? ThesisError, .emptyTitle)
        }
    }

    func testNewChapterGoesBeforeAppendixChapters() throws {
        try write("main.tex", """
        \\begin{document}
        \\include{chapters/a}
        \\appendix
        \\include{chapters/p}
        \\end{document}
        """)
        try write("chapters/a.tex", "\\chapter{A}\n")
        try write("chapters/p.tex", "\\chapter{P}\n")

        let plan = try assembler.planNewChapter(title: "Middle", folder: folder)
        let main = plan.newMain
        XCTAssertTrue(try XCTUnwrap(main.range(of: "chapters/middle}")).lowerBound < XCTUnwrap(main.range(of: "\\appendix")).lowerBound)
    }

    // MARK: Build scope

    func testBuildScopeIsAddedChangedAndRemoved() throws {
        try writeFileThesis()

        let scoped = try assembler.planBuildScope(only: ["chapters/b"], folder: folder)
        XCTAssertTrue(scoped.newMain.contains("\\includeonly{chapters/b}"))
        let only = try XCTUnwrap(scoped.newMain.range(of: "\\includeonly"))
        let begin = try XCTUnwrap(scoped.newMain.range(of: "\\begin{document}"))
        XCTAssertTrue(only.lowerBound < begin.lowerBound, "\\includeonly belongs in the preamble")
        try assembler.commit(scoped, folder: folder)
        XCTAssertEqual(try assembler.scan(folder: folder).buildOnly, ["chapters/b"])

        let changed = try assembler.planBuildScope(only: ["chapters/a", "chapters/d"], folder: folder)
        XCTAssertEqual(count("\\includeonly", in: changed.newMain), 1)
        XCTAssertTrue(changed.newMain.contains("\\includeonly{chapters/a,chapters/d}"))
        try assembler.commit(changed, folder: folder)

        // Reordering keeps the scope.
        let reordered = try assembler.plan(folder: folder, order: slots(["chapters/d", "chapters/c", "chapters/b", "chapters/a"]))
        XCTAssertTrue(reordered.newMain.contains("\\includeonly{chapters/a,chapters/d}"))

        let cleared = try assembler.planBuildScope(only: nil, folder: folder)
        XCTAssertFalse(cleared.newMain.contains("includeonly"))
        XCTAssertFalse(cleared.newMain.contains("build scope"))
        try assembler.commit(cleared, folder: folder)
        XCTAssertNil(try assembler.scan(folder: folder).buildOnly)

        // Clearing again changes nothing.
        XCTAssertFalse(try assembler.planBuildScope(only: nil, folder: folder).mainChanged)
    }

    func testBuildScopeRefusesChaptersThatAreNotIncludeFiles() throws {
        try writeFileThesis()
        XCTAssertThrowsError(try assembler.planBuildScope(only: ["chapters/c"], folder: folder)) {
            XCTAssertEqual($0 as? ThesisError, .notAFileChapter("chapters/c"))
        }
        XCTAssertThrowsError(try assembler.planBuildScope(only: ["zzz"], folder: folder)) {
            XCTAssertEqual($0 as? ThesisError, .unknownChapter("zzz"))
        }

        try write("main.tex", inlineMain)
        XCTAssertThrowsError(try assembler.planBuildScope(only: ["inline:1"], folder: folder)) {
            XCTAssertEqual($0 as? ThesisError, .notAFileChapter("inline:1"))
        }
    }

    // MARK: Errors and safety

    func testBadInputIsReportedNotGuessed() throws {
        XCTAssertThrowsError(try assembler.scan(folder: folder)) {
            XCTAssertEqual($0 as? ThesisError, .mainFileMissing("main.tex"))
        }

        try write("main.tex", "\\documentclass{report}\nno body here\n")
        XCTAssertThrowsError(try assembler.scan(folder: folder)) {
            XCTAssertEqual($0 as? ThesisError, .noDocumentBody)
        }

        try writeFileThesis()
        XCTAssertThrowsError(try assembler.plan(folder: folder, order: slots(["chapters/a", "nope"]))) {
            XCTAssertEqual($0 as? ThesisError, .unknownChapter("nope"))
        }
        XCTAssertThrowsError(try assembler.plan(folder: folder, order: slots(["chapters/a", "chapters/a"]))) {
            XCTAssertEqual($0 as? ThesisError, .duplicateChapter("chapters/a"))
        }
    }

    func testCommitNeverOverwritesAnExistingFileAndKeepsMainUntouched() throws {
        try write("main.tex", inlineMain)
        let plan = try assembler.plan(folder: folder, order: slots(["inline:1", "inline:2", "inline:3", "inline:4", "inline:5"], appendix: ["inline:5"]))

        try write("chapters/introduction.tex", "someone else's file\n")
        XCTAssertThrowsError(try assembler.commit(plan, folder: folder)) {
            XCTAssertEqual($0 as? ThesisError, .fileExists("chapters/introduction.tex"))
        }
        XCTAssertEqual(try read("main.tex"), inlineMain)
        XCTAssertEqual(try read("chapters/introduction.tex"), "someone else's file\n")
        XCTAssertFalse(exists("chapters/method.tex"), "nothing was written before the check")

        // A fresh plan picks a free name instead.
        let next = try assembler.plan(folder: folder, order: slots(["inline:1", "inline:2", "inline:3", "inline:4", "inline:5"], appendix: ["inline:5"]))
        XCTAssertEqual(next.newFiles.first?.path, "chapters/introduction-2.tex")
    }

    func testLineEndingsAndMissingFinalNewlineAreKept() throws {
        let crlf = "\\begin{document}\r\n\\include{chapters/a}\r\n\\include{chapters/b}\r\n\\end{document}"
        try write("main.tex", crlf)
        try write("chapters/a.tex", "\\chapter{A}\n")
        try write("chapters/b.tex", "\\chapter{B}\n")

        let plan = try assembler.plan(folder: folder, order: slots(["chapters/b", "chapters/a"]))
        XCTAssertTrue(plan.newMain.contains("\r\n"))
        XCTAssertFalse(plan.newMain.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "no bare LF mixed in")
        XCTAssertTrue(plan.newMain.hasSuffix("\\end{document}"), "still no final newline")
    }

    func testChapterFolderAndDefaultCommandCanBeChosen() throws {
        let custom = ThesisAssembler(chapterFolder: "parts/", defaultCommand: .input)
        try write("main.tex", "\\begin{document}\n\\input{parts/one}\n\\end{document}\n")
        try write("parts/one.tex", "\\chapter{One}\n")

        let plan = try custom.planNewChapter(title: "Two", folder: folder)
        XCTAssertEqual(plan.createdChapterID, "parts/two")
        XCTAssertTrue(plan.newMain.contains("\\input{parts/two}"))
        XCTAssertEqual(try custom.scan(folder: folder).chapters.map(\.id), ["parts/one"])
    }

    // MARK: Helpers

    func testSlugAndWordCount() {
        XCTAssertEqual(ThesisAssembler.slug("Results & Discussion"), "results-discussion")
        XCTAssertEqual(ThesisAssembler.slug("Évaluation générale"), "evaluation-generale")
        XCTAssertEqual(ThesisAssembler.slug("  --  "), "chapter")
        XCTAssertLessThanOrEqual(ThesisAssembler.slug(String(repeating: "word ", count: 30)).count, 40)

        XCTAssertEqual(ThesisAssembler.wordCount("\\chapter{Intro}\nOne two \\textbf{three} % hidden words\nfour."), 5)
        XCTAssertEqual(ThesisAssembler.wordCount(""), 0)
    }
}