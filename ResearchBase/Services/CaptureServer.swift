//
//  CaptureServer.swift
//  ResearchBase
//
//  Owner: Agent 30 · Features: X-01 (local capture endpoint)
//
//  A small HTTP server for a future browser extension. It listens on
//  127.0.0.1 only, is OFF until `start()` is called, and answers only
//  requests that carry the secret token and an allowed Origin.
//
//      GET  /v1/ping                        {"app":"ResearchBase","api":1}
//      GET  /v1/lookup?doi=|arxiv=|url=     is it already in the library?
//      POST /v1/capture                     {url, title?, doi?, authors?, abstract?, pdf?: base64}
//      POST /v1/attachments/{itemId}        PDF bytes the browser downloaded
//      GET  /v1/collections                 names for a "save into…" menu
//      GET  /v1/tags                        tag names for suggestions
//
//  Every paper that arrives (or is turned away) is written to `capture_log`.
//  New papers land in the Inbox (review_state = 'inbox', source_kind = 'browser').
//
//  PUBLIC API
//    struct CaptureConfig               port, allowed origins, limits
//    enum CaptureServerState            .stopped, .listening(port:), .failed(String)
//    struct CaptureHTTPRequest / CaptureHTTPResponse
//    @MainActor final class CaptureServer
//      init(model: LibraryModel, token: String, config: CaptureConfig = .init())
//      var state: CaptureServerState
//      var onStateChange: ((CaptureServerState) -> Void)?
//      var isPaused: Bool                      "Pause capture" in the menu bar (X-02)
//      func start() throws                     binds 127.0.0.1:<port>
//      func stop()
//      func updateToken(_:)                    after "Regenerate"
//      func updateAllowedOrigins(_:)
//      func handle(_ request:) -> CaptureHTTPResponse     the whole API, no network needed
//      static func generateToken() -> String             "rb_" + 32 hex characters
//      static func maskedToken(_:) -> String             "rb_••••••••••••••••3f9a"
//      static func parseRequest(_ data: Data) -> CaptureParseResult   pure HTTP parsing
//
//  Rules this file follows
//    * Schema is frozen: it writes only items (through ItemStore), attachments (through
//      AttachmentStore), item_tags / collection_items (through TagStore / CollectionStore)
//      and capture_log, all of which exist.
//    * It never deletes or overwrites anything. A paper that is already in the library
//      is reported as a duplicate, not added again.
//    * The token is held in memory. Storing it (Keychain, F-56) belongs to Agent 2 and the
//      Settings screen; this file only receives it.
//    * Loopback only. The listener refuses to bind to anything else, and a request whose Host
//      header is not 127.0.0.1 or localhost is refused (this blocks DNS-rebinding pages).
//

import Foundation
import Network
import Security

// MARK: - Configuration and state

nonisolated struct CaptureConfig: Equatable {

    static let defaultPort: UInt16 = 24680

    var port: UInt16 = CaptureConfig.defaultPort

    /// Origins the extension may call from, e.g. "chrome-extension://abcdefgh".
    var allowedOrigins: Set<String> = []

    /// Browsers always send Origin. Tools like curl do not. Off by default (the spec asks for both).
    var allowRequestsWithoutOrigin = false

    /// Largest request body accepted (a base64 PDF is about a third bigger than the PDF).
    var maxBodyBytes = 100 * 1024 * 1024

    /// Largest request header block accepted.
    var maxHeaderBytes = 16 * 1024

    /// A connection that sends nothing for this long is dropped.
    var idleTimeout: TimeInterval = 15
}

nonisolated enum CaptureServerState: Equatable {
    case stopped
    case listening(port: UInt16)
    case failed(String)
}

// MARK: - HTTP value types

nonisolated struct CaptureHTTPRequest {
    var method: String
    /// Path without the query string, e.g. "/v1/lookup".
    var path: String
    var query: [String: String]
    /// Header names are lower-cased.
    var headers: [String: String]
    var body: Data

    init(method: String, path: String, query: [String: String] = [:],
         headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }
}

