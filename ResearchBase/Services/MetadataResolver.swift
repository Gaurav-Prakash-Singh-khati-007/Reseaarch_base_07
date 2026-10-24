//
//  MetadataResolver.swift
//  ResearchBase
//
//  Owner: Agent 5 · Features: F-15
//
//  Paste a DOI, an arXiv ID or a link and get the paper's details back.
//  Answers are cached in the `lookup_cache` table so a lookup still works
//  offline, and every failure ends in a plain-language error that tells the
//  person to fill the fields in by hand (nothing here ever blocks manual entry).
//
//  Where the answers come from
//    DOI    Crossref (api.crossref.org); if Crossref does not know the DOI,
//           doi.org content negotiation (CSL-JSON), which covers DataCite
//           (Zenodo, Figshare ...) and other registries.
//    arXiv  the arXiv API (export.arxiv.org), Atom feed.
//    URL    the page's own <meta> tags (citation_*, Dublin Core, Open Graph).
//           If the page names a DOI, the DOI is looked up instead, because
//           that answer is richer.
//
//  This file never writes to `items`. It returns a `ResolvedMetadata` and
//  `toNewItem()` turns it into the `NewItem` that `ItemStore` already accepts.
//  The only table it writes is `lookup_cache`.
//
//  PUBLIC API
//    MetadataResolver(database:http:cacheLifetime:now:)
//    MetadataResolver(library:)                                   convenience
//    resolver.resolve(_ text: String, forceRefresh:) async throws -> ResolvedMetadata
//    resolver.resolve(_ id: MetadataIdentifier, forceRefresh:) async throws -> ResolvedMetadata
//    resolver.cached(_ id: MetadataIdentifier) -> ResolvedMetadata?   offline read, no network
//    resolver.purgeCache(olderThan:) -> Int
//    MetadataResolver.identify(_ text: String) -> MetadataIdentifier?   what did the person paste?
//    MetadataIdentifier   .doi(String) / .arxiv(String) / .url(URL)
//    ResolvedMetadata     fields + toNewItem()
//    MetadataSource       crossref / doiCSL / arxiv / web
//    MetadataError        plain-language failures
//    MetadataHTTPClient   protocol (tests pass a stub); URLSessionMetadataClient is the default
//
//  Uses only finished code: LibraryDatabase, Library, ItemType, SourceKind,
//  CreatorInput, NewItem, TextNormalizer.
//

import Foundation

// MARK: - What was pasted

enum MetadataIdentifier: Equatable {

    case doi(String)        // lower-case, no URL prefix
    case arxiv(String)      // no "arXiv:" prefix, no version
    case url(URL)

    /// Key in `lookup_cache`.
    var cacheKey: String {
        switch self {
        case .doi(let doi): return "doi:\(doi)"
        case .arxiv(let id): return "arxiv:\(id.lowercased())"
        case .url(let url): return "url:\(url.absoluteString)"
        }
    }

    /// How the item will be recorded as having arrived (`items.source_kind`).
    var sourceKind: SourceKind {
        switch self {
        case .doi: return .doi
        case .arxiv: return .arxiv
        case .url: return .url
        }
    }

    /// A link a person can open, stored in `items.source_url`.
    var sourceURLText: String {
        switch self {
        case .doi(let doi): return "https://doi.org/\(doi)"
        case .arxiv(let id): return "https://arxiv.org/abs/\(id)"
        case .url(let url): return url.absoluteString
        }
    }
}

// MARK: - Result

enum MetadataSource: String, Equatable {
    case crossref
    case doiCSL = "doi_csl"
    case arxiv
    case web

    var displayName: String {
        switch self {
        case .crossref: return "Crossref"
        case .doiCSL: return "doi.org"
        case .arxiv: return "arXiv"
        case .web: return "the web page"
        }
    }
}

struct ResolvedMetadata: Equatable {

    var type: ItemType
    var title: String
    var creators: [CreatorInput]
    var year: Int?
    /// 1 to 12 when the source gave one. `NewItem` has no month, so a caller that wants it sets it afterwards.
    var month: Int?
    var venue: String
    var abstract: String
    var volume: String
    var issue: String
    var pages: String
    var publisher: String
    var doi: String?
    var arxivID: String?
    var url: String
    var language: String

    var source: MetadataSource
    /// What the person pasted.
    var capturedVia: SourceKind
    var sourceURL: String

    var fetchedAt: Date
    /// Answered from `lookup_cache` without asking the internet.
    var fromCache: Bool
    /// From the cache, past its lifetime, because the internet could not be reached.
    var isStale: Bool

