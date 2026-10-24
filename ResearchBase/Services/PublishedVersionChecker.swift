//
//  PublishedVersionChecker.swift
//  ResearchBase
//
//  Owner: Agent 7 · Features: F-21
//
//  Answers two questions about a paper, from its DOI and/or arXiv ID:
//    1. Has this preprint been published? (gives the published DOI and where)
//    2. Has this paper been retracted, or flagged with an expression of concern?
//
//  Sources: Crossref (published-version link, retraction notices), the arXiv API
//  (journal DOI of an arXiv-only paper), OpenAlex (second opinion on retractions).
//
//  This file only ASKS and ANSWERS. It never touches the database and never
//  edits an item. The caller stores the answer in the existing items columns
//  published_doi / retracted / last_checked_at, but only when `status == .checked`
//  (a failed or offline check must leave the old values alone).
//  No sandbox exception is needed: the project has the App Sandbox off.
//
//  PUBLIC API
//    struct PublishedVersionQuery          doi, arxivID
//    enum RetractionState                  .noneFound / .retracted / .expressionOfConcern / .unknown
//    struct PublishedVersionResult         status, publishedDOI, publishedVenue, publishedYear,
//                                          retraction, checkedAt, sourcesAnswered,
//                                          isRetracted, needsAttention, summaryLine
//    enum PublishedVersionCheckInterval    .weekly / .monthly / .never  (Settings, F-21 row)
//    protocol PublishedVersionFetching     one async method; swap it in tests
//    struct URLSessionFetcher              the real network
//    struct PublishedVersionChecker
//      init(contactEmail:allowNetwork:fetcher:)
//      func check(_ query:now:) async -> PublishedVersionResult
//      func checkMany(_ items:pause:sleep:onResult:) async      (the weekly background pass)
//      static func isDue(lastCheckedAt:interval:now:) -> Bool
//
//  Threading: everything is nonisolated and Sendable; call from any task.
//  TextNormalizer is main-actor isolated, so two tiny private copies of its
//  DOI / arXiv rules live here (same results).
//

import Foundation

// MARK: - Query and result

nonisolated struct PublishedVersionQuery: Equatable, Sendable {
    var doi: String?
    var arxivID: String?

    init(doi: String? = nil, arxivID: String? = nil) {
        self.doi = doi
        self.arxivID = arxivID
    }
}

nonisolated enum RetractionState: Equatable, Sendable {
    /// At least one retraction-aware source answered and none reported a problem.
    case noneFound
    /// Crossref lists a retraction, withdrawal or removal notice, or OpenAlex says retracted.
    case retracted(noticeDOI: String?)
    case expressionOfConcern(noticeDOI: String?)
    /// No retraction-aware source answered. Says nothing either way.
    case unknown

    fileprivate var rank: Int {
        switch self {
        case .retracted: return 3
        case .expressionOfConcern: return 2
        case .noneFound: return 1
        case .unknown: return 0
        }
    }
}

