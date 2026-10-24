//
//  LatexCompilerTests.swift
//  ResearchBase
//
//  Created by Gaurav Khati on 21/10/26.
//


//
//  LatexCompilerTests.swift
//  ResearchBaseTests
//
//  Owner: Agent 24 (tests for LatexCompiler.swift). Log samples were captured
//  from real latexmk / pdflatex runs. Tests that need a TeX installation skip
//  themselves when none is found.
//

import XCTest
@testable import ResearchBase

final class LatexCompilerTests: XCTestCase {

    typealias LC = LatexCompiler

    // MARK: Helpers

    private func makeDraft(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rbA24-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (rel, text) in files {
            let url = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func codes(_ d: [LC.Diagnostic]) -> [String] { d.compactMap { $0.code } }

    // MARK: Engine and settings (L-07, L-08)

    func testEngineStorageValues() {
        XCTAssertEqual(LC.Engine(storageValue: "latexmk-pdflatex"), .pdflatex)
        XCTAssertEqual(LC.Engine(storageValue: "latexmk-xelatex"), .xelatex)
        XCTAssertEqual(LC.Engine(storageValue: "latexmk + lualatex"), .lualatex)
        XCTAssertEqual(LC.Engine(storageValue: "Tectonic"), .tectonic)
        XCTAssertEqual(LC.Engine(storageValue: "something odd"), .pdflatex)
        for e in LC.Engine.allCases { XCTAssertEqual(LC.Engine(storageValue: e.storageValue), e) }
        XCTAssertEqual(LC.Engine.pdflatex.storageValue, "latexmk-pdflatex")   // schema default
    }

    func testDefaultSettingsAreSafe() {
        let s = LC.Settings()
        XCTAssertFalse(s.shellEscape)
        XCTAssertEqual(s.timeoutSeconds, 60)
        XCTAssertEqual(s.effectiveOutputFolder, ".build")
        var bad = LC.Settings()
        for v in ["../x", "/tmp/x", "~/x", "", "."] {
            bad.outputFolder = v
            XCTAssertEqual(bad.effectiveOutputFolder, ".build", v)
        }
        bad.outputFolder = "out/pdf/"
        XCTAssertEqual(bad.effectiveOutputFolder, "out/pdf")
        bad.timeoutSeconds = 0
        XCTAssertEqual(bad.effectiveTimeout, 5)
    }

    func testCommandLines() {
        var s = LC.Settings()
        let a = LC.latexmkArguments(engine: .xelatex, mainFile: "main.tex", settings: s)
        XCTAssertEqual(a.first, "-pdfxe")
        XCTAssertTrue(a.contains("-norc"))
        XCTAssertTrue(a.contains("-latexoption=-no-shell-escape"))
        XCTAssertTrue(a.contains("-outdir=.build"))
        XCTAssertTrue(a.contains("-file-line-error"))
        XCTAssertEqual(a.last, "main.tex")
        s.shellEscape = true
        let b = LC.latexmkArguments(engine: .pdflatex, mainFile: "main.tex", settings: s)
        XCTAssertFalse(b.contains("-norc"))
        XCTAssertTrue(b.contains("-latexoption=-shell-escape"))
        XCTAssertTrue(LC.tectonicArguments(mainFile: "main.tex", settings: s).contains("shell-escape"))
        XCTAssertFalse(LC.tectonicArguments(mainFile: "main.tex", settings: LC.Settings()).contains("shell-escape"))
    }

    // MARK: Log parsing (L-04)

    func testFileLineErrorWithContext() {
        let log = """
        (./main.tex
        ./main.tex:4: Undefined control sequence.
        l.4 Hi \\foo
                    and
        The control sequence at the end of the top line
        """
        let d = LC.parseLog(log)
        XCTAssertEqual(d.count, 1)
        XCTAssertEqual(d[0].severity, .error)
        XCTAssertEqual(d[0].file, "main.tex")
        XCTAssertEqual(d[0].line, 4)
        XCTAssertTrue(d[0].message.contains("\\foo"), d[0].message)
        XCTAssertTrue(d[0].canJump)
        XCTAssertNotNil(d[0].help)
    }

    func testMissingPackageBangFormat() {
        let log = """
        (./main.tex
        ! LaTeX Error: File `nonexistentpkg.sty' not found.

        Type X to quit or <RETURN> to proceed,
        or enter new name. (Default extension: sty)

        Enter file name:
        ! Emergency stop.
        <read *>

        l.2 \\usepackage{nonexistentpkg}
        """
        let d = LC.parseLog(log)
        let e = d.first { $0.missing != nil }
        XCTAssertNotNil(e)
        XCTAssertEqual(e?.missing?.kind, .package)
        XCTAssertEqual(e?.missing?.installCommand, "sudo tlmgr install nonexistentpkg")
        XCTAssertEqual(e?.file, "main.tex")
        XCTAssertEqual(e?.code, "missing-package:nonexistentpkg")
    }

    func testMissingResourceTables() {
        XCTAssertEqual(LC.missingResource(kind: .package, name: "algorithmic.sty").tlmgrPackage, "algorithms")
        XCTAssertEqual(LC.missingResource(kind: .package, name: "tikz").tlmgrPackage, "pgf")
        XCTAssertEqual(LC.missingResource(kind: .documentClass, name: "IEEEtran.cls").tlmgrPackage, "IEEEtran")
        let manual = LC.missingResource(kind: .documentClass, name: "svjour3")
        XCTAssertNil(manual.tlmgrPackage)
        XCTAssertNil(manual.installCommand)
        XCTAssertTrue(manual.explanation.contains("publisher"))
        XCTAssertEqual(LC.missingResource(kind: .bibStyle, name: "plainnat.bst").tlmgrPackage, "natbib")
        XCTAssertNil(LC.missingResource(kind: .font, name: "Foo").installCommand)
    }

    func testMissingImageAndFontAndClass() {
        let log = """
        ./main.tex:5: Package pdftex.def Error: File `figures/nope.png' not found: using draft setting.
        ! LaTeX Error: File `IEEEtranX.cls' not found.
        ! Package fontspec Error: The font "Foo Sans" cannot be found.
        """
        let d = LC.parseLog(log)
        XCTAssertTrue(d.contains { $0.code == "missing-file:figures/nope.png" && $0.line == 5 })
        XCTAssertTrue(d.contains { $0.missing?.kind == .documentClass })
        XCTAssertTrue(d.contains { $0.missing?.kind == .font && $0.missing?.name == "Foo Sans" })
    }

    func testCitationAndReferenceWarnings() {
        let log = """
        Package natbib Warning: Citation `nokey' on page 1 undefined on input line 5.

        LaTeX Warning: Reference `nolabel' on page 1 undefined on input line 6.

        LaTeX Warning: There were undefined references.
        """
        let d = LC.parseLog(log)
        XCTAssertEqual(d.count, 2)
        XCTAssertEqual(d[0].code, "cite-missing:nokey")
        XCTAssertEqual(d[0].line, 5)
        XCTAssertEqual(d[0].category, .citation)
        XCTAssertEqual(d[1].code, "ref-missing:nolabel")
        XCTAssertEqual(d[1].severity, .warning)
    }

    func testWarningIsAttributedToIncludedFile() {
        let log = """
        (./main.tex
        (./chapters/c1.tex

        Package natbib Warning: Citation `k1' on page 1 undefined on input line 1.

        )
        Package natbib Warning: Citation `k2' on page 2 undefined on input line 9.
        )
        """
        let d = LC.parseLog(log)
        XCTAssertEqual(d.count, 2)
        XCTAssertEqual(d[0].file, "chapters/c1.tex")
        XCTAssertEqual(d[1].file, "main.tex")
    }

    func testPackageWarningContinuationAndLayout() {
        let log = """
        Package hyperref Warning: Token not allowed in a PDF string (Unicode):
        (hyperref)                removing `math shift' on input line 12.

        Overfull \\hbox (12.3pt too wide) in paragraph at lines 20--21
        """
        let d = LC.parseLog(log)
        XCTAssertEqual(d.count, 2)
        XCTAssertEqual(d[0].line, 12)
        XCTAssertTrue(d[0].message.hasPrefix("hyperref:"))
        XCTAssertEqual(d[1].category, .layout)
        XCTAssertEqual(d[1].line, 20)
    }

    func testErrorInsideTexmfFileIsMappedToDraft() {
        let log = """
        (./main.tex
        (/usr/share/texlive/tex/latex/tools/x.tex
        /usr/share/texlive/tex/latex/tools/x.tex:38: .
        l.38 \\errmessage{}
        ) )
        """
        let d = LC.parseLog(log)
        XCTAssertEqual(d.count, 1)
        XCTAssertEqual(d[0].file, "main.tex")
        XCTAssertNil(d[0].line)
        XCTAssertFalse(d[0].canJump)
        XCTAssertTrue(d[0].message.hasPrefix("In x.tex"))
    }

    func testEmergencyStopDroppedWhenRealErrorExists() {
        let log = """
        ./main.tex:4: Undefined control sequence.
        ./main.tex:6: Emergency stop.
        ./main.tex:6:  ==> Fatal error occurred, no output PDF file produced!
        """
        let merged = LC.mergeDiagnostics([LC.parseLog(log)])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].line, 4)
    }