    init(
        type: ItemType = .article,
        title: String,
        creators: [CreatorInput] = [],
        year: Int? = nil,
        month: Int? = nil,
        venue: String = "",
        abstract: String = "",
        volume: String = "",
        issue: String = "",
        pages: String = "",
        publisher: String = "",
        doi: String? = nil,
        arxivID: String? = nil,
        url: String = "",
        language: String = "",
        source: MetadataSource,
        capturedVia: SourceKind = .manual,
        sourceURL: String = "",
        fetchedAt: Date = Date(),
        fromCache: Bool = false,
        isStale: Bool = false
    ) {
        self.type = type
        self.title = title
        self.creators = creators
        self.year = year
        self.month = month
        self.venue = venue
        self.abstract = abstract
        self.volume = volume
        self.issue = issue
        self.pages = pages
        self.publisher = publisher
        self.doi = doi
        self.arxivID = arxivID
        self.url = url
        self.language = language
        self.source = source
        self.capturedVia = capturedVia
        self.sourceURL = sourceURL
        self.fetchedAt = fetchedAt
        self.fromCache = fromCache
        self.isStale = isStale
    }

    /// The input `ItemStore` takes. Review state stays at its default; the caller decides inbox or library.
    func toNewItem() -> NewItem {
        NewItem(
            type: type,
            title: title,
            creators: creators,
            year: year,
            venue: venue,
            abstract: abstract,
            volume: volume,
            issue: issue,
            pages: pages,
            publisher: publisher,
            doi: doi,
            arxivID: arxivID,
            url: url,
            sourceKind: capturedVia,
            sourceURL: sourceURL
        )
    }
}

// MARK: - Errors

enum MetadataError: LocalizedError, Equatable {

    /// The text is not a DOI, an arXiv ID or a web link.
    case notRecognised(String)
    /// The service answered that it has no such record.
    case notFound(String)
    /// No internet, or the service is busy or down.
    case offline
    case serviceUnavailable(String)
    /// The answer could not be understood or had no title.
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .notRecognised:
            return "That does not look like a DOI, an arXiv ID or a web link. You can fill in the fields by hand."
        case .notFound(let what):
            return "No record was found for \(what). Check it for typing mistakes, or fill in the fields by hand."
        case .offline:
            return "The lookup service could not be reached. Fill in the fields by hand, or try again when you are online."
        case .serviceUnavailable(let who):
            return "\(who) is busy or not answering right now. Try again in a little while, or fill in the fields by hand."
        case .badResponse(let why):
            return "The answer could not be used (\(why)). You can fill in the fields by hand."
        }
    }
}

// MARK: - Network seam

protocol MetadataHTTPClient {
    func send(_ request: URLRequest) async throws -> (data: Data, response: HTTPURLResponse)
}

struct URLSessionMetadataClient: MetadataHTTPClient {

    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 30
            self.session = URLSession(configuration: configuration)
        }
    }

    func send(_ request: URLRequest) async throws -> (data: Data, response: HTTPURLResponse) {

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw MetadataError.badResponse("not an HTTP answer")
        }

        return (data, http)
    }
}

// MARK: - Resolver

final class MetadataResolver {

    private let database: LibraryDatabase
    private let http: MetadataHTTPClient
    private let cacheLifetime: TimeInterval
    private let now: () -> Date

    init(
        database: LibraryDatabase,
        http: MetadataHTTPClient = URLSessionMetadataClient(),
        cacheLifetime: TimeInterval = 30 * 24 * 60 * 60,
        now: @escaping () -> Date = { Date() }
    ) {
        self.database = database
        self.http = http
        self.cacheLifetime = cacheLifetime
        self.now = now
    }

    convenience init(library: Library) {
        self.init(database: library.database)
    }

    // MARK: Public

    /// Takes whatever the person pasted.
    func resolve(_ text: String, forceRefresh: Bool = false) async throws -> ResolvedMetadata {

        guard let identifier = Self.identify(text) else {
            throw MetadataError.notRecognised(text)
        }

        return try await resolve(identifier, forceRefresh: forceRefresh)
    }

    func resolve(_ identifier: MetadataIdentifier, forceRefresh: Bool = false) async throws -> ResolvedMetadata {

        let key = identifier.cacheKey
        let cached = readCache(key)

        if !forceRefresh, let cached, now().timeIntervalSince(cached.fetchedAt) < cacheLifetime {
            return cached
        }

        do {
            var fresh = try await fetch(identifier)
            fresh.capturedVia = identifier.sourceKind
            fresh.sourceURL = identifier.sourceURLText
            fresh.fetchedAt = now()
            fresh.fromCache = false
            fresh.isStale = false

            writeCache(key, fresh)
            return fresh

        } catch {
            // Offline or the service is down: an old answer beats no answer.
            if var old = cached, Self.isTransient(error) {
                old.isStale = true
                return old
            }
            throw error
        }
    }

    /// Whatever is stored for this identifier, fresh or not. Never touches the network.
    func cached(_ identifier: MetadataIdentifier) -> ResolvedMetadata? {
        readCache(identifier.cacheKey)
    }

    /// Removes cached answers fetched before `date`. Returns how many were removed.
    @discardableResult
    func purgeCache(olderThan date: Date) -> Int {
        (try? database.run(
            "DELETE FROM lookup_cache WHERE fetched_at < ?",
            [.text(Library.nowISO(date))]
        )) ?? 0
    }