nonisolated struct PublishedVersionResult: Equatable, Sendable {

    enum Status: Equatable, Sendable {
        /// At least one source answered. Safe to store.
        case checked
        /// No DOI and no arXiv ID: nothing to ask.
        case nothingToCheck
        /// Network is switched off ("Work offline"). Nothing was sent.
        case offline
        /// Every source that was tried failed. Keep the old values.
        case failed(String)
    }

    var status: Status
    /// Lower-case DOI of the published version, when the item is a preprint that has one.
    var publishedDOI: String?
    var publishedVenue: String?
    var publishedYear: Int?
    var retraction: RetractionState
    var checkedAt: Date
    /// Which sources gave a real answer, e.g. ["Crossref", "OpenAlex"].
    var sourcesAnswered: [String]
    /// True when the arXiv API was called (callers pace those requests).
    var contactedArXiv: Bool = false

    var isRetracted: Bool {
        if case .retracted = retraction { return true }
        return false
    }

    /// Worth a warning banner: retracted or an expression of concern.
    var needsAttention: Bool {
        switch retraction {
        case .retracted, .expressionOfConcern: return true
        case .noneFound, .unknown: return false
        }
    }

    /// One line for the banner under the paper title.
    var summaryLine: String {
        switch status {
        case .nothingToCheck: return "Add a DOI or arXiv ID to check for a published version."
        case .offline: return "Offline: not checked."
        case .failed(let reason): return reason
        case .checked:
            var parts: [String] = []
            switch retraction {
            case .retracted: parts.append("This paper has been retracted.")
            case .expressionOfConcern: parts.append("An expression of concern was published for this paper.")
            case .noneFound: break
            case .unknown: break
            }
            if publishedDOI != nil {
                var place = [publishedVenue, publishedYear.map(String.init)].compactMap { $0 }.joined(separator: " ")
                if place.isEmpty { place = "doi:\(publishedDOI ?? "")" }
                parts.append("Also published at \(place).")
            }
            if retraction == .noneFound && !needsAttention { parts.append("Retraction check: none found.") }
            if parts.isEmpty { parts.append("Checked: nothing new found.") }
            return parts.joined(separator: " ")
        }
    }
}

// MARK: - How often (Settings: "Check for published versions and retractions")

nonisolated enum PublishedVersionCheckInterval: String, CaseIterable, Sendable {
    case weekly, monthly, never

    var days: Int? {
        switch self {
        case .weekly: return 7
        case .monthly: return 30
        case .never: return nil
        }
    }
}

// MARK: - Network seam

nonisolated protocol PublishedVersionFetching: Sendable {
    /// Returns the body and the HTTP status code. Throws only when there is no HTTP answer at all.
    func fetch(_ request: URLRequest) async throws -> (Data, Int)
}