    func testBibliographyLog() {
        let blg = """
        I couldn't open style file nostyle.bst
        ---line 3 of file main.aux
        Warning--I didn't find a database entry for "ghost2020"
        I was expecting a `,' or a `}'---line 12 of file refs.bib
        I couldn't open database file nope.bib
        """
        let d = LC.parseBibliographyLog(blg)
        XCTAssertTrue(d.contains { $0.missing?.kind == .bibStyle })
        XCTAssertTrue(d.contains { $0.code == "cite-missing:ghost2020" })
        XCTAssertTrue(d.contains { $0.file == "refs.bib" && $0.line == 12 })
        XCTAssertTrue(d.contains { $0.code == "missing-file:nope.bib" })
    }

    func testLatexmkOutputMaxRuns() {
        let d = LC.parseLatexmkOutput("Latexmk: Maximum runs of pdflatex reached without getting stable files")
        XCTAssertEqual(d.count, 1)
        XCTAssertEqual(d[0].code, "max-runs")
    }

    func testMergeKeepsTheCopyWithALine() {
        let a = LC.Diagnostic(severity: .warning, category: .citation, message: "no line", code: "cite-missing:x")
        let b = LC.Diagnostic(severity: .warning, category: .citation, file: "main.tex", line: 7, message: "with line", code: "cite-missing:x")
        let m = LC.mergeDiagnostics([[a], [b]])
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(m[0].line, 7)
    }

