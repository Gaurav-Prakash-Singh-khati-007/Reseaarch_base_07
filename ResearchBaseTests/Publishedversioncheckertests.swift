//
//  PublishedVersionCheckerTests.swift
//  ResearchBaseTests
//
//  Owner: Agent 7 · Features: F-21
//
//  No test touches the real network: a stub fetcher answers from canned
//  Crossref / OpenAlex / arXiv bodies and records every request.
//

import XCTest
@testable import ResearchBase

// MARK: - Test doubles

nonisolated final class RBA7Recorder<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [T] = []
    func add(_ value: T) { lock.lock(); storage.append(value); lock.unlock() }
    var all: [T] { lock.lock(); defer { lock.unlock() }; return storage }
}

/// Answers from `route`. Returning nil makes the call throw (no connection).
nonisolated final class RBA7StubFetcher: PublishedVersionFetching, @unchecked Sendable {

    struct NoConnection: Error {}

    let requests = RBA7Recorder<URLRequest>()
    private let route: @Sendable (String) -> (Int, Data)?

    init(route: @escaping @Sendable (String) -> (Int, Data)?) { self.route = route }

    var urls: [String] { requests.all.compactMap { $0.url?.absoluteString } }

    func fetch(_ request: URLRequest) async throws -> (Data, Int) {
        requests.add(request)
        guard let answer = route(request.url?.absoluteString ?? "") else { throw NoConnection() }
        return (answer.1, answer.0)
    }
}

// MARK: - Canned bodies

nonisolated private func crossrefBody(
    preprintOf: [String] = [],
    subtype: String? = nil,
    updatedBy: [(type: String, doi: String)] = [],
    container: String? = nil,
    short: String? = nil,
    year: Int? = nil
) -> Data {
    var message: [String: Any] = [:]
    if !preprintOf.isEmpty {
        message["relation"] = ["is-preprint-of": preprintOf.map { ["id-type": "doi", "id": $0] }]
    }
    if let subtype { message["subtype"] = subtype }
    if !updatedBy.isEmpty {
        message["updated-by"] = updatedBy.map { ["type": $0.type, "DOI": $0.doi, "label": $0.type] }
    }
    if let container { message["container-title"] = [container] }
    if let short { message["short-container-title"] = [short] }
    if let year { message["issued"] = ["date-parts": [[year, 7, 1]]] }
    return try! JSONSerialization.data(withJSONObject: ["status": "ok", "message": message])
}

nonisolated private func openAlexBody(retracted: Bool) -> Data {
    try! JSONSerialization.data(withJSONObject: ["id": "https://openalex.org/W1", "is_retracted": retracted])
}

