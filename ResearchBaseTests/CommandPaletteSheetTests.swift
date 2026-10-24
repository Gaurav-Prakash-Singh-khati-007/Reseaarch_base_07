//
//  CommandPaletteSheetTests.swift
//  ResearchBase
//
//  Created by Gaurav Khati on 23/10/26.
//


//
//  CommandPaletteSheetTests.swift
//  Owner: Agent 60 (tests for CommandPaletteSheet.swift: PaletteLogic)
//

import XCTest
@testable import ResearchBase

final class CommandPaletteSheetTests: XCTestCase {

    private func cmd(_ title: String, _ keywords: [String] = []) -> CommandPaletteItem {
        CommandPaletteItem(title: title, iconName: "circle", shortcut: "", keywords: keywords) {}
    }

    func testRankOrder() {
        XCTAssertEqual(PaletteLogic.rank(title: "Back up now", query: "back up now"), 0)
        XCTAssertEqual(PaletteLogic.rank(title: "Back up now", query: "back"), 1)
        XCTAssertEqual(PaletteLogic.rank(title: "Go to Library", query: "lib"), 2)
        XCTAssertEqual(PaletteLogic.rank(title: "Switch theme", query: "itch"), 3)
        XCTAssertEqual(PaletteLogic.rank(title: "Back up now", keywords: ["backup"], query: "backup"), 4)
        XCTAssertEqual(PaletteLogic.rank(title: "Build current draft", query: "bld"), 6)
        XCTAssertNil(PaletteLogic.rank(title: "Show Trash", query: "zzz"))
    }

    func testEveryWordMustMatch() {
        XCTAssertNotNil(PaletteLogic.rank(title: "Go to Library", query: "go lib"))
        XCTAssertNil(PaletteLogic.rank(title: "Go to Library", query: "go zzz"))
    }

    func testFilterRanksBestFirstAndKeepsTiesInOrder() {
        let all = [cmd("Go to Library"), cmd("Library tools"), cmd("Show Trash", ["deleted"])]
        XCTAssertEqual(PaletteLogic.filter(all, query: "lib").map(\.title), ["Library tools", "Go to Library"])
        XCTAssertEqual(PaletteLogic.filter(all, query: "deleted").map(\.title), ["Show Trash"])
        XCTAssertEqual(PaletteLogic.filter(all, query: "  ").count, 3)
    }

    func testSubsequence() {
        XCTAssertTrue(PaletteLogic.isSubsequence("bld", of: "build current draft"))
        XCTAssertFalse(PaletteLogic.isSubsequence("dlb", of: "build"))
    }

    func testPaperSearchThreshold() {
        XCTAssertFalse(PaletteLogic.shouldSearchPapers("a"))
        XCTAssertFalse(PaletteLogic.shouldSearchPapers(" a "))
        XCTAssertTrue(PaletteLogic.shouldSearchPapers("at"))
    }

    func testMovedWrapsAround() {
        XCTAssertEqual(PaletteLogic.moved(0, by: -1, count: 5), 4)
        XCTAssertEqual(PaletteLogic.moved(4, by: 1, count: 5), 0)
        XCTAssertEqual(PaletteLogic.moved(2, by: 1, count: 5), 3)
        XCTAssertEqual(PaletteLogic.moved(0, by: 1, count: 0), 0)
    }

    func testPaperSubtitle() {
        XCTAssertEqual(PaletteLogic.paperSubtitle(year: 2017), "Paper · 2017")
        XCTAssertEqual(PaletteLogic.paperSubtitle(year: nil), "Paper")
    }
}