nonisolated struct URLSessionFetcher: PublishedVersionFetching {
    func fetch(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

// MARK: - Checker

nonisolated struct PublishedVersionChecker: Sendable {

    /// Sent with requests so Crossref and OpenAlex give the faster "polite" tier.
    var contactEmail: String?
    /// False when the person chose "Never contact the internet".
    var allowNetwork: Bool
    var fetcher: PublishedVersionFetching

    init(
        contactEmail: String? = nil,
        allowNetwork: Bool = true,
        fetcher: PublishedVersionFetching = URLSessionFetcher()
    ) {
        self.contactEmail = contactEmail
        self.allowNetwork = allowNetwork
        self.fetcher = fetcher
    }

    // MARK: One paper

    func check(_ query: PublishedVersionQuery, now: Date = Date()) async -> PublishedVersionResult {

        let ownDOI = Self.normalizedDOI(query.doi)
        var arxivID = Self.normalizedArXivID(query.arxivID)
        let arxivDOIPrefix = "10.48550/arxiv."
        if arxivID == nil, let d = ownDOI, d.hasPrefix(arxivDOIPrefix) {
            arxivID = String(d.dropFirst(arxivDOIPrefix.count))
        }

        func early(_ status: PublishedVersionResult.Status) -> PublishedVersionResult {
            PublishedVersionResult(status: status, retraction: .unknown, checkedAt: now, sourcesAnswered: [])
        }
        guard ownDOI != nil || arxivID != nil else { return early(.nothingToCheck) }
        guard allowNetwork else { return early(.offline) }

        var state = Gathered()
        let ownIsArXivDOI = ownDOI?.hasPrefix("10.48550/") == true

        // 1. The item's own DOI at Crossref (arXiv DOIs live at DataCite, not Crossref).
        if let doi = ownDOI, !ownIsArXivDOI {
            await askCrossref(doi, role: .own, into: &state)
        }

        // 2. An arXiv-only paper, or a preprint with no link yet: ask arXiv for the journal DOI.
        let ownMayBePreprint = ownDOI == nil || ownIsArXivDOI || state.ownIsPreprint
        if state.publishedDOI == nil, ownMayBePreprint, let id = arxivID {
            await askArXiv(id, ownDOI: ownDOI, into: &state)
        }

        // 3. The published version: where it appeared, and whether IT was retracted.
        if let published = state.publishedDOI, published != ownDOI {
            await askCrossref(published, role: .published, into: &state)
        }

        // 4. Second opinion on retractions, for the paper people actually cite.
        if let target = state.publishedDOI ?? ownDOI, !target.hasPrefix("10.48550/") {
            await askOpenAlex(target, into: &state)
        }

        // Build the answer.
        let status: PublishedVersionResult.Status
        if state.gotAnyAnswer {
            status = .checked
        } else if let reason = state.failures.first {
            status = .failed(reason)
        } else {
            status = .checked
        }

        var retraction = state.retraction
        if retraction.rank < RetractionState.noneFound.rank, state.retractionSourceAnswered {
            retraction = .noneFound
        }

        return PublishedVersionResult(
            status: status,
            publishedDOI: state.publishedDOI,
            publishedVenue: state.venue,
            publishedYear: state.year,
            retraction: retraction,
            checkedAt: now,
            sourcesAnswered: state.sourcesAnswered,
            contactedArXiv: state.contactedArXiv
        )
    }

    // MARK: Many papers (the weekly background pass)

    /// Checks one paper after another, politely. Stops when the task is cancelled, when the
    /// network is off, or after 3 failures in a row (probably offline).
    /// - Parameters:
    ///   - pause: seconds to wait between papers. After a paper that used arXiv the wait is at least 3.
    ///   - sleep: replaceable in tests.
    ///   - onResult: called once per paper, in order, with the id the caller gave.
    func checkMany(
        _ items: [(id: String, query: PublishedVersionQuery)],
        pause: TimeInterval = 1.0,
        sleep: @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        },
        onResult: @Sendable (String, PublishedVersionResult) async -> Void
    ) async {
        var failuresInARow = 0
        for item in items {
            if Task.isCancelled { return }

            let result = await check(item.query)
            await onResult(item.id, result)

            if result.status == .offline { return }
            if case .failed = result.status { failuresInARow += 1 } else { failuresInARow = 0 }
            if failuresInARow >= 3 { return }

            let wait = result.contactedArXiv ? max(pause, 3.0) : pause
            await sleep(wait)
        }
    }

    // MARK: Is a check due?

    /// True when the paper was never checked, or the last check is older than the interval.
    /// Unreadable dates count as never checked.
    static func isDue(
        lastCheckedAt: String?,
        interval: PublishedVersionCheckInterval,
        now: Date = Date()
    ) -> Bool {
        guard let days = interval.days else { return false }
        guard let text = lastCheckedAt, let last = parseISO(text) else { return true }
        return now.timeIntervalSince(last) >= Double(days) * 86_400
    }

    // MARK: - Sources

    private enum Role { case own, published }

    /// What the sources told us, gathered across the steps.
    private struct Gathered {
        var publishedDOI: String?
        var venue: String?
        var year: Int?
        var retraction: RetractionState = .unknown
        var ownIsPreprint = false
        var sourcesAnswered: [String] = []
        var failures: [String] = []
        var gotAnyAnswer = false
        var retractionSourceAnswered = false
        var contactedArXiv = false

        mutating func answered(_ source: String) {
            gotAnyAnswer = true
            if !sourcesAnswered.contains(source) { sourcesAnswered.append(source) }
        }

        mutating func merge(_ new: RetractionState) {
            if new.rank > retraction.rank { retraction = new }
        }
    }

    private enum Outcome {
        case answer(Data)
        case notFound
        case failure(String)
    }

    // Crossref

    struct CrossrefInfo: Equatable {
        var preprintOf: [String] = []
        var isPreprint = false
        var retraction: RetractionState = .noneFound
        var venue: String?
        var year: Int?
    }

    private func askCrossref(_ doi: String, role: Role, into state: inout Gathered) async {
        guard let url = makeURL(base: "https://api.crossref.org/works/", path: doi, mailto: true) else { return }

        switch await get(url, source: "Crossref", accept: "application/json") {
        case .failure(let message):
            state.failures.append(message)
        case .notFound:
            state.gotAnyAnswer = true     // reachable, simply does not know this DOI
        case .answer(let data):
            guard let info = Self.parseCrossref(data) else {
                state.failures.append("Crossref sent an answer that could not be read.")
                return
            }
            state.answered("Crossref")
            state.retractionSourceAnswered = true
            state.merge(info.retraction)

            switch role {
            case .own:
                state.ownIsPreprint = info.isPreprint || !info.preprintOf.isEmpty
                if let first = info.preprintOf.first(where: { $0 != doi }) {
                    state.publishedDOI = first
                }
            case .published:
                if let venue = info.venue { state.venue = venue }
                if let year = info.year { state.year = year }
            }
        }
    }

    static func parseCrossref(_ data: Data) -> CrossrefInfo? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let message = root["message"] as? [String: Any] else { return nil }

        var info = CrossrefInfo()

        if let relation = message["relation"] as? [String: Any],
           let links = relation["is-preprint-of"] as? [[String: Any]] {
            for link in links {
                let type = (link["id-type"] as? String)?.lowercased()
                if type == nil || type == "doi", let id = normalizedDOI(link["id"] as? String) {
                    info.preprintOf.append(id)
                }
            }
        }
        info.isPreprint = (message["subtype"] as? String)?.lowercased() == "preprint"

        // Notices that point at this paper: retraction, withdrawal, removal, expression of concern.
        if let updates = message["updated-by"] as? [[String: Any]] {
            var best = RetractionState.noneFound
            for update in updates {
                let type = ((update["type"] as? String) ?? (update["update-type"] as? String) ?? "")
                    .lowercased()
                    .replacingOccurrences(of: "-", with: "_")
                let notice = normalizedDOI(update["DOI"] as? String)
                let found: RetractionState?
                switch type {
                case "retraction", "withdrawal", "removal": found = .retracted(noticeDOI: notice)
                case "expression_of_concern": found = .expressionOfConcern(noticeDOI: notice)
                default: found = nil
                }
                if let found, found.rank > best.rank { best = found }
            }
            info.retraction = best
        }

        let shortNames = message["short-container-title"] as? [String]
        let longNames = message["container-title"] as? [String]
        info.venue = [shortNames?.first, longNames?.first]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }

        if let issued = message["issued"] as? [String: Any],
           let parts = issued["date-parts"] as? [[Any]],
           let year = parts.first?.first as? Int {
            info.year = year
        }
        return info
    }

    // arXiv

    private func askArXiv(_ id: String, ownDOI: String?, into state: inout Gathered) async {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? id
        guard let url = URL(string: "https://export.arxiv.org/api/query?id_list=\(encoded)") else { return }
        state.contactedArXiv = true

        switch await get(url, source: "arXiv", accept: "application/atom+xml") {
        case .failure(let message):
            state.failures.append(message)
        case .notFound:
            state.gotAnyAnswer = true
        case .answer(let data):
            state.answered("arXiv")
            let parser = rbA7_ArXivAtomParser()
            let xml = XMLParser(data: data)
            xml.delegate = parser
            xml.parse()

            if let doi = Self.normalizedDOI(parser.doi), doi != ownDOI, !doi.hasPrefix("10.48550/") {
                state.publishedDOI = doi
            }
            if state.venue == nil, let ref = parser.journalRef, !ref.isEmpty {
                state.venue = ref     // replaced by Crossref's name when step 3 succeeds
            }
        }
    }

    // OpenAlex

    private func askOpenAlex(_ doi: String, into state: inout Gathered) async {
        guard let url = makeURL(
            base: "https://api.openalex.org/works/doi:", path: doi, mailto: true, extraQuery: "select=id,is_retracted"
        ) else { return }

        switch await get(url, source: "OpenAlex", accept: "application/json") {
        case .failure(let message):
            state.failures.append(message)
        case .notFound:
            state.gotAnyAnswer = true
        case .answer(let data):
            guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let retracted = root["is_retracted"] as? Bool else {
                state.failures.append("OpenAlex sent an answer that could not be read.")
                return
            }
            state.answered("OpenAlex")
            state.retractionSourceAnswered = true
            state.merge(retracted ? .retracted(noticeDOI: nil) : .noneFound)
        }
    }

    // MARK: HTTP

    private func get(_ url: URL, source: String, accept: String) async -> Outcome {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        do {
            let (data, code) = try await fetcher.fetch(request)
            switch code {
            case 200..<300: return .answer(data)
            case 404: return .notFound
            case 429: return .failure("\(source) asked us to slow down. Try again later.")
            default: return .failure("\(source) answered with an error (\(code)). Try again later.")
            }
        } catch {
            return .failure("Couldn’t reach \(source). You may be offline.")
        }
    }

    private var userAgent: String {
        if let email = cleanEmail { return "ResearchBase/1.0 (mailto:\(email))" }
        return "ResearchBase/1.0"
    }

    private var cleanEmail: String? {
        guard let email = contactEmail?.trimmingCharacters(in: .whitespacesAndNewlines),
              email.contains("@"), !email.contains(" ") else { return nil }
        return email
    }

    private func makeURL(base: String, path: String, mailto: Bool, extraQuery: String? = nil) -> URL? {
        guard let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        var query: [String] = []
        if let extraQuery { query.append(extraQuery) }
        if mailto, let email = cleanEmail,
           let encoded = email.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            query.append("mailto=\(encoded)")
        }
        let tail = query.isEmpty ? "" : "?" + query.joined(separator: "&")
        return URL(string: base + encodedPath + tail)
    }

    // MARK: - Small helpers (private copies of TextNormalizer rules, which is main-actor isolated)

    static func normalizedDOI(_ text: String?) -> String? {
        guard var value = text?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else { return nil }
        for prefix in ["https://doi.org/", "http://doi.org/", "https://dx.doi.org/",
                       "http://dx.doi.org/", "doi.org/", "doi:"] where value.hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count))
            break
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func normalizedArXivID(_ text: String?) -> String? {
        guard var value = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        let lower = value.lowercased()
        for prefix in ["https://arxiv.org/abs/", "http://arxiv.org/abs/", "arxiv.org/abs/", "arxiv:"]
        where lower.hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count))
            break
        }
        // drop a version suffix: 1706.03762v5 -> 1706.03762
        if let range = value.range(of: #"v\d+$"#, options: .regularExpression) {
            value.removeSubrange(range)
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func parseISO(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }
}

// MARK: - arXiv Atom reader (private to this file)

/// Reads <arxiv:doi> and <arxiv:journal_ref> of the first <entry> in an arXiv API answer.
nonisolated private final class rbA7_ArXivAtomParser: NSObject, XMLParserDelegate {

    private(set) var doi: String?
    private(set) var journalRef: String?

    private var insideEntry = false
    private var entriesSeen = 0
    private var capturing: String?
    private var buffer = ""

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "entry" {
            entriesSeen += 1
            insideEntry = entriesSeen == 1
        } else if insideEntry, elementName == "arxiv:doi" || elementName == "arxiv:journal_ref" {
            capturing = elementName
            buffer = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturing != nil { buffer += string }
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == capturing {
            let value = buffer.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            if elementName == "arxiv:doi", doi == nil {
                doi = value.split(separator: " ").first.map(String.init)
            } else if elementName == "arxiv:journal_ref", journalRef == nil {
                journalRef = value
            }
            capturing = nil
        }
        if elementName == "entry" { insideEntry = false }
    }
}
