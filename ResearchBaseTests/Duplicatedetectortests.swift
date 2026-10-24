//
//  DuplicateDetectorTests.swift
//  ResearchBaseTests
//
//  Owner: Agent 8 · Features: F-18
//
//  The matching rules are tested on hand-built indexes (no database).
//  The reading side is tested on a real temporary library.
//

import XCTest
@testable import ResearchBase

// MARK: - Helpers for the pure tests

private let fedAvg = "Communication-Efficient Learning of Deep Networks from Decentralized Data"

nonisolated private func rbA8Entry(
    _ id: String,
    _ title: String,
    author: String? = "McMahan",
    year: Int? = 2017,
    doi: String? = nil,
    arxiv: String? = nil,
    inbox: Bool = false,
    trashed: Bool = false
) -> DuplicateIndex.Entry {
    DuplicateIndex.Entry(
        id: id, title: title, year: year, firstAuthorFamily: author,
        doi: doi, arxivID: arxiv, isInbox: inbox, isTrashed: trashed
    )
}

nonisolated private func rbA8Match(
    _ probe: DuplicateProbe, _ entries: [DuplicateIndex.Entry], files: [String: [String]] = [:], limit: Int = 10
) -> [DuplicateMatch] {
    DuplicateMatcher.matches(for: probe, in: DuplicateIndex(entries: entries, fileHashes: files), limit: limit)
}

// MARK: - Pure matching

final class DuplicateMatcherTests: XCTestCase {

    // MARK: Normalising

    func testTitleKey() {
        XCTAssertEqual(DuplicateMatcher.titleKey("The Art of  Lists!"), "art of lists")
        XCTAssertEqual(DuplicateMatcher.titleKey("Müller & Sons: Über Alles (arXiv 1234.5678)"), "muller and sons uber alles")
        XCTAssertEqual(DuplicateMatcher.titleKey("Federated Optimization [v2]"), "federated optimization")
        XCTAssertEqual(DuplicateMatcher.titleKey("(Only parentheses)"), "only parentheses")
        XCTAssertEqual(DuplicateMatcher.titleKey("  "), "")
        XCTAssertEqual(DuplicateMatcher.titleKey("A"), "a", "a lone article is not dropped")
    }

    func testMainTitleKey() {
        XCTAssertEqual(DuplicateMatcher.mainTitleKey("Deep Learning: A Survey"), "deep learning")
        XCTAssertEqual(DuplicateMatcher.mainTitleKey("Deep Learning - A Survey"), "deep learning")
        XCTAssertNil(DuplicateMatcher.mainTitleKey("Deep Learning"))
        XCTAssertNil(DuplicateMatcher.mainTitleKey("Well-known results"), "a hyphen inside a word is not a subtitle")
    }

    func testDiceSanity() {
        XCTAssertEqual(DuplicateMatcher.dice("night", "night"), 1.0, accuracy: 0.0001)
        XCTAssertEqual(DuplicateMatcher.dice("abcd", "wxyz"), 0.0, accuracy: 0.0001)
        XCTAssertGreaterThan(DuplicateMatcher.dice("federated optimization", "federated optimisation"), 0.9)
    }

    // MARK: Identifiers and files

    func testSameDOIIsCertainEvenWithADifferentTitle() {
        let found = rbA8Match(
            DuplicateProbe(doi: "https://doi.org/10.1109/CVPR.2016.90", title: "Something else entirely"),
            [rbA8Entry("a", "Deep Residual Learning", doi: "10.1109/cvpr.2016.90")]
        )
        XCTAssertEqual(found.map(\.itemID), ["a"])
        XCTAssertEqual(found[0].confidence, .certain)
        XCTAssertEqual(found[0].reasons, [.sameDOI])
        XCTAssertEqual(found[0].bannerText, "Already in your library (matched by DOI).")
    }

    func testArXivIDMatchIgnoresPrefixAndVersion() {
        let found = rbA8Match(
            DuplicateProbe(arxivID: "arXiv:1706.03762v5"),
            [rbA8Entry("a", "Attention Is All You Need", arxiv: "1706.03762")]
        )
        XCTAssertEqual(found.first?.reasons, [.sameArXivID])
        XCTAssertEqual(found.first?.confidence, .certain)
    }