nonisolated struct CaptureHTTPResponse {
    var status: Int
    var headers: [String: String] = [:]
    var body: Data = Data()

    /// The body as a JSON object, for tests and callers.
    var json: [String: Any]? {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    var jsonArray: [Any]? {
        (try? JSONSerialization.jsonObject(with: body)) as? [Any]
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 408: return "Request Timeout"
        case 409: return "Conflict"
        case 413: return "Payload Too Large"
        case 415: return "Unsupported Media Type"
        case 503: return "Service Unavailable"
        default: return status < 400 ? "OK" : "Error"
        }
    }

    /// The bytes sent on the wire.
    func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        var all = headers
        all["Content-Length"] = String(body.count)
        all["Connection"] = "close"
        all["Cache-Control"] = "no-store"
        all["X-Content-Type-Options"] = "nosniff"
        for (name, value) in all.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }
}

nonisolated enum CaptureParseResult {
    /// Not enough bytes yet.
    case incomplete
    case request(CaptureHTTPRequest)
    /// The request can never be valid; send this status and close.
    case rejected(status: Int, message: String)
}

// MARK: - Server

@MainActor
final class CaptureServer {

    // MARK: State

    let model: LibraryModel
    private(set) var config: CaptureConfig
    private var token: String

    private(set) var state: CaptureServerState = .stopped {
        didSet { if state != oldValue { onStateChange?(state) } }
    }

    var onStateChange: ((CaptureServerState) -> Void)?

