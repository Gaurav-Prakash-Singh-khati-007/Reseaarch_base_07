//
//  MetadataResolverTests.swift
//  ResearchBase
//
//  Created by Gaurav Khati on 20/10/26.
//


//
//  MetadataResolverTests.swift
//  ResearchBaseTests
//
//  Owner: Agent 5 · Features: F-15
//
//  No test touches the internet: a stub answers every request from a
//  table, and every library lives in a temporary folder.
//

import XCTest
@testable import ResearchBase

@MainActor
final class MetadataResolverTests: XCTestCase {

    // MARK: Stub network

    private final class StubHTTP: MetadataHTTPClient {

        enum Reply {
            case ok(String, contentType: String = "application/json")
            case status(Int)
            case fail(URLError.Code)
        }

        /// First entry whose key is contained in the request URL wins.
        var replies: [(contains: String, reply: Reply)] = []
        private(set) var requests: [URL] = []

        func on(_ contains: String, _ reply: Reply) {
            replies.append((contains, reply))
        }

        func send(_ request: URLRequest) async throws -> (data: Data, response: HTTPURLResponse) {

            let url = try XCTUnwrap(request.url)
            requests.append(url)

            guard let match = replies.first(where: { url.absoluteString.contains($0.contains) }) else {
                throw URLError(.cannotFindHost)
            }

            switch match.reply {
            case .ok(let body, let contentType):
                return (Data(body.utf8), response(url, 200, contentType))
            case .status(let code):
                return (Data(), response(url, code, "text/plain"))
            case .fail(let code):
                throw URLError(code)
            }
        }

