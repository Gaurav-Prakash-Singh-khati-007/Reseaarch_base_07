//
//  QuickAddSheetTests.swift
//  ResearchBase
//
//  Created by Gaurav Khati on 23/10/26.
//


//
//  QuickAddSheetTests.swift
//  Owner: Agent 58 (tests for QuickAddSheet.swift: QuickAddLogic)
//

import XCTest
@testable import ResearchBase

final class QuickAddSheetTests: XCTestCase {

    func testLinesSplitsAndDropsEmpty() {
        XCTAssertEqual(QuickAddLogic.lines("  10.1/a \n\n arXiv:1706.03762\r\n"), ["10.1/a", "arXiv:1706.03762"])
        XCTAssertTrue(QuickAddLogic.lines(" \n ").isEmpty)
    }

    func testFallbackForDOIKeepsIdentifierAndGoesToInbox() {
        let text = "10.1109/CVPR.2016.90"
        let item = QuickAddLogic.fallbackItem(for: text, identifier: MetadataResolver.identify(text))
        XCTAssertEqual(item.title, text)
        XCTAssertNotNil(item.doi)
        XCTAssertEqual(item.sourceKind, .doi)
        XCTAssertEqual(item.reviewState, .inbox)
    }

    func testFallbackForArXivIsPreprint() {
        let item = QuickAddLogic.fallbackItem(for: "arXiv:1706.03762", identifier: MetadataResolver.identify("arXiv:1706.03762"))
        XCTAssertEqual(item.arxivID, "1706.03762")
        XCTAssertEqual(item.type, .preprint)
        XCTAssertEqual(item.sourceKind, .arxiv)
    }

    func testFallbackForPlainTextIsManual() {
        let item = QuickAddLogic.fallbackItem(for: "attention paper", identifier: nil)
        XCTAssertEqual(item.sourceKind, .manual)
        XCTAssertNil(item.doi)
        XCTAssertEqual(item.reviewState, .inbox)
    }

    func testPDFNames() {
        let c = QuickAddLogic.creators(fromPDFNames: ["Kaiming He", "Zhang, Xiangyu", "  ", "UNESCO"])
        XCTAssertEqual(c.map(\.family), ["He", "Zhang", "UNESCO"])
        XCTAssertEqual(c.map(\.given), ["Kaiming", "Xiangyu", ""])
    }

    func testCancellation() {
        XCTAssertTrue(QuickAddLogic.isCancellation(URLError(.cancelled)))
        XCTAssertFalse(QuickAddLogic.isCancellation(URLError(.timedOut)))
    }
}