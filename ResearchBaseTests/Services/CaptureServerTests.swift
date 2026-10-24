//
//  CaptureServerTests.swift
//  ResearchBase
//
//  Created by Gaurav Khati on 21/10/26.
//


//
//  CaptureServerTests.swift
//  ResearchBaseTests
//
//  Owner: Agent 30 · X-01. Most tests call `handle(_:)` directly (no network).
//  One test starts the real listener on a spare port and talks to it over loopback.
//

import XCTest
@testable import ResearchBase

@MainActor
final class CaptureServerTests: XCTestCase {

    private let token = "rb_0123456789abcdef0123456789abcdef"
    private let origin = "chrome-extension://abcdefgh"
    private let port: UInt16 = 24680

    // MARK: Helpers

    private func makeServer(
        _ model: LibraryModel, allowNoOrigin: Bool = false, port: UInt16? = nil
    ) -> CaptureServer {
        var config = CaptureConfig()
        config.port = port ?? self.port
        config.allowedOrigins = [origin]
        config.allowRequestsWithoutOrigin = allowNoOrigin
        return CaptureServer(model: model, token: token, config: config)
    }

    private func request(
        _ method: String, _ path: String, query: [String: String] = [:], body: Data = Data(),
        token sent: String? = nil, origin sentOrigin: String? = nil, host: String? = nil
    ) -> CaptureHTTPRequest {
        var headers = ["host": host ?? "127.0.0.1:\(port)"]
        headers["x-rb-token"] = sent ?? token
        headers["origin"] = sentOrigin ?? origin
        return CaptureHTTPRequest(method: method, path: path, query: query, headers: headers, body: body)
    }

    private func post(_ path: String, _ object: [String: Any]) throws -> CaptureHTTPRequest {
        request("POST", path, body: try JSONSerialization.data(withJSONObject: object))
    }

    private func pdfBytes(_ extra: String = "") -> Data { Data("%PDF-1.4 \(extra) fake".utf8) }

    private func count(_ model: LibraryModel, _ table: String, where clause: String = "1") throws -> Int {
        try ModelTestSupport.count(model, table, where: clause)
    }

    // MARK: Security