    func testSameFileFingerprintIsCertain() {
        let hash = String(repeating: "ab", count: 32)
        let found = rbA8Match(
            DuplicateProbe(title: "Unrelated name", fileSHA256s: [hash.uppercased()]),
            [rbA8Entry("a", "Whatever it was called"), rbA8Entry("b", "Another")],
            files: ["b": [hash]]
        )
        XCTAssertEqual(found.map(\.itemID), ["b"])
        XCTAssertEqual(found[0].reasons, [.sameFile])
        XCTAssertEqual(found[0].confidence, .certain)
    }

    func testSeveralReasonsAreListedStrongestFirst() {
        let hash = String(repeating: "cd", count: 32)
        let found = rbA8Match(
            DuplicateProbe(doi: "10.1/x", title: fedAvg, year: 2017, firstAuthorFamily: "McMahan", fileSHA256s: [hash]),
            [rbA8Entry("a", fedAvg, doi: "10.1/x")],
            files: ["a": [hash]]
        )
        XCTAssertEqual(found[0].reasons, [.sameDOI, .sameFile, .sameTitle])
        XCTAssertEqual(found[0].matchedByText, "DOI, identical file and title")
    }

    // MARK: Titles

    func testSameTitleAnyCaseAccentsAndPunctuationWithSameAuthorAndYearIsLikely() {
        let found = rbA8Match(
            DuplicateProbe(title: "COMMUNICATION EFFICIENT LEARNING of deep networks from decentralised data!".replacingOccurrences(of: "decentralised", with: "decentralized"),
                           year: 2017, firstAuthorFamily: "mcmahan"),
            [rbA8Entry("a", fedAvg)]
        )
        XCTAssertEqual(found.first?.confidence, .likely)
        XCTAssertEqual(found.first?.reasons, [.sameTitle])
    }

    func testArXivSuffixInTheTitleIsIgnored() {
        let found = rbA8Match(
            DuplicateProbe(title: "Federated optimization in heterogeneous networks (arXiv 1812.06127)", firstAuthorFamily: "Li"),
            [rbA8Entry("a", "Federated Optimization in Heterogeneous Networks", author: "Li", year: 2020)]
        )
        XCTAssertEqual(found.first?.reasons, [.sameTitle])
        XCTAssertEqual(found.first?.confidence, .likely)
    }

    func testPreprintAndPaperOneYearApartStillMatch() {
        let found = rbA8Match(
            DuplicateProbe(title: fedAvg, year: 2016, firstAuthorFamily: "McMahan"),
            [rbA8Entry("a", fedAvg, year: 2017)]
        )
        XCTAssertEqual(found.first?.confidence, .likely)
    }

    func testSameLongTitleByADifferentFirstAuthorIsOnlyPossible() {
        let found = rbA8Match(
            DuplicateProbe(title: fedAvg, year: 2017, firstAuthorFamily: "Nobody"),
            [rbA8Entry("a", fedAvg)]
        )
        XCTAssertEqual(found.first?.confidence, .possible)
        XCTAssertEqual(found.first?.bannerText, "Possible duplicate (matched by title).")
    }

    func testDifferentAuthorAndFarApartYearsIsNotAMatch() {
        let found = rbA8Match(
            DuplicateProbe(title: fedAvg, year: 1990, firstAuthorFamily: "Nobody"),
            [rbA8Entry("a", fedAvg, year: 2017)]
        )
        XCTAssertTrue(found.isEmpty)
    }

    func testShortGenericTitleNeedsTheSameFirstAuthor() {
        let entries = [rbA8Entry("a", "Introduction", author: "Smith")]

        XCTAssertTrue(rbA8Match(DuplicateProbe(title: "Introduction", firstAuthorFamily: "Jones"), entries).isEmpty)
        XCTAssertTrue(rbA8Match(DuplicateProbe(title: "Introduction"), entries).isEmpty, "unknown author is not enough")
        XCTAssertEqual(rbA8Match(DuplicateProbe(title: "Introduction", firstAuthorFamily: "Smith"), entries).first?.itemID, "a")
    }

    func testTypoLevelDifferenceIsASimilarTitle() {
        let found = rbA8Match(
            DuplicateProbe(title: "Federated Optimisation in Heterogeneous Networks", year: 2020, firstAuthorFamily: "Li"),
            [rbA8Entry("a", "Federated Optimization in Heterogeneous Networks", author: "Li", year: 2020)]
        )
        XCTAssertEqual(found.first?.reasons, [.similarTitle])
        XCTAssertEqual(found.first?.confidence, .likely)
    }