    // MARK: Recognising what was pasted

    static func identify(_ raw: String) -> MetadataIdentifier? {

        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let lower = text.lowercased()

        let newStyle = #"\d{4}\.\d{4,5}"#
        let oldStyle = #"[a-z\-]+(?:\.[a-z]{2})?/\d{7}"#
        let arxivPattern = "(\(newStyle)|\(oldStyle))"

        // 1. arXiv links and "arXiv:" prefixes.
        if let id = MRRegex.first("arxiv\\.org/(?:abs|pdf)/\(arxivPattern)", in: text) {
            return .arxiv(id)
        }
        if lower.hasPrefix("arxiv:"), let id = MRRegex.first(arxivPattern, in: String(text.dropFirst(6))) {
            return .arxiv(id)
        }

        // 2. A link: arXiv handled above, doi.org links are DOIs, everything else is a web page.
        let isLink = lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("www.")

        if isLink {
            let normalised = lower.hasPrefix("www.") ? "https://" + text : text

            guard let url = URL(string: normalised), let host = url.host?.lowercased(), host.contains(".") else {
                return nil
            }

            if host == "doi.org" || host == "dx.doi.org" || host == "www.doi.org" {
                if let doi = extractDOI(from: normalised) { return doiOrArxiv(doi) }
            }
            return .url(url)
        }

        // 3. A DOI, with or without "doi:".
        if let doi = extractDOI(from: text) {
            return doiOrArxiv(doi)
        }

        // 4. A bare arXiv ID.
        if MRRegex.matches("^\(arxivPattern)(?:v\\d+)?$", text) {
            return .arxiv(MRRegex.first("^\(arxivPattern)", in: text) ?? text)
        }

        return nil
    }