    func testPingAnswersWithTokenAndOrigin() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let response = makeServer(model).handle(request("GET", "/v1/ping"))

        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.json?["app"] as? String, "ResearchBase")
        XCTAssertEqual(response.json?["api"] as? Int, 1)
        XCTAssertEqual(response.headers["Access-Control-Allow-Origin"], origin)
    }

    func testWrongOrMissingTokenIsRefused() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let server = makeServer(model)

        XCTAssertEqual(server.handle(request("GET", "/v1/ping", token: "rb_wrong")).status, 401)
        XCTAssertEqual(server.handle(request("GET", "/v1/ping", token: "")).status, 401)

        var noToken = request("GET", "/v1/ping")
        noToken.headers["x-rb-token"] = nil
        XCTAssertEqual(server.handle(noToken).status, 401)
    }

    func testUnknownOriginIsRefusedEvenWithTheRightToken() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let response = makeServer(model).handle(request("GET", "/v1/ping", origin: "https://evil.example"))

        XCTAssertEqual(response.status, 403)
        XCTAssertNil(response.headers["Access-Control-Allow-Origin"], "no CORS for other sites")
    }

    func testMissingOriginIsRefusedUnlessAllowed() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        var noOrigin = request("GET", "/v1/ping")
        noOrigin.headers["origin"] = nil

        XCTAssertEqual(makeServer(model).handle(noOrigin).status, 403)
        XCTAssertEqual(makeServer(model, allowNoOrigin: true).handle(noOrigin).status, 200)
    }

    func testWrongHostIsRefused() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let server = makeServer(model)

        XCTAssertEqual(server.handle(request("GET", "/v1/ping", host: "evil.example")).status, 403)
        XCTAssertEqual(server.handle(request("GET", "/v1/ping", host: "127.0.0.1:9999")).status, 403)
        XCTAssertEqual(server.handle(request("GET", "/v1/ping", host: "localhost:\(port)")).status, 200)
    }

    func testPreflightNeedsOnlyAnAllowedOrigin() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let server = makeServer(model)

        var ok = request("OPTIONS", "/v1/capture")
        ok.headers["x-rb-token"] = nil
        let allowed = server.handle(ok)
        XCTAssertEqual(allowed.status, 204)
        XCTAssertTrue(allowed.headers["Access-Control-Allow-Headers"]?.contains("X-RB-Token") == true)

        var bad = ok
        bad.headers["origin"] = "https://evil.example"
        XCTAssertEqual(server.handle(bad).status, 403)
    }

    func testTokenCompareAndHelpers() {
        XCTAssertTrue(CaptureServer.constantTimeEqual("abc", "abc"))
        XCTAssertFalse(CaptureServer.constantTimeEqual("abc", "abd"))
        XCTAssertFalse(CaptureServer.constantTimeEqual("abc", "abcd"))
        XCTAssertFalse(CaptureServer.constantTimeEqual("", "a"))

        let a = CaptureServer.generateToken(), b = CaptureServer.generateToken()
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.count, 35)
        XCTAssertTrue(a.hasPrefix("rb_"))

        let masked = CaptureServer.maskedToken("rb_0123456789abcdef0123456789abc3f9a".replacingOccurrences(of: "abc3f9a", with: "xyz3f9a"))
        XCTAssertTrue(masked.hasPrefix("rb_•"))
        XCTAssertTrue(masked.hasSuffix("3f9a"))
        XCTAssertFalse(masked.contains("0123"))
    }

    func testServerWillNotStartWithoutAToken() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let server = CaptureServer(model: model, token: "short")

        XCTAssertThrowsError(try server.start()) { XCTAssertEqual($0 as? CaptureServerError, .noToken) }
        guard case .failed = server.state else { return XCTFail("state should be failed") }
    }

    // MARK: Routing

    func testUnknownAddressAndWrongMethod() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let server = makeServer(model)

        XCTAssertEqual(server.handle(request("GET", "/v2/ping")).status, 404)
        XCTAssertEqual(server.handle(request("GET", "/v1/capture")).status, 405)
        XCTAssertEqual(server.handle(request("GET", "/v1/attachments/x")).status, 405)
    }

    // MARK: Capture

    func testCaptureAddsAnInboxItemAndLogsIt() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let server = makeServer(model)

        let response = server.handle(try post("/v1/capture", [
            "url": "https://arxiv.org/abs/1602.05629",
            "title": "Communication-Efficient Learning of Deep Networks",
            "doi": "https://doi.org/10.48550/arXiv.1602.05629",
            "authors": "McMahan, Brendan; Moore, Eider",
            "abstract": "We present..."
        ]))

        XCTAssertEqual(response.status, 201)
        XCTAssertEqual(response.json?["status"] as? String, "added")
        let id = try XCTUnwrap(response.json?["itemId"] as? String)

        let item = try XCTUnwrap(try model.items.fetch(id: id))
        XCTAssertEqual(item.reviewState, .inbox)
        XCTAssertEqual(item.sourceKind, .browser)
        XCTAssertEqual(item.sourceURL, "https://arxiv.org/abs/1602.05629")
        XCTAssertEqual(item.arxivID, "1602.05629")
        XCTAssertEqual(item.type, .preprint)
        XCTAssertEqual(try model.creators.creators(of: id).map(\.creator.family), ["McMahan", "Moore"])

        XCTAssertEqual(try count(model, "capture_log", where: "result = 'added' AND via = 'browser' AND item_id = '\(id)'"), 1)
    }

    func testCaptureWithOnlyAnAddressGetsAReadableTitle() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let response = makeServer(model).handle(try post("/v1/capture", ["url": "https://example.org/papers/42"]))

        XCTAssertEqual(response.status, 201)
        XCTAssertEqual(response.json?["title"] as? String, "example.org · 42")
    }

    func testCapturingTheSamePaperTwiceIsADuplicate() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let server = makeServer(model)
        let body: [String: Any] = ["url": "https://example.org/p", "title": "A paper", "doi": "10.1000/xyz"]

        let first = server.handle(try post("/v1/capture", body))
        let second = server.handle(try post("/v1/capture", body))
        // Same DOI, different address and spelling: still the same paper.
        let third = server.handle(try post("/v1/capture", ["title": "Again", "doi": "DOI:10.1000/XYZ"]))

        XCTAssertEqual(first.status, 201)
        XCTAssertEqual(second.status, 200)
        XCTAssertEqual(second.json?["status"] as? String, "duplicate")
        XCTAssertEqual(second.json?["itemId"] as? String, first.json?["itemId"] as? String)
        XCTAssertEqual(third.json?["status"] as? String, "duplicate")
        XCTAssertEqual(try count(model, "items"), 1)
        XCTAssertEqual(try count(model, "capture_log", where: "result = 'duplicate'"), 2)
    }

    func testCaptureStoresAnEmbeddedPDF() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let pdf = pdfBytes("embedded").base64EncodedString()

        let response = makeServer(model).handle(try post("/v1/capture", [
            "url": "https://example.org/a", "title": "With PDF", "pdf": pdf
        ]))

        XCTAssertEqual(response.status, 201)
        let id = try XCTUnwrap(response.json?["itemId"] as? String)
        XCTAssertEqual(try count(model, "attachments", where: "item_id = '\(id)' AND kind = 'pdf' AND is_primary = 1"), 1)
    }

    func testBadInputIsRejectedAndLoggedWithoutCreatingAnything() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let server = makeServer(model)

        XCTAssertEqual(server.handle(request("POST", "/v1/capture", body: Data("not json".utf8))).status, 400)
        XCTAssertEqual(server.handle(try post("/v1/capture", [:])).status, 400)
        XCTAssertEqual(server.handle(try post("/v1/capture", ["url": "javascript:alert(1)"])).status, 400)
        XCTAssertEqual(server.handle(try post("/v1/capture", ["url": "file:///etc/passwd", "title": "x"])).status, 400)
        XCTAssertEqual(server.handle(try post("/v1/capture", [
            "url": "https://example.org/x", "title": "Bad pdf", "pdf": Data("hello".utf8).base64EncodedString()
        ])).status, 400)

        XCTAssertEqual(try count(model, "items"), 0)
        XCTAssertGreaterThanOrEqual(try count(model, "capture_log", where: "result = 'rejected'"), 4)
    }

    func testPausedServerTurnsCapturesAwayButStillPings() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let server = makeServer(model)
        server.isPaused = true

        XCTAssertEqual(server.handle(request("GET", "/v1/ping")).status, 200)
        XCTAssertEqual(server.handle(try post("/v1/capture", ["url": "https://example.org/a", "title": "T"])).status, 503)
        XCTAssertEqual(try count(model, "items"), 0)
        XCTAssertEqual(try count(model, "capture_log", where: "result = 'paused'"), 1)
    }

    func testCaptureCanFileIntoACollectionAndTag() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let collection = try model.collections.create(name: "Federated")

        let response = makeServer(model).handle(try post("/v1/capture", [
            "url": "https://example.org/a", "title": "Filed", "collectionId": collection.id, "tags": ["baseline", "read-later"]
        ]))

        let id = try XCTUnwrap(response.json?["itemId"] as? String)
        XCTAssertEqual(try model.collections.collections(containing: id).map(\.id), [collection.id])
        XCTAssertEqual(Set(try model.tags.tags(of: id).map(\.name)), ["baseline", "read-later"])
    }

    // MARK: Lookup

    func testLookupFindsByDOIArxivAndURL() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let server = makeServer(model)
        let added = server.handle(try post("/v1/capture", [
            "url": "https://arxiv.org/abs/1602.05629", "title": "FedAvg", "doi": "10.1000/abc"
        ]))
        let id = try XCTUnwrap(added.json?["itemId"] as? String)

        for query in [["doi": "10.1000/ABC"], ["arxiv": "arXiv:1602.05629"],
                      ["url": "https://arxiv.org/abs/1602.05629"], ["url": "https://arxiv.org/abs/1602.05629/"]] {
            let found = server.handle(request("GET", "/v1/lookup", query: query))
            XCTAssertEqual(found.json?["found"] as? Bool, true, "\(query)")
            XCTAssertEqual(found.json?["itemId"] as? String, id)
            XCTAssertEqual(found.json?["inInbox"] as? Bool, true)
        }

        XCTAssertEqual(server.handle(request("GET", "/v1/lookup", query: ["doi": "10.9/none"])).json?["found"] as? Bool, false)
        XCTAssertEqual(server.handle(request("GET", "/v1/lookup")).status, 400)
    }

    func testLookupIgnoresPapersInTheTrash() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let server = makeServer(model)
        let added = server.handle(try post("/v1/capture", ["title": "Gone", "doi": "10.1000/gone"]))
        try ModelTestSupport.trash(model, itemID: try XCTUnwrap(added.json?["itemId"] as? String))

        XCTAssertEqual(server.handle(request("GET", "/v1/lookup", query: ["doi": "10.1000/gone"])).json?["found"] as? Bool, false)
    }

    // MARK: Attachments

    func testAttachmentUploadAddsAPDFToAnExistingPaper() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let server = makeServer(model)
        let item = try ModelTestSupport.item(model)

        let ok = server.handle(request("POST", "/v1/attachments/\(item.id)", body: pdfBytes("upload")))

        XCTAssertEqual(ok.status, 200)
        XCTAssertEqual(try count(model, "attachments", where: "item_id = '\(item.id)'"), 1)
        XCTAssertEqual(try count(model, "capture_log", where: "result = 'attached'"), 1)
    }

    func testAttachmentUploadRefusesBadTargetsAndNonPDFs() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let server = makeServer(model)
        let item = try ModelTestSupport.item(model)

        XCTAssertEqual(server.handle(request("POST", "/v1/attachments/\(UUID().uuidString)", body: pdfBytes())).status, 404)
        XCTAssertEqual(server.handle(request("POST", "/v1/attachments/not-an-id", body: pdfBytes())).status, 400)
        XCTAssertEqual(server.handle(request("POST", "/v1/attachments/\(item.id)", body: Data("<html>".utf8))).status, 415)
        XCTAssertEqual(try count(model, "attachments"), 0)
    }

    // MARK: Collections and tags

    func testCollectionsAndTagsListNames() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        _ = try model.collections.create(name: "Thesis")
        _ = try model.tags.create(name: "baseline")
        let server = makeServer(model)

        let collections = server.handle(request("GET", "/v1/collections")).json?["collections"] as? [[String: Any]]
        let tags = server.handle(request("GET", "/v1/tags")).json?["tags"] as? [[String: Any]]

        XCTAssertEqual(collections?.compactMap { $0["name"] as? String }, ["Thesis"])
        XCTAssertEqual(tags?.compactMap { $0["name"] as? String }, ["baseline"])
    }

    // MARK: HTTP parsing

    func testParseRequestReadsMethodPathQueryHeadersAndBody() {
        let raw = "POST /v1/capture?x=1&y=a%20b HTTP/1.1\r\nHost: 127.0.0.1:24680\r\nX-RB-Token: t\r\nContent-Length: 5\r\n\r\nhello"

        guard case .request(let r) = CaptureServer.parseRequest(Data(raw.utf8)) else { return XCTFail("not parsed") }

        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.path, "/v1/capture")
        XCTAssertEqual(r.query, ["x": "1", "y": "a b"])
        XCTAssertEqual(r.headers["x-rb-token"], "t")
        XCTAssertEqual(String(data: r.body, encoding: .utf8), "hello")
    }

    func testParseRequestWaitsForTheRestOfTheBody() {
        let partialHeader = Data("GET /v1/ping HTTP/1.1\r\nHost: x".utf8)
        let partialBody = Data("POST /a HTTP/1.1\r\nContent-Length: 10\r\n\r\nabc".utf8)

        guard case .incomplete = CaptureServer.parseRequest(partialHeader) else { return XCTFail("header") }
        guard case .incomplete = CaptureServer.parseRequest(partialBody) else { return XCTFail("body") }
    }

    func testParseRequestRefusesBadAndOversizedInput() {
        func status(_ text: String, maxBody: Int = 1000) -> Int? {
            if case .rejected(let s, _) = CaptureServer.parseRequest(Data(text.utf8), maxBodyBytes: maxBody) { return s }
            return nil
        }
        XCTAssertEqual(status("garbage\r\n\r\n"), 400)
        XCTAssertEqual(status("GET /a HTTP/1.1\r\nbadheader\r\n\r\n"), 400)
        XCTAssertEqual(status("POST /a HTTP/1.1\r\nContent-Length: 5000\r\n\r\n", maxBody: 1000), 413)
        XCTAssertEqual(status("POST /a HTTP/1.1\r\nContent-Length: -1\r\n\r\n"), 400)
        XCTAssertEqual(status("POST /a HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"), 400)
        XCTAssertEqual(status("GET /../etc/passwd HTTP/1.1\r\n\r\n"), 400)
        XCTAssertEqual(status("GET relative HTTP/1.1\r\n\r\n"), 400)
    }

    func testResponseSerializesWithLengthAndNoStore() throws {
        let wire = String(data: CaptureServer.json(200, ["ok": true]).serialized(), encoding: .utf8) ?? ""

        XCTAssertTrue(wire.hasPrefix("HTTP/1.1 200 OK\r\n"), wire)
        XCTAssertTrue(wire.contains("Content-Length: 11\r\n"), wire)
        XCTAssertTrue(wire.contains("Cache-Control: no-store"), wire)
        XCTAssertTrue(wire.hasSuffix("\r\n\r\n{\"ok\":true}"), wire)
    }

    func testArxivIDIsOnlyTakenFromArxivAddresses() {
        XCTAssertEqual(CaptureServer.arxivID(fromAddress: "https://arxiv.org/abs/1602.05629v2?x=1"), "1602.05629v2")
        XCTAssertEqual(CaptureServer.arxivID(fromAddress: "https://arxiv.org/pdf/1602.05629.pdf"), "1602.05629")
        XCTAssertNil(CaptureServer.arxivID(fromAddress: "https://example.org/papers/42"))
        XCTAssertNil(CaptureServer.arxivID(fromAddress: ""))
    }

    func testPlainAddressIsNeverStoredAsAnArxivID() throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let response = makeServer(model).handle(try post("/v1/capture", ["url": "https://example.org/papers/42", "title": "T"]))
        let id = try XCTUnwrap(response.json?["itemId"] as? String)

        XCTAssertNil(try XCTUnwrap(try model.items.fetch(id: id)).arxivID)
        XCTAssertEqual(try XCTUnwrap(try model.items.fetch(id: id)).type, .article)
    }

    func testParseAuthorsFormats() {
        func families(_ value: Any?) -> [String] { CaptureServer.parseAuthors(value).map(\.family) }

        XCTAssertEqual(families("Vaswani, Ashish; Shazeer, Noam"), ["Vaswani", "Shazeer"])
        XCTAssertEqual(families("Ashish Vaswani and Noam Shazeer"), ["Vaswani", "Shazeer"])
        XCTAssertEqual(families(["Ada Lovelace", "Turing, Alan"]), ["Lovelace", "Turing"])
        XCTAssertEqual(families(nil), [])
        XCTAssertEqual(families(42), [])
    }

    // MARK: Real socket

    func testRealListenerAnswersOverLoopbackAndRefusesAnOpenRequest() async throws {
        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }
        let spare = UInt16.random(in: 36000...39000)
        let server = makeServer(model, port: spare)
        defer { server.stop() }

        try server.start()
        var waited = 0
        while server.state != .listening(port: spare), waited < 60 {
            try await Task.sleep(nanoseconds: 50_000_000)
            waited += 1
        }
        guard server.state == .listening(port: spare) else {
            throw XCTSkip("Could not listen on port \(spare): \(server.state)")
        }

        let url = URL(string: "http://127.0.0.1:\(spare)/v1/ping")!

        var good = URLRequest(url: url)
        good.setValue(token, forHTTPHeaderField: "X-RB-Token")
        good.setValue(origin, forHTTPHeaderField: "Origin")
        let (data, response) = try await URLSession.shared.data(for: good)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["app"] as? String, "ResearchBase")

        let (_, refused) = try await URLSession.shared.data(from: url)   // no token, no origin
        XCTAssertEqual((refused as? HTTPURLResponse)?.statusCode, 403)

        server.stop()
        XCTAssertEqual(server.state, .stopped)
    }
}