        private func response(_ url: URL, _ status: Int, _ contentType: String) -> HTTPURLResponse {
            HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": contentType]
            )!
        }
    }

    // MARK: Fixtures

    private let crossrefJSON = """
    {"status":"ok","message":{
      "DOI":"10.1038/NATURE12373",
      "type":"journal-article",
      "title":["Nanometre-scale thermometry in a <i>living</i> cell &amp; more"],
      "subtitle":[],
      "container-title":["Nature"],
      "volume":"500","issue":"7460","page":"54-58",
      "publisher":"Springer Science and Business Media LLC",
      "author":[
        {"given":"G.","family":"Kucsko","ORCID":"http://orcid.org/0000-0002-1825-0097","sequence":"first"},
        {"given":"P. C.","family":"Maurer"},
        {"name":"The Diamond Consortium"}
      ],
      "issued":{"date-parts":[[2013,7,31]]},
      "created":{"date-parts":[[2013,8,1]]},
      "abstract":"<jats:p>Abstract. Sensitive probes of temperature.</jats:p>",
      "language":"en"
    }}
    """

    private let arxivFeed = """
    <?xml version="1.0" encoding="UTF-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom">
      <title type="html">ArXiv Query: search_query=&amp;id_list=1706.03762</title>
      <entry>
        <id>http://arxiv.org/abs/1706.03762v7</id>
        <published>2017-06-12T17:57:34Z</published>
        <title>Attention Is All
          You Need</title>
        <summary>  The dominant sequence transduction models are based on complex networks.
        </summary>
        <author><name>Ashish Vaswani</name></author>
        <author><name>Llion Jones</name></author>
        <author><name>Ludwig van Beethoven</name></author>
      </entry>
    </feed>
    """

    private let arxivErrorFeed = """
    <feed xmlns="http://www.w3.org/2005/Atom">
      <entry>
        <id>http://arxiv.org/api/errors#incorrect_id_format_for_9999</id>
        <title>Error</title>
        <summary>incorrect id format</summary>
      </entry>
    </feed>
    """

    private let dataciteCSL = """
    {"type":"dataset","title":"A Great Dataset","author":[{"family":"Doe","given":"Jane"}],
     "publisher":"Zenodo","issued":{"date-parts":[[2021]]},"DOI":"10.5281/zenodo.123"}
    """

    private let articleHTML = """
    <html><head>
    <title>Fallback title</title>
    <meta name="citation_title" content="A Study of Things">
    <meta name="citation_author" content="Smith, Alice">
    <meta name="citation_author" content="Bob van Dijk">
    <meta name="citation_publication_date" content="2020/05/17">
    <meta name="citation_journal_title" content="Journal of Things">
    <meta name="citation_volume" content="12">
    <meta name="citation_firstpage" content="100">
    <meta name="citation_lastpage" content="120">
    </head><body></body></html>
    """

    private let articleWithDOIHTML = """
    <html><head>
    <meta name="citation_title" content="Page version of title">
    <meta name="citation_doi" content="10.1038/nature12373">
    </head></html>
    """

    private let plainPageHTML = """
    <html><head><title>My Blog Post</title>
    <meta property="og:site_name" content="Example Blog">
    <meta property="og:description" content="A short description.">
    <meta property="article:published_time" content="2023-02-03T10:00:00Z">
    </head></html>
    """

    // MARK: Helpers

    private func makeResolver(
        http: StubHTTP,
        lifetime: TimeInterval = 30 * 24 * 3600,
        now: @escaping () -> Date = { Date() }
    ) throws -> (MetadataResolver, Library) {

        let folder = try TestSupport.makeTempDirectory(self)
            .appendingPathComponent(Library.folderName, isDirectory: true)
        let library = try Library.open(at: folder)
        addTeardownBlock { library.close() }

        return (MetadataResolver(database: library.database, http: http, cacheLifetime: lifetime, now: now), library)
    }

    private func cacheRowCount(_ library: Library) throws -> Int {
        Int(try library.database.scalarInt("SELECT COUNT(*) FROM lookup_cache") ?? -1)
    }

    // MARK: identify

    func testIdentifiesDOIsInEveryCommonShape() {
        let expected = MetadataIdentifier.doi("10.1038/nature12373")

        for text in [
            "10.1038/nature12373",
            "  10.1038/NATURE12373  ",
            "doi:10.1038/nature12373",
            "DOI: 10.1038/nature12373",
            "https://doi.org/10.1038/nature12373",
            "http://dx.doi.org/10.1038/nature12373",
            "10.1038/nature12373."
        ] {
            XCTAssertEqual(MetadataResolver.identify(text), expected, text)
        }
    }

    func testIdentifiesArxivInEveryCommonShape() {
        XCTAssertEqual(MetadataResolver.identify("arXiv:1706.03762"), .arxiv("1706.03762"))
        XCTAssertEqual(MetadataResolver.identify("arxiv:1706.03762v5"), .arxiv("1706.03762"))
        XCTAssertEqual(MetadataResolver.identify("1706.03762"), .arxiv("1706.03762"))
        XCTAssertEqual(MetadataResolver.identify("1706.03762v7"), .arxiv("1706.03762"))
        XCTAssertEqual(MetadataResolver.identify("https://arxiv.org/abs/1706.03762v2"), .arxiv("1706.03762"))
        XCTAssertEqual(MetadataResolver.identify("https://arxiv.org/pdf/1706.03762.pdf"), .arxiv("1706.03762"))
        XCTAssertEqual(MetadataResolver.identify("hep-th/9901001"), .arxiv("hep-th/9901001"))
        XCTAssertEqual(MetadataResolver.identify("https://arxiv.org/abs/hep-th/9901001"), .arxiv("hep-th/9901001"))
    }

    func testArxivDOIIsTreatedAsTheArxivID() {
        XCTAssertEqual(MetadataResolver.identify("10.48550/arXiv.1706.03762"), .arxiv("1706.03762"))
    }

    func testIdentifiesWebLinks() throws {
        XCTAssertEqual(
            MetadataResolver.identify("https://example.com/paper?id=3"),
            .url(try XCTUnwrap(URL(string: "https://example.com/paper?id=3")))
        )
        XCTAssertEqual(
            MetadataResolver.identify("www.example.com/a"),
            .url(try XCTUnwrap(URL(string: "https://www.example.com/a")))
        )
    }

    func testRejectsTextThatIsNothingUseful() {
        XCTAssertNil(MetadataResolver.identify(""))
        XCTAssertNil(MetadataResolver.identify("   "))
        XCTAssertNil(MetadataResolver.identify("attention is all you need"))
        XCTAssertNil(MetadataResolver.identify("ftp://example.com/file"))
    }

    func testResolveThrowsNotRecognisedWithoutTouchingTheNetwork() async throws {
        let http = StubHTTP()
        let (resolver, _) = try makeResolver(http: http)

        do {
            _ = try await resolver.resolve("hello there")
            XCTFail("should throw")
        } catch let error as MetadataError {
            guard case .notRecognised = error else { return XCTFail("wrong error \(error)") }
        }

        XCTAssertTrue(http.requests.isEmpty)
    }

    // MARK: DOI

    func testDOIIsFilledInFromCrossref() async throws {
        let http = StubHTTP()
        http.on("api.crossref.org/works/10.1038/nature12373", .ok(crossrefJSON))
        let (resolver, _) = try makeResolver(http: http)

        let m = try await resolver.resolve("https://doi.org/10.1038/NATURE12373")

        XCTAssertEqual(m.title, "Nanometre-scale thermometry in a living cell & more")
        XCTAssertEqual(m.type, .article)
        XCTAssertEqual(m.venue, "Nature")
        XCTAssertEqual(m.volume, "500")
        XCTAssertEqual(m.issue, "7460")
        XCTAssertEqual(m.pages, "54-58")
        XCTAssertEqual(m.year, 2013)
        XCTAssertEqual(m.month, 7)
        XCTAssertEqual(m.doi, "10.1038/nature12373")
        XCTAssertEqual(m.url, "https://doi.org/10.1038/nature12373")
        XCTAssertEqual(m.abstract, "Sensitive probes of temperature.")
        XCTAssertEqual(m.language, "en")
        XCTAssertEqual(m.source, .crossref)
        XCTAssertEqual(m.capturedVia, .doi)
        XCTAssertEqual(m.sourceURL, "https://doi.org/10.1038/nature12373")
        XCTAssertFalse(m.fromCache)

        XCTAssertEqual(m.creators.count, 3)
        XCTAssertEqual(m.creators[0].family, "Kucsko")
        XCTAssertEqual(m.creators[0].given, "G.")
        XCTAssertEqual(m.creators[0].orcid, "0000-0002-1825-0097")
        XCTAssertEqual(m.creators[2].family, "The Diamond Consortium")
        XCTAssertTrue(m.creators[2].isOrganisation)
    }

    func testUnknownToCrossrefFallsBackToDOIOrg() async throws {
        let http = StubHTTP()
        http.on("api.crossref.org", .status(404))
        http.on("https://doi.org/10.5281/zenodo.123", .ok(dataciteCSL, contentType: "application/vnd.citationstyles.csl+json"))
        let (resolver, _) = try makeResolver(http: http)

        let m = try await resolver.resolve("10.5281/zenodo.123")

        XCTAssertEqual(m.title, "A Great Dataset")
        XCTAssertEqual(m.type, .dataset)
        XCTAssertEqual(m.year, 2021)
        XCTAssertEqual(m.source, .doiCSL)
        XCTAssertEqual(m.creators.first?.family, "Doe")
    }

    func testDOINobodyKnowsIsNotFoundWithAFriendlyMessage() async throws {
        let http = StubHTTP()
        http.on("api.crossref.org", .status(404))
        http.on("https://doi.org/", .status(404))
        let (resolver, library) = try makeResolver(http: http)

        do {
            _ = try await resolver.resolve("10.9999/does-not-exist")
            XCTFail("should throw")
        } catch let error as MetadataError {
            guard case .notFound = error else { return XCTFail("wrong error \(error)") }
            XCTAssertTrue(error.localizedDescription.contains("by hand"))
        }

        XCTAssertEqual(try cacheRowCount(library), 0, "failures are never cached")
    }

    // MARK: arXiv

    func testArxivIsFilledInFromTheAtomFeed() async throws {
        let http = StubHTTP()
        http.on("export.arxiv.org", .ok(arxivFeed, contentType: "application/atom+xml"))
        let (resolver, _) = try makeResolver(http: http)

        let m = try await resolver.resolve("arXiv:1706.03762v5")

        XCTAssertEqual(m.title, "Attention Is All You Need")
        XCTAssertEqual(m.type, .preprint)
        XCTAssertEqual(m.arxivID, "1706.03762")
        XCTAssertEqual(m.year, 2017)
        XCTAssertEqual(m.month, 6)
        XCTAssertEqual(m.venue, "arXiv")
        XCTAssertEqual(m.url, "https://arxiv.org/abs/1706.03762")
        XCTAssertTrue(m.abstract.hasPrefix("The dominant sequence"))
        XCTAssertEqual(m.source, .arxiv)
        XCTAssertEqual(m.capturedVia, .arxiv)

        XCTAssertEqual(m.creators.map(\.family), ["Vaswani", "Jones", "van Beethoven"])
        XCTAssertEqual(m.creators.map(\.given), ["Ashish", "Llion", "Ludwig"])
    }

    func testArxivErrorEntryIsNotFound() async throws {
        let http = StubHTTP()
        http.on("export.arxiv.org", .ok(arxivErrorFeed, contentType: "application/atom+xml"))
        let (resolver, _) = try makeResolver(http: http)

        do {
            _ = try await resolver.resolve("arXiv:1706.03762")
            XCTFail("should throw")
        } catch let error as MetadataError {
            guard case .notFound = error else { return XCTFail("wrong error \(error)") }
        }
    }

    // MARK: web pages

    func testWebPageReadsCitationMetaTags() async throws {
        let http = StubHTTP()
        http.on("example.org/paper", .ok(articleHTML, contentType: "text/html; charset=utf-8"))
        let (resolver, _) = try makeResolver(http: http)

        let m = try await resolver.resolve("https://example.org/paper")

        XCTAssertEqual(m.title, "A Study of Things")
        XCTAssertEqual(m.type, .article)
        XCTAssertEqual(m.venue, "Journal of Things")
        XCTAssertEqual(m.volume, "12")
        XCTAssertEqual(m.pages, "100–120")
        XCTAssertEqual(m.year, 2020)
        XCTAssertEqual(m.month, 5)
        XCTAssertEqual(m.url, "https://example.org/paper")
        XCTAssertEqual(m.source, .web)
        XCTAssertEqual(m.capturedVia, .url)

        XCTAssertEqual(m.creators.map(\.family), ["Smith", "van Dijk"])
        XCTAssertEqual(m.creators.map(\.given), ["Alice", "Bob"])
    }

    func testWebPageWithADOIUsesTheDOIRecord() async throws {
        let http = StubHTTP()
        http.on("example.org/with-doi", .ok(articleWithDOIHTML, contentType: "text/html"))
        http.on("api.crossref.org", .ok(crossrefJSON))
        let (resolver, _) = try makeResolver(http: http)

        let m = try await resolver.resolve("https://example.org/with-doi")

        XCTAssertEqual(m.title, "Nanometre-scale thermometry in a living cell & more")
        XCTAssertEqual(m.doi, "10.1038/nature12373")
        // Still recorded as having arrived by link.
        XCTAssertEqual(m.capturedVia, .url)
        XCTAssertEqual(m.sourceURL, "https://example.org/with-doi")
    }

    func testPlainPageBecomesAWebpageItem() async throws {
        let http = StubHTTP()
        http.on("example.org/post", .ok(plainPageHTML, contentType: "text/html"))
        let (resolver, _) = try makeResolver(http: http)

        let m = try await resolver.resolve("https://example.org/post")

        XCTAssertEqual(m.type, .webpage)
        XCTAssertEqual(m.title, "My Blog Post")
        XCTAssertEqual(m.venue, "Example Blog")
        XCTAssertEqual(m.abstract, "A short description.")
        XCTAssertEqual(m.year, 2023)
        XCTAssertEqual(m.month, 2)
    }

    func testPDFLinkIsRefusedWithAnExplanation() async throws {
        let http = StubHTTP()
        http.on("example.org/file.pdf", .ok("%PDF-1.4", contentType: "application/pdf"))
        let (resolver, _) = try makeResolver(http: http)

        do {
            _ = try await resolver.resolve("https://example.org/file.pdf")
            XCTFail("should throw")
        } catch let error as MetadataError {
            guard case .badResponse = error else { return XCTFail("wrong error \(error)") }
        }
    }

    // MARK: cache

    func testSecondLookupComesFromTheCacheWithoutTheNetwork() async throws {
        let http = StubHTTP()
        http.on("api.crossref.org", .ok(crossrefJSON))
        let (resolver, library) = try makeResolver(http: http)

        let first = try await resolver.resolve("10.1038/nature12373")
        XCTAssertFalse(first.fromCache)
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(try cacheRowCount(library), 1)

        let second = try await resolver.resolve("doi:10.1038/NATURE12373")
        XCTAssertTrue(second.fromCache)
        XCTAssertFalse(second.isStale)
        XCTAssertEqual(http.requests.count, 1, "no second request")
        XCTAssertEqual(second.title, first.title)
        XCTAssertEqual(second.creators, first.creators)
        XCTAssertEqual(second.type, first.type)
        XCTAssertEqual(second.month, first.month)
    }

    func testForceRefreshAsksAgain() async throws {
        let http = StubHTTP()
        http.on("api.crossref.org", .ok(crossrefJSON))
        let (resolver, _) = try makeResolver(http: http)

        _ = try await resolver.resolve("10.1038/nature12373")
        _ = try await resolver.resolve("10.1038/nature12373", forceRefresh: true)

        XCTAssertEqual(http.requests.count, 2)
    }

    func testExpiredCacheIsRefreshed() async throws {
        let http = StubHTTP()
        http.on("api.crossref.org", .ok(crossrefJSON))

        var clock = Date()
        let (resolver, _) = try makeResolver(http: http, lifetime: 3_600, now: { clock })

        _ = try await resolver.resolve("10.1038/nature12373")
        clock = clock.addingTimeInterval(7_200)
        _ = try await resolver.resolve("10.1038/nature12373")

        XCTAssertEqual(http.requests.count, 2)
    }

    func testOfflineFallsBackToAnExpiredCacheEntryAndSaysSo() async throws {
        let http = StubHTTP()
        http.on("api.crossref.org", .ok(crossrefJSON))

        var clock = Date()
        let (resolver, _) = try makeResolver(http: http, lifetime: 3_600, now: { clock })

        _ = try await resolver.resolve("10.1038/nature12373")

        // Now the internet goes away and the entry is old.
        http.replies = [("api.crossref.org", .fail(.notConnectedToInternet))]
        clock = clock.addingTimeInterval(7_200)

        let m = try await resolver.resolve("10.1038/nature12373")

        XCTAssertTrue(m.fromCache)
        XCTAssertTrue(m.isStale)
        XCTAssertEqual(m.title, "Nanometre-scale thermometry in a living cell & more")
    }

    func testBusyServiceAlsoFallsBackToTheCache() async throws {
        let http = StubHTTP()
        http.on("api.crossref.org", .ok(crossrefJSON))
        let (resolver, _) = try makeResolver(http: http)

        _ = try await resolver.resolve("10.1038/nature12373")

        http.replies = [("api.crossref.org", .status(503))]
        let m = try await resolver.resolve("10.1038/nature12373", forceRefresh: true)

        XCTAssertTrue(m.isStale)
    }

    func testOfflineWithNothingCachedThrowsOffline() async throws {
        let http = StubHTTP()
        http.on("api.crossref.org", .fail(.notConnectedToInternet))
        let (resolver, _) = try makeResolver(http: http)

        do {
            _ = try await resolver.resolve("10.1038/nature12373")
            XCTFail("should throw")
        } catch let error as MetadataError {
            XCTAssertEqual(error, .offline)
            XCTAssertTrue(error.localizedDescription.contains("by hand"))
        }
    }

    func testNotFoundDoesNotFallBackToTheCache() async throws {
        let http = StubHTTP()
        http.on("api.crossref.org", .ok(crossrefJSON))
        let (resolver, _) = try makeResolver(http: http)

        _ = try await resolver.resolve("10.1038/nature12373")

        http.replies = [("api.crossref.org", .status(404)), ("https://doi.org/", .status(404))]

        do {
            _ = try await resolver.resolve("10.1038/nature12373", forceRefresh: true)
            XCTFail("a record that is really gone is not hidden by the cache")
        } catch let error as MetadataError {
            guard case .notFound = error else { return XCTFail("wrong error \(error)") }
        }
    }

    func testCachedReadsWithoutTheNetworkAndPurgeRemovesOldRows() async throws {
        let http = StubHTTP()
        http.on("api.crossref.org", .ok(crossrefJSON))
        let (resolver, library) = try makeResolver(http: http)

        XCTAssertNil(resolver.cached(.doi("10.1038/nature12373")))

        _ = try await resolver.resolve("10.1038/nature12373")

        XCTAssertNotNil(resolver.cached(.doi("10.1038/nature12373")))
        XCTAssertEqual(http.requests.count, 1)

        XCTAssertEqual(resolver.purgeCache(olderThan: Date().addingTimeInterval(-3_600)), 0)
        XCTAssertEqual(resolver.purgeCache(olderThan: Date().addingTimeInterval(3_600)), 1)
        XCTAssertEqual(try cacheRowCount(library), 0)
    }

    // MARK: ItemStore hand-off

    func testToNewItemCarriesEverythingItemStoreNeeds() async throws {
        let http = StubHTTP()
        http.on("api.crossref.org", .ok(crossrefJSON))
        let (resolver, _) = try makeResolver(http: http)

        let item = try await resolver.resolve("10.1038/nature12373").toNewItem()

        XCTAssertEqual(item.type, .article)
        XCTAssertEqual(item.title, "Nanometre-scale thermometry in a living cell & more")
        XCTAssertEqual(item.creators.count, 3)
        XCTAssertEqual(item.year, 2013)
        XCTAssertEqual(item.venue, "Nature")
        XCTAssertEqual(item.doi, "10.1038/nature12373")
        XCTAssertEqual(item.sourceKind, .doi)
        XCTAssertEqual(item.sourceURL, "https://doi.org/10.1038/nature12373")
    }
}