    private static func extractDOI(from text: String) -> String? {

        guard let found = MRRegex.first(#"(10\.\d{4,9}/[^\s"<>]+)"#, in: text) else { return nil }

        var doi = found
        let trailing = CharacterSet(charactersIn: ".,;:)]}>'\"")

        while let last = doi.unicodeScalars.last, trailing.contains(last) {
            doi.removeLast()
        }

        return TextNormalizer.doi(doi)
    }

    /// arXiv's own DOIs (10.48550/arXiv.NNNN.NNNNN) are the same paper as the arXiv ID.
    private static func doiOrArxiv(_ doi: String) -> MetadataIdentifier {
        if doi.hasPrefix("10.48550/arxiv."), let id = arxivID(fromDOI: doi) {
            return .arxiv(id)
        }
        return .doi(doi)
    }

    private static func arxivID(fromDOI doi: String) -> String? {
        guard doi.hasPrefix("10.48550/arxiv.") else { return nil }
        let rest = String(doi.dropFirst("10.48550/arxiv.".count))
        return MRRegex.first(#"^(\d{4}\.\d{4,5})"#, in: rest)
    }

    // MARK: Fetching

    private func fetch(_ identifier: MetadataIdentifier) async throws -> ResolvedMetadata {
        switch identifier {
        case .doi(let doi): return try await fetchDOI(doi)
        case .arxiv(let id): return try await fetchArxiv(id)
        case .url(let url): return try await fetchWebPage(url)
        }
    }

    // DOI ----------------------------------------------------------------

    private func fetchDOI(_ doi: String) async throws -> ResolvedMetadata {

        let encoded = doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? doi

        do {
            let url = try makeURL("https://api.crossref.org/works/\(encoded)")
            let (data, _) = try await get(url, accept: "application/json", service: "Crossref", what: "DOI \(doi)")

            guard
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let message = json["message"] as? [String: Any]
            else {
                throw MetadataError.badResponse("Crossref sent something unexpected")
            }

            return try parseWork(message, source: .crossref, fallbackDOI: doi)

        } catch MetadataError.notFound {
            // Not a Crossref DOI. doi.org knows every registry.
            let url = try makeURL("https://doi.org/\(encoded)")
            let (data, _) = try await get(
                url,
                accept: "application/vnd.citationstyles.csl+json",
                service: "doi.org",
                what: "DOI \(doi)"
            )

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw MetadataError.badResponse("doi.org sent something unexpected")
            }

            return try parseWork(json, source: .doiCSL, fallbackDOI: doi)
        }
    }

    // arXiv --------------------------------------------------------------

    private func fetchArxiv(_ id: String) async throws -> ResolvedMetadata {

        var components = URLComponents(string: "https://export.arxiv.org/api/query")
        components?.queryItems = [URLQueryItem(name: "id_list", value: id)]

        guard let url = components?.url else {
            throw MetadataError.notRecognised(id)
        }

        let (data, _) = try await get(url, accept: "application/atom+xml", service: "arXiv", what: "arXiv ID \(id)")

        guard let xml = String(data: data, encoding: .utf8) else {
            throw MetadataError.badResponse("arXiv sent unreadable text")
        }

        return try parseArxivFeed(xml, requested: id)
    }

    // Web page -----------------------------------------------------------

    private func fetchWebPage(_ pageURL: URL) async throws -> ResolvedMetadata {

        let (data, response) = try await get(
            pageURL,
            accept: "text/html,application/xhtml+xml",
            service: pageURL.host ?? "The website",
            what: pageURL.absoluteString
        )

        let contentType = (response.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()

        if contentType.contains("pdf") {
            throw MetadataError.badResponse("this link is a PDF file; download it and add it as a file instead")
        }

        let slice = data.prefix(700_000)
        let html = String(data: slice, encoding: .utf8)
            ?? String(data: slice, encoding: .isoLatin1)
            ?? ""

        guard !html.isEmpty else {
            throw MetadataError.badResponse("the page was empty")
        }

        let page = try parseWebPage(html, pageURL: pageURL)

        // A DOI on the page gives a better answer than the page's own tags.
        if let doi = page.doi {
            do {
                return try await resolve(.doi(doi))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Fall through to what the page itself says.
            }
        }

        return page.metadata
    }

    // HTTP ---------------------------------------------------------------

    private func get(
        _ url: URL,
        accept: String,
        service: String,
        what: String
    ) async throws -> (data: Data, response: HTTPURLResponse) {

        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw MetadataError.notRecognised(url.absoluteString)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let result: (data: Data, response: HTTPURLResponse)

        do {
            result = try await http.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as MetadataError {
            throw error
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            if Self.transientURLErrors.contains(error.code) { throw MetadataError.offline }
            throw MetadataError.badResponse(error.localizedDescription)
        } catch {
            throw MetadataError.badResponse(error.localizedDescription)
        }

        switch result.response.statusCode {
        case 200...299:
            return result
        case 404, 410:
            throw MetadataError.notFound(what)
        case 408, 429, 500...599:
            throw MetadataError.serviceUnavailable(service)
        default:
            throw MetadataError.badResponse("\(service) answered with code \(result.response.statusCode)")
        }
    }

    private func makeURL(_ text: String) throws -> URL {
        guard let url = URL(string: text) else { throw MetadataError.notRecognised(text) }
        return url
    }

    private static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"
        return "ResearchBase/\(version) (macOS; personal research library)"
    }

    private static let transientURLErrors: Set<URLError.Code> = [
        .notConnectedToInternet, .timedOut, .networkConnectionLost, .cannotFindHost,
        .cannotConnectToHost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff
    ]

    private static func isTransient(_ error: Error) -> Bool {
        if let error = error as? MetadataError {
            switch error {
            case .offline, .serviceUnavailable: return true
            default: return false
            }
        }
        return false
    }

    // MARK: Cache

    private struct StoredCreator: Codable {
        var family: String
        var given: String
        var suffix: String
        var isOrganisation: Bool
        var orcid: String?
        var role: String
    }

    private struct StoredMetadata: Codable {
        var type: String
        var title: String
        var creators: [StoredCreator]
        var year: Int?
        var month: Int?
        var venue: String
        var abstract: String
        var volume: String
        var issue: String
        var pages: String
        var publisher: String
        var doi: String?
        var arxivID: String?
        var url: String
        var language: String
        var source: String
        var capturedVia: String
        var sourceURL: String
    }

    private func readCache(_ key: String) -> ResolvedMetadata? {

        guard
            let rows = try? database.rows(
                "SELECT response_json, fetched_at FROM lookup_cache WHERE key = ?",
                [.text(key)]
            ),
            let row = rows.first,
            let json = row.text("response_json"),
            let data = json.data(using: .utf8),
            let stored = try? JSONDecoder().decode(StoredMetadata.self, from: data)
        else {
            return nil
        }

        let creators = stored.creators.map {
            CreatorInput(
                family: $0.family,
                given: $0.given,
                suffix: $0.suffix,
                isOrganisation: $0.isOrganisation,
                orcid: $0.orcid,
                role: CreatorRole(rawValue: $0.role) ?? .author
            )
        }

        return ResolvedMetadata(
            type: ItemType(rawValue: stored.type) ?? .article,
            title: stored.title,
            creators: creators,
            year: stored.year,
            month: stored.month,
            venue: stored.venue,
            abstract: stored.abstract,
            volume: stored.volume,
            issue: stored.issue,
            pages: stored.pages,
            publisher: stored.publisher,
            doi: stored.doi,
            arxivID: stored.arxivID,
            url: stored.url,
            language: stored.language,
            source: MetadataSource(rawValue: stored.source) ?? .web,
            capturedVia: SourceKind(rawValue: stored.capturedVia) ?? .manual,
            sourceURL: stored.sourceURL,
            fetchedAt: row.text("fetched_at").flatMap { Self.parseISO($0) } ?? .distantPast,
            fromCache: true,
            isStale: false
        )
    }

    private func writeCache(_ key: String, _ metadata: ResolvedMetadata) {

        let stored = StoredMetadata(
            type: metadata.type.rawValue,
            title: metadata.title,
            creators: metadata.creators.map {
                StoredCreator(
                    family: $0.family,
                    given: $0.given,
                    suffix: $0.suffix,
                    isOrganisation: $0.isOrganisation,
                    orcid: $0.orcid,
                    role: $0.role.rawValue
                )
            },
            year: metadata.year,
            month: metadata.month,
            venue: metadata.venue,
            abstract: metadata.abstract,
            volume: metadata.volume,
            issue: metadata.issue,
            pages: metadata.pages,
            publisher: metadata.publisher,
            doi: metadata.doi,
            arxivID: metadata.arxivID,
            url: metadata.url,
            language: metadata.language,
            source: metadata.source.rawValue,
            capturedVia: metadata.capturedVia.rawValue,
            sourceURL: metadata.sourceURL
        )

        guard
            let data = try? JSONEncoder().encode(stored),
            let json = String(data: data, encoding: .utf8)
        else {
            return
        }

        // A cache that cannot be written must never turn a good answer into an error.
        _ = try? database.run(
            "INSERT OR REPLACE INTO lookup_cache (key, source, response_json, fetched_at) VALUES (?, ?, ?, ?)",
            [.text(key), .text(metadata.source.rawValue), .text(json), .text(Library.nowISO(metadata.fetchedAt))]
        )
    }

    private static func parseISO(_ text: String) -> Date? {

        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }

    // MARK: Parsing · Crossref and CSL-JSON

    /// Crossref's `message` and doi.org's CSL-JSON share most field names, so one reader handles both.
    private func parseWork(
        _ work: [String: Any],
        source: MetadataSource,
        fallbackDOI: String
    ) throws -> ResolvedMetadata {

        var title = MRText.clean(Self.firstString(work["title"]))
        let subtitle = MRText.clean(Self.firstString(work["subtitle"]))

        if !subtitle.isEmpty, !title.lowercased().contains(subtitle.lowercased()) {
            title += ": " + subtitle
        }

        guard !title.isEmpty else {
            throw MetadataError.badResponse("the record has no title")
        }

        var creators: [CreatorInput] = []
        for entry in (work["author"] as? [[String: Any]]) ?? [] {
            if let creator = Self.creator(from: entry, role: .author) { creators.append(creator) }
        }
        for entry in (work["editor"] as? [[String: Any]]) ?? [] {
            if let creator = Self.creator(from: entry, role: .editor) { creators.append(creator) }
        }

        let (year, month) = Self.issuedDate(work)

        let doi = TextNormalizer.doi(work["DOI"] as? String) ?? TextNormalizer.doi(fallbackDOI)

        var venue = MRText.clean(Self.firstString(work["container-title"]))
        if venue.isEmpty { venue = MRText.clean(Self.firstString(work["short-container-title"])) }
        if venue.isEmpty { venue = MRText.clean(Self.firstString(work["group-title"])) }
        if venue.isEmpty,
           let institutions = work["institution"] as? [[String: Any]],
           let name = institutions.first?["name"] as? String {
            venue = MRText.clean(name)
        }

        var pages = MRText.clean(Self.firstString(work["page"]))
        if pages.isEmpty { pages = MRText.clean(Self.firstString(work["article-number"])) }

        var type = Self.itemType(forWorkType: work["type"] as? String, venue: venue, doi: doi)
        var arxivID: String?

        if let doi, let id = Self.arxivID(fromDOI: doi) {
            arxivID = id
            type = .preprint
        }

        let url: String
        if let doi {
            url = "https://doi.org/\(doi)"
        } else {
            url = MRText.clean(Self.firstString(work["URL"]))
        }

        return ResolvedMetadata(
            type: type,
            title: title,
            creators: creators,
            year: year,
            month: month,
            venue: venue,
            abstract: MRText.abstract(Self.firstString(work["abstract"])),
            volume: MRText.clean(Self.firstString(work["volume"])),
            issue: MRText.clean(Self.firstString(work["issue"])),
            pages: pages,
            publisher: MRText.clean(Self.firstString(work["publisher"])),
            doi: doi,
            arxivID: arxivID,
            url: url,
            language: MRText.clean(Self.firstString(work["language"])),
            source: source
        )
    }

    private static func firstString(_ value: Any?) -> String {
        if let text = value as? String { return text }
        if let list = value as? [Any] {
            for element in list {
                if let text = element as? String, !text.isEmpty { return text }
            }
        }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }

    private static func creator(from entry: [String: Any], role: CreatorRole) -> CreatorInput? {

        let family = MRText.clean((entry["family"] as? String) ?? "")
        let given = MRText.clean((entry["given"] as? String) ?? "")
        let name = MRText.clean((entry["name"] as? String) ?? (entry["literal"] as? String) ?? "")
        let suffix = MRText.clean((entry["suffix"] as? String) ?? "")

        let orcidSource = (entry["ORCID"] as? String) ?? (entry["orcid"] as? String) ?? ""
        let orcid = MRRegex.first(#"(\d{4}-\d{4}-\d{4}-\d{3}[\dXx])"#, in: orcidSource)?.uppercased()

        if family.isEmpty && given.isEmpty {
            guard !name.isEmpty else { return nil }
            return CreatorInput(family: name, isOrganisation: true, orcid: orcid, role: role)
        }

        if family.isEmpty {
            return CreatorInput(family: given, orcid: orcid, role: role)
        }

        return CreatorInput(family: family, given: given, suffix: suffix, orcid: orcid, role: role)
    }

    /// First usable date among the fields that mean "when it appeared". `created` (when the DOI was
    /// registered) is the last resort, because it is often years off.
    private static func issuedDate(_ work: [String: Any]) -> (year: Int?, month: Int?) {

        for key in ["issued", "published", "published-print", "published-online", "created"] {

            guard
                let container = work[key] as? [String: Any],
                let outer = container["date-parts"] as? [Any],
                let parts = outer.first as? [Any]
            else {
                continue
            }

            let numbers = parts.map { ($0 as? NSNumber)?.intValue }

            guard let first = numbers.first, let year = first, (1400...2200).contains(year) else {
                continue
            }

            var month: Int?
            if numbers.count > 1, let m = numbers[1], (1...12).contains(m) { month = m }

            return (year, month)
        }

        return (nil, nil)
    }

    private static func itemType(forWorkType raw: String?, venue: String, doi: String?) -> ItemType {

        switch (raw ?? "").lowercased() {

        case "journal-article", "article-journal", "journal-issue", "journal-volume", "journal":
            return .article
        case "proceedings-article", "paper-conference", "proceedings", "proceedings-series":
            return .conference
        case "book", "monograph", "edited-book", "reference-book", "book-set", "book-series", "book-track":
            return .book
        case "book-chapter", "book-section", "book-part", "chapter", "reference-entry",
             "entry-encyclopedia", "entry-dictionary":
            return .chapter
        case "posted-content", "preprint":
            return .preprint
        case "dissertation", "thesis":
            return .thesis
        case "report", "report-component", "report-series", "standard":
            return .report
        case "dataset":
            return .dataset
        case "software":
            return .software
        case "webpage", "post-weblog", "post":
            return .webpage
        case "article":
            // CSL uses plain "article" for preprints.
            let lowerVenue = venue.lowercased()
            if (doi ?? "").hasPrefix("10.48550/") || lowerVenue.contains("arxiv") || lowerVenue.contains("rxiv") {
                return .preprint
            }
            return .article
        default:
            return .article
        }
    }

    // MARK: Parsing · arXiv

    private func parseArxivFeed(_ xml: String, requested: String) throws -> ResolvedMetadata {

        let missing = MetadataError.notFound("arXiv ID \(requested)")

        guard let entry = MRRegex.first("<entry>(.*?)</entry>", in: xml, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            throw missing
        }

        let entryID = MRText.clean(MRText.tag("id", in: entry))

        // arXiv answers a bad ID with an entry that is really an error message.
        if entryID.contains("/api/errors") { throw missing }

        let title = MRText.clean(MRText.tag("title", in: entry))
        if title.isEmpty || title.lowercased() == "error" { throw missing }

        var arxivID = requested
        if let found = MRRegex.first(#"/abs/(.+?)(?:v\d+)?$"#, in: entryID) { arxivID = found }

        let published = MRText.tag("published", in: entry)
        let year = MRRegex.first(#"^(\d{4})"#, in: published).flatMap { Int($0) }
        let month = MRRegex.first(#"^\d{4}-(\d{2})"#, in: published).flatMap { Int($0) }

        let creators: [CreatorInput] = MRRegex
            .all(#"<author>\s*<name>(.*?)</name>"#, in: entry, options: [.caseInsensitive, .dotMatchesLineSeparators])
            .map { MRText.clean($0) }
            .filter { !$0.isEmpty }
            .map { Self.creator(fromFullName: $0) }

        var doi = TextNormalizer.doi(MRText.clean(MRText.tag("arxiv:doi", in: entry)))
        if doi?.isEmpty == true { doi = nil }

        return ResolvedMetadata(
            type: .preprint,
            title: title,
            creators: creators,
            year: year,
            month: month,
            venue: "arXiv",
            abstract: MRText.abstract(MRText.tag("summary", in: entry)),
            doi: doi,
            arxivID: arxivID,
            url: "https://arxiv.org/abs/\(arxivID)",
            source: .arxiv
        )
    }

    /// "Ada Lovelace" -> Lovelace, Ada.  "Ludwig van Beethoven" -> van Beethoven, Ludwig.
    private static func creator(fromFullName full: String, role: CreatorRole = .author) -> CreatorInput {

        if let comma = full.firstIndex(of: ",") {
            let family = String(full[..<comma]).trimmingCharacters(in: .whitespaces)
            let given = String(full[full.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
            return CreatorInput(family: family.isEmpty ? full : family, given: family.isEmpty ? "" : given, role: role)
        }

        var words = full.split(separator: " ").map(String.init)

        guard words.count > 1 else {
            return CreatorInput(family: full, role: role)
        }

        // A name that ends in Jr./Sr./II keeps it as a suffix.
        var suffix = ""
        if let last = words.last, ["jr.", "jr", "sr.", "sr", "ii", "iii", "iv"].contains(last.lowercased()), words.count > 2 {
            suffix = last
            words.removeLast()
        }

        let particles: Set<String> = [
            "van", "von", "de", "der", "den", "da", "di", "del", "della", "du", "dos", "das",
            "la", "le", "bin", "ben", "al", "el", "ter", "ten", "st."
        ]

        var familyStart = words.count - 1
        while familyStart > 1, particles.contains(words[familyStart - 1].lowercased()) {
            familyStart -= 1
        }

        let given = words[..<familyStart].joined(separator: " ")
        let family = words[familyStart...].joined(separator: " ")

        return CreatorInput(family: family, given: given, suffix: suffix, role: role)
    }

    // MARK: Parsing · web page

    private func parseWebPage(_ html: String, pageURL: URL) throws -> (metadata: ResolvedMetadata, doi: String?) {

        let meta = Self.metaTags(in: html)

        func first(_ keys: String...) -> String {
            for key in keys {
                if let value = meta[key]?.first(where: { !$0.isEmpty }) { return MRText.clean(value) }
            }
            return ""
        }

        var title = first("citation_title", "dc.title", "og:title", "twitter:title")
        if title.isEmpty {
            title = MRText.clean(
                MRRegex.first("<title[^>]*>(.*?)</title>", in: html, options: [.caseInsensitive, .dotMatchesLineSeparators]) ?? ""
            )
        }

        guard !title.isEmpty else {
            throw MetadataError.badResponse("the page has no title")
        }

        // Authors
        var names = meta["citation_author"] ?? []
        if names.isEmpty { names = meta["dc.creator"] ?? [] }
        if names.isEmpty { names = meta["author"] ?? [] }

        let creators = names
            .map { MRText.clean($0) }
            .filter { !$0.isEmpty }
            .map { Self.creator(fromFullName: $0) }

        // Date
        let dateText = first(
            "citation_publication_date", "citation_date", "citation_online_date",
            "dc.date", "article:published_time", "citation_year"
        )
        let year = MRRegex.first(#"((?:1[4-9]|20|21)\d{2})"#, in: dateText).flatMap { Int($0) }
        let month = MRRegex.first(#"(?:1[4-9]|20|21)\d{2}[-/](\d{1,2})"#, in: dateText)
            .flatMap { Int($0) }
            .flatMap { (1...12).contains($0) ? $0 : nil }

        // Where it appeared
        let journal = first("citation_journal_title")
        let conference = first("citation_conference_title", "citation_conference")
        let bookTitle = first("citation_inbook_title")
        let siteName = first("og:site_name")

        var venue = journal
        if venue.isEmpty { venue = conference }
        if venue.isEmpty { venue = bookTitle }
        if venue.isEmpty { venue = siteName }

        let firstPage = first("citation_firstpage")
        let lastPage = first("citation_lastpage")
        var pages = firstPage
        if !firstPage.isEmpty, !lastPage.isEmpty { pages = "\(firstPage)–\(lastPage)" }

        var publisher = first("citation_publisher", "dc.publisher")
        if publisher.isEmpty { publisher = first("citation_dissertation_institution", "citation_technical_report_institution") }

        let type: ItemType
        if !journal.isEmpty {
            type = .article
        } else if !conference.isEmpty {
            type = .conference
        } else if !bookTitle.isEmpty {
            type = .chapter
        } else if !first("citation_dissertation_institution").isEmpty {
            type = .thesis
        } else if !first("citation_technical_report_institution").isEmpty {
            type = .report
        } else if !first("citation_arxiv_id").isEmpty {
            type = .preprint
        } else {
            type = .webpage
        }

        // Identifiers
        var doi: String?
        for key in ["citation_doi", "dc.identifier", "prism.doi"] {
            for value in meta[key] ?? [] {
                if let found = Self.extractDOI(from: value) { doi = found; break }
            }
            if doi != nil { break }
        }

        var arxivID: String?
        let arxivText = first("citation_arxiv_id")
        if !arxivText.isEmpty {
            arxivID = MRRegex.first(#"((?:\d{4}\.\d{4,5})|(?:[a-z\-]+(?:\.[a-z]{2})?/\d{7}))"#, in: arxivText)
        }

        var abstract = first("citation_abstract", "dc.description")
        if abstract.isEmpty, type == .webpage { abstract = first("og:description", "description") }

        let metadata = ResolvedMetadata(
            type: type,
            title: title,
            creators: creators,
            year: year,
            month: month,
            venue: venue,
            abstract: MRText.abstract(abstract),
            volume: first("citation_volume"),
            issue: first("citation_issue"),
            pages: pages,
            publisher: publisher,
            doi: doi,
            arxivID: arxivID,
            url: pageURL.absoluteString,
            language: first("citation_language", "dc.language"),
            source: .web
        )

        return (metadata, doi)
    }

    /// name/property (lower-cased) -> every content value, in page order.
    private static func metaTags(in html: String) -> [String: [String]] {

        var result: [String: [String]] = [:]

        for tag in MRRegex.all(#"(<meta\s[^>]*>)"#, in: html, options: [.caseInsensitive, .dotMatchesLineSeparators]) {

            var attributes: [String: String] = [:]

            let pattern = #"([a-zA-Z_:][\w:.-]*)\s*=\s*(?:"([^"]*)"|'([^']*)')"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }

            let range = NSRange(tag.startIndex..., in: tag)

            for match in regex.matches(in: tag, range: range) {

                guard let nameRange = Range(match.range(at: 1), in: tag) else { continue }

                var value = ""
                if let r = Range(match.range(at: 2), in: tag) {
                    value = String(tag[r])
                } else if let r = Range(match.range(at: 3), in: tag) {
                    value = String(tag[r])
                }

                attributes[String(tag[nameRange]).lowercased()] = value
            }

            guard
                let key = (attributes["name"] ?? attributes["property"])?.lowercased(),
                let content = attributes["content"],
                !key.isEmpty
            else {
                continue
            }

            result[key, default: []].append(content)
        }

        return result
    }
}

// MARK: - Small text helpers (private to this file)

private enum MRText {

    /// Strips tags, decodes entities, collapses white space.
    static func clean(_ text: String) -> String {
        let withoutTags = stripTags(text)
        return decodeEntities(withoutTags)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// Like `clean`, plus: paragraph breaks become spaces, a leading "Abstract" label is dropped, length is capped.
    static func abstract(_ text: String) -> String {

        var value = text
            .replacingOccurrences(of: "</jats:p>", with: " ")
            .replacingOccurrences(of: "</p>", with: " ")
            .replacingOccurrences(of: "<br>", with: " ")
            .replacingOccurrences(of: "<br/>", with: " ")

        value = clean(value)

        for label in ["Abstract.", "Abstract:", "Abstract"] where value.hasPrefix(label) {
            value = String(value.dropFirst(label.count)).trimmingCharacters(in: .whitespaces)
            break
        }

        if value.count > 8_000 { value = String(value.prefix(8_000)) }
        return value
    }

    static func stripTags(_ text: String) -> String {
        MRRegex.replace("<[^>]+>", in: text, with: "")
    }

    /// Text of the first <name>…</name> (attributes allowed). Empty when absent.
    static func tag(_ name: String, in xml: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        return MRRegex.first(
            "<\(escaped)(?:\\s[^>]*)?>(.*?)</\(escaped)>",
            in: xml,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) ?? ""
    }

    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "ndash": "–", "mdash": "—", "hellip": "…", "lsquo": "‘", "rsquo": "’",
        "ldquo": "“", "rdquo": "”", "eacute": "é", "egrave": "è", "uuml": "ü",
        "ouml": "ö", "auml": "ä", "szlig": "ß"
    ]

    static func decodeEntities(_ text: String) -> String {

        guard text.contains("&"),
              let regex = try? NSRegularExpression(pattern: #"&(#x[0-9a-fA-F]+|#\d+|[a-zA-Z]+);"#)
        else {
            return text
        }

        var result = text
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))

        // Back to front, so earlier ranges stay valid.
        for match in matches.reversed() {

            guard
                let whole = Range(match.range, in: result),
                let inner = Range(match.range(at: 1), in: result)
            else {
                continue
            }

            let body = String(result[inner])
            var replacement: String?

            if body.hasPrefix("#x") || body.hasPrefix("#X") {
                replacement = UInt32(body.dropFirst(2), radix: 16)
                    .flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else if body.hasPrefix("#") {
                replacement = UInt32(body.dropFirst(1))
                    .flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else {
                replacement = named[body.lowercased()]
            }

            if let replacement { result.replaceSubrange(whole, with: replacement) }
        }

        return result
    }
}

private enum MRRegex {

    static func first(
        _ pattern: String,
        in text: String,
        group: Int = 1,
        options: NSRegularExpression.Options = [.caseInsensitive]
    ) -> String? {

        guard
            let regex = try? NSRegularExpression(pattern: pattern, options: options),
            let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            group < match.numberOfRanges,
            let range = Range(match.range(at: group), in: text)
        else {
            return nil
        }

        return String(text[range])
    }

    static func all(
        _ pattern: String,
        in text: String,
        group: Int = 1,
        options: NSRegularExpression.Options = [.caseInsensitive]
    ) -> [String] {

        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }

        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard group < match.numberOfRanges, let range = Range(match.range(at: group), in: text) else {
                return nil
            }
            return String(text[range])
        }
    }

    static func matches(_ pattern: String, _ text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func replace(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return text
        }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: template
        )
    }
}