nonisolated private func arxivBody(doi: String?, journalRef: String? = nil) -> Data {
    var entry = "<id>http://arxiv.org/abs/1706.03762v5</id><title>Attention</title>"
    if let doi { entry += "<arxiv:doi xmlns:arxiv=\"http://arxiv.org/schemas/atom\">\(doi)</arxiv:doi>" }
    if let journalRef {
        entry += "<arxiv:journal_ref xmlns:arxiv=\"http://arxiv.org/schemas/atom\">\(journalRef)</arxiv:journal_ref>"
    }
    let xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom"><title>query</title><entry>\(entry)</entry></feed>
    """
    return Data(xml.utf8)
}

// MARK: - Tests

@MainActor
final class PublishedVersionCheckerTests: XCTestCase {

    private func checker(
        email: String? = nil,
        allowNetwork: Bool = true,
        _ stub: RBA7StubFetcher
    ) -> PublishedVersionChecker {
        PublishedVersionChecker(contactEmail: email, allowNetwork: allowNetwork, fetcher: stub)
    }

    // MARK: Published version

    func testPreprintWithPublishedVersion() async {
        let stub = RBA7StubFetcher { url in
            if url.contains("/works/10.1111/preprint.1") {
                return (200, crossrefBody(preprintOf: ["10.2222/Journal.2"], subtype: "preprint"))
            }
            if url.contains("/works/10.2222/journal.2") {
                return (200, crossrefBody(container: "Proceedings of ICML", short: "ICML", year: 2020))
            }
            if url.contains("openalex.org") { return (200, openAlexBody(retracted: false)) }
            return (404, Data())
        }

        let result = await checker(stub).check(PublishedVersionQuery(doi: "10.1111/preprint.1"))

        XCTAssertEqual(result.status, .checked)
        XCTAssertEqual(result.publishedDOI, "10.2222/journal.2")
        XCTAssertEqual(result.publishedVenue, "ICML")
        XCTAssertEqual(result.publishedYear, 2020)
        XCTAssertEqual(result.retraction, .noneFound)
        XCTAssertEqual(Set(result.sourcesAnswered), ["Crossref", "OpenAlex"])
        XCTAssertFalse(result.contactedArXiv, "Crossref already linked the published version")
        XCTAssertFalse(result.needsAttention)
        XCTAssertTrue(result.summaryLine.contains("Also published at ICML 2020"))
        XCTAssertEqual(stub.urls.count, 3)
    }

    func testArXivOnlyPaperGetsItsJournalDOI() async {
        let stub = RBA7StubFetcher { url in
            if url.contains("export.arxiv.org") { return (200, arxivBody(doi: "10.5555/journal.7")) }
            if url.contains("/works/10.5555/journal.7") {
                return (200, crossrefBody(container: "Journal of Examples", year: 2018))
            }
            if url.contains("openalex.org") { return (200, openAlexBody(retracted: false)) }
            return (404, Data())
        }

        let result = await checker(stub).check(PublishedVersionQuery(arxivID: "arXiv:1706.03762v5"))

        XCTAssertEqual(result.status, .checked)
        XCTAssertEqual(result.publishedDOI, "10.5555/journal.7")
        XCTAssertEqual(result.publishedVenue, "Journal of Examples")
        XCTAssertEqual(result.publishedYear, 2018)
        XCTAssertTrue(result.contactedArXiv)
        XCTAssertTrue(stub.urls.contains { $0.contains("id_list=1706.03762") && !$0.contains("v5") },
                      "prefix and version are stripped before asking arXiv")
    }

    func testArXivAnswerWithoutDOIMeansNotPublishedYet() async {
        let stub = RBA7StubFetcher { url in
            url.contains("export.arxiv.org") ? (200, arxivBody(doi: nil)) : (404, Data())
        }
        let result = await checker(stub).check(PublishedVersionQuery(arxivID: "1706.03762"))

        XCTAssertEqual(result.status, .checked)
        XCTAssertNil(result.publishedDOI)
        XCTAssertEqual(result.retraction, .unknown, "no retraction-aware source answered")
    }

    func testArXivDOIIsNotSentToCrossref() async {
        let stub = RBA7StubFetcher { url in
            url.contains("export.arxiv.org") ? (200, arxivBody(doi: nil)) : (404, Data())
        }
        _ = await checker(stub).check(PublishedVersionQuery(doi: "10.48550/arXiv.1706.03762"))

        XCTAssertFalse(stub.urls.contains { $0.contains("crossref.org") }, "arXiv DOIs are not at Crossref")
        XCTAssertTrue(stub.urls.contains { $0.contains("export.arxiv.org") && $0.contains("1706.03762") })
    }

    func testArticleThatIsNotAPreprintDoesNotAskArXiv() async {
        let stub = RBA7StubFetcher { url in
            if url.contains("crossref.org") { return (200, crossrefBody(container: "Nature", year: 2019)) }
            if url.contains("openalex.org") { return (200, openAlexBody(retracted: false)) }
            return (404, Data())
        }
        let result = await checker(stub).check(PublishedVersionQuery(doi: "10.1038/x1", arxivID: "1706.03762"))

        XCTAssertNil(result.publishedDOI)
        XCTAssertFalse(result.contactedArXiv)
        XCTAssertEqual(result.retraction, .noneFound)
    }

    // MARK: Retractions

    func testRetractionNoticeFromCrossref() async {
        let stub = RBA7StubFetcher { url in
            if url.contains("crossref.org") {
                return (200, crossrefBody(updatedBy: [("correction", "10.3333/fix.1"), ("retraction", "10.3333/Notice.1")]))
            }
            return (200, openAlexBody(retracted: false))
        }
        let result = await checker(stub).check(PublishedVersionQuery(doi: "10.3333/bad.1"))

        XCTAssertEqual(result.retraction, .retracted(noticeDOI: "10.3333/notice.1"))
        XCTAssertTrue(result.isRetracted)
        XCTAssertTrue(result.needsAttention)
        XCTAssertTrue(result.summaryLine.contains("retracted"))
    }

    func testRetractionFromOpenAlexWhenCrossrefDoesNotKnowThePaper() async {
        let stub = RBA7StubFetcher { url in
            url.contains("openalex.org") ? (200, openAlexBody(retracted: true)) : (404, Data())
        }
        let result = await checker(stub).check(PublishedVersionQuery(doi: "10.4444/x"))

        XCTAssertEqual(result.status, .checked)
        XCTAssertEqual(result.retraction, .retracted(noticeDOI: nil))
        XCTAssertEqual(result.sourcesAnswered, ["OpenAlex"])
    }

    func testExpressionOfConcernAndWithdrawal() async {
        let concern = RBA7StubFetcher { url in
            url.contains("crossref.org")
                ? (200, crossrefBody(updatedBy: [("expression_of_concern", "10.5.5/eoc")]))
                : (200, openAlexBody(retracted: false))
        }
        let a = await checker(concern).check(PublishedVersionQuery(doi: "10.6666/x"))
        XCTAssertEqual(a.retraction, .expressionOfConcern(noticeDOI: "10.5.5/eoc"))
        XCTAssertTrue(a.needsAttention)
        XCTAssertFalse(a.isRetracted)

        let withdrawn = RBA7StubFetcher { url in
            url.contains("crossref.org")
                ? (200, crossrefBody(updatedBy: [("withdrawal", "10.5.5/w")]))
                : (200, openAlexBody(retracted: false))
        }
        let b = await checker(withdrawn).check(PublishedVersionQuery(doi: "10.6666/y"))
        XCTAssertTrue(b.isRetracted)
    }

    func testRetractionOfThePublishedVersionIsFound() async {
        let stub = RBA7StubFetcher { url in
            if url.contains("/works/10.1111/pre.9") { return (200, crossrefBody(preprintOf: ["10.2222/pub.9"])) }
            if url.contains("/works/10.2222/pub.9") {
                return (200, crossrefBody(updatedBy: [("retraction", "10.2222/ret.9")], container: "J", year: 2021))
            }
            return (200, openAlexBody(retracted: false))
        }
        let result = await checker(stub).check(PublishedVersionQuery(doi: "10.1111/pre.9"))

        XCTAssertEqual(result.publishedDOI, "10.2222/pub.9")
        XCTAssertTrue(result.isRetracted)
    }

    // MARK: Failure, offline, nothing to check

    func testOfflineSwitchSendsNothing() async {
        let stub = RBA7StubFetcher { _ in (200, Data()) }
        let result = await checker(allowNetwork: false, stub).check(PublishedVersionQuery(doi: "10.1/x"))

        XCTAssertEqual(result.status, .offline)
        XCTAssertTrue(stub.urls.isEmpty)
    }

    func testNothingToCheck() async {
        let stub = RBA7StubFetcher { _ in (200, Data()) }
        let result = await checker(stub).check(PublishedVersionQuery(doi: "  ", arxivID: nil))

        XCTAssertEqual(result.status, .nothingToCheck)
        XCTAssertTrue(stub.urls.isEmpty)
    }

    func testEverySourceFailingIsAFailedCheck() async {
        let stub = RBA7StubFetcher { _ in nil }
        let result = await checker(stub).check(PublishedVersionQuery(doi: "10.1/x"))

        guard case .failed(let reason) = result.status else { return XCTFail("expected .failed") }
        XCTAssertTrue(reason.contains("Crossref"))
        XCTAssertEqual(result.retraction, .unknown)
    }

    func testRateLimitIsAFailureNotAnAnswer() async {
        let stub = RBA7StubFetcher { _ in (429, Data()) }
        let result = await checker(stub).check(PublishedVersionQuery(doi: "10.1/x"))

        guard case .failed(let reason) = result.status else { return XCTFail("expected .failed") }
        XCTAssertTrue(reason.contains("slow down"))
    }

    func testUnknownEverywhereIsCheckedButSaysNothing() async {
        let stub = RBA7StubFetcher { _ in (404, Data()) }
        let result = await checker(stub).check(PublishedVersionQuery(doi: "10.1/x"))

        XCTAssertEqual(result.status, .checked)
        XCTAssertEqual(result.retraction, .unknown)
        XCTAssertNil(result.publishedDOI)
        XCTAssertTrue(result.sourcesAnswered.isEmpty)
    }

    func testUnreadableAnswerIsAFailure() async {
        let stub = RBA7StubFetcher { _ in (200, Data("not json".utf8)) }
        let result = await checker(stub).check(PublishedVersionQuery(doi: "10.1/x"))

        if case .failed = result.status { } else { XCTFail("expected .failed") }
    }

    // MARK: Polite tier

    func testContactEmailIsSentOnlyWhenItLooksLikeOne() async {
        let withEmail = RBA7StubFetcher { _ in (404, Data()) }
        _ = await checker(email: "me@example.org", withEmail).check(PublishedVersionQuery(doi: "10.1/x"))
        XCTAssertTrue(withEmail.urls.allSatisfy { $0.contains("mailto=me@example.org") || $0.contains("mailto=me%40example.org") })
        XCTAssertTrue(withEmail.requests.all.allSatisfy {
            $0.value(forHTTPHeaderField: "User-Agent")?.contains("mailto:me@example.org") == true
        })

        let junk = RBA7StubFetcher { _ in (404, Data()) }
        _ = await checker(email: "not an email", junk).check(PublishedVersionQuery(doi: "10.1/x"))
        XCTAssertTrue(junk.urls.allSatisfy { !$0.contains("mailto") })
    }

    // MARK: Schedule

    func testIsDue() {
        let now = Date()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let threeDaysAgo = iso.string(from: now.addingTimeInterval(-3 * 86_400))
        let tenDaysAgo = iso.string(from: now.addingTimeInterval(-10 * 86_400))

        XCTAssertTrue(PublishedVersionChecker.isDue(lastCheckedAt: nil, interval: .weekly, now: now))
        XCTAssertTrue(PublishedVersionChecker.isDue(lastCheckedAt: "garbage", interval: .weekly, now: now))
        XCTAssertFalse(PublishedVersionChecker.isDue(lastCheckedAt: threeDaysAgo, interval: .weekly, now: now))
        XCTAssertTrue(PublishedVersionChecker.isDue(lastCheckedAt: tenDaysAgo, interval: .weekly, now: now))
        XCTAssertFalse(PublishedVersionChecker.isDue(lastCheckedAt: tenDaysAgo, interval: .monthly, now: now))
        XCTAssertFalse(PublishedVersionChecker.isDue(lastCheckedAt: nil, interval: .never, now: now))
    }

    // MARK: Many papers

    func testCheckManyPacesRequestsAndGivesArXivMoreRoom() async {
        let stub = RBA7StubFetcher { _ in (404, Data()) }
        let sleeps = RBA7Recorder<TimeInterval>()
        let seen = RBA7Recorder<String>()

        await checker(stub).checkMany(
            [("a", PublishedVersionQuery(doi: "10.1/a")),
             ("b", PublishedVersionQuery(arxivID: "1706.03762")),
             ("c", PublishedVersionQuery(doi: "10.1/c"))],
            pause: 1,
            sleep: { sleeps.add($0) },
            onResult: { id, _ in seen.add(id) }
        )

        XCTAssertEqual(seen.all, ["a", "b", "c"])
        XCTAssertEqual(sleeps.all, [1, 3, 1])
    }

    func testCheckManyStopsAfterThreeFailuresInARow() async {
        let stub = RBA7StubFetcher { _ in nil }
        let seen = RBA7Recorder<String>()

        await checker(stub).checkMany(
            (1...6).map { (id: "p\($0)", query: PublishedVersionQuery(doi: "10.1/p\($0)")) },
            pause: 0,
            sleep: { _ in },
            onResult: { id, _ in seen.add(id) }
        )

        XCTAssertEqual(seen.all, ["p1", "p2", "p3"])
    }

    func testCheckManyStopsRightAwayWhenOffline() async {
        let stub = RBA7StubFetcher { _ in (404, Data()) }
        let seen = RBA7Recorder<String>()

        await checker(allowNetwork: false, stub).checkMany(
            [("a", PublishedVersionQuery(doi: "10.1/a")), ("b", PublishedVersionQuery(doi: "10.1/b"))],
            pause: 0,
            sleep: { _ in },
            onResult: { id, _ in seen.add(id) }
        )

        XCTAssertEqual(seen.all, ["a"])
        XCTAssertTrue(stub.urls.isEmpty)
    }
}