    // MARK: Static checks

    func testBeginEndMismatchHasBothLines() throws {
        let d = try makeDraft(["main.tex": "\\documentclass{article}\n\\begin{document}\n\\begin{itemize}\n\\item a\n\\end{enumerate}\n\\end{document}\n"])
        let out = LC.staticChecks(draftFolder: d, mainFile: "main.tex")
        let e = out.first { $0.code?.hasPrefix("mismatch") == true }
        XCTAssertNotNil(e)
        XCTAssertTrue(e!.message.contains("line 5"))
        XCTAssertTrue(e!.message.contains("line 3"))
        XCTAssertEqual(e!.line, 5)
    }

    func testMissingEndDocumentAndUnclosedBrace() throws {
        let d = try makeDraft(["main.tex": "\\documentclass{article}\n\\begin{document}\n\\textbf{oops\nText.\n"])
        let c = codes(LC.staticChecks(draftFolder: d, mainFile: "main.tex"))
        XCTAssertTrue(c.contains("missing-end-document"))
        XCTAssertTrue(c.contains { $0.hasPrefix("open-brace") })
    }

    func testExtraClosingBrace() throws {
        let d = try makeDraft(["main.tex": "\\documentclass{article}\n\\begin{document}\nHello }\n\\end{document}\n"])
        let out = LC.staticChecks(draftFolder: d, mainFile: "main.tex")
        XCTAssertTrue(out.contains { $0.code?.hasPrefix("extra-brace") == true && $0.line == 3 })
    }

    func testNoDocumentclass() throws {
        let d = try makeDraft(["main.tex": "Hello\n"])
        XCTAssertTrue(codes(LC.staticChecks(draftFolder: d, mainFile: "main.tex")).contains("no-documentclass"))
    }

    func testNoFalseAlarmsFromMacrosCommentsAndVerbatim() throws {
        let tex = """
        \\documentclass{article}
        \\newcommand{\\bi}{\\begin{itemize}}
        \\newcommand{\\ei}{\\end{itemize}}
        \\def\\ba{\\begin{align}}
        \\begin{document}
        % \\begin{figure} in a comment {
        Escaped \\{ and \\} and 50\\% fine.
        \\begin{verbatim}
        \\begin{nothing} { unbalanced
        \\end{verbatim}
        Inline \\verb|{| works.
        \\begin{itemize}\\item a\\end{itemize}
        \\end{document}
        """
        let d = try makeDraft(["main.tex": tex])
        let errs = LC.staticChecks(draftFolder: d, mainFile: "main.tex").filter { $0.severity == .error }
        XCTAssertTrue(errs.isEmpty, "\(errs)")
    }

    func testMissingGraphicAndGraphicsPath() throws {
        let tex = "\\documentclass{article}\\usepackage{graphicx}\\graphicspath{{img/}}\n\\begin{document}\n\\includegraphics{a}\n\\includegraphics{missing.png}\n\\end{document}\n"
        let d = try makeDraft(["main.tex": tex, "img/a.png": "x"])
        let out = LC.staticChecks(draftFolder: d, mainFile: "main.tex")
        XCTAssertFalse(out.contains { $0.code == "missing-file:a" })
        XCTAssertTrue(out.contains { $0.code == "missing-file:missing.png" && $0.line == 4 })
    }

