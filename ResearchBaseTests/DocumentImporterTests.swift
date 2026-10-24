//
//  DocumentImporterTests.swift
//  ResearchBase
//
//  Created by Gaurav Khati on 21/10/26.
//


//
//  DocumentImporterTests.swift
//  ResearchBaseTests
//
//  Owner: Agent 34 · Features: F-40
//

import XCTest
@testable import ResearchBase

final class DocumentImporterTests: XCTestCase {

    private let importer = DocumentImporter()

    // MARK: Helpers

    private func tempDir() throws -> URL {
        try TestSupport.makeTempDirectory(self)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    private func zip(_ folder: URL, as name: String) throws -> URL {
        let output = folder.deletingLastPathComponent().appendingPathComponent(name)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--norsrc", folder.path, output.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return output
    }

    private func warnings(_ result: DocumentImportResult) -> [String] {
        result.issues.filter { $0.level == .warning }.map(\.message)
    }

    // MARK: Basics

    func testKindAndUnsupportedAndMissingFiles() throws {
        XCTAssertEqual(DocumentImporter.kind(of: URL(fileURLWithPath: "/x/Paper.TEX")), .tex)
        XCTAssertEqual(DocumentImporter.kind(of: URL(fileURLWithPath: "/x/a.docx")), .docx)
        XCTAssertNil(DocumentImporter.kind(of: URL(fileURLWithPath: "/x/a.doc")))

        let dir = try tempDir()
        let old = dir.appendingPathComponent("old.doc")
        try write("x", to: old)
        XCTAssertThrowsError(try importer.preview(old)) { XCTAssertEqual($0 as? DocumentImportError, .unsupportedType("doc")) }
        XCTAssertThrowsError(try importer.preview(dir.appendingPathComponent("nope.tex")))
    }

    func testEscapeLatex() {
        XCTAssertEqual(DocumentImporter.escapeLatex("50% of R&D_x #1 {a} ~ ^"),
                       "50\\% of R\\&D\\_x \\#1 \\{a\\} \\textasciitilde{} \\textasciicircum{}")
        XCTAssertEqual(DocumentImporter.escapeLatex("a\u{00A0}b"), "a~b")
    }

    // MARK: .tex

    func testTexImportBringsReferencedFilesAndListsMissingOnes() throws {
        let dir = try tempDir()
        try write("""
        \\documentclass{article}
        \\title{Client {Drift}}
        % \\includegraphics{figures/commented.png}
        \\begin{document}
        Hello world.
        \\includegraphics{figures/a}
        \\includegraphics{figures/missing.png}
        \\input{sections/intro}
        \\input{../outside}
        \\bibliographystyle{plainnat}
        \\bibliography{refs}
        \\end{document}
        """, to: dir.appendingPathComponent("paper.tex"))
        try write("png", to: dir.appendingPathComponent("figures/a.png"))
        try write("@article{k, title={T}}", to: dir.appendingPathComponent("refs.bib"))
        try write("Intro \\includegraphics{figures/b.pdf}", to: dir.appendingPathComponent("sections/intro.tex"))
        try write("pdf", to: dir.appendingPathComponent("figures/b.pdf"))
        try write("not mine", to: dir.appendingPathComponent("figures/unrelated.png"))

        let destination = try tempDir().appendingPathComponent("draft")
        let result = try importer.importDocument(from: dir.appendingPathComponent("paper.tex"), into: destination)

        XCTAssertEqual(result.kind, .tex)
        XCTAssertEqual(result.mainFile, "main.tex")
        XCTAssertEqual(result.title, "Client Drift")
        XCTAssertEqual(result.files, ["figures/a.png", "figures/b.pdf", "main.tex", "refs.bib", "sections/intro.tex"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("figures/b.pdf").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("figures/unrelated.png").path))

        let messages = warnings(result).joined(separator: "\n")
        XCTAssertTrue(messages.contains("figures/missing.png"))
        XCTAssertTrue(messages.contains("../outside"))
        XCTAssertFalse(messages.contains("commented.png"))
        XCTAssertTrue(result.wordCount >= 2)
    }

    func testTexThatIsNotUTF8IsNotedAndSavedAsUTF8() throws {
        let dir = try tempDir()
        var bytes = Data("\\documentclass{article}\\begin{document}caf".utf8)
        bytes.append(0xE9)
        bytes.append(Data("\\end{document}".utf8))
        let file = dir.appendingPathComponent("old.tex")
        try bytes.write(to: file)

        let destination = try tempDir().appendingPathComponent("draft")
        let result = try importer.importDocument(from: file, into: destination)

        XCTAssertTrue(result.issues.contains { $0.message.contains("Latin-1") })
        XCTAssertEqual(read(destination.appendingPathComponent("main.tex"))?.contains("café"), true)
    }

    // MARK: Writing into the draft folder

    func testPreviewWritesNothingAndOverwriteRulesAreKept() throws {
        let dir = try tempDir()
        let source = dir.appendingPathComponent("p.tex")
        try write("\\documentclass{article}\\begin{document}New text\\end{document}", to: source)

        let destination = try tempDir().appendingPathComponent("draft")
        try write("OLD", to: destination.appendingPathComponent("main.tex"))
        try write("keep me", to: destination.appendingPathComponent("refs.bib"))

        let preview = try importer.preview(source)
        XCTAssertEqual(preview.files, ["main.tex"])
        XCTAssertEqual(read(destination.appendingPathComponent("main.tex")), "OLD")

        XCTAssertThrowsError(try importer.importDocument(from: source, into: destination)) {
            XCTAssertEqual($0 as? DocumentImportError, .wouldOverwrite("main.tex"))
        }
        XCTAssertEqual(read(destination.appendingPathComponent("main.tex")), "OLD")

        try importer.importDocument(from: source, into: destination, overwrite: true)
        XCTAssertEqual(read(destination.appendingPathComponent("main.tex"))?.contains("New text"), true)
        XCTAssertEqual(read(destination.appendingPathComponent("refs.bib")), "keep me", "files not in the import are untouched")
    }

    func testAFailedCopyLeavesTheDestinationAsItWas() throws {
        let dir = try tempDir()
        let project = dir.appendingPathComponent("proj", isDirectory: true)
        try write("\\documentclass{article}", to: project.appendingPathComponent("main.tex"))
        try write("x", to: project.appendingPathComponent("chapters/one.tex"))
        try write("x", to: project.appendingPathComponent("figures/x.png"))
        let archive = try zip(project, as: "proj.zip")

        let destination = try tempDir().appendingPathComponent("draft")
        try write("OLD", to: destination.appendingPathComponent("main.tex"))
        try write("i am a file, not a folder", to: destination.appendingPathComponent("figures"))   // blocks figures/x.png

        XCTAssertThrowsError(try importer.importDocument(from: archive, into: destination, overwrite: true))
        XCTAssertEqual(read(destination.appendingPathComponent("main.tex")), "OLD")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("chapters/one.tex").path))
    }

    // MARK: .zip

    func testZipKeepsLayoutFindsMainFileAndSkipsLeftovers() throws {
        let dir = try tempDir()
        let project = dir.appendingPathComponent("MyPaper", isDirectory: true)
        try write("\\documentclass{article}\\title{Zip Paper}\\begin{document}\\input{chapters/one}\\end{document}",
                  to: project.appendingPathComponent("main.tex"))
        try write("Chapter one text", to: project.appendingPathComponent("chapters/one.tex"))
        try write("png", to: project.appendingPathComponent("figures/x.png"))
        try write("aux", to: project.appendingPathComponent("main.aux"))
        try write("log", to: project.appendingPathComponent("main.log"))
        try write("junk", to: project.appendingPathComponent(".DS_Store"))
        let archive = try zip(project, as: "MyPaper.zip")

        let destination = try tempDir().appendingPathComponent("draft")
        let result = try importer.importDocument(from: archive, into: destination)

        XCTAssertEqual(result.kind, .zip)
        XCTAssertEqual(result.title, "Zip Paper")
        XCTAssertEqual(result.mainFile, "main.tex")
        XCTAssertEqual(result.files, ["chapters/one.tex", "figures/x.png", "main.tex"])
        XCTAssertTrue(result.issues.contains { $0.message.contains("2 build files") })
        XCTAssertTrue(warnings(result).isEmpty)
    }

    func testZipMainFileChoiceAndMissingFiles() throws {
        let dir = try tempDir()
        let project = dir.appendingPathComponent("p", isDirectory: true)
        try write("\\documentclass{article}\\begin{document}\\includegraphics{figures/lost.png}\\end{document}",
                  to: project.appendingPathComponent("thesis.tex"))
        try write("\\documentclass{article}", to: project.appendingPathComponent("old/draft.tex"))
        let archive = try zip(project, as: "p.zip")

        let result = try importer.preview(archive)
        XCTAssertEqual(result.mainFile, "thesis.tex", "the shallowest file with \\documentclass")
        XCTAssertTrue(result.issues.contains { $0.level == .note && $0.message.contains("Several files") })
        XCTAssertTrue(warnings(result).contains { $0.contains("figures/lost.png") })
    }

    func testZipWithoutDocumentclassWarnsAndWithoutTexFails() throws {
        let dir = try tempDir()
        let fragments = dir.appendingPathComponent("frag", isDirectory: true)
        try write("just text", to: fragments.appendingPathComponent("part.tex"))
        let result = try importer.preview(try zip(fragments, as: "frag.zip"))
        XCTAssertEqual(result.mainFile, "part.tex")
        XCTAssertFalse(warnings(result).isEmpty)

        let noTex = dir.appendingPathComponent("none", isDirectory: true)
        try write("hello", to: noTex.appendingPathComponent("readme.txt"))
        XCTAssertThrowsError(try importer.preview(try zip(noTex, as: "none.zip"))) {
            XCTAssertEqual($0 as? DocumentImportError, .noTexFile)
        }
    }

    // MARK: .docx

    private let namespaces = #"xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:m="http://schemas.openxmlformats.org/officeDocument/2006/math" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture""#

    private func p(_ inner: String, style: String? = nil, extra: String = "") -> String {
        let properties = (style != nil || !extra.isEmpty)
            ? "<w:pPr>" + (style.map { "<w:pStyle w:val=\"\($0)\"/>" } ?? "") + extra + "</w:pPr>"
            : ""
        return "<w:p>\(properties)\(inner)</w:p>"
    }

    private func r(_ text: String, bold: Bool = false, italic: Bool = false) -> String {
        let properties = (bold || italic) ? "<w:rPr>" + (bold ? "<w:b/>" : "") + (italic ? "<w:i/>" : "") + "</w:rPr>" : ""
        return "<w:r>\(properties)<w:t xml:space=\"preserve\">\(text)</w:t></w:r>"
    }

    private func makeDocx(
        body: String,
        extra: [String: String] = [:],
        binary: [String: Data] = [:],
        name: String = "doc.docx"
    ) throws -> URL {
        let package = try tempDir().appendingPathComponent("pkg", isDirectory: true)
        try write("<?xml version=\"1.0\" encoding=\"UTF-8\"?><w:document \(namespaces)><w:body>\(body)</w:body></w:document>",
                  to: package.appendingPathComponent("word/document.xml"))
        for (path, xml) in extra { try write(xml, to: package.appendingPathComponent(path)) }
        for (path, data) in binary {
            let url = package.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        return try zip(package, as: name)
    }

    /// Imports a .docx and returns the LaTeX, the result and the folder it was written to.
    private func convert(
        body: String,
        extra: [String: String] = [:],
        binary: [String: Data] = [:]
    ) throws -> (tex: String, result: DocumentImportResult, folder: URL) {
        let docx = try makeDocx(body: body, extra: extra, binary: binary)
        let folder = try tempDir().appendingPathComponent("draft")
        let result = try importer.importDocument(from: docx, into: folder)
        return (read(folder.appendingPathComponent("main.tex")) ?? "", result, folder)
    }

    func testDocxHeadingsFormattingAndEscaping() throws {
        let output = try convert(body:
            p(r("Client Drift"), style: "Title") +
            p(r("Introduction"), style: "Heading1") +
            p(r("Plain ") + r("bold", bold: true) + r(" and ") + r("slanted", italic: true) + r(" &amp; 50% of R_x")) +
            p(r("Method"), style: "Heading2") +
            p(r("References"), style: "Heading1")
        )

        XCTAssertEqual(output.result.kind, .docx)
        XCTAssertEqual(output.result.title, "Client Drift")
        XCTAssertEqual(output.result.mainFile, "main.tex")
        XCTAssertTrue(output.tex.contains(#"\title{Client Drift}"#))
        XCTAssertTrue(output.tex.contains(#"\maketitle"#))
        XCTAssertTrue(output.tex.contains(#"\section{Introduction}"#))
        XCTAssertTrue(output.tex.contains(#"\subsection{Method}"#))
        XCTAssertTrue(output.tex.contains(#"\section*{References}"#))
        XCTAssertTrue(output.tex.contains(#"\textbf{bold}"#))
        XCTAssertTrue(output.tex.contains(#"\textit{slanted}"#))
        XCTAssertTrue(output.tex.contains(#"\& 50\% of R\_x"#))
        XCTAssertTrue(output.tex.contains(#"\begin{document}"#))
        XCTAssertTrue(output.tex.hasSuffix("\\end{document}\n"))
    }

    func testDocxSplitRunsWithSameFormattingAreMerged() throws {
        let output = try convert(body: p(r("Hel", bold: true) + r("lo", bold: true) + r(" you")))
        XCTAssertTrue(output.tex.contains(#"\textbf{Hello} you"#))
    }

    func testDocxBulletAndNumberedLists() throws {
        let numbering = """
        <?xml version="1.0" encoding="UTF-8"?><w:numbering \(namespaces)>
        <w:abstractNum w:abstractNumId="0"><w:lvl w:ilvl="0"><w:numFmt w:val="bullet"/></w:lvl><w:lvl w:ilvl="1"><w:numFmt w:val="bullet"/></w:lvl></w:abstractNum>
        <w:abstractNum w:abstractNumId="1"><w:lvl w:ilvl="0"><w:numFmt w:val="decimal"/></w:lvl></w:abstractNum>
        <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>
        <w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num>
        </w:numbering>
        """
        func item(_ text: String, num: Int, level: Int = 0) -> String {
            p(r(text), extra: "<w:numPr><w:ilvl w:val=\"\(level)\"/><w:numId w:val=\"\(num)\"/></w:numPr>")
        }

        let output = try convert(
            body: item("one", num: 1) + item("nested", num: 1, level: 1) + item("two", num: 1) +
                  p(r("In between")) +
                  item("first", num: 2) + item("second", num: 2),
            extra: ["word/numbering.xml": numbering]
        )

        let tex = output.tex
        XCTAssertTrue(tex.contains(#"\begin{itemize}"#))
        XCTAssertTrue(tex.contains(#"\begin{enumerate}"#))
        XCTAssertEqual(tex.components(separatedBy: #"\begin{itemize}"#).count - 1, 2, "one outer list and one nested")
        XCTAssertEqual(tex.components(separatedBy: #"\end{itemize}"#).count - 1, 2)
        XCTAssertEqual(tex.components(separatedBy: #"\item"#).count - 1, 5)

        let closeBeforeParagraph = tex.range(of: #"\end{itemize}"#, options: .backwards)!.lowerBound
        XCTAssertTrue(closeBeforeParagraph < tex.range(of: "In between")!.lowerBound)
        XCTAssertTrue(tex.range(of: "In between")!.lowerBound < tex.range(of: #"\begin{enumerate}"#)!.lowerBound)
    }

    func testDocxTable() throws {
        func cell(_ text: String, span: Int = 1) -> String {
            "<w:tc>" + (span > 1 ? "<w:tcPr><w:gridSpan w:val=\"\(span)\"/></w:tcPr>" : "") + p(r(text)) + "</w:tc>"
        }
        let table = "<w:tbl><w:tr>\(cell("Name"))\(cell("Score"))</w:tr><w:tr>\(cell("A"))\(cell("0.91"))</w:tr><w:tr>\(cell("Wide", span: 2))</w:tr></w:tbl>"

        let output = try convert(body: table)
        XCTAssertTrue(output.tex.contains(#"\begin{tabular}"#))
        XCTAssertTrue(output.tex.contains(#"Name & Score \\ \hline"#))
        XCTAssertTrue(output.tex.contains(#"A & 0.91 \\ \hline"#))
        XCTAssertTrue(output.tex.contains(#"\multicolumn{2}"#))
    }

    func testDocxHyperlinkAndFootnote() throws {
        let rels = """
        <?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId9" Type="hyperlink" Target="https://example.org/x?a=1&amp;b=2" TargetMode="External"/></Relationships>
        """
        let footnotes = """
        <?xml version="1.0" encoding="UTF-8"?><w:footnotes \(namespaces)>
        <w:footnote w:type="separator" w:id="-1"><w:p><w:r><w:t>SEPARATORTEXT</w:t></w:r></w:p></w:footnote>
        <w:footnote w:id="2"><w:p><w:r><w:footnoteRef/></w:r><w:r><w:t xml:space="preserve"> See Smith 2020.</w:t></w:r></w:p></w:footnote>
        </w:footnotes>
        """
        let output = try convert(
            body: p("<w:hyperlink r:id=\"rId9\">" + r("our site") + "</w:hyperlink>" + r(" and a claim") +
                    "<w:r><w:footnoteReference w:id=\"2\"/></w:r>"),
            extra: ["word/_rels/document.xml.rels": rels, "word/footnotes.xml": footnotes]
        )

        XCTAssertTrue(output.tex.contains(#"\href{https://example.org/x?a=1\&b=2}{our site}"#))
        XCTAssertTrue(output.tex.contains(#"\footnote{See Smith 2020.}"#))
        XCTAssertFalse(output.tex.contains("SEPARATORTEXT"))
    }

    func testDocxEquations() throws {
        func t(_ text: String) -> String { "<m:r><m:t>\(text)</m:t></m:r>" }
        let inline = "<m:oMath><m:f><m:num>\(t("a"))</m:num><m:den>\(t("b"))</m:den></m:f>\(t("+"))<m:sSup><m:e>\(t("x"))</m:e><m:sup>\(t("2"))</m:sup></m:sSup></m:oMath>"
        let sum = "<m:oMath><m:nary><m:naryPr><m:chr m:val=\"∑\"/></m:naryPr><m:sub>\(t("i=1"))</m:sub><m:sup>\(t("n"))</m:sup><m:e>\(t("α"))</m:e></m:nary></m:oMath>"
        let root = "<m:oMath><m:rad><m:radPr><m:degHide m:val=\"1\"/></m:radPr><m:deg/><m:e>\(t("x"))</m:e></m:rad></m:oMath>"
        let display = "<m:oMathPara><m:oMath>\(t("E"))\(t("="))\(t("m"))\(t("c"))</m:oMath></m:oMathPara>"

        let output = try convert(body: p(r("Inline ") + inline + r(" then ") + sum + r(" and ") + root) + p(display))

        XCTAssertTrue(output.tex.contains(#"$\frac{a}{b}+{x}^{2}$"#))
        XCTAssertTrue(output.tex.contains(#"$\sum_{i=1}^{n} \alpha$"#))
        XCTAssertTrue(output.tex.contains(#"$\sqrt{x}$"#))
        XCTAssertTrue(output.tex.contains(#"\[ E=mc \]"#))
        XCTAssertTrue(output.result.issues.filter { $0.message.contains("Equation") }.isEmpty)
    }

    func testDocxUnknownEquationPartIsListed() throws {
        let odd = "<m:oMath><m:strangeThing><m:r><m:t>q</m:t></m:r></m:strangeThing></m:oMath>"
        let output = try convert(body: p(odd))
        XCTAssertTrue(warnings(output.result).contains { $0.contains("Equation 1") })
    }

    func testDocxPictureIsCopiedAndUnusableFormatsAreListed() throws {
        let rels = """
        <?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId5" Type="image" Target="media/image1.png"/>
        <Relationship Id="rId6" Type="image" Target="media/chart.emf"/></Relationships>
        """
        func picture(_ id: String) -> String {
            "<w:r><w:drawing><wp:inline><a:graphic><a:graphicData><pic:pic><pic:blipFill><a:blip r:embed=\"\(id)\"/></pic:blipFill></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>"
        }

        let output = try convert(
            body: p(picture("rId5")) + p(picture("rId6")),
            extra: ["word/_rels/document.xml.rels": rels],
            binary: ["word/media/image1.png": Data([1, 2, 3]), "word/media/chart.emf": Data([4, 5])]
        )

        XCTAssertTrue(output.result.files.contains("figures/image1.png"))
        XCTAssertTrue(output.result.files.contains("figures/chart.emf"))
        XCTAssertEqual(try Data(contentsOf: output.folder.appendingPathComponent("figures/image1.png")), Data([1, 2, 3]))
        XCTAssertTrue(output.tex.contains(#"\includegraphics[width=0.8\linewidth]{figures/image1.png}"#))
        XCTAssertTrue(output.tex.contains("\\begin{center}\n\\includegraphics"), "a picture alone on its line is centred")
        XCTAssertTrue(warnings(output.result).contains { $0.contains("chart.emf") })
    }

    func testDocxTableOfContentsAndReferenceManagerCitations() throws {
        func field(_ instruction: String, result: String) -> String {
            "<w:r><w:fldChar w:fldCharType=\"begin\"/></w:r><w:r><w:instrText xml:space=\"preserve\"> \(instruction) </w:instrText></w:r>" +
            "<w:r><w:fldChar w:fldCharType=\"separate\"/></w:r>" + r(result) + "<w:r><w:fldChar w:fldCharType=\"end\"/></w:r>"
        }

        let output = try convert(body:
            p(field(#"TOC \o "1-3""#, result: "Chapter 1 ........ 4")) +
            p(r("As shown ") + field("ADDIN ZOTERO_ITEM CSL_CITATION {}", result: "(Smith, 2020)"))
        )

        XCTAssertTrue(output.tex.contains(#"\tableofcontents"#))
        XCTAssertFalse(output.tex.contains("Chapter 1"))
        XCTAssertTrue(output.tex.contains("(Smith, 2020)"), "citation text stays as plain text")
        XCTAssertTrue(warnings(output.result).contains { $0.contains("reference manager") })
    }

    func testDocxTrackedChangesCommentsAndOddCharactersAreListed() throws {
        let comments = "<?xml version=\"1.0\"?><w:comments \(namespaces)><w:comment w:id=\"0\"/><w:comment w:id=\"1\"/></w:comments>"
        let output = try convert(
            body: p("<w:ins>" + r("kept") + "</w:ins><w:del><w:r><w:delText>gone</w:delText></w:r></w:del>" + r(" Ω Ж")),
            extra: ["word/comments.xml": comments]
        )

        XCTAssertTrue(output.tex.contains("kept"))
        XCTAssertFalse(output.tex.contains("gone"))
        let notes = output.result.issues.filter { $0.level == .note }.map(\.message).joined(separator: "\n")
        XCTAssertTrue(notes.contains("tracked changes"))
        XCTAssertTrue(notes.contains("2 comments"))
        XCTAssertTrue(notes.contains("Ω"))
    }

    func testDocxTitleAndAuthorFromDocumentProperties() throws {
        let core = "<?xml version=\"1.0\"?><cp:coreProperties xmlns:cp=\"x\" xmlns:dc=\"y\"><dc:title>From properties</dc:title><dc:creator>Ada Lovelace</dc:creator></cp:coreProperties>"
        let output = try convert(body: p(r("Just text")), extra: ["docProps/core.xml": core])

        XCTAssertEqual(output.result.title, "From properties")
        XCTAssertEqual(output.result.author, "Ada Lovelace")
        XCTAssertTrue(output.tex.contains(#"\author{Ada Lovelace}"#))
    }

    func testDocxCenteredParagraphAbstractAndEmptyParagraphs() throws {
        let output = try convert(body:
            p(r("Summary of the work."), style: "Abstract") +
            p("") +
            p(r("Centered line"), extra: "<w:jc w:val=\"center\"/>")
        )
        XCTAssertTrue(output.tex.contains("\\begin{abstract}\nSummary of the work.\n\\end{abstract}"))
        XCTAssertTrue(output.tex.contains("\\begin{center}\nCentered line\n\\end{center}"))
    }

    func testNotAWordDocumentIsRefused() throws {
        let dir = try tempDir()
        let fake = dir.appendingPathComponent("fake.docx")
        try write("this is not a zip", to: fake)
        XCTAssertThrowsError(try importer.preview(fake)) { XCTAssertEqual($0 as? DocumentImportError, .notAWordDocument) }

        let other = dir.appendingPathComponent("other", isDirectory: true)
        try write("hi", to: other.appendingPathComponent("hello.txt"))
        let wrong = try zip(other, as: "wrong.docx")
        XCTAssertThrowsError(try importer.preview(wrong)) { XCTAssertEqual($0 as? DocumentImportError, .notAWordDocument) }
    }
}