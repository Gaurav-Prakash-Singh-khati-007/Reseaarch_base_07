//
//  SnippetPaletteViewTests.swift
//  ResearchBase
//
//  Created by Gaurav Khati on 22/10/26.
//


//
//  SnippetPaletteViewTests.swift
//  ResearchBaseTests
//
//  Owner: Agent 40 (tests for SnippetPaletteView.swift)
//

import XCTest
@testable import ResearchBase

final class SnippetPaletteViewTests: XCTestCase {

    typealias L = LatexSnippetLibrary

    func testTriggersAndIdsAreUniqueAndEverySnippetHasOneCaretMark() {
        XCTAssertEqual(Set(L.all.map(\.trigger)).count, L.all.count)
        XCTAssertEqual(Set(L.all.map(\.id)).count, L.all.count)
        for s in L.all {
            XCTAssertEqual(s.body.components(separatedBy: "$0").count - 1, 1, "\(s.name) needs exactly one $0")
        }
    }

    func testSnippetsHaveBalancedEnvironments() {
        for s in L.all {
            let begins = s.body.components(separatedBy: "\\begin{").count
            let ends = s.body.components(separatedBy: "\\end{").count
            XCTAssertEqual(begins, ends, s.name)
        }
    }

    func testRequiredSnippetsExist() {
        for t in ["eq", "fig", "tab", "alg", "thm"] { XCTAssertNotNil(L.snippet(forTrigger: t), t) }
        XCTAssertNil(L.snippet(forTrigger: "nope"))
    }

    func testInsertPlacesCaretAtMarkAndRemovesIt() {
        let s = L.snippet(forTrigger: "eq")!
        let r = s.insertion(into: "ab", selection: NSRange(location: 1, length: 0))
        XCTAssertFalse(r.text.contains("$0"))
        XCTAssertTrue(r.text.hasPrefix("a\\begin{equation}\n  "))
        XCTAssertTrue(r.text.hasSuffix("\\end{equation}b"))
        XCTAssertEqual(r.selection.location, ("a\\begin{equation}\n  " as NSString).length)
        XCTAssertEqual((r.text as NSString).substring(with: r.insertedRange).hasPrefix("\\begin{equation}"), true)
    }

    func testInsertReplacesTheSelection() {
        let s = L.snippet(forTrigger: "def")!
        let r = s.insertion(into: "XXXXX", selection: NSRange(location: 1, length: 3))
        XCTAssertTrue(r.text.hasPrefix("X\\begin{definition}["))
        XCTAssertTrue(r.text.hasSuffix("\\end{definition}X"))
    }

    func testContinuationLinesKeepTheIndentation() {
        let s = L.snippet(forTrigger: "itemize")!
        let text = "    "
        let r = s.insertion(into: text, selection: NSRange(location: 4, length: 0))
        let lines = r.text.components(separatedBy: "\n")
        XCTAssertEqual(lines.first, "    \\begin{itemize}")
        XCTAssertTrue(lines.dropFirst().allSatisfy { $0.hasPrefix("    ") })
    }

    func testInsertAtEndAndWithEmojiBeforeUsesUTF16() {
        let s = L.snippet(forTrigger: "lst")!
        let text = "😀 "
        let r = s.insertion(into: text, selection: NSRange(location: 3, length: 0))
        XCTAssertEqual(r.insertedRange.location, 3)
        XCTAssertEqual((r.text as NSString).substring(to: r.selection.location).hasSuffix("label={lst:}]\n"), true)
    }

    func testOutOfRangeSelectionIsClamped() {
        let s = L.snippet(forTrigger: "eq")!
        let r = s.insertion(into: "abc", selection: NSRange(location: 99, length: 5))
        XCTAssertTrue(r.text.hasPrefix("abc\\begin{equation}"))
    }

    // MARK: Trigger before the caret

    func testTriggerBeforeCaret() {
        let hit = L.trigger(before: 6, in: "Hi.\neq")
        XCTAssertEqual(hit?.snippet.trigger, "eq")
        XCTAssertEqual(hit?.range, NSRange(location: 4, length: 2))
        XCTAssertNotNil(L.trigger(before: 2, in: "eq"))
    }

    func testTriggerNeedsAWholeWordNotACommand() {
        XCTAssertNil(L.trigger(before: 3, in: "\\eq"))
        XCTAssertNil(L.trigger(before: 6, in: "equals"))
        XCTAssertNil(L.trigger(before: 4, in: "xfig"))
        XCTAssertNil(L.trigger(before: 0, in: "eq"))
        XCTAssertNil(L.trigger(before: 1, in: "e "))
        XCTAssertNil(L.trigger(before: 9, in: "eq"))
    }

    // MARK: Search

    func testSearch() {
        XCTAssertEqual(L.search("").count, L.all.count)
        XCTAssertEqual(L.search("fig").first?.trigger, "fig")
        XCTAssertTrue(L.search("table").contains { $0.trigger == "tab" })
        XCTAssertEqual(L.search("EQ").first?.trigger, "eq")
        XCTAssertTrue(L.search("zzzz").isEmpty)
        XCTAssertTrue(L.search("code").contains { $0.trigger == "lst" })
    }
}