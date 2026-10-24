//
//  LatexEditorViewTests.swift
//  ResearchBase
//
//  Created by Gaurav Khati on 22/10/26.
//


//
//  LatexEditorViewTests.swift
//  ResearchBaseTests
//
//  Owner: Agent 39 (tests for LatexEditorView.swift)
//  Covers the pure logic: \cite / \ref context, ranking, labels, outline, word count,
//  positions, and loading citation candidates from a real temporary library.
//

import XCTest
@testable import ResearchBase

final class LatexEditorViewTests: XCTestCase {

    typealias A = LatexAutocomplete

    private func context(_ text: String, caret: Int? = nil) -> LatexCompletionContext? {
        A.completionContext(in: text, caret: caret ?? (text as NSString).length)
    }

    // MARK: Context

    func testCiteContextAtEndOfKey() {
        let c = context(#"See \cite{mcm"#)
        XCTAssertEqual(c?.kind, .citation)
        XCTAssertEqual(c?.command, "cite")
        XCTAssertEqual(c?.prefix, "mcm")
        XCTAssertEqual(c?.replacementRange, NSRange(location: 10, length: 3))
    }

    func testEmptyPrefixRightAfterBrace() {
        let c = context(#"\cite{"#)
        XCTAssertEqual(c?.prefix, "")
        XCTAssertEqual(c?.replacementRange, NSRange(location: 6, length: 0))
    }

    func testSecondKeyAfterComma() {
        let c = context(#"\cite{alpha, be"#)
        XCTAssertEqual(c?.prefix, "be")
        XCTAssertEqual(c?.replacementRange, NSRange(location: 13, length: 2))
    }

    func testOptionalArgumentsAndStarredAndBiblatexCommands() {
        XCTAssertEqual(context(#"\citep[see][p. 3]{x"#)?.command, "citep")
        XCTAssertEqual(context(#"\cite*{x"#)?.command, "cite")
        XCTAssertEqual(context(#"\parencite{x"#)?.kind, .citation)
        XCTAssertEqual(context(#"\nocite{x"#)?.kind, .citation)
    }

    func testRefFamilyIsReference() {
        XCTAssertEqual(context(#"see \ref{fig"#)?.kind, .reference)
        XCTAssertEqual(context(#"\eqref{eq"#)?.kind, .reference)
        XCTAssertEqual(context(#"\cref{a, b"#)?.prefix, "b")
    }

    func testNoContextOutsideTheArgument() {
        XCTAssertNil(context(#"\cite{a} and more"#))
        XCTAssertNil(context(#"\section{Intro"#))
        XCTAssertNil(context(#"\citeauthor"#))
        XCTAssertNil(context("plain text"))
        XCTAssertNil(context(#"\textbf{cite"#))
    }

    func testCommentedOutLineGivesNoContext() {
        XCTAssertNil(context(#"% \cite{a"#))
        XCTAssertNotNil(context(#"100\% \cite{a"#), "an escaped percent is not a comment")
    }

    func testArgumentDoesNotCrossLines() {
        XCTAssertNil(context("\\cite{a\nsecond line"))
    }

    func testCaretInTheMiddleUsesTextBeforeTheCaret() {
        let text = #"\cite{alpha, beta, gamma}"#
        let c = context(text, caret: 15)
        XCTAssertEqual(c?.prefix, "be")
        XCTAssertEqual(A.citationKey(in: text, caret: 15), "beta")
    }

    func testCitationKeyNilOutsideCiteAndForRefs() {
        XCTAssertNil(A.citationKey(in: #"\ref{fig}"#, caret: 7))
        XCTAssertNil(A.citationKey(in: "hello", caret: 2))
        XCTAssertNil(A.citationKey(in: #"\cite{}"#, caret: 6))
    }

    func testEmojiBeforeTheCommandKeepsUTF16Offsets() {
        let text = "😀 \\cite{ab"
        let c = context(text)
        XCTAssertEqual(c?.prefix, "ab")
        XCTAssertEqual((text as NSString).substring(with: c!.replacementRange), "ab")
    }

    // MARK: Labels

    func testLabelsSkipCommentsAndDuplicates() {
        let text = """
        \\section{A}\\label{sec:a}
        % \\label{sec:old}
        \\begin{figure}\\label{fig:one}\\end{figure}
        \\label{sec:a}
        """
        let labels = A.labels(in: text)
        XCTAssertEqual(labels.map(\.name), ["sec:a", "fig:one"])
        XCTAssertEqual(labels.map(\.line), [1, 3])
        XCTAssertTrue(labels[0].context.contains("\\section{A}"))
    }

    // MARK: Ranking

    private let pool = [
        LatexCitationCandidate(key: "mcmahan2017communication", title: "Communication-Efficient Learning of Deep Networks", authors: ["McMahan", "Moore"], year: 2017),
        LatexCitationCandidate(key: "vaswani2017attention", title: "Attention Is All You Need", authors: ["Vaswani"], year: 2017),
        LatexCitationCandidate(key: "devlin2019bert", title: "BERT: Pre-training of Deep Bidirectional Transformers", authors: ["Devlin"], year: 2019),
    ]

    func testSuggestionsMatchKeyAuthorTitleAndYear() {
        XCTAssertEqual(A.citationSuggestions(prefix: "mcm", candidates: pool).map(\.key), ["mcmahan2017communication"])
        XCTAssertEqual(A.citationSuggestions(prefix: "vaswani", candidates: pool).first?.key, "vaswani2017attention")
        XCTAssertEqual(A.citationSuggestions(prefix: "attention", candidates: pool).first?.key, "vaswani2017attention")
        XCTAssertEqual(A.citationSuggestions(prefix: "2019", candidates: pool).map(\.key), ["devlin2019bert"])
    }

    func testEveryWordMustMatchAndKeyMatchesComeFirst() {
        XCTAssertEqual(A.citationSuggestions(prefix: "deep 2017", candidates: pool).map(\.key), ["mcmahan2017communication"])
        XCTAssertTrue(A.citationSuggestions(prefix: "deep zzz", candidates: pool).isEmpty)
        let keyFirst = A.citationSuggestions(prefix: "2017", candidates: pool).map(\.key)
        XCTAssertEqual(Set(keyFirst), ["mcmahan2017communication", "vaswani2017attention"])
    }

    func testEmptyPrefixGivesNewestFirstAndRespectsLimit() {
        XCTAssertEqual(A.citationSuggestions(prefix: "", candidates: pool).first?.key, "devlin2019bert")
        XCTAssertEqual(A.citationSuggestions(prefix: "", candidates: pool, limit: 2).count, 2)
        XCTAssertTrue(A.citationSuggestions(prefix: "x", candidates: []).isEmpty)
    }

    func testReferenceSuggestionsStartsWithBeforeContains() {
        let labels = ["fig:a", "tab:fig", "sec:x"].map { LatexLabel(name: $0, line: 1, context: "") }
        XCTAssertEqual(A.referenceSuggestions(prefix: "fig", labels: labels).map(\.name), ["fig:a", "tab:fig"])
        XCTAssertEqual(A.referenceSuggestions(prefix: "", labels: labels).count, 3)
        XCTAssertEqual(A.referenceSuggestions(prefix: "FIG:", labels: labels).map(\.name), ["fig:a"])
    }

    func testCandidateSummary() {
        XCTAssertEqual(pool[0].summary, "McMahan & Moore, 2017 · Communication-Efficient Learning of Deep Networks")
        let three = LatexCitationCandidate(key: "k", title: "", authors: ["A", "B", "C"], year: nil)
        XCTAssertEqual(three.summary, "A et al., n.d.")
    }

    // MARK: Outline

    func testOutlineFindsSectionsAndSkipsComments() {
        let text = """
        \\section{Intro}
          \\subsection*{Background}
        % \\section{Hidden}
        \\section[short]{Methods}
        \\paragraph{Detail}
        """
        let entries = LatexOutline.entries(in: text)
        XCTAssertEqual(entries.map(\.title), ["Intro", "Background", "Methods", "Detail"])
        XCTAssertEqual(entries.map(\.depth), [2, 3, 2, 5])
        XCTAssertEqual(entries.map(\.line), [1, 2, 4, 5])
    }

    // MARK: Counting

    func testWordCountIgnoresPreambleCommentsMathAndCitations() {
        let text = #"""
        \documentclass{article}
        \usepackage{amsmath}
        \begin{document}
        Hello \textbf{brave} world $x^2$ % ignored words here
        \begin{equation} a + b = c \end{equation}
        As shown by \cite{k} and Figure~\ref{fig:a}, end.
        \end{document}
        trailing junk
        """#
        // Hello brave world As shown by and Figure end
        XCTAssertEqual(LatexTextStats.wordCount(in: text), 9)
    }

    func testWordCountOfPlainTextAndEmpty() {
        XCTAssertEqual(LatexTextStats.wordCount(in: ""), 0)
        XCTAssertEqual(LatexTextStats.wordCount(in: "one two  three\nfour"), 4)
    }

    // MARK: Positions

    func testPositionAndLocationAreInverse() {
        let text = "ab\ncde\nf"
        XCTAssertEqual(LatexTextStats.position(of: 0, in: text).line, 1)
        let p = LatexTextStats.position(of: 4, in: text)
        XCTAssertEqual(p.line, 2)
        XCTAssertEqual(p.column, 2)
        XCTAssertEqual(LatexTextStats.location(line: 2, column: 2, in: text), 4)
        XCTAssertEqual(LatexTextStats.location(line: 3, column: nil, in: text), 7)
    }

    func testLocationClampsToTheTextAndTheLine() {
        let text = "ab\ncde\nf"
        XCTAssertEqual(LatexTextStats.location(line: 99, column: 1, in: text), (text as NSString).length)
        XCTAssertEqual(LatexTextStats.location(line: 1, column: 50, in: text), 2, "stays before the line end")
    }

    // MARK: Library

    @MainActor
    func testCitationSourceReadsKeysAuthorsAndSkipsTrash() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        let kept = try ModelTestSupport.item(model, title: "Attention Is All You Need",
                                             author: "Vaswani", given: "Ashish", year: 2017)
        let gone = try ModelTestSupport.item(model, title: "Old Paper", author: "Smith", given: "Jo", year: 1999)
        try ModelTestSupport.trash(model, itemID: gone.id)

        let found = try LatexCitationSource.load(from: model)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.key, kept.citationKey)
        XCTAssertEqual(found.first?.authors, ["Vaswani"])
        XCTAssertEqual(found.first?.year, 2017)
        XCTAssertEqual(found.first?.title, "Attention Is All You Need")
    }

    @MainActor
    func testCitationSourceEmptyLibrary() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        XCTAssertTrue(try LatexCitationSource.load(from: model).isEmpty)
    }

    // MARK: Commands, environments, packages

    func testCommandContextNeedsBackslashAndTwoLetters() {
        XCTAssertNil(context(#"\s"#))
        let c = context(#"Text \sec"#)
        XCTAssertEqual(c?.kind, .command)
        XCTAssertEqual(c?.prefix, "sec")
        XCTAssertEqual(c?.replacementRange, NSRange(location: 6, length: 3))
    }

    func testCommandContextIgnoresLineBreakAndComments() {
        XCTAssertNil(context(#"a \\sec"#))
        XCTAssertNil(context("% \\sec"))
        XCTAssertNil(context("plain text"))
    }

    func testCommandSuggestionsStartWithTypedLetters() {
        let c = context(#"\subs"#)!
        let names = A.nameSuggestions(for: c, in: #"\subs"#)
        XCTAssertTrue(names.contains("subsection"))
        XCTAssertTrue(names.allSatisfy { $0.lowercased().hasPrefix("subs") })
    }

    func testBeginContextOffersEnvironments() {
        let text = #"\begin{ite"#
        let c = context(text)
        XCTAssertEqual(c?.kind, .environment)
        XCTAssertTrue(A.nameSuggestions(for: c!, in: text).contains("itemize"))
    }

    func testEndContextOffersOpenEnvironmentFirst() {
        let text = "\\begin{document}\n\\begin{figure}\n\\end{"
        let c = context(text)
        XCTAssertEqual(c?.kind, .endEnvironment)
        XCTAssertEqual(A.nameSuggestions(for: c!, in: text).first, "figure")
    }

    func testClosedEnvironmentsAreNotOffered() {
        let text = "\\begin{figure}\n\\end{figure}\n\\end{"
        XCTAssertEqual(A.openEnvironments(in: text, before: (text as NSString).length), [])
    }

    func testUsePackageContextOffersPackages() {
        let text = #"\usepackage{ams"#
        let c = context(text)
        XCTAssertEqual(c?.kind, .package)
        XCTAssertTrue(A.nameSuggestions(for: c!, in: text).contains("amsmath"))
    }

    func testCommandTemplatesPutCaretInsideBraces() {
        XCTAssertEqual(A.commandTemplates["section"]?.suffix, "{}")
        XCTAssertEqual(A.commandTemplates["section"]?.caretBack, 1)
        XCTAssertEqual(A.commandTemplates["frac"]?.caretBack, 3)
    }
}