    func testSameMainTitleWithASubtitleIsSimilar() {
        let found = rbA8Match(
            DuplicateProbe(title: "Federated Learning of Deep Networks", firstAuthorFamily: "Kone"),
            [rbA8Entry("a", "Federated Learning of Deep Networks: Strategies for Improving Communication", author: "Kone", year: 2016)]
        )
        XCTAssertEqual(found.first?.reasons, [.similarTitle])
    }

    func testUnrelatedTitlesDoNotMatch() {
        let found = rbA8Match(
            DuplicateProbe(title: "Attention Is All You Need", year: 2017, firstAuthorFamily: "Vaswani"),
            [rbA8Entry("a", fedAvg), rbA8Entry("b", "Deep Residual Learning for Image Recognition", author: "He", year: 2016)]
        )
        XCTAssertTrue(found.isEmpty)
    }

    func testDifferentDOIsKeepATitleMatchFromBeingMoreThanPossible() {
        let found = rbA8Match(
            DuplicateProbe(doi: "10.1/aaa", title: fedAvg, year: 2017, firstAuthorFamily: "McMahan"),
            [rbA8Entry("a", fedAvg, doi: "10.1/bbb")]
        )
        XCTAssertEqual(found.first?.reasons, [.sameTitle])
        XCTAssertEqual(found.first?.confidence, .possible)
    }

    // MARK: Result shape

    func testAnItemNeverMatchesItself() {
        let found = rbA8Match(
            DuplicateProbe(doi: "10.1/x", title: fedAvg, excludingItemID: "a"),
            [rbA8Entry("a", fedAvg, doi: "10.1/x")]
        )
        XCTAssertTrue(found.isEmpty)
    }

    func testSortedByConfidenceThenLimited() {
        let entries = [
            rbA8Entry("poss", fedAvg, author: "Other"),
            rbA8Entry("cert", "Different title entirely", doi: "10.1/x"),
            rbA8Entry("like", fedAvg)
        ]
        let probe = DuplicateProbe(doi: "10.1/x", title: fedAvg, year: 2017, firstAuthorFamily: "McMahan")

        XCTAssertEqual(rbA8Match(probe, entries).map(\.itemID), ["cert", "like", "poss"])
        XCTAssertEqual(rbA8Match(probe, entries, limit: 2).map(\.itemID), ["cert", "like"])
        XCTAssertTrue(rbA8Match(probe, entries, limit: 0).isEmpty)
    }

    func testInboxAndTrashFlagsAndBanner() {
        let found = rbA8Match(
            DuplicateProbe(doi: "10.1/x"),
            [rbA8Entry("a", "T", doi: "10.1/x", inbox: true), rbA8Entry("b", "U", doi: "10.1/x", trashed: true)]
        )
        let byID = Dictionary(uniqueKeysWithValues: found.map { ($0.itemID, $0) })
        XCTAssertEqual(byID["a"]?.isInInbox, true)
        XCTAssertEqual(byID["b"]?.isTrashed, true)
        XCTAssertEqual(byID["b"]?.bannerText, "In your Trash (matched by DOI).")
    }

    func testEmptyProbeFindsNothing() {
        XCTAssertTrue(rbA8Match(DuplicateProbe(), [rbA8Entry("a", fedAvg, doi: "10.1/x")]).isEmpty)
    }
}

// MARK: - Reading the real library

@MainActor
final class DuplicateDetectorTests: XCTestCase {

    private func make(_ model: LibraryModel, title: String = fedAvg, author: String = "McMahan",
                      year: Int? = 2017, doi: String? = nil, state: ReviewState = .accepted) throws -> ModelItem {
        try model.items.create(NewItem(
            type: .conference, title: title,
            creators: [CreatorInput(family: author, given: "B.")],
            year: year, doi: doi, reviewState: state
        ))
    }

    func testDuplicateOfAStoredItemByDOIAndTitle() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        let a = try make(model, doi: "10.1000/Same.1")
        let b = try make(model, doi: "https://doi.org/10.1000/same.1")
        _ = try make(model, title: "A completely different paper about graphs", author: "Other", year: 2001)

        let found = try DuplicateDetector(model: model).duplicates(of: a.id)