    func testCitationsAgainstLibraryKeys() throws {
        let tex = "\\documentclass{article}\n\\begin{document}\n\\cite{known,ghost}\\nocite{*}\\citestyle{plain}\n\\end{document}\n"
        let d = try makeDraft(["main.tex": tex])
        let out = LC.staticChecks(draftFolder: d, mainFile: "main.tex", libraryCitationKeys: ["known"])
        XCTAssertEqual(codes(out).filter { $0.hasPrefix("cite-missing") }, ["cite-missing:ghost"])
        XCTAssertEqual(out.first { $0.code == "cite-missing:ghost" }?.severity, .warning)
        // Without library keys and without a .bib file, the check is skipped.
        XCTAssertTrue(LC.staticChecks(draftFolder: d, mainFile: "main.tex").filter { $0.category == .citation }.isEmpty)
    }

    func testCitationsFallBackToBibFile() throws {
        let tex = "\\documentclass{article}\n\\begin{document}\n\\cite{in_bib,not_in_bib}\n\\bibliography{refs}\n\\end{document}\n"
        let d = try makeDraft(["main.tex": tex, "refs.bib": "@article{in_bib,\n title={T}}\n"])
        let c = codes(LC.staticChecks(draftFolder: d, mainFile: "main.tex"))
        XCTAssertEqual(c.filter { $0.hasPrefix("cite-missing") }, ["cite-missing:not_in_bib"])
        XCTAssertFalse(c.contains("missing-file:refs.bib"))
    }

    func testReferencesAndFollowedInputs() throws {
        let main = "\\documentclass{article}\n\\begin{document}\n\\input{chapters/c1}\nSee \\ref{sec:a} and \\cref{sec:b,sec:ghost}.\n\\end{document}\n"
        let c1 = "\\section{A}\\label{sec:a}\n\\begin{itemize}\n"
        let d = try makeDraft(["main.tex": main, "chapters/c1.tex": c1, "other.tex": "\\label{sec:b}"])
        let out = LC.staticChecks(draftFolder: d, mainFile: "main.tex")
        XCTAssertEqual(codes(out).filter { $0.hasPrefix("ref-missing") }, ["ref-missing:sec:ghost"])
        // The unclosed itemize is found in the included file, with that file's name.
        XCTAssertTrue(out.contains { $0.file == "chapters/c1.tex" && $0.code?.hasPrefix("unclosed") == true })
    }

    func testMissingMainFile() throws {
        let d = try makeDraft([:])
        XCTAssertEqual(codes(LC.staticChecks(draftFolder: d, mainFile: "main.tex")), ["missing-main"])
    }

    // MARK: Build behaviour that needs no TeX

