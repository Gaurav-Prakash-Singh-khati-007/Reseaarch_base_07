//
//  CitationGraphServiceTests.swift
//  ResearchBaseTests
//
//  Owner: Agent 37 · Features: F-25
//
//  Every test uses a temporary library and a fake transport. Nothing here
//  touches the network, the real library or the old store.
//

import XCTest
@testable import ResearchBase

// MARK: - Fake network

@MainActor
private final class FakeCitationTransport: CitationGraphTransport {

    var handler: (URL) throws -> (Data, Int)
    private(set) var urls: [URL] = []

    init(_ handler: @escaping (URL) throws -> (Data, Int)) {
        self.handler = handler
    }

    var calls: Int { urls.count }

    func get(_ url: URL) async throws -> (data: Data, status: Int) {
        urls.append(url)
        let (data, status) = try handler(url)
        return (data, status)
    }
}

private struct Offline: Error {}

// MARK: - Fixtures

private func json(_ object: Any) -> Data {
    (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
}

private func work(
    _ short: String, doi: String?, title: String, year: Int = 2019,
    venue: String = "Venue", type: String = "article", authors: [String] = ["Ada Lovelace"]
) -> [String: Any] {
    var object: [String: Any] = [
        "id": "https://openalex.org/\(short)",
        "title": title,
        "publication_year": year,
        "type": type,
        "primary_location": ["source": ["display_name": venue]],
        "authorships": authors.map { ["author": ["display_name": $0]] }
    ]
    if let doi { object["doi"] = "https://doi.org/\(doi)" }
    return object
}

private let ownWork: [String: Any] = [
    "id": "https://openalex.org/W1",
    "doi": "https://doi.org/10.1/own",
    "title": "Own Paper",
    "publication_year": 2020,
    "referenced_works": ["https://openalex.org/W2", "https://openalex.org/W3"],
    "cited_by_count": 10
]

/// Answers like OpenAlex for the library built by `makeLibrary`.
private func standardHandler() -> (URL) throws -> (Data, Int) {
    return { url in
        let text = url.absoluteString.removingPercentEncoding ?? url.absoluteString
        if text.contains("/works/doi:10.1/own") { return (json(ownWork), 200) }
        if text.contains("filter=openalex:") {
            return (json(["results": [
                work("W2", doi: "10.1/inlib", title: "In Library Ref"),
                work("W3", doi: "10.1/outlib", title: "Outside Ref", type: "proceedings-article")
            ]]), 200)
        }
        if text.contains("sort=cited_by_count:desc") {
            return (json(["results": [
                work("W4", doi: "10.1/citer", title: "Citer In Library"),
                work("W5", doi: "10.1/far", title: "Far Citer")
            ]]), 200)
        }
        if text.contains(",doi:") {
            return (json(["results": [work("W4", doi: "10.1/citer", title: "Citer In Library")]]), 200)
        }
        return (Data(), 404)
    }
}

// MARK: - Tests

@MainActor
final class CitationGraphServiceTests: XCTestCase {

    // MARK: Helpers

    private struct Library3 {
        let model: LibraryModel
        let own: ModelItem
        let inLib: ModelItem
        let citer: ModelItem
    }

    private func makeItem(
        _ model: LibraryModel, _ title: String, doi: String? = nil, arxiv: String? = nil, year: Int? = 2020
    ) throws -> ModelItem {
        var new = NewItem(title: title)
        new.year = year
        new.doi = doi
        new.arxivID = arxiv
        return try model.items.create(new)
    }

    private func cite(_ model: LibraryModel, _ from: ModelItem, _ to: ModelItem, rel: LinkRel = .cites) throws {
        try model.links.add(from: LinkEnd(.item, from.id), to: LinkEnd(.item, to.id), rel: rel)
    }

    private func makeLibrary() throws -> Library3 {
        let model = try ModelTestSupport.makeModel(self)
        addTeardownBlock { model.library.close() }
        return Library3(
            model: model,
            own: try makeItem(model, "Own Paper", doi: "10.1/own"),
            inLib: try makeItem(model, "In Library Ref", doi: "10.1/inlib"),
            citer: try makeItem(model, "Citer In Library", doi: "10.1/citer"))
    }

    private func service(
        _ model: LibraryModel,
        transport: FakeCitationTransport,
        online: Bool = true,
        config: CitationGraphConfig = CitationGraphConfig()
    ) -> CitationGraphService {
        CitationGraphService(model: model, transport: transport, config: config, isOnlineEnabled: { online })
    }

    // MARK: Local graph

    func testLocalGraphReadsCitesCitedByAndRelatedLinks() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        let a = try makeItem(model, "A")
        let b = try makeItem(model, "B")
        let c = try makeItem(model, "C")
        let d = try makeItem(model, "D")
        try cite(model, a, b)
        try cite(model, c, a)
        try cite(model, a, d, rel: .related)

        let transport = FakeCitationTransport { _ in throw Offline() }
        let graph = try service(model, transport: transport, online: false).localGraph(for: a.id)

        XCTAssertEqual(graph.cites.inLibrary.map(\.itemID), [b.id])
        XCTAssertEqual(graph.citedBy.inLibrary.map(\.itemID), [c.id])
        XCTAssertEqual(graph.related.map(\.itemID), [d.id])
        XCTAssertEqual(graph.source, .libraryOnly(reason: nil))
        XCTAssertEqual(transport.calls, 0)
    }

    func testLocalGraphIgnoresPapersInTheTrash() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        let a = try makeItem(model, "A")
        let b = try makeItem(model, "B")
        try cite(model, a, b)
        try ModelTestSupport.trash(model, itemID: b.id)

        let transport = FakeCitationTransport { _ in throw Offline() }
        let graph = try service(model, transport: transport).localGraph(for: a.id)

        XCTAssertTrue(graph.cites.inLibrary.isEmpty)
    }

    // MARK: Related by citations

    func testRelatedByCitationsFindsSharedReferencesAndCoCitations() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        let a = try makeItem(model, "A")
        let b = try makeItem(model, "B")
        let x = try makeItem(model, "X")
        let p = try makeItem(model, "P")
        let z = try makeItem(model, "Z")

        // A and B both cite X (shared reference).
        try cite(model, a, x)
        try cite(model, b, x)
        // P cites A and Z (cited together).
        try cite(model, p, a)
        try cite(model, p, z)

        let transport = FakeCitationTransport { _ in throw Offline() }
        let related = try service(model, transport: transport).relatedByCitations(itemID: a.id)

        let shared = Dictionary(uniqueKeysWithValues: related.map { ($0.ref.itemID, $0.shared) })
        XCTAssertEqual(shared[b.id], 1)
        XCTAssertEqual(shared[z.id], 1)
        XCTAssertNil(shared[a.id], "A paper is never related to itself")
        XCTAssertEqual(transport.calls, 0)
    }

    func testRelatedByCitationsRespectsLimit() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        let a = try makeItem(model, "A")
        let x = try makeItem(model, "X")
        try cite(model, a, x)
        for name in ["B", "C", "D"] {
            try cite(model, try makeItem(model, name), x)
        }

        let transport = FakeCitationTransport { _ in throw Offline() }
        let related = try service(model, transport: transport).relatedByCitations(itemID: a.id, limit: 2)
        XCTAssertEqual(related.count, 2)
    }

    // MARK: Online off / not possible

    func testOnlineOffMakesNoRequest() async throws {
        let lib = try makeLibrary()
        let transport = FakeCitationTransport(standardHandler())

        let graph = try await service(lib.model, transport: transport, online: false).graph(for: lib.own.id)

        XCTAssertEqual(graph.source, .libraryOnly(reason: "Online lookup is off."))
        XCTAssertEqual(transport.calls, 0)
    }

    func testPaperWithoutDOIOrArXivIDIsNeverSentAnywhere() async throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let bare = try makeItem(model, "No identifiers")
        let transport = FakeCitationTransport(standardHandler())

        let graph = try await service(model, transport: transport).graph(for: bare.id)

        XCTAssertEqual(transport.calls, 0)
        guard case .libraryOnly(let reason) = graph.source else { return XCTFail("expected library only") }
        XCTAssertTrue(reason?.contains("no DOI or arXiv ID") == true)
    }

    func testArXivOnlyPaperUsesItsDataCiteDOI() async throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let paper = try makeItem(model, "Preprint", arxiv: "1602.05629")
        let transport = FakeCitationTransport { _ in (Data(), 404) }

        _ = try await service(model, transport: transport).graph(for: paper.id)

        let first = transport.urls.first?.absoluteString.removingPercentEncoding ?? ""
        XCTAssertTrue(first.contains("/works/doi:10.48550/arxiv.1602.05629"), first)
    }

    // MARK: Live graph

    func testLiveGraphSplitsLibraryPapersFromTheRest() async throws {
        let lib = try makeLibrary()
        let transport = FakeCitationTransport(standardHandler())

        let graph = try await service(lib.model, transport: transport).graph(for: lib.own.id)

        // Cites
        XCTAssertEqual(graph.cites.inLibrary.map(\.itemID), [lib.inLib.id])
        XCTAssertEqual(graph.cites.elsewhere.map(\.doi), ["10.1/outlib"])
        XCTAssertEqual(graph.cites.elsewhere.first?.type, .conference)
        XCTAssertEqual(graph.cites.elsewhereTotal, 1)

        // Cited by
        XCTAssertEqual(graph.citedBy.inLibrary.map(\.itemID), [lib.citer.id])
        XCTAssertEqual(graph.citedBy.elsewhere.map(\.doi), ["10.1/far"])
        XCTAssertEqual(graph.citedBy.elsewhereTotal, 9)

        guard case .live = graph.source else { return XCTFail("expected a live graph, got \(graph.source)") }
        XCTAssertEqual(transport.calls, 4)
    }

    func testOnlyIdentifiersAreSentToTheNetwork() async throws {
        let lib = try makeLibrary()
        let transport = FakeCitationTransport(standardHandler())

        _ = try await service(lib.model, transport: transport).graph(for: lib.own.id)

        for url in transport.urls {
            let text = url.absoluteString.removingPercentEncoding ?? ""
            XCTAssertFalse(text.contains("Own Paper"), text)
            XCTAssertFalse(text.contains("In Library Ref"), text)
        }
    }

    func testContactEmailIsSentButNotPartOfTheCacheKey() async throws {
        let lib = try makeLibrary()
        let transport = FakeCitationTransport(standardHandler())
        var config = CitationGraphConfig()
        config.contactEmail = "me@example.org"

        _ = try await service(lib.model, transport: transport, config: config).graph(for: lib.own.id)

        let sent = transport.urls.map { $0.absoluteString.removingPercentEncoding ?? "" }
        XCTAssertTrue(sent.allSatisfy { $0.contains("mailto=me@example.org") })
        XCTAssertEqual(try ModelTestSupport.count(lib.model, "lookup_cache", where: "key LIKE '%mailto%'"), 0)
        XCTAssertGreaterThan(try ModelTestSupport.count(lib.model, "lookup_cache"), 0)
    }

    // MARK: Cache and offline

    func testFreshCacheIsUsedWithoutAskingTheNetwork() async throws {
        let lib = try makeLibrary()
        let transport = FakeCitationTransport(standardHandler())
        let svc = service(lib.model, transport: transport)

        _ = try await svc.graph(for: lib.own.id)
        let callsAfterFirst = transport.calls

        let second = try await svc.graph(for: lib.own.id)

        XCTAssertEqual(transport.calls, callsAfterFirst)
        guard case .cached(_, let because) = second.source else { return XCTFail("expected cached, got \(second.source)") }
        XCTAssertNil(because, "A fresh copy is not an error")
        XCTAssertEqual(second.cites.elsewhere.count, 1)
    }

    func testNetworkFailureShowsTheCachedCopyAndSaysSo() async throws {
        let lib = try makeLibrary()
        let transport = FakeCitationTransport(standardHandler())
        let svc = service(lib.model, transport: transport)
        _ = try await svc.graph(for: lib.own.id)

        transport.handler = { _ in throw Offline() }
        let refreshed = try await svc.graph(for: lib.own.id, forceRefresh: true)

        guard case .cached(_, let because) = refreshed.source else { return XCTFail("expected cached, got \(refreshed.source)") }
        XCTAssertEqual(because, "OpenAlex could not be reached.")
        XCTAssertEqual(refreshed.cites.elsewhere.map(\.doi), ["10.1/outlib"])
    }

    func testNetworkFailureWithNoCacheFallsBackToTheLibraryPart() async throws {
        let lib = try makeLibrary()
        try cite(lib.model, lib.own, lib.inLib)
        let transport = FakeCitationTransport { _ in throw Offline() }

        let graph = try await service(lib.model, transport: transport).graph(for: lib.own.id)

        XCTAssertEqual(graph.cites.inLibrary.map(\.itemID), [lib.inLib.id])
        XCTAssertTrue(graph.cites.elsewhere.isEmpty)
        XCTAssertEqual(graph.source, .libraryOnly(reason: "OpenAlex could not be reached. Showing your library only."))
    }

    func testUnknownPaperIsReportedPlainly() async throws {
        let lib = try makeLibrary()
        let transport = FakeCitationTransport { _ in (Data(), 404) }

        let graph = try await service(lib.model, transport: transport).graph(for: lib.own.id)

        XCTAssertEqual(graph.source, .libraryOnly(reason: "OpenAlex does not know this paper."))
    }

    func testServerErrorMentionsTheStatusAndKeepsTheLibraryPart() async throws {
        let lib = try makeLibrary()
        let transport = FakeCitationTransport { _ in (Data(), 500) }

        let graph = try await service(lib.model, transport: transport).graph(for: lib.own.id)

        guard case .libraryOnly(let reason) = graph.source else { return XCTFail("expected library only") }
        XCTAssertTrue(reason?.contains("(500)") == true)
    }

    func testUnreadableAnswerFallsBackToTheLibraryPart() async throws {
        let lib = try makeLibrary()
        let transport = FakeCitationTransport { _ in (Data("not json".utf8), 200) }

        let graph = try await service(lib.model, transport: transport).graph(for: lib.own.id)

        guard case .libraryOnly(let reason) = graph.source else { return XCTFail("expected library only") }
        XCTAssertTrue(reason?.contains("could not be read") == true)
    }

    // MARK: Saving links

    func testSaveLibraryLinksWritesEachLinkOnce() throws {
        let lib = try makeLibrary()
        let transport = FakeCitationTransport { _ in throw Offline() }
        let svc = service(lib.model, transport: transport)

        var cites = CitationSection()
        cites.inLibrary = [CitationLibraryRef(itemID: lib.inLib.id, title: "In Library Ref", year: 2020)]
        var citedBy = CitationSection()
        citedBy.inLibrary = [CitationLibraryRef(itemID: lib.citer.id, title: "Citer", year: 2020)]
        let graph = CitationGraph(
            itemID: lib.own.id, cites: cites, citedBy: citedBy, related: [], source: .live(fetchedAt: ""))

        XCTAssertEqual(try svc.saveLibraryLinks(from: graph), 2)
        XCTAssertEqual(try svc.saveLibraryLinks(from: graph), 0)
        XCTAssertEqual(try ModelTestSupport.count(lib.model, "links", where: "rel = 'cites'"), 2)

        let local = try svc.localGraph(for: lib.own.id)
        XCTAssertEqual(local.cites.inLibrary.map(\.itemID), [lib.inLib.id])
        XCTAssertEqual(local.citedBy.inLibrary.map(\.itemID), [lib.citer.id])
    }

    // MARK: Add to Inbox

    func testAddToInboxCreatesInboxPapersAndSkipsWhatIsAlreadyThere() throws {
        let lib = try makeLibrary()
        let transport = FakeCitationTransport { _ in throw Offline() }
        let svc = service(lib.model, transport: transport)

        let fresh = CitationExternalWork(
            openAlexID: "W9", doi: "10.1/new", title: "Brand New", year: 2021, venue: "NeurIPS",
            type: .conference, authors: ["Ada Lovelace", "Turing, Alan"])
        let duplicateOfFresh = fresh
        let alreadyThere = CitationExternalWork(
            openAlexID: "W2", doi: "10.1/inlib", title: "In Library Ref", year: 2019, venue: "",
            type: .article, authors: [])
        let untitled = CitationExternalWork(
            openAlexID: "W8", doi: nil, title: "   ", year: nil, venue: "", type: .article, authors: [])

        let result = try svc.addToInbox(
            [fresh, duplicateOfFresh, alreadyThere, untitled],
            relatedTo: lib.own.id, direction: .sourceCitesNew)

        XCTAssertEqual(result.added.count, 1)
        XCTAssertEqual(result.alreadyInLibrary, 2)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(result.linked, 2, "one link to the new paper, one to the paper already in the library")

        let newID = try XCTUnwrap(result.added.first)
        let item = try XCTUnwrap(try lib.model.items.fetch(id: newID))
        XCTAssertEqual(item.reviewState, .inbox)
        XCTAssertEqual(item.sourceKind, .import)
        XCTAssertEqual(item.sourceURL, "https://openalex.org/W9")
        XCTAssertEqual(item.doi, "10.1/new")
        XCTAssertEqual(item.type, .conference)

        let people = try lib.model.creators.creators(of: newID)
        XCTAssertEqual(people.map { $0.creator.family }, ["Lovelace", "Turing"])
        XCTAssertEqual(people.map { $0.creator.given }, ["Ada", "Alan"])

        // Direction: the paper on screen cites the new one.
        XCTAssertEqual(try ModelTestSupport.count(
            lib.model, "links", where: "from_id = '\(lib.own.id)' AND to_id = '\(newID)' AND rel = 'cites'"), 1)
    }

    func testAddToInboxCanLinkTheOtherWayRound() throws {
        let lib = try makeLibrary()
        let transport = FakeCitationTransport { _ in throw Offline() }
        let svc = service(lib.model, transport: transport)

        let citing = CitationExternalWork(
            openAlexID: "W7", doi: "10.1/citing", title: "Citing Paper", year: 2022, venue: "",
            type: .article, authors: [])
        let result = try svc.addToInbox([citing], relatedTo: lib.own.id, direction: .newCitesSource)

        let newID = try XCTUnwrap(result.added.first)
        XCTAssertEqual(try ModelTestSupport.count(
            lib.model, "links", where: "from_id = '\(newID)' AND to_id = '\(lib.own.id)' AND rel = 'cites'"), 1)
    }

    func testAddToInboxTwiceDoesNotCreateDuplicates() throws {
        let lib = try makeLibrary()
        let transport = FakeCitationTransport { _ in throw Offline() }
        let svc = service(lib.model, transport: transport)
        let work = CitationExternalWork(
            openAlexID: "W9", doi: "10.1/new", title: "Brand New", year: 2021, venue: "",
            type: .article, authors: [])

        let first = try svc.addToInbox([work], relatedTo: lib.own.id)
        let second = try svc.addToInbox([work], relatedTo: lib.own.id)

        XCTAssertEqual(first.added.count, 1)
        XCTAssertEqual(second.added.count, 0)
        XCTAssertEqual(second.alreadyInLibrary, 1)
        XCTAssertEqual(try ModelTestSupport.count(lib.model, "items", where: "doi = '10.1/new'"), 1)
        XCTAssertEqual(try ModelTestSupport.count(lib.model, "links", where: "rel = 'cites'"), 1)
    }

    // MARK: Parsing (pure)

    func testShortIDTakesTheLastPartOfTheURL() {
        XCTAssertEqual(CitationGraphService.shortID("https://openalex.org/W2741809807"), "W2741809807")
        XCTAssertEqual(CitationGraphService.shortID("W1"), "W1")
    }

    func testParseWorkReadsTheFieldsTheScreenNeeds() throws {
        var object = work("W42", doi: "10.1/ABC", title: "  Spaced Title ", year: 2018,
                          venue: "ICML", type: "proceedings-article",
                          authors: ["Ada Lovelace", "  ", "Alan Turing"])
        object["extra"] = "ignored"

        let parsed = try XCTUnwrap(CitationGraphService.parseWork(object))

        XCTAssertEqual(parsed.openAlexID, "W42")
        XCTAssertEqual(parsed.doi, "10.1/abc", "DOI is lower-cased with no URL prefix")
        XCTAssertEqual(parsed.title, "Spaced Title")
        XCTAssertEqual(parsed.year, 2018)
        XCTAssertEqual(parsed.venue, "ICML")
        XCTAssertEqual(parsed.type, .conference)
        XCTAssertEqual(parsed.authors, ["Ada Lovelace", "Alan Turing"])
    }

    func testParseWorkWithoutAnIDIsDropped() {
        XCTAssertNil(CitationGraphService.parseWork(["title": "No id"]))
        let data = json(["results": [["title": "No id"], work("W1", doi: nil, title: "Has id")]])
        let parsed = CitationGraphService.parseWorks(data)
        XCTAssertEqual(parsed.map(\.openAlexID), ["W1"])
        XCTAssertNil(parsed.first?.doi)
    }

    func testParseWorksOfGarbageIsEmpty() {
        XCTAssertTrue(CitationGraphService.parseWorks(Data("nope".utf8)).isEmpty)
        XCTAssertNil(CitationGraphService.parseWorkDetails(Data("nope".utf8)))
    }

    func testParseWorkDetailsReadsReferencesAndCount() throws {
        let details = try XCTUnwrap(CitationGraphService.parseWorkDetails(json(ownWork)))
        XCTAssertEqual(details.shortID, "W1")
        XCTAssertEqual(details.referencedIDs, ["W2", "W3"])
        XCTAssertEqual(details.citedByCount, 10)
    }

    func testMapTypeCoversTheKnownKinds() {
        XCTAssertEqual(CitationGraphService.mapType("preprint"), .preprint)
        XCTAssertEqual(CitationGraphService.mapType("book"), .book)
        XCTAssertEqual(CitationGraphService.mapType("book-chapter"), .chapter)
        XCTAssertEqual(CitationGraphService.mapType("dissertation"), .thesis)
        XCTAssertEqual(CitationGraphService.mapType("report"), .report)
        XCTAssertEqual(CitationGraphService.mapType("dataset"), .dataset)
        XCTAssertEqual(CitationGraphService.mapType("article"), .article)
        XCTAssertEqual(CitationGraphService.mapType(nil), .article)
        XCTAssertEqual(CitationGraphService.mapType("something-new"), .article)
    }

    func testWorkPathPrefersTheDOIThenArXiv() {
        XCTAssertEqual(
            CitationGraphService.workPath(doi: "https://doi.org/10.1/X", arxivID: "1602.05629"),
            "/works/doi:10.1/x")
        XCTAssertEqual(
            CitationGraphService.workPath(doi: nil, arxivID: "arXiv:1602.05629"),
            "/works/doi:10.48550/arxiv.1602.05629")
        XCTAssertNil(CitationGraphService.workPath(doi: "  ", arxivID: nil))
        XCTAssertNil(CitationGraphService.workPath(doi: nil, arxivID: nil))
    }

    func testDisplayNamesBecomeCreators() {
        let plain = CitationGraphService.creator(fromDisplayName: "Ada Byron Lovelace")
        XCTAssertEqual(plain.family, "Lovelace")
        XCTAssertEqual(plain.given, "Ada Byron")

        let inverted = CitationGraphService.creator(fromDisplayName: "Turing,  Alan")
        XCTAssertEqual(inverted.family, "Turing")
        XCTAssertEqual(inverted.given, "Alan")

        XCTAssertEqual(CitationGraphService.creator(fromDisplayName: "Voltaire").family, "Voltaire")
    }
}
