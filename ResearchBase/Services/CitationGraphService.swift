//
//  CitationGraphService.swift
//  ResearchBase
//
//  Owner: Agent 37 · Features: F-25 (related papers and citation graph)
//
//  Feeds the paper's "Related" tab: what a paper cites and what cites it, inside
//  the library and, only when the person has switched online lookup on, beyond it.
//
//      Cites      In your library (2)      Not in your library (21)  [Add all to Inbox]
//      Cited by   In your library (3)      Elsewhere: about 3,400 · from OpenAlex, cached 5 days ago
//
//  Two layers
//    1. LOCAL (always works, offline): `links` rows with rel = 'cites' between papers,
//       plus rel = 'related'. `localGraph`, `relatedByCitations` (papers that share
//       references or are cited together) need no network at all.
//    2. ONLINE (optional): OpenAlex. Used only when `isOnlineEnabled()` returns true.
//       Every answer is stored in `lookup_cache`; a fresh copy is reused without any request,
//       and when OpenAlex cannot be reached the cached copy is shown and the graph says so.
//
//  PUBLIC API
//    protocol CitationGraphTransport           how bytes are fetched (tests pass a fake)
//    struct CitationGraphConfig                base URL, contact e-mail, cache age, limits
//    struct CitationLibraryRef / CitationExternalWork / CitationSection / CitationGraph
//    enum CitationGraphSource                  .libraryOnly(reason:), .live(fetchedAt:), .cached(fetchedAt:because:)
//    struct CitationRelated                    a related paper and why (shared count)
//    struct CitationAddResult
//    enum CitationDirection                    .sourceCitesNew, .newCitesSource
//    @MainActor final class CitationGraphService
//      init(model:, transport:, config:, isOnlineEnabled:)
//      func localGraph(for itemID:) throws -> CitationGraph
//      func graph(for itemID:, forceRefresh:) async throws -> CitationGraph
//      func relatedByCitations(itemID:, limit:) throws -> [CitationRelated]
//      func saveLibraryLinks(from graph:) throws -> Int          writes rel 'cites' links, never duplicates
//      func addToInbox(_ works:, relatedTo itemID:, direction:) throws -> CitationAddResult
//      static func parseWork(_:) / parseWorks(_:) / shortID(_:) / mapType(_:)
//
//  Rules this file follows
//    * Schema is frozen. It reads items/links, writes links (through LinkStore), items (through
//      ItemStore, review_state 'inbox') and lookup_cache. Nothing else.
//    * Nothing is deleted or overwritten. Links that exist are kept; papers already in the
//      library (same DOI) are skipped by addToInbox.
//    * Online lookup is off unless the caller says it is on, and a paper with no DOI or arXiv
//      ID is never sent anywhere.
//    * Only identifiers (DOI, OpenAlex ID) go to OpenAlex. No titles, notes or library content.
//    * Offline is normal: a failed request is not an error for the screen. `graph(for:)` returns
//      the library part plus a plain-words reason in `source`.
//

import Foundation

// MARK: - Transport

protocol CitationGraphTransport {
    /// GET the URL. Throws when the network fails; returns the HTTP status otherwise.
    func get(_ url: URL) async throws -> (data: Data, status: Int)
}