        XCTAssertEqual(found.map(\.itemID), [b.id], "not itself, not the unrelated paper")
        XCTAssertEqual(found[0].confidence, .certain)
        XCTAssertEqual(found[0].reasons, [.sameDOI, .sameTitle])
    }

    func testProbeForItemTakesFirstAuthorYearAndFiles() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        let a = try make(model)
        let attachment = try model.attachments.add(fileAt: try ModelTestSupport.makeFile(self), to: a.id)

        let probe = try DuplicateDetector(model: model).probe(forItem: a.id)

        XCTAssertEqual(probe.firstAuthorFamily, "McMahan")
        XCTAssertEqual(probe.year, 2017)
        XCTAssertEqual(probe.fileSHA256s, [attachment.sha256])
        XCTAssertEqual(probe.excludingItemID, a.id)
    }

    func testDroppedFileIsRecognisedByItsFingerprint() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let detector = DuplicateDetector(model: model)

        let a = try make(model, title: "Stored under a different name")
        try model.attachments.add(fileAt: try ModelTestSupport.makeFile(self, name: "one.pdf", content: "same bytes"), to: a.id)

        let dropped = try ModelTestSupport.makeFile(self, name: "download (1).pdf", content: "same bytes")
        let other = try ModelTestSupport.makeFile(self, name: "other.pdf", content: "different bytes")

        let hit = try detector.matches(for: DuplicateProbe(fileSHA256s: [try detector.fileFingerprint(of: dropped)]))
        XCTAssertEqual(hit.map(\.itemID), [a.id])
        XCTAssertEqual(hit.first?.reasons, [.sameFile])

        let miss = try detector.matches(for: DuplicateProbe(fileSHA256s: [try detector.fileFingerprint(of: other)]))
        XCTAssertTrue(miss.isEmpty)
    }

    func testTrashIsLeftOutUnlessAskedFor() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let detector = DuplicateDetector(model: model)

        let a = try make(model, doi: "10.1/trash")
        try ModelTestSupport.trash(model, itemID: a.id)
        let probe = DuplicateProbe(doi: "10.1/trash")

        XCTAssertTrue(try detector.matches(for: probe).isEmpty)

        let withTrash = try detector.matches(for: probe, includeTrashed: true)
        XCTAssertEqual(withTrash.map(\.itemID), [a.id])
        XCTAssertEqual(withTrash.first?.isTrashed, true)
    }

    func testInboxCopiesAreFoundAndFlagged() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        let waiting = try make(model, doi: "10.1/inbox", state: .inbox)

        let found = try DuplicateDetector(model: model).matches(for: DuplicateProbe(doi: "10.1/inbox"))
        XCTAssertEqual(found.map(\.itemID), [waiting.id])
        XCTAssertEqual(found.first?.isInInbox, true)
    }

    func testReasonsBetweenTwoItemsForTheMergeSheet() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        let a = try make(model)
        let b = try make(model)
        let c = try make(model, title: "Unrelated graph paper", author: "Other", year: 1999)
        for item in [a, b] {
            try model.attachments.add(fileAt: try ModelTestSupport.makeFile(self, content: "shared"), to: item.id)
        }

        let detector = DuplicateDetector(model: model)
        XCTAssertEqual(try detector.reasons(between: a.id, and: b.id), [.sameFile, .sameTitle])
        XCTAssertEqual(try detector.reasons(between: a.id, and: c.id), [])
    }

    func testBuildIndexOnceAndMatchManyPapers() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        let a = try make(model, doi: "10.1/one")
        let b = try make(model, title: "Federated Optimization in Heterogeneous Networks", author: "Li", year: 2020)

        let detector = DuplicateDetector(model: model)
        let index = try detector.buildIndex()

        XCTAssertEqual(detector.matches(for: DuplicateProbe(doi: "10.1/one"), in: index).map(\.itemID), [a.id])
        XCTAssertEqual(
            detector.matches(for: DuplicateProbe(title: "federated optimization in heterogeneous networks", year: 2020, firstAuthorFamily: "Li"), in: index).map(\.itemID),
            [b.id]
        )
    }

    func testUnknownItemThrows() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        XCTAssertThrowsError(try DuplicateDetector(model: model).probe(forItem: "nope")) { error in
            XCTAssertEqual(error as? ModelError, .notFound(kind: "paper", id: "nope"))
        }
    }
}