    func testBuildRefusesWhenDiskIsTooFull() async throws {
        let d = try makeDraft(["main.tex": "\\documentclass{article}\\begin{document}x\\end{document}"])
        var s = LC.Settings()
        s.minimumFreeBytes = Int64.max
        let r = await LC().build(draftFolder: d, settings: s)
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r.diagnostics.first?.code, "disk-space")
        XCTAssertFalse(FileManager.default.fileExists(atPath: d.appendingPathComponent(".build").path))
    }

    func testBuildWithMissingMainFile() async throws {
        let d = try makeDraft([:])
        let r = await LC().build(draftFolder: d)
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r.diagnostics.first?.code, "missing-main")
    }

    func testBuildRejectsPathTricks() async throws {
        let d = try makeDraft(["main.tex": "x"])
        let r = await LC().build(draftFolder: d, mainFile: "../main.tex")
        XCTAssertEqual(r.diagnostics.first?.code, "bad-main")
    }

    func testCleanBuildFilesKeepsPDF() throws {
        let d = try makeDraft([".build/main.aux": "a", ".build/main.log": "l", ".build/main.bbl": "b",
                               ".build/main.pdf": "p", ".build/main.synctex.gz": "s", ".build/chapters/c.aux": "c"])
        XCTAssertEqual(try LC.cleanBuildFiles(draftFolder: d), 4)
        XCTAssertTrue(FileManager.default.fileExists(atPath: d.appendingPathComponent(".build/main.pdf").path))
        XCTAssertEqual(try LC.cleanBuildFiles(draftFolder: d, includingPDF: true), 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: d.appendingPathComponent(".build").path))
    }

    func testMirrorSubfolders() throws {
        let d = try makeDraft(["main.tex": "x", "chapters/c1.tex": "y", "figures/a.png": "z"])
        let out = d.appendingPathComponent(".build", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        LC.mirrorSubfolders(draft: d, outDir: out)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("chapters").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("figures").path))
    }

    func testDiskSpaceCheck() {
        let tmp = FileManager.default.temporaryDirectory
        XCTAssertTrue(LC.hasEnoughDiskSpace(at: tmp, minimumBytes: 1))
        XCTAssertFalse(LC.hasEnoughDiskSpace(at: tmp, minimumBytes: Int64.max))
    }

    // MARK: Running commands

    func testRunCommandCapturesOutput() async {
        let r = await LC.runCommand(executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["hello"], timeout: 10)
        XCTAssertEqual(r.exitCode, 0)
        XCTAssertEqual(r.output.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
        XCTAssertFalse(r.timedOut)
    }

    func testRunCommandTimesOut() async {
        let r = await LC.runCommand(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["20"], timeout: 0.5)
        XCTAssertTrue(r.timedOut)
        XCTAssertLessThan(r.duration, 10)
    }

    func testRunCommandCancels() async {
        let task = Task { await LC.runCommand(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["20"], timeout: 60) }
        try? await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        let r = await task.value
        XCTAssertTrue(r.cancelled)
        XCTAssertLessThan(r.duration, 10)
    }

    func testRunCommandReportsLaunchFailure() async {
        let r = await LC.runCommand(executable: URL(fileURLWithPath: "/nonexistent/tool"), arguments: [], timeout: 5)
        XCTAssertNotNil(r.launchError)
    }

    // MARK: Real builds (skipped when no TeX is installed)

    func testRealBuildSucceedsAndBuildsIncludes() async throws {
        let inst = LC.locateInstallation()
        try XCTSkipUnless(inst.hasSystemTeX, "No TeX installation on this machine")
        let main = "\\documentclass{article}\n\\begin{document}\nHello.\n\\include{chapters/c2}\n\\end{document}\n"
        let d = try makeDraft(["main.tex": main, "chapters/c2.tex": "Chapter two.\n"])
        let r = await LC().build(draftFolder: d)
        XCTAssertTrue(r.ok, "\(r.diagnostics)\n\(r.rawOutput)")
        XCTAssertNotNil(r.pdfURL)
        XCTAssertEqual(r.pages, 2)
        XCTAssertEqual(r.errorCount, 0)
        XCTAssertNotNil(r.synctexURL)
    }

    func testRealBuildReportsClickableError() async throws {
        let inst = LC.locateInstallation()
        try XCTSkipUnless(inst.hasSystemTeX, "No TeX installation on this machine")
        let main = "\\documentclass{article}\n\\begin{document}\nHi \\foo here\n\\end{document}\n"
        let d = try makeDraft(["main.tex": main])
        let r = await LC().build(draftFolder: d)
        XCTAssertFalse(r.ok)
        let e = r.diagnostics.first { $0.severity == .error }
        XCTAssertEqual(e?.file, "main.tex")
        XCTAssertEqual(e?.line, 3)
        XCTAssertTrue(e?.canJump ?? false)
    }

    func testRealBuildExplainsMissingPackage() async throws {
        let inst = LC.locateInstallation()
        try XCTSkipUnless(inst.hasSystemTeX && inst.kpsewhich != nil, "No TeX installation on this machine")
        let main = "\\documentclass{article}\n\\usepackage{rbA24nopackage}\n\\begin{document}x\\end{document}\n"
        let d = try makeDraft(["main.tex": main])
        let r = await LC().build(draftFolder: d)
        XCTAssertFalse(r.ok)
        let m = r.diagnostics.filter { $0.code == "missing-package:rba24nopackage" }
        XCTAssertEqual(m.count, 1)   // preflight and log reports are merged
        XCTAssertEqual(m.first?.line, 2)
        XCTAssertNotNil(m.first?.missing?.installCommand)
    }

    func testRealBuildTimeout() async throws {
        let inst = LC.locateInstallation()
        try XCTSkipUnless(inst.hasSystemTeX, "No TeX installation on this machine")
        // An endless macro loop.
        let main = "\\documentclass{article}\n\\begin{document}\n\\def\\a{\\a\\a}\\a\n\\end{document}\n"
        let d = try makeDraft(["main.tex": main])
        var s = LC.Settings()
        s.timeoutSeconds = 5
        let r = await LC().build(draftFolder: d, settings: s)
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.timedOut || r.errorCount > 0)
    }
}