    /// While paused, the server stays up and answers /v1/ping, but turns captures away.
    var isPaused = false

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "researchbase.capture", qos: .userInitiated)
    private var connections: [ObjectIdentifier: CaptureConnection] = [:]

    init(model: LibraryModel, token: String, config: CaptureConfig = CaptureConfig()) {
        self.model = model
        self.token = token
        self.config = config
    }

    // MARK: Settings the Settings screen changes

    func updateToken(_ newToken: String) { token = newToken }

    func updateAllowedOrigins(_ origins: Set<String>) { config.allowedOrigins = origins }

    // MARK: Tokens

    /// "rb_" followed by 32 random hex characters (128 bits).
    static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            bytes = (0..<16).map { _ in UInt8.random(in: 0...255) }
        }
        return "rb_" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// "rb_••••••••••••••••3f9a": the first three and last four characters only.
    static func maskedToken(_ token: String) -> String {
        guard token.count > 8 else { return String(repeating: "•", count: max(token.count, 1)) }
        return String(token.prefix(3)) + String(repeating: "•", count: 16) + String(token.suffix(4))
    }

    // MARK: Start and stop

    /// Starts listening on 127.0.0.1. Does nothing when already listening.
    /// An empty token is refused, so the server can never run open.
    func start() throws {

        if case .listening = state { return }

        guard token.count >= 16 else {
            state = .failed("The capture token is missing or too short.")
            throw CaptureServerError.noToken
        }
        guard let port = NWEndpoint.Port(rawValue: config.port), config.port != 0 else {
            state = .failed("The port number is not valid.")
            throw CaptureServerError.badPort
        }

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: port)
        parameters.allowLocalEndpointReuse = true

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            state = .failed("Could not listen on port \(config.port): \(error.localizedDescription)")
            throw CaptureServerError.cannotListen(error.localizedDescription)
        }

        listener.stateUpdateHandler = { [weak self] newState in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.listenerChanged(newState, port: self.config.port)
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in self?.accept(connection) }
        }

        self.listener = listener
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        state = .stopped
    }

    private func listenerChanged(_ newState: NWListener.State, port: UInt16) {
        switch newState {
        case .ready:
            state = .listening(port: port)
        case .failed(let error):
            listener?.cancel()
            listener = nil
            state = .failed("Capture could not start on port \(port). Another app may be using it. (\(error.localizedDescription))")
        case .cancelled:
            if case .failed = state { return }
            state = .stopped
        default:
            break
        }
    }

    private func accept(_ nwConnection: NWConnection) {

        // Belt and braces: the listener is bound to loopback, but refuse anything else anyway.
        if case let .hostPort(host, _) = nwConnection.endpoint, !Self.isLoopback(host) {
            nwConnection.cancel()
            return
        }

        let connection = CaptureConnection(
            connection: nwConnection, queue: queue, config: config,
            respond: { [weak self] request in
                await self?.handleAsync(request) ?? CaptureServer.json(503, ["error": "Capture is not running."])
            },
            finished: { [weak self] id in
                Task { @MainActor in self?.connections.removeValue(forKey: id) }
            })
        connections[ObjectIdentifier(connection)] = connection
        connection.start()
    }

    nonisolated private static func isLoopback(_ host: NWEndpoint.Host) -> Bool {
        switch host {
        case .ipv4(let address): return address == IPv4Address.loopback
        case .ipv6(let address): return address == IPv6Address.loopback
        case .name(let name, _): return name == "localhost"
        @unknown default: return false
        }
    }

    private func handleAsync(_ request: CaptureHTTPRequest) async -> CaptureHTTPResponse {
        handle(request)
    }

    // MARK: - The API (no network needed)

    /// Checks the request, runs it and returns the answer. Never throws.
    func handle(_ request: CaptureHTTPRequest) -> CaptureHTTPResponse {

        // 1. Host: only the loopback names, with our port. Blocks DNS rebinding.
        guard hostIsAllowed(request) else {
            return Self.json(403, ["error": "Wrong host."])
        }

        let origin = request.headers["origin"]

        // 2. Preflight: the browser asks before sending the token, so only the Origin is checked.
        if request.method == "OPTIONS" {
            guard let origin, config.allowedOrigins.contains(origin) else {
                return Self.json(403, ["error": "This origin is not allowed."])
            }
            return withCORS(CaptureHTTPResponse(status: 204), origin: origin, preflight: true)
        }

        // 3. Origin.
        if let origin {
            guard config.allowedOrigins.contains(origin) else {
                return Self.json(403, ["error": "This origin is not allowed."])
            }
        } else if !config.allowRequestsWithoutOrigin {
            return Self.json(403, ["error": "An allowed Origin is required."])
        }

        // 4. Token.
        guard let sent = request.headers["x-rb-token"], Self.constantTimeEqual(sent, token) else {
            return withCORS(Self.json(401, ["error": "Missing or wrong token."]), origin: origin)
        }

        // 5. Route.
        let response = route(request)
        return withCORS(response, origin: origin)
    }

    private func hostIsAllowed(_ request: CaptureHTTPRequest) -> Bool {
        guard let host = request.headers["host"]?.lowercased() else { return false }
        let port = config.port
        return host == "127.0.0.1:\(port)" || host == "localhost:\(port)" || host == "[::1]:\(port)"
    }

    private func withCORS(_ response: CaptureHTTPResponse, origin: String?, preflight: Bool = false) -> CaptureHTTPResponse {
        guard let origin, config.allowedOrigins.contains(origin) else { return response }
        var copy = response
        copy.headers["Access-Control-Allow-Origin"] = origin
        copy.headers["Vary"] = "Origin"
        if preflight {
            copy.headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
            copy.headers["Access-Control-Allow-Headers"] = "X-RB-Token, Content-Type"
            copy.headers["Access-Control-Max-Age"] = "600"
        }
        return copy
    }

    nonisolated static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var difference = x.count ^ y.count
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0
            let r = i < y.count ? y[i] : 0
            difference |= Int(l ^ r)
        }
        return difference == 0
    }

    // MARK: Routing

    private func route(_ request: CaptureHTTPRequest) -> CaptureHTTPResponse {

        let path = request.path
        let method = request.method

        do {
            switch (method, path) {

            case ("GET", "/v1/ping"):
                return Self.json(200, ["app": "ResearchBase", "api": 1, "paused": isPaused])

            case ("GET", "/v1/lookup"):
                return try lookup(request)

            case ("POST", "/v1/capture"):
                return try capture(request)

            case ("GET", "/v1/collections"):
                let list = try model.collections.all().map { ["id": $0.id, "name": $0.name, "parentId": $0.parentID ?? NSNull()] as [String: Any] }
                return Self.jsonValue(200, ["collections": list])

            case ("GET", "/v1/tags"):
                let list = try model.tags.all().map { ["id": $0.id, "name": $0.name] }
                return Self.jsonValue(200, ["tags": list])

            default:
                if path.hasPrefix("/v1/attachments/") {
                    guard method == "POST" else { return Self.json(405, ["error": "Use POST."]) }
                    let itemID = String(path.dropFirst("/v1/attachments/".count))
                    return try attach(itemID: itemID, request: request)
                }
                let known = ["/v1/ping", "/v1/lookup", "/v1/capture", "/v1/collections", "/v1/tags"]
                if known.contains(path) { return Self.json(405, ["error": "Wrong method for this address."]) }
                return Self.json(404, ["error": "Unknown address."])
            }
        } catch let error as ModelError {
            return Self.json(400, ["error": error.errorDescription ?? "The request could not be completed."])
        } catch {
            return Self.json(500, ["error": "Something went wrong inside ResearchBase."])
        }
    }

    // MARK: GET /v1/lookup

    private func lookup(_ request: CaptureHTTPRequest) throws -> CaptureHTTPResponse {

        let doi = TextNormalizer.doi(request.query["doi"])
        let arxiv = TextNormalizer.arxivID(request.query["arxiv"])
        let url = (request.query["url"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        guard doi != nil || arxiv != nil || !url.isEmpty else {
            return Self.json(400, ["error": "Give doi, arxiv or url."])
        }

        if let match = try findExisting(doi: doi, arxiv: arxiv, url: url) {
            return Self.jsonValue(200, [
                "found": true, "itemId": match.id, "title": match.title,
                "inInbox": match.reviewState == .inbox
            ])
        }
        return Self.jsonValue(200, ["found": false])
    }

    /// Looks for a paper by DOI, then arXiv ID, then address. Papers in the Trash do not count.
    private func findExisting(doi: String?, arxiv: String?, url: String) throws -> ModelItem? {

        if let doi, let id = try model.database.scalarText(
            "SELECT id FROM items WHERE doi = ? AND deleted_at IS NULL LIMIT 1", [.text(doi)]) {
            return try model.items.fetch(id: id)
        }
        if let arxiv, let id = try model.database.scalarText(
            "SELECT id FROM items WHERE arxiv_id = ? AND deleted_at IS NULL LIMIT 1", [.text(arxiv)]) {
            return try model.items.fetch(id: id)
        }
        if !url.isEmpty {
            let plain = url.hasSuffix("/") ? String(url.dropLast()) : url
            let slash = plain + "/"
            if let id = try model.database.scalarText(
                """
                SELECT id FROM items
                WHERE deleted_at IS NULL AND (url IN (?, ?) OR source_url IN (?, ?))
                LIMIT 1
                """,
                [.text(plain), .text(slash), .text(plain), .text(slash)]) {
                return try model.items.fetch(id: id)
            }
        }
        return nil
    }

    // MARK: POST /v1/capture

    private func capture(_ request: CaptureHTTPRequest) throws -> CaptureHTTPResponse {

        if isPaused {
            try log(result: "paused", detail: "Capture is paused.", sourceURL: "", itemID: nil)
            return Self.json(503, ["error": "Capture is paused."])
        }

        guard let object = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] else {
            return Self.json(400, ["error": "The body must be a JSON object."])
        }

        let url = Self.string(object["url"])
        let rawTitle = Self.string(object["title"])
        let doi = TextNormalizer.doi(Self.string(object["doi"]))
        let arxiv = TextNormalizer.arxivID(Self.string(object["arxiv"]))
            ?? Self.arxivID(fromAddress: url)

        guard !url.isEmpty || doi != nil || !rawTitle.isEmpty else {
            try log(result: "rejected", detail: "No url, doi or title.", sourceURL: "", itemID: nil)
            return Self.json(400, ["error": "Give at least a url, a doi or a title."])
        }
        if !url.isEmpty, !Self.isWebAddress(url) {
            try log(result: "rejected", detail: "Not an http(s) address.", sourceURL: url, itemID: nil)
            return Self.json(400, ["error": "The url must start with http:// or https://."])
        }

        // Already there? Say so, add nothing, and still accept a PDF for it.
        if let existing = try findExisting(doi: doi, arxiv: arxiv, url: url) {
            var detail = "Already in the library."
            if let pdf = Self.string(object["pdf"]).nonEmpty {
                detail += (try? attachPDF(base64: pdf, to: existing.id)) == true ? " PDF added." : " PDF not added."
            }
            try log(result: "duplicate", detail: detail, sourceURL: url, itemID: existing.id)
            return Self.jsonValue(200, [
                "status": "duplicate", "itemId": existing.id, "title": existing.title,
                "inInbox": existing.reviewState == .inbox
            ])
        }

        // A PDF that is not a PDF is refused before anything is created.
        var pdfData: Data?
        if let pdf = Self.string(object["pdf"]).nonEmpty {
            guard let data = Data(base64Encoded: pdf, options: .ignoreUnknownCharacters), Self.looksLikePDF(data) else {
                try log(result: "rejected", detail: "The pdf was not valid base64 PDF data.", sourceURL: url, itemID: nil)
                return Self.json(400, ["error": "The pdf is not valid PDF data."])
            }
            pdfData = data
        }

        let title = rawTitle.isEmpty ? Self.fallbackTitle(url: url, doi: doi) : rawTitle

        var new = NewItem(title: title)
        new.type = (arxiv != nil) ? .preprint : .article
        new.creators = Self.parseAuthors(object["authors"])
        new.abstract = Self.string(object["abstract"])
        new.venue = Self.string(object["venue"])
        if let year = object["year"] as? Int, (0...9999).contains(year) { new.year = year }
        new.doi = doi
        new.arxivID = arxiv
        new.url = url
        new.sourceKind = .browser
        new.sourceURL = url
        new.reviewState = .inbox

        let item = try model.items.create(new)

        var notes: [String] = []

        if let pdfData {
            if (try? attachPDFData(pdfData, to: item.id)) != true { notes.append("PDF could not be stored.") }
        }
        if let tags = object["tags"] as? [String] {
            for name in tags.prefix(20) {
                if let tag = try? model.tags.findOrCreate(name: name) {
                    try? model.tags.assign(tagID: tag.id, to: item.id)
                }
            }
        }
        if let collectionID = Self.string(object["collectionId"]).nonEmpty {
            if (try? model.collections.addItem(item.id, to: collectionID)) == nil {
                notes.append("Collection not found.")
            }
        }

        try log(result: "added", detail: notes.joined(separator: " "), sourceURL: url, itemID: item.id)
        return Self.jsonValue(201, ["status": "added", "itemId": item.id, "title": item.title, "inInbox": true])
    }

    // MARK: POST /v1/attachments/{itemId}

    private func attach(itemID: String, request: CaptureHTTPRequest) throws -> CaptureHTTPResponse {

        guard UUID(uuidString: itemID) != nil else {
            return Self.json(400, ["error": "That is not a valid item id."])
        }
        guard try model.items.fetch(id: itemID) != nil else {
            return Self.json(404, ["error": "No such paper."])
        }
        guard Self.looksLikePDF(request.body) else {
            return Self.json(415, ["error": "Only PDF files are accepted."])
        }
        if isPaused {
            return Self.json(503, ["error": "Capture is paused."])
        }

        guard try attachPDFData(request.body, to: itemID) else {
            return Self.json(500, ["error": "The PDF could not be stored."])
        }
        try log(result: "attached", detail: "PDF added to an existing paper.", sourceURL: "", itemID: itemID)
        return Self.jsonValue(200, ["status": "attached", "itemId": itemID])
    }

    // MARK: Files

    @discardableResult
    private func attachPDF(base64: String, to itemID: String) throws -> Bool {
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters), Self.looksLikePDF(data) else {
            return false
        }
        return try attachPDFData(data, to: itemID)
    }

    /// Writes the bytes to a temporary file, lets AttachmentStore copy and fingerprint it, then removes the temporary file.
    @discardableResult
    private func attachPDFData(_ data: Data, to itemID: String) throws -> Bool {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("rb-capture-\(UUID().uuidString).pdf")
        try data.write(to: temporary, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temporary) }
        _ = try model.attachments.add(fileAt: temporary, to: itemID, kind: .pdf)
        return true
    }

    // MARK: capture_log

    private func log(result: String, detail: String, sourceURL: String, itemID: String?) throws {
        try model.database.run(
            "INSERT INTO capture_log (id, at, via, source_url, item_id, result, detail) VALUES (?, ?, 'browser', ?, ?, ?, ?)",
            [.text(model.newID()), .text(model.now()), .text(sourceURL),
             LibraryModel.text(itemID), .text(result), .text(detail)]
        )
    }

    // MARK: - Pure helpers

    nonisolated static func looksLikePDF(_ data: Data) -> Bool {
        data.count >= 5 && data.prefix(1024).range(of: Data("%PDF-".utf8)) != nil
    }

    /// The arXiv id inside an arxiv.org address (abs or pdf), or nil for any other address.
    /// TextNormalizer.arxivID returns plain text unchanged, so it cannot be used to detect one.
    nonisolated static func arxivID(fromAddress address: String) -> String? {
        let lower = address.lowercased()
        for marker in ["arxiv.org/abs/", "arxiv.org/pdf/"] {
            guard let range = lower.range(of: marker) else { continue }
            var tail = String(address[range.upperBound...])
            if let end = tail.firstIndex(where: { $0 == "?" || $0 == "#" }) { tail = String(tail[..<end]) }
            tail = tail.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if tail.lowercased().hasSuffix(".pdf") { tail = String(tail.dropLast(4)) }
            return tail.isEmpty ? nil : tail
        }
        return nil
    }

    nonisolated static func isWebAddress(_ text: String) -> Bool {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && url.host != nil
    }

    nonisolated static func fallbackTitle(url: String, doi: String?) -> String {
        if let doi { return "DOI \(doi)" }
        if let host = URL(string: url)?.host {
            let last = URL(string: url)?.lastPathComponent ?? ""
            return last.isEmpty || last == "/" ? host : "\(host) · \(last)"
        }
        return "Untitled capture"
    }

    nonisolated private static func string(_ value: Any?) -> String {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Authors come as a list of strings or as one text ("A; B", "A and B"). Names may be
    /// "Family, Given" or "Given Family".
    nonisolated static func parseAuthors(_ value: Any?) -> [CreatorInput] {
        var names: [String] = []
        if let list = value as? [String] {
            names = list
        } else if let text = value as? String {
            var t = text
            if !t.contains(";") {
                t = t.replacingOccurrences(of: " and ", with: ";").replacingOccurrences(of: " & ", with: ";")
            }
            names = t.contains(";") ? t.components(separatedBy: ";") : [t]
        }
        return names.prefix(100).compactMap { raw -> CreatorInput? in
            let name = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            guard !name.isEmpty else { return nil }
            if let comma = name.firstIndex(of: ",") {
                let family = name[..<comma].trimmingCharacters(in: .whitespaces)
                let given = name[name.index(after: comma)...].trimmingCharacters(in: .whitespaces)
                return family.isEmpty ? nil : CreatorInput(family: family, given: given)
            }
            let words = name.split(separator: " ").map(String.init)
            if words.count == 1 { return CreatorInput(family: name) }
            return CreatorInput(family: words.last ?? name, given: words.dropLast().joined(separator: " "))
        }
    }

    // MARK: JSON responses

    nonisolated static func json(_ status: Int, _ object: [String: Any]) -> CaptureHTTPResponse {
        jsonValue(status, object)
    }

    nonisolated static func jsonValue(_ status: Int, _ object: Any) -> CaptureHTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return CaptureHTTPResponse(
            status: status, headers: ["Content-Type": "application/json; charset=utf-8"], body: data)
    }

    // MARK: - HTTP parsing (pure)

    /// Reads one HTTP/1.1 request from the bytes received so far.
    nonisolated static func parseRequest(
        _ data: Data, maxHeaderBytes: Int = 16 * 1024, maxBodyBytes: Int = 100 * 1024 * 1024
    ) -> CaptureParseResult {

        let separator = Data("\r\n\r\n".utf8)
        guard let end = data.range(of: separator) else {
            return data.count > maxHeaderBytes
                ? .rejected(status: 413, message: "Headers too large.")
                : .incomplete
        }
        guard end.lowerBound <= maxHeaderBytes else {
            return .rejected(status: 413, message: "Headers too large.")
        }

        guard let head = String(data: data[..<end.lowerBound], encoding: .utf8) else {
            return .rejected(status: 400, message: "Headers are not text.")
        }
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard first.count == 3, first[2].hasPrefix("HTTP/1.") else {
            return .rejected(status: 400, message: "Not an HTTP request.")
        }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else {
                return .rejected(status: 400, message: "Bad header line.")
            }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        if headers["transfer-encoding"] != nil {
            return .rejected(status: 400, message: "Chunked uploads are not supported.")
        }

        var length = 0
        if let text = headers["content-length"] {
            guard let n = Int(text), n >= 0 else { return .rejected(status: 400, message: "Bad Content-Length.") }
            guard n <= maxBodyBytes else { return .rejected(status: 413, message: "Body too large.") }
            length = n
        }

        let bodyStart = end.upperBound
        guard data.count - bodyStart >= length else { return .incomplete }
        let body = data.subdata(in: bodyStart..<(bodyStart + length))

        // Path and query.
        let target = first[1]
        var path = target
        var query: [String: String] = [:]
        if let mark = target.firstIndex(of: "?") {
            path = String(target[..<mark])
            var components = URLComponents()
            components.percentEncodedQuery = String(target[target.index(after: mark)...])
            for item in components.queryItems ?? [] { query[item.name] = item.value ?? "" }
        }
        path = path.removingPercentEncoding ?? path
        guard path.hasPrefix("/"), !path.contains("..") else {
            return .rejected(status: 400, message: "Bad path.")
        }

        return .request(CaptureHTTPRequest(
            method: first[0].uppercased(), path: path, query: query, headers: headers, body: body))
    }
}

