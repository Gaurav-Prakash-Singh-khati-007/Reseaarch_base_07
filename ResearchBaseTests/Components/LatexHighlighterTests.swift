//
//  LatexHighlighterTests.swift
//  ResearchBase
//
//  Created by Gaurav Khati on 21/10/26.
//


//
//  LatexHighlighterTests.swift
//  ResearchBaseTests
//
//  Owner: Agent 33 · L-01
//

import XCTest
import AppKit
@testable import ResearchBase

@MainActor
final class LatexHighlighterTests: XCTestCase {

    /// (kind, text) pairs, so a failure shows what was found.
    private func found(_ text: String, range: NSRange? = nil, keys: Set<String>? = nil) -> [String] {
        let ns = text as NSString
        return LatexHighlighter.tokens(in: text, range: range, knownCitationKeys: keys)
            .map { "\($0.kind):\(ns.substring(with: $0.range))" }
    }

    func testCommentRunsToTheEndOfTheLine() {
        XCTAssertEqual(found("a % note \\x\nb"), ["comment:% note \\x"])
    }

    func testEscapedPercentIsACommandNotAComment() {
        XCTAssertEqual(found("50\\% growth"), ["command:\\%"])
    }

    func testMathInlineAndDisplay() {
        XCTAssertEqual(found("so $x^2$ and $$y$$"), ["math:$x^2$", "math:$$y$$"])
    }

    func testLoneDollarAndEscapedDollarAreLeftAlone() {
        XCTAssertEqual(found("costs $5 here"), [])
        XCTAssertEqual(found("costs \\$5 here"), ["command:\\$"])
    }

    func testCommandsAndBrackets() {
        XCTAssertEqual(found("\\section*{Intro}"), ["command:\\section*", "bracket:{", "bracket:}"])
        XCTAssertEqual(found("a \\\\ b"), ["command:\\\\"])
    }

    func testEnvironmentIsSplitIntoCommandBracketsAndName() {
        XCTAssertEqual(found("\\begin{equation}"),
                       ["command:\\begin", "bracket:{", "environmentName:equation", "bracket:}"])
        XCTAssertEqual(found("\\end{align*}"),
                       ["command:\\end", "bracket:{", "environmentName:align*", "bracket:}"])
    }

    func testRefAndLabelArguments() {
        XCTAssertEqual(found("\\ref{fig:a}"), ["command:\\ref", "bracket:{", "reference:fig:a", "bracket:}"])
        XCTAssertEqual(found("\\eqref{e1}"), ["command:\\eqref", "bracket:{", "reference:e1", "bracket:}"])
        XCTAssertEqual(found("\\label{fig:a}"), ["command:\\label", "bracket:{", "argument:fig:a", "bracket:}"])
        XCTAssertEqual(found("\\usepackage[utf8]{inputenc}"),
                       ["command:\\usepackage", "bracket:[", "bracket:]", "bracket:{", "argument:inputenc", "bracket:}"])
    }

    func testCiteWithoutLibraryKeysIsAPlainReference() {
        XCTAssertEqual(found("\\cite{a,b}"), ["command:\\cite", "bracket:{", "reference:a,b", "bracket:}"])
    }

    func testCiteKeysAreCheckedOneByOne() {
        XCTAssertEqual(
            found("\\citep{known1, nope ,known2}", keys: ["known1", "known2"]),
            ["command:\\citep", "bracket:{", "citationKnown:known1", "citationMissing:nope",
             "citationKnown:known2", "bracket:}"])
    }

    func testNociteStarAndOptionalArgument() {
        XCTAssertEqual(found("\\nocite{*}", keys: []),
                       ["command:\\nocite", "bracket:{", "citationKnown:*", "bracket:}"])
        XCTAssertEqual(found("\\cite[p. 3]{k}", keys: ["k"]),
                       ["command:\\cite", "bracket:[", "bracket:]", "bracket:{", "citationKnown:k", "bracket:}"])
    }

    func testEmptyArgumentMakesNoArgumentToken() {
        XCTAssertEqual(found("\\cite{}", keys: []), ["command:\\cite", "bracket:{", "bracket:}"])
    }

