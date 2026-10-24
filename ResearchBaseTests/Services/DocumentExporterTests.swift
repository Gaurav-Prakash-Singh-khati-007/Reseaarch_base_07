//
//  DocumentExporterTests.swift
//  ResearchBase
//
//  Created by Gaurav Khati on 21/10/26.
//


//
//  DocumentExporterTests.swift
//  ResearchBaseTests
//
//  Owner: Agent 35 · Feature: F-40
//

import XCTest
@testable import ResearchBase

@MainActor
final class DocumentExporterTests: XCTestCase {

    // MARK: Helpers

    private static let tinyPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!

    private func makeDraft(_ files: [String: Data]) throws -> URL {
        let folder = try TestSupport.makeTempDirectory(self).appendingPathComponent("draft", isDirectory: true)
        for (name, data) in files {
            let url = folder.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        return folder
    }

    private func text(_ string: String) -> Data { Data(string.utf8) }

    private func output(_ folder: URL, _ name: String) -> URL {
        folder.deletingLastPathComponent().appendingPathComponent(name)
    }

    /// Reads a stored-only .zip (what `ZipWriter` produces) and checks every CRC.
    private func unzip(_ url: URL) throws -> [String: Data] {
        let data = [UInt8](try Data(contentsOf: url))

        func u16(_ at: Int) -> Int { Int(data[at]) | Int(data[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }

        var end = data.count - 22
        while end >= 0, u32(end) != 0x06054b50 { end -= 1 }
        XCTAssertGreaterThanOrEqual(end, 0, "end-of-directory record")

        let count = u16(end + 10)
        var offset = u32(end + 16)
        var files: [String: Data] = [:]

        for _ in 0..<count {
            XCTAssertEqual(u32(offset), 0x02014b50)
            let crc = UInt32(u32(offset + 16))
            let size = u32(offset + 24)
            let nameLength = u16(offset + 28)
            let extraLength = u16(offset + 30)
            let commentLength = u16(offset + 32)
            let local = u32(offset + 42)
            let name = String(decoding: data[(offset + 46)..<(offset + 46 + nameLength)], as: UTF8.self)

            XCTAssertEqual(u32(local), 0x04034b50)
            let start = local + 30 + u16(local + 26) + u16(local + 28)
            let content = Data(data[start..<(start + size)])
            XCTAssertEqual(ZipWriter.crc32(content), crc, "CRC of \(name)")

            files[name] = content
            offset += 46 + nameLength + extraLength + commentLength
        }
        return files
    }

    private let paper = """
    \\documentclass{article}
    \\usepackage{amsmath}
    \\title{Federated Drift}
    \\author{Anna M\\"uller \\and Brendan McMahan}
    \\begin{document}
    \\maketitle
    % a comment that must disappear
    \\begin{abstract}
    We study drift.
    \\end{abstract}
    \\section{Introduction}\\label{sec:intro}
    Models \\textbf{drift} apart~\\cite{mcmahan2017,lee2019}; see Section~\\ref{sec:intro} and Eq.~\\eqref{eq:loss}.\\footnote{A short note.}
    Inline math $x^2 + \\alpha$ here.

    \\begin{equation}\\label{eq:loss}
    L = \\frac{1}{n}\\sum_{i=1}^{n} \\ell_i
    \\end{equation}

    \\subsection{Details}
    \\begin{itemize}
    \\item First point
    \\item Second \\emph{point}
    \\end{itemize}
    \\begin{enumerate}
    \\item One
    \\item Two
    \\end{enumerate}

    \\begin{table}
    \\caption{Results}
    \\begin{tabular}{lr}
    \\hline
    Method & Accuracy \\\\
    \\hline
    FedAvg & 85 \\\\
    \\end{tabular}
    \\end{table}

    \\begin{figure}
    \\includegraphics[width=\\linewidth]{figures/plot}
    \\caption{Accuracy over rounds}
    \\end{figure}

    \\bibliography{refs}
    \\end{document}
    """

    private let citations: CitationProvider = { key in
        switch key {
        case "mcmahan2017": return CitationText(key: key, author: "McMahan et al.", year: "2017", inline: "McMahan et al., 2017", reference: "McMahan, B. (2017). Communication-efficient learning.")
        case "lee2019": return CitationText(key: key, author: "Lee", year: "2019", inline: "Lee, 2019", reference: "Lee, K. (2019). On drift.")
        default: return nil
        }
    }

    // MARK: LaTeX project zip

    func testZipKeepsSourcesAndLeavesBuildLeftoversOut() throws {
        let folder = try makeDraft([
            "main.tex": text("\\documentclass{article}"), "refs.bib": text("@article{a}"),
            "figures/plot.png": Self.tinyPNG, "chapters/one.tex": text("one"),
            "main.aux": text("x"), "main.log": text("x"), "main.pdf": text("pdf"),
            "build/main.pdf": text("pdf"), ".hidden": text("x"), "main.bbl": text("bbl")
        ])
        let target = output(folder, "out.zip")

        let report = try DocumentExporter().export(folder: folder, title: "T", format: .latexZip, to: target)
        XCTAssertEqual(report.outputURL, target)

        let files = try unzip(target)
        XCTAssertEqual(Set(files.keys), ["main.tex", "refs.bib", "figures/plot.png", "chapters/one.tex", "main.bbl"])
        XCTAssertEqual(files["main.tex"], text("\\documentclass{article}"))
        XCTAssertEqual(files["figures/plot.png"], Self.tinyPNG)
    }

    func testMissingMainFileAndExistingDestination() throws {
        let folder = try makeDraft(["other.tex": text("x")])
        let target = output(folder, "out.zip")

        XCTAssertThrowsError(try DocumentExporter().export(folder: folder, title: "T", format: .latexZip, to: target)) {
            XCTAssertEqual($0 as? DocumentExportError, .mainFileMissing("main.tex"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path), "no half-written file")

        try text("old").write(to: target)
        let folder2 = try makeDraft(["main.tex": text("x")])
        XCTAssertThrowsError(try DocumentExporter().export(folder: folder2, title: "T", format: .latexZip, to: target))
        XCTAssertNoThrow(try DocumentExporter().export(folder: folder2, title: "T", format: .latexZip, to: target, overwrite: true))
        XCTAssertNotNil(try unzip(target)["main.tex"])
    }

    // MARK: PDF

    func testPDFCopiesTheLastBuild() throws {
        let folder = try makeDraft(["main.tex": text("x")])
        let target = output(folder, "out.pdf")

        XCTAssertThrowsError(try DocumentExporter().export(folder: folder, title: "T", format: .pdf, to: target)) {
            XCTAssertEqual($0 as? DocumentExportError, .noBuild)
        }

        try FileManager.default.createDirectory(at: folder.appendingPathComponent("build"), withIntermediateDirectories: true)
        try text("%PDF built").write(to: folder.appendingPathComponent("build/main.pdf"))

        try DocumentExporter().export(folder: folder, title: "T", format: .pdf, to: target)
        XCTAssertEqual(try Data(contentsOf: target), text("%PDF built"))
        XCTAssertEqual(DocumentExporter.findLastBuild(folder: folder, mainFile: "main.tex")?.lastPathComponent, "main.pdf")
    }

    // MARK: Markdown and plain text

    func testMarkdownExport() throws {
        let folder = try makeDraft(["main.tex": text(paper)])
        let target = output(folder, "out.md")

        let report = try DocumentExporter(citations: citations).export(folder: folder, title: "Fallback", format: .markdown, to: target)
        let md = try String(contentsOf: target, encoding: .utf8)

        XCTAssertTrue(md.hasPrefix("# Federated Drift\n"))
        XCTAssertTrue(md.contains("Anna Müller, Brendan McMahan"))
        XCTAssertTrue(md.contains("## Introduction"))
        XCTAssertTrue(md.contains("### Details"))
        XCTAssertTrue(md.contains("**drift**"))
        XCTAssertTrue(md.contains("[@mcmahan2017; @lee2019]"))
        XCTAssertTrue(md.contains("$x^2 + \\alpha$"))
        XCTAssertTrue(md.contains("$$\nL = \\frac{1}{n}\\sum_{i=1}^{n} \\ell_i \\tag{1}\n$$"))
        XCTAssertTrue(md.contains("- First point"))
        XCTAssertTrue(md.contains("1. One"))
        XCTAssertTrue(md.contains("| Method | Accuracy |"))
        XCTAssertTrue(md.contains("![Accuracy over rounds](figures/plot)"))
        XCTAssertTrue(md.contains("[^1]: A short note."))
        XCTAssertTrue(md.contains("Section 1") || md.contains("see Section 1"), "\\ref resolves to the section number")
        XCTAssertTrue(md.contains("(1)"), "\\eqref resolves to (1)")
        XCTAssertFalse(md.contains("a comment that must disappear"))
        XCTAssertEqual(report.citedKeys, ["mcmahan2017", "lee2019"])
    }

    func testPlainTextExportHasNoMarkup() throws {
        let folder = try makeDraft(["main.tex": text(paper)])
        let target = output(folder, "out.txt")

        try DocumentExporter(citations: citations).export(folder: folder, title: "Fallback", format: .plainText, to: target)
        let txt = try String(contentsOf: target, encoding: .utf8)

        XCTAssertTrue(txt.hasPrefix("Federated Drift\n"))
        XCTAssertTrue(txt.contains("(McMahan et al., 2017; Lee, 2019)"))
        XCTAssertTrue(txt.contains("1 Introduction"))
        XCTAssertTrue(txt.contains("1.1 Details"))
        XCTAssertTrue(txt.contains("x^2 + α"))
        XCTAssertTrue(txt.contains("L = 1/n∑_(i = 1)^n ℓ_i"), txt)
        XCTAssertFalse(txt.contains("\\textbf"))
        XCTAssertFalse(txt.contains("**"))
        XCTAssertTrue(txt.contains("References"))
        XCTAssertTrue(txt.contains("Lee, K. (2019). On drift."))
    }

    func testMissingCitationsAreReportedNotFatal() throws {
        let folder = try makeDraft(["main.tex": text("\\begin{document}Known~\\cite{lee2019} and unknown~\\citep{ghost}.\\end{document}")])
        let target = output(folder, "out.txt")

        let report = try DocumentExporter(citations: citations).export(folder: folder, title: "T", format: .plainText, to: target)
        let txt = try String(contentsOf: target, encoding: .utf8)

        XCTAssertTrue(txt.contains("(ghost)"))
        XCTAssertTrue(report.warnings.contains { $0.contains("ghost") })
        XCTAssertFalse(report.warnings.contains { $0.contains("lee2019") })
    }

    func testInputAndChapterFilesAreExpanded() throws {
        let folder = try makeDraft([
            "main.tex": text("\\begin{document}\n\\input{chapters/one}\n\\include{chapters/two}\n\\end{document}"),
            "chapters/one.tex": text("\\chapter{Start}\nHello.\n\\section{Inner}\nText."),
            "chapters/two.tex": text("\\chapter{End}\nBye.")
        ])
        let target = output(folder, "out.md")

        try DocumentExporter().export(folder: folder, title: "Thesis", format: .markdown, to: target)
        let md = try String(contentsOf: target, encoding: .utf8)

        XCTAssertTrue(md.contains("## Start"))
        XCTAssertTrue(md.contains("### Inner"))
        XCTAssertTrue(md.contains("## End"))
        XCTAssertTrue(md.contains("Hello.") && md.contains("Bye."))
    }

    func testUnsupportedThingsAreListedAsWarnings() throws {
        let folder = try makeDraft(["main.tex": text("\\begin{document}\\begin{tikzpicture}draw\\end{tikzpicture}\\frobnicate{kept}\\end{document}")])
        let report = try DocumentExporter().export(folder: folder, title: "T", format: .plainText, to: output(folder, "o.txt"))

        XCTAssertTrue(report.warnings.contains { $0.contains("tikzpicture") })
        XCTAssertTrue(report.warnings.contains { $0.contains("frobnicate") })
    }

    // MARK: Word

    func testDocxIsAValidPackageWithEquationsFootnotesAndPictures() throws {
        let folder = try makeDraft(["main.tex": text(paper), "figures/plot.png": Self.tinyPNG])
        let target = output(folder, "out.docx")

        let report = try DocumentExporter(citations: citations).export(folder: folder, title: "Fallback", format: .docx, to: target)
        let parts = try unzip(target)

        for name in ["[Content_Types].xml", "_rels/.rels", "word/document.xml", "word/_rels/document.xml.rels",
                     "word/styles.xml", "word/numbering.xml", "word/settings.xml", "word/footnotes.xml", "docProps/core.xml"] {
            XCTAssertNotNil(parts[name], name)
        }

        // Every XML part is well-formed.
        for (name, data) in parts where name.hasSuffix(".xml") || name.hasSuffix(".rels") {
            let parser = XMLParser(data: data)
            XCTAssertTrue(parser.parse(), "\(name): \(parser.parserError?.localizedDescription ?? "")")
        }

        let document = String(decoding: parts["word/document.xml"]!, as: UTF8.self)
        XCTAssertTrue(document.contains("<w:pStyle w:val=\"Title\"/>"))
        XCTAssertTrue(document.contains("<w:pStyle w:val=\"Heading1\"/>"))
        XCTAssertTrue(document.contains("Introduction"))
        XCTAssertTrue(document.contains("<m:sSup>"), "x^2 becomes a Word equation")
        XCTAssertTrue(document.contains("<m:f>") && document.contains("<m:nary>"), "fraction and sum")
        XCTAssertTrue(document.contains("(McMahan et al., 2017; Lee, 2019)"))
        XCTAssertTrue(document.contains("<w:tbl>"))
        XCTAssertTrue(document.contains("<w:footnoteReference w:id=\"1\"/>"))
        XCTAssertTrue(document.contains("r:embed=\"rIdImg1\""))
        XCTAssertTrue(document.contains("Figure 1. "))
        XCTAssertTrue(document.contains("Lee, K. (2019). On drift."), "reference list")

        XCTAssertEqual(parts["word/media/image1.png"], Self.tinyPNG)
        XCTAssertTrue(String(decoding: parts["word/footnotes.xml"]!, as: UTF8.self).contains("A short note."))
        XCTAssertTrue(String(decoding: parts["word/numbering.xml"]!, as: UTF8.self).contains("w:numId=\"2\""), "numbered list gets its own counter")
        XCTAssertFalse(report.warnings.contains { $0.contains("figure") }, "\(report.warnings)")
    }

    func testDocxReportsFiguresItCannotEmbed() throws {
        let folder = try makeDraft([
            "main.tex": text("\\begin{document}\\begin{figure}\\includegraphics{a}\\includegraphics{b}\\includegraphics{missing}\\caption{C}\\end{figure}\\end{document}"),
            "a.pdf": text("%PDF"), "b.png": Self.tinyPNG
        ])
        let report = try DocumentExporter().export(folder: folder, title: "T", format: .docx, to: output(folder, "o.docx"))

        XCTAssertTrue(report.warnings.contains { $0.contains("missing") })
        XCTAssertTrue(report.warnings.contains { $0.contains("“a”") && $0.contains("not embedded") }, "\(report.warnings)")
        XCTAssertFalse(report.warnings.contains { $0.contains("“b”") })
    }

    // MARK: Names and library

    func testSuggestedFileNames() {
        XCTAssertEqual(DocumentExporter.suggestedFileName(title: "My: paper/draft?", format: .docx), "My paper draft.docx")
        XCTAssertEqual(DocumentExporter.suggestedFileName(title: "   ", format: .markdown), "Draft.md")
        XCTAssertEqual(DocumentExporter.suggestedFileName(title: "T", format: .latexZip), "T.zip")
        XCTAssertLessThanOrEqual(DocumentExporter.suggestedFileName(title: String(repeating: "a", count: 300), format: .pdf).count, 84)
    }

    func testExportingADraftFromTheLibraryUsesItsFolderAndTheExportsFolder() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        let item = try ModelTestSupport.item(model)
        let key = try XCTUnwrap(try model.items.fetch(id: item.id)?.citationKey)

        let id = try ModelTestSupport.insertDraft(model)
        let folder = try model.library.url(forRelativePath: "drafts/\(id)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try text("\\begin{document}Learning~\\cite{\(key)}.\\end{document}").write(to: folder.appendingPathComponent("main.tex"))

        let exporter = DocumentExporter(citations: DocumentExporter.libraryCitations(model: model))
        let first = try exporter.export(draftID: id, model: model, format: .plainText)
        let second = try exporter.export(draftID: id, model: model, format: .plainText)

        XCTAssertTrue(first.outputURL.path.hasPrefix(model.library.exportsURL.path))
        XCTAssertEqual(first.outputURL.lastPathComponent, "My paper.txt")
        XCTAssertEqual(second.outputURL.lastPathComponent, "My paper 2.txt", "never overwrites by accident")

        let out = try String(contentsOf: first.outputURL, encoding: .utf8)
        XCTAssertTrue(out.contains("(McMahan, 2017)"), out)
        XCTAssertTrue(out.contains("McMahan, B. (2017)"), out)
        XCTAssertTrue(first.warnings.isEmpty, "\(first.warnings)")

        XCTAssertThrowsError(try exporter.export(draftID: "missing", model: model, format: .markdown)) {
            XCTAssertEqual($0 as? DocumentExportError, .draftNotFound("missing"))
        }
    }

    func testCRC32MatchesTheStandardCheckValue() {
        XCTAssertEqual(ZipWriter.crc32(Data("123456789".utf8)), 0xCBF43926)
    }
}