nonisolated struct URLSessionCitationTransport: CitationGraphTransport {

    var timeout: TimeInterval = 15

    func get(_ url: URL) async throws -> (data: Data, status: Int) {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ResearchBase (macOS)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

// MARK: - Configuration

nonisolated struct CitationGraphConfig: Equatable {

    var baseURL = "https://api.openalex.org"

    /// OpenAlex asks polite clients to identify themselves. Optional; sent as `mailto`.
    var contactEmail: String?

    /// A cached answer younger than this is used without asking the network.
    var cacheFreshDays = 7

    /// At most this many references of one paper are looked up.
    var maxReferences = 100

    /// How many of the most-cited citing papers are listed under "Elsewhere".
    var citedByPageSize = 25

    /// At most this many library DOIs are checked when finding which library papers cite this one.
    var maxLibraryDOIsChecked = 150
}

// MARK: - Result types

struct CitationLibraryRef: Equatable {
    let itemID: String
    let title: String
    let year: Int?
}

struct CitationExternalWork: Equatable {
    let openAlexID: String          // "W2741809807"
    let doi: String?                // normalised, no https://doi.org/
    let title: String
    let year: Int?
    let venue: String
    let type: ItemType
    let authors: [String]           // "Given Family"
}

struct CitationSection: Equatable {
    var inLibrary: [CitationLibraryRef] = []
    /// Works that are not in the library (for "Cites": the references that were looked up;
    /// for "Cited by": the most-cited citing papers).
    var elsewhere: [CitationExternalWork] = []
    /// "about 3,400" and "Not in your library (21)": how many exist beyond the library. Nil when unknown.
    var elsewhereTotal: Int?
}

enum CitationGraphSource: Equatable {
    /// Only the library was used. `reason` says why in plain words (nil when it was simply the request).
    case libraryOnly(reason: String?)
    case live(fetchedAt: String)
    /// Shown from the cache. `because` is set when the network failed.
    case cached(fetchedAt: String, because: String?)
}

struct CitationGraph: Equatable {
    let itemID: String
    var cites: CitationSection
    var citedBy: CitationSection
    /// Papers linked with rel 'related'.
    var related: [CitationLibraryRef]
    var source: CitationGraphSource
}

struct CitationRelated: Equatable {
    let ref: CitationLibraryRef
    /// References in common plus papers that cite both.
    let shared: Int
}

struct CitationAddResult: Equatable {
    var added: [String] = []             // new item ids, in order
    var alreadyInLibrary = 0
    var skipped = 0                       // no usable title
    var linked = 0                        // links written
}

enum CitationDirection: Equatable {
    /// The paper on screen cites the new paper ("Cites" list).
    case sourceCitesNew
    /// The new paper cites the paper on screen ("Cited by" list).
    case newCitesSource
}

enum CitationGraphError: LocalizedError, Equatable {
    case unreachable
    case badStatus(Int)
    case notFound
    case unreadable

    var errorDescription: String? {
        switch self {
        case .unreachable: return "OpenAlex could not be reached."
        case .badStatus(let code): return "OpenAlex answered with an error (\(code))."
        case .notFound: return "OpenAlex does not know this paper."
        case .unreadable: return "OpenAlex sent an answer that could not be read."
        }
    }
}

// MARK: - Service

@MainActor
final class CitationGraphService {

    let model: LibraryModel
    private let transport: CitationGraphTransport
    let config: CitationGraphConfig
    private let isOnlineEnabled: () -> Bool

    init(
        model: LibraryModel,
        transport: CitationGraphTransport = URLSessionCitationTransport(),
        config: CitationGraphConfig = CitationGraphConfig(),
        isOnlineEnabled: @escaping () -> Bool = { false }
    ) {
        self.model = model
        self.transport = transport
        self.config = config
        self.isOnlineEnabled = isOnlineEnabled
    }

    // MARK: - Local graph

    /// What the library alone knows. Never touches the network.
    func localGraph(for itemID: String) throws -> CitationGraph {
        CitationGraph(
            itemID: itemID,
            cites: CitationSection(inLibrary: try linked(itemID, outgoing: true, rel: .cites)),
            citedBy: CitationSection(inLibrary: try linked(itemID, outgoing: false, rel: .cites)),
            related: try relatedLinks(itemID),
            source: .libraryOnly(reason: nil))
    }

    private func linked(_ itemID: String, outgoing: Bool, rel: LinkRel) throws -> [CitationLibraryRef] {
        let (near, far) = outgoing ? ("from", "to") : ("to", "from")
        let rows = try model.database.rows(
            """
            SELECT i.id, i.title, i.year FROM links l
            JOIN items i ON i.id = l.\(far)_id
            WHERE l.from_type = 'item' AND l.to_type = 'item'
              AND l.\(near)_id = ? AND l.rel = ? AND i.deleted_at IS NULL
            ORDER BY i.year, i.title, i.id
            """,
            [.text(itemID), .text(rel.rawValue)])
        return rows.compactMap(Self.ref)
    }

    private func relatedLinks(_ itemID: String) throws -> [CitationLibraryRef] {
        var refs: [CitationLibraryRef] = []
        for (near, far) in [("from", "to"), ("to", "from")] {
            let rows = try model.database.rows(
                """
                SELECT i.id, i.title, i.year FROM links l
                JOIN items i ON i.id = l.\(far)_id
                WHERE l.from_type = 'item' AND l.to_type = 'item'
                  AND l.\(near)_id = ? AND l.rel = 'related' AND i.deleted_at IS NULL
                """,
                [.text(itemID)])
            refs.append(contentsOf: rows.compactMap(Self.ref))
        }
        return refs.sorted { ($0.year ?? 0, $0.title, $0.itemID) < ($1.year ?? 0, $1.title, $1.itemID) }
    }

    private static func ref(_ row: SQLRow) -> CitationLibraryRef? {
        guard let id = row.text("id"), let title = row.text("title") else { return nil }
        return CitationLibraryRef(itemID: id, title: title, year: row.int("year").map(Int.init))
    }

    // MARK: - Related by citations (local, offline)

    /// Papers that share references with this one (bibliographic coupling) or that are cited
    /// together with it by some third paper (co-citation). Highest overlap first.
    func relatedByCitations(itemID: String, limit: Int = 10) throws -> [CitationRelated] {

        let rows = try model.database.rows(
            """
            SELECT i.id, i.title, i.year, SUM(s.n) AS shared FROM (
                -- shares a reference: item -> Y <- X
                SELECT l2.from_id AS other, COUNT(*) AS n
                FROM links l1 JOIN links l2 ON l2.to_id = l1.to_id AND l2.to_type = 'item'
                WHERE l1.from_type = 'item' AND l1.from_id = ? AND l1.to_type = 'item' AND l1.rel = 'cites'
                  AND l2.from_type = 'item' AND l2.rel = 'cites' AND l2.from_id <> l1.from_id
                GROUP BY l2.from_id
                UNION ALL
                -- cited together: P -> item and P -> Z
                SELECT l2.to_id AS other, COUNT(*) AS n
                FROM links l1 JOIN links l2 ON l2.from_id = l1.from_id AND l2.from_type = 'item'
                WHERE l1.to_type = 'item' AND l1.to_id = ? AND l1.from_type = 'item' AND l1.rel = 'cites'
                  AND l2.to_type = 'item' AND l2.rel = 'cites' AND l2.to_id <> l1.to_id
                GROUP BY l2.to_id
            ) s
            JOIN items i ON i.id = s.other
            WHERE i.deleted_at IS NULL AND i.id <> ?
            GROUP BY i.id
            ORDER BY shared DESC, i.year DESC, i.title
            LIMIT ?
            """,
            [.text(itemID), .text(itemID), .text(itemID), .int(Int64(max(limit, 0)))])

        return rows.compactMap { row in
            guard let ref = Self.ref(row), let shared = row.int("shared") else { return nil }
            return CitationRelated(ref: ref, shared: Int(shared))
        }
    }

    // MARK: - Full graph (library + optional OpenAlex)

    /// The library part, plus OpenAlex when online lookup is on and the paper has a DOI or arXiv ID.
    /// Never throws because of the network: the reason is in `source`.
    func graph(for itemID: String, forceRefresh: Bool = false) async throws -> CitationGraph {

        var graph = try localGraph(for: itemID)

        guard isOnlineEnabled() else {
            graph.source = .libraryOnly(reason: "Online lookup is off.")
            return graph
        }
        guard let item = try model.items.fetch(id: itemID) else {
            graph.source = .libraryOnly(reason: "That paper is not in the library.")
            return graph
        }
        guard let workPath = Self.workPath(doi: item.doi, arxivID: item.arxivID) else {
            graph.source = .libraryOnly(reason: "This paper has no DOI or arXiv ID, so nothing beyond the library can be looked up.")
            return graph
        }

        var fetches: [Fetched] = []

        do {
            // 1. The paper itself.
            let workURL = try url(path: workPath, query: [
                "select": "id,doi,title,publication_year,referenced_works,cited_by_count"])
            let own = try await fetch(workURL, forceRefresh: forceRefresh)
            fetches.append(own)

            guard let me = Self.parseWorkDetails(own.data) else { throw CitationGraphError.unreadable }

            // 2. What it cites.
            let libraryByDOI = try libraryDOIs(excluding: itemID)
            let references = Array(me.referencedIDs.prefix(config.maxReferences))
            var referenced: [CitationExternalWork] = []
            for chunk in references.chunked(50) {
                let u = try url(path: "/works", query: [
                    "filter": "openalex:" + chunk.joined(separator: "|"),
                    "per-page": "50",
                    "select": Self.listSelect])
                let f = try await fetch(u, forceRefresh: forceRefresh)
                fetches.append(f)
                referenced.append(contentsOf: Self.parseWorks(f.data))
            }
            let (refsInLibrary, refsElsewhere) = split(referenced, by: libraryByDOI)
            graph.cites.inLibrary = merge(graph.cites.inLibrary, refsInLibrary)
            graph.cites.elsewhere = refsElsewhere
            graph.cites.elsewhereTotal = max(me.referencedIDs.count - graph.cites.inLibrary.count, refsElsewhere.count)

            // 3. What cites it: first the library papers that do, then the most-cited others.
            var citingInLibrary: [CitationLibraryRef] = []
            let dois = Array(libraryByDOI.keys.sorted().prefix(config.maxLibraryDOIsChecked))
                .filter { !$0.contains(",") && !$0.contains("|") }
            for chunk in dois.chunked(50) {
                let u = try url(path: "/works", query: [
                    "filter": "cites:\(me.shortID),doi:" + chunk.joined(separator: "|"),
                    "per-page": "50",
                    "select": Self.listSelect])
                let f = try await fetch(u, forceRefresh: forceRefresh)
                fetches.append(f)
                let (found, _) = split(Self.parseWorks(f.data), by: libraryByDOI)
                citingInLibrary.append(contentsOf: found)
            }
            graph.citedBy.inLibrary = merge(graph.citedBy.inLibrary, citingInLibrary)

            let top = try url(path: "/works", query: [
                "filter": "cites:\(me.shortID)",
                "sort": "cited_by_count:desc",
                "per-page": String(config.citedByPageSize),
                "select": Self.listSelect])
            let f = try await fetch(top, forceRefresh: forceRefresh)
            fetches.append(f)
            let (_, citingElsewhere) = split(Self.parseWorks(f.data), by: libraryByDOI)
            graph.citedBy.elsewhere = citingElsewhere
            graph.citedBy.elsewhereTotal = max(me.citedByCount - graph.citedBy.inLibrary.count, citingElsewhere.count)

            graph.source = Self.combinedSource(fetches)

        } catch let error as CitationGraphError {
            // Whatever was gathered before the failure is dropped: half a graph would mislead.
            graph = try localGraph(for: itemID)
            graph.source = .libraryOnly(reason: error == .notFound
                ? error.errorDescription
                : "\(error.errorDescription ?? "OpenAlex could not be used.") Showing your library only.")
        }

        return graph
    }

    // MARK: Saving what was found

    /// Writes 'cites' links between library papers that the online graph found. Existing links are
    /// kept; nothing is removed. Returns how many links are new.
    @discardableResult
    func saveLibraryLinks(from graph: CitationGraph) throws -> Int {

        var created = 0
        try model.atomically {
            for ref in graph.cites.inLibrary where ref.itemID != graph.itemID {
                if try addCitesLink(from: graph.itemID, to: ref.itemID) { created += 1 }
            }
            for ref in graph.citedBy.inLibrary where ref.itemID != graph.itemID {
                if try addCitesLink(from: ref.itemID, to: graph.itemID) { created += 1 }
            }
        }
        return created
    }

    private func addCitesLink(from: String, to: String) throws -> Bool {
        let before = try model.database.scalarInt(
            "SELECT 1 FROM links WHERE from_type='item' AND from_id=? AND to_type='item' AND to_id=? AND rel='cites'",
            [.text(from), .text(to)])
        if before != nil { return false }
        try model.links.add(from: LinkEnd(.item, from), to: LinkEnd(.item, to), rel: .cites)
        return true
    }

    // MARK: Add to Inbox

    /// "Add all to Inbox": creates an Inbox paper for each work that is not already in the library
    /// (matched by DOI). When `itemID` is given, a 'cites' link ties each new paper to it.
    @discardableResult
    func addToInbox(
        _ works: [CitationExternalWork],
        relatedTo itemID: String? = nil,
        direction: CitationDirection = .sourceCitesNew
    ) throws -> CitationAddResult {

        var result = CitationAddResult()

        try model.atomically {
            var seenDOIs = Set<String>()

            for work in works {

                let title = work.title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { result.skipped += 1; continue }

                if let doi = work.doi {
                    if !seenDOIs.insert(doi).inserted { result.alreadyInLibrary += 1; continue }
                    let existing = try model.database.scalarText(
                        "SELECT id FROM items WHERE doi = ? AND deleted_at IS NULL LIMIT 1", [.text(doi)])
                    if let existing {
                        result.alreadyInLibrary += 1
                        if let itemID, existing != itemID {
                            if try link(itemID, existing, direction) { result.linked += 1 }
                        }
                        continue
                    }
                }

                var new = NewItem(title: title)
                new.type = work.type
                new.creators = work.authors.map(Self.creator)
                new.year = work.year
                new.venue = work.venue
                new.doi = work.doi
                new.sourceKind = .import
                new.sourceURL = "https://openalex.org/\(work.openAlexID)"
                new.reviewState = .inbox

                let item = try model.items.create(new)
                result.added.append(item.id)

                if let itemID, try link(itemID, item.id, direction) { result.linked += 1 }
            }
        }
        return result
    }

    private func link(_ source: String, _ new: String, _ direction: CitationDirection) throws -> Bool {
        switch direction {
        case .sourceCitesNew: return try addCitesLink(from: source, to: new)
        case .newCitesSource: return try addCitesLink(from: new, to: source)
        }
    }

    // MARK: - Fetching with the cache

    private struct Fetched {
        let data: Data
        let fetchedAt: String
        /// nil = live or fresh cache; set = shown from the cache because the network failed.
        let staleBecause: String?
        let fromCache: Bool
    }

    private func fetch(_ url: URL, forceRefresh: Bool) async throws -> Fetched {

        let key = "openalex:" + url.absoluteString
        let cached = try readCache(key)

        if let cached, !forceRefresh, isFresh(cached.fetchedAt) {
            return Fetched(data: cached.data, fetchedAt: cached.fetchedAt, staleBecause: nil, fromCache: true)
        }

        do {
            let (data, status) = try await transport.get(withContact(url))
            switch status {
            case 200:
                try writeCache(key, data)
                return Fetched(data: data, fetchedAt: model.now(), staleBecause: nil, fromCache: false)
            case 404:
                throw CitationGraphError.notFound
            default:
                throw CitationGraphError.badStatus(status)
            }
        } catch let error as CitationGraphError {
            if error == .notFound { throw error }
            if let cached {
                return Fetched(data: cached.data, fetchedAt: cached.fetchedAt,
                               staleBecause: error.errorDescription, fromCache: true)
            }
            throw error
        } catch {
            if let cached {
                return Fetched(data: cached.data, fetchedAt: cached.fetchedAt,
                               staleBecause: CitationGraphError.unreachable.errorDescription, fromCache: true)
            }
            throw CitationGraphError.unreachable
        }
    }

    private func readCache(_ key: String) throws -> (data: Data, fetchedAt: String)? {
        guard let row = try model.database.rows(
            "SELECT response_json, fetched_at FROM lookup_cache WHERE key = ?", [.text(key)]).first,
              let json = row.text("response_json"), let at = row.text("fetched_at") else { return nil }
        return (Data(json.utf8), at)
    }

    private func writeCache(_ key: String, _ data: Data) throws {
        guard let text = String(data: data, encoding: .utf8) else { return }
        try model.database.run(
            "INSERT OR REPLACE INTO lookup_cache (key, source, response_json, fetched_at) VALUES (?, 'openalex', ?, ?)",
            [.text(key), .text(text), .text(model.now())])
    }

    private func isFresh(_ fetchedAt: String) -> Bool {
        guard let date = Self.parseISO(fetchedAt) else { return false }
        return Date().timeIntervalSince(date) < Double(config.cacheFreshDays) * 86_400
    }

    private static func combinedSource(_ fetches: [Fetched]) -> CitationGraphSource {
        let cachedOnes = fetches.filter { $0.fromCache }
        guard !cachedOnes.isEmpty else {
            return .live(fetchedAt: fetches.map(\.fetchedAt).max() ?? "")
        }
        // Report the oldest copy, because that is how stale the list can be.
        let oldest = cachedOnes.map(\.fetchedAt).min() ?? ""
        let reason = fetches.compactMap(\.staleBecause).first
        return .cached(fetchedAt: oldest, because: reason)
    }

    static func parseISO(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    // MARK: - URLs

    static let listSelect = "id,doi,title,publication_year,primary_location,authorships,type"

    /// "/works/doi:10.1000/xyz". An arXiv ID uses its DataCite DOI, which OpenAlex also indexes.
    static func workPath(doi: String?, arxivID: String?) -> String? {
        if let doi = TextNormalizer.doi(doi), !doi.isEmpty { return "/works/doi:\(doi)" }
        if let raw = arxivID?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let id = TextNormalizer.arxivID(raw) ?? raw
            return "/works/doi:10.48550/arxiv.\(id.lowercased())"
        }
        return nil
    }

    private func url(path: String, query: [String: String]) throws -> URL {
        guard var components = URLComponents(string: config.baseURL) else { throw CitationGraphError.unreachable }
        components.path = path
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw CitationGraphError.unreachable }
        return url
    }

    /// The contact e-mail is added to the request only, not to the cache key.
    private func withContact(_ url: URL) -> URL {
        guard let email = config.contactEmail, !email.isEmpty,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "mailto", value: email)]
        return components.url ?? url
    }

    // MARK: - Library lookups

    /// DOI → library paper, for papers that are not in the Trash.
    private func libraryDOIs(excluding itemID: String) throws -> [String: CitationLibraryRef] {
        var map: [String: CitationLibraryRef] = [:]
        let rows = try model.database.rows(
            "SELECT id, title, year, doi FROM items WHERE doi IS NOT NULL AND doi <> '' AND deleted_at IS NULL AND id <> ?",
            [.text(itemID)])
        for row in rows {
            if let doi = row.text("doi"), let ref = Self.ref(row) { map[doi] = ref }
        }
        return map
    }

    private func split(
        _ works: [CitationExternalWork], by library: [String: CitationLibraryRef]
    ) -> ([CitationLibraryRef], [CitationExternalWork]) {
        var inside: [CitationLibraryRef] = []
        var outside: [CitationExternalWork] = []
        for work in works {
            if let doi = work.doi, let ref = library[doi] { inside.append(ref) } else { outside.append(work) }
        }
        return (inside, outside)
    }

    private func merge(_ a: [CitationLibraryRef], _ b: [CitationLibraryRef]) -> [CitationLibraryRef] {
        var seen = Set<String>()
        return (a + b)
            .filter { seen.insert($0.itemID).inserted }
            .sorted { ($0.year ?? 0, $0.title, $0.itemID) < ($1.year ?? 0, $1.title, $1.itemID) }
    }

    // MARK: - Parsing OpenAlex answers (pure)

    struct WorkDetails: Equatable {
        let shortID: String
        let referencedIDs: [String]
        let citedByCount: Int
    }

    /// "https://openalex.org/W2741809807" → "W2741809807".
    nonisolated static func shortID(_ id: String) -> String {
        id.split(separator: "/").last.map(String.init) ?? id
    }

    nonisolated static func parseWorkDetails(_ data: Data) -> WorkDetails? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = object["id"] as? String else { return nil }
        let references = (object["referenced_works"] as? [String] ?? []).map(shortID)
        return WorkDetails(
            shortID: shortID(id), referencedIDs: references,
            citedByCount: (object["cited_by_count"] as? Int) ?? 0)
    }

    nonisolated static func parseWorks(_ data: Data) -> [CitationExternalWork] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let results = object["results"] as? [[String: Any]] else { return [] }
        return results.compactMap(parseWork)
    }

    nonisolated static func parseWork(_ object: [String: Any]) -> CitationExternalWork? {
        guard let id = object["id"] as? String else { return nil }

        let doi = TextNormalizer.doi(object["doi"] as? String)
        let title = (object["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let year = object["publication_year"] as? Int

        var venue = ""
        if let location = object["primary_location"] as? [String: Any],
           let source = location["source"] as? [String: Any],
           let name = source["display_name"] as? String { venue = name }

        let authors = (object["authorships"] as? [[String: Any]] ?? []).compactMap { entry -> String? in
            ((entry["author"] as? [String: Any])?["display_name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyString
        }

        return CitationExternalWork(
            openAlexID: shortID(id), doi: (doi?.isEmpty == false) ? doi : nil, title: title, year: year,
            venue: venue, type: mapType(object["type"] as? String), authors: authors)
    }

    nonisolated static func mapType(_ openAlexType: String?) -> ItemType {
        switch openAlexType ?? "" {
        case "preprint": return .preprint
        case "proceedings-article", "proceedings", "conference-paper": return .conference
        case "book": return .book
        case "book-chapter", "chapter": return .chapter
        case "dissertation": return .thesis
        case "report": return .report
        case "dataset": return .dataset
        default: return .article
        }
    }

    /// "Given Family" → family = last word; "Family, Given" is respected.
    nonisolated static func creator(fromDisplayName name: String) -> CreatorInput {
        let text = name.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if let comma = text.firstIndex(of: ",") {
            return CreatorInput(
                family: text[..<comma].trimmingCharacters(in: .whitespaces),
                given: text[text.index(after: comma)...].trimmingCharacters(in: .whitespaces))
        }
        let words = text.split(separator: " ").map(String.init)
        guard words.count > 1 else { return CreatorInput(family: text) }
        return CreatorInput(family: words.last ?? text, given: words.dropLast().joined(separator: " "))
    }

    private static func creator(_ name: String) -> CreatorInput { creator(fromDisplayName: name) }
}

// MARK: - Small helpers

private extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return [] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

private extension String {
    nonisolated var nonEmptyString: String? { isEmpty ? nil : self }
}