    func testTokensDoNotOverlapAndStayInOrder() {
        let text = "\\begin{figure}\n\\caption{See \\cref{f} and $a$}% done\n\\end{figure}\n"
        let tokens = LatexHighlighter.tokens(in: text)
        var end = 0
        for t in tokens {
            XCTAssertGreaterThanOrEqual(t.range.location, end)
            end = NSMaxRange(t.range)
        }
        XCTAssertLessThanOrEqual(end, (text as NSString).length)
    }

    func testRangesAreUTF16SoEmojiDoNotShiftThem() {
        let text = "😀 % c"
        let ns = text as NSString
        let token = LatexHighlighter.tokens(in: text).first
        XCTAssertEqual(token?.kind, .comment)
        XCTAssertEqual(ns.substring(with: token!.range), "% c")
    }

    func testRangeLimitsTheSearchToWholeLines() {
        let text = "\\alpha\n\\beta\n\\gamma\n"
        let ns = text as NSString
        let middle = ns.range(of: "bet")        // inside line 2
        XCTAssertEqual(found(text, range: middle), ["command:\\beta"])
        let two = ns.range(of: "\\beta\n\\gam")   // spans lines 2 and 3
        XCTAssertEqual(found(text, range: two), ["command:\\beta", "command:\\gamma"])
    }

    func testEmptyTextHasNoTokens() {
        XCTAssertEqual(found(""), [])
        XCTAssertEqual(LatexHighlighter.lineRange(covering: NSRange(location: 3, length: 2), in: "" as NSString).length, 0)
    }

    // MARK: Colouring

    private func color(_ s: NSAttributedString, at index: Int) -> NSColor? {
        s.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
    }

    func testApplyColoursKindsWithTheTheme() {
        let theme = LatexHighlightTheme.make()
        let storage = NSMutableAttributedString(string: "text \\cmd $m$ % c\n")

        LatexHighlighter.apply(to: storage, theme: theme)

        XCTAssertEqual(color(storage, at: 0), theme.text)
        XCTAssertEqual(color(storage, at: 6), theme.command)
        XCTAssertEqual(color(storage, at: 11), theme.math)
        XCTAssertEqual(color(storage, at: 15), theme.comment)
        XCTAssertEqual(storage.string, "text \\cmd $m$ % c\n", "the text itself is never changed")
    }

    func testMissingCitationGetsAnUnderlineAndFixingItRemovesIt() {
        let theme = LatexHighlightTheme.make()
        let storage = NSMutableAttributedString(string: "\\cite{nope}\n")

        LatexHighlighter.apply(to: storage, theme: theme, knownCitationKeys: [])
        XCTAssertEqual(color(storage, at: 7), theme.citationMissing)
        XCTAssertNotNil(storage.attribute(.underlineStyle, at: 7, effectiveRange: nil))

        LatexHighlighter.apply(to: storage, theme: theme, knownCitationKeys: ["nope"])
        XCTAssertEqual(color(storage, at: 7), theme.citationKnown)
        XCTAssertNil(storage.attribute(.underlineStyle, at: 7, effectiveRange: nil))
    }

    func testIncrementalApplyOnlyTouchesTheEditedLineAndKeepsOtherAttributes() {
        let theme = LatexHighlightTheme.make()
        let storage = NSMutableAttributedString(string: "\\a\n\\b\n\\c\n")
        LatexHighlighter.apply(to: storage, theme: theme)

        // Another feature marks line 1 and the person edits line 3 into a comment.
        storage.addAttribute(.toolTip, value: "margin comment", range: NSRange(location: 0, length: 2))
        storage.replaceCharacters(in: NSRange(location: 6, length: 2), with: "% ")
        storage.addAttribute(.foregroundColor, value: NSColor.black, range: NSRange(location: 0, length: 2))

        LatexHighlighter.apply(to: storage, range: NSRange(location: 6, length: 2), theme: theme)

        XCTAssertEqual(color(storage, at: 6), theme.comment, "edited line recoloured")
        XCTAssertEqual(color(storage, at: 0), NSColor.black, "other lines untouched")
        XCTAssertEqual(storage.attribute(.toolTip, at: 0, effectiveRange: nil) as? String, "margin comment")
    }

    func testApplyOnTextStorageAndEmptyStorageIsSafe() {
        let storage = NSTextStorage(string: "\\x")
        LatexHighlighter.apply(to: storage)
        XCTAssertNotNil(color(storage, at: 0))

        LatexHighlighter.apply(to: NSMutableAttributedString(string: ""))
    }
}