// MARK: - Errors

enum CaptureServerError: LocalizedError, Equatable {
    case noToken
    case badPort
    case cannotListen(String)

    var errorDescription: String? {
        switch self {
        case .noToken: return "Capture needs a secret token before it can start."
        case .badPort: return "The port number is not valid."
        case .cannotListen(let why): return "Capture could not start. Another app may be using the port. (\(why))"
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

// MARK: - One network connection

/// Reads one request, asks the server for the answer, writes it, and closes.
private final class CaptureConnection {

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let config: CaptureConfig
    private let respond: (CaptureHTTPRequest) async -> CaptureHTTPResponse
    private let finished: (ObjectIdentifier) -> Void

    private var buffer = Data()
    private var done = false
    private var timeout: DispatchWorkItem?

    init(
        connection: NWConnection, queue: DispatchQueue, config: CaptureConfig,
        respond: @escaping (CaptureHTTPRequest) async -> CaptureHTTPResponse,
        finished: @escaping (ObjectIdentifier) -> Void
    ) {
        self.connection = connection
        self.queue = queue
        self.config = config
        self.respond = respond
        self.finished = finished
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.close() }
            if case .cancelled = state { self?.finish() }
        }
        connection.start(queue: queue)
        armTimeout()
        receive()
    }

    func cancel() {
        connection.cancel()
    }

    private func armTimeout() {
        timeout?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.send(CaptureServer.json(408, ["error": "Request timed out."]))
        }
        timeout = item
        queue.asyncAfter(deadline: .now() + config.idleTimeout, execute: item)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.done else { return }

            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.armTimeout()

                switch CaptureServer.parseRequest(
                    self.buffer, maxHeaderBytes: self.config.maxHeaderBytes, maxBodyBytes: self.config.maxBodyBytes
                ) {
                case .incomplete:
                    break
                case .rejected(let status, let message):
                    self.send(CaptureServer.json(status, ["error": message]))
                    return
                case .request(let request):
                    self.timeout?.cancel()
                    self.buffer = Data()
                    Task {
                        let response = await self.respond(request)
                        self.queue.async { self.send(response) }
                    }
                    return
                }
            }

            if error != nil || isComplete {
                self.close()
                return
            }
            self.receive()
        }
    }

    private func send(_ response: CaptureHTTPResponse) {
        guard !done else { return }
        done = true
        timeout?.cancel()
        connection.send(content: response.serialized(), contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { [weak self] _ in self?.close() })
    }

    private func close() {
        done = true
        timeout?.cancel()
        connection.cancel()
    }

    private func finish() {
        finished(ObjectIdentifier(self))
    }
}
