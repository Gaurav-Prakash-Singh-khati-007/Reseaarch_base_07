//
//  PaperListFilters.swift
//  ResearchBase
//
//  Phase 13 — Papers workspace
//
//  Pure filtering / searching / sorting logic for the Papers screen.
//  No persistence, no SwiftUI. It only reads fields that already
//  exist on PaperRecord, so it adds no model changes.
//

import Foundation

// MARK: - Reading Status Label

extension ReadingStatus {

    /// Name shown in the UI. The stored values stay Unread / Reading / Read.
    var libraryLabel: String {
        switch self {
        case .unread: return "To Read"
        case .reading: return "Reading"
        case .read: return "Completed"
        }
    }
}

// MARK: - Status Filter

enum PaperStatusFilter: String, CaseIterable, Identifiable {

    case all = "All"
    case unread = "Unread"
    case reading = "Reading"
    case read = "Read"

    var id: String { rawValue }

    /// Name shown on the filter chips. The raw values stay as they are.
    var libraryLabel: String {
        switch self {
        case .all: return "All"
        case .unread: return "To Read"
        case .reading: return "Reading"
        case .read: return "Completed"
        }
    }

    func matches(_ status: ReadingStatus) -> Bool {
        switch self {
        case .all: return true
        case .unread: return status == .unread
        case .reading: return status == .reading
        case .read: return status == .read
        }
    }
}

// MARK: - PDF Filter

enum PaperPDFFilter: String, CaseIterable, Identifiable {

    case any = "Any"
    case withPDF = "Has PDF"
    case withoutPDF = "No PDF file"

    var id: String { rawValue }
}

// MARK: - PDF State

/// What is actually true about a paper's PDF right now.
enum PaperPDFState {

    /// A path is stored and the file exists on disk.
    case available

    /// A path is stored but the file cannot be found.
    case missing

    /// No PDF was ever attached.
    case none

    static func of(_ paper: PaperRecord) -> PaperPDFState {

        let path = paper.pdfFilePath
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !path.isEmpty else { return .none }

        return FileManager.default.fileExists(atPath: path)
            ? .available
            : .missing
    }
}

// MARK: - Sort Option

enum PaperSortOption: String, CaseIterable, Identifiable {

    case recentlyAdded = "Recently Added"
    case recentlyOpened = "Recently Opened"
    case titleAZ = "Title (A–Z)"
    case yearNewest = "Year (Newest)"
    case yearOldest = "Year (Oldest)"
    case highestRated = "Highest Rated"

    var id: String { rawValue }
}

// MARK: - Filters

struct PaperListFilters: Equatable {

    var searchText: String = ""
    var status: PaperStatusFilter = .all
    var pdf: PaperPDFFilter = .any
    var tag: String? = nil
    var sort: PaperSortOption = .recentlyAdded

    /// True when anything other than the default view is active.
    /// Sorting alone does not count as filtering.
    var isFiltering: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || status != .all
            || pdf != .any
            || tag != nil
    }

    /// Clears search and filters. Keeps the chosen sort order.
    mutating func reset() {
        searchText = ""
        status = .all
        pdf = .any
        tag = nil
    }

    // MARK: Apply

    func apply(to papers: [PaperRecord]) -> [PaperRecord] {

        let terms = searchText
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)

        let filtered = papers.filter { paper in

            guard status.matches(paper.readingStatus) else {
                return false
            }

            if let selectedTag = tag {
                let hasTag = paper.tags.contains {
                    $0.caseInsensitiveCompare(selectedTag) == .orderedSame
                }
                if !hasTag { return false }
            }

            switch pdf {
            case .any:
                break
            case .withPDF:
                if PaperPDFState.of(paper) != .available { return false }
            case .withoutPDF:
                if PaperPDFState.of(paper) == .available { return false }
            }

            if !terms.isEmpty {
                let haystack = Self.searchableText(for: paper)
                for term in terms where !haystack.contains(term) {
                    return false
                }
            }

            return true
        }

        return sorted(filtered)
    }

    // MARK: Sort

    private func sorted(_ papers: [PaperRecord]) -> [PaperRecord] {

        func titleOrder(_ a: PaperRecord, _ b: PaperRecord) -> Bool {
            a.title.localizedStandardCompare(b.title) == .orderedAscending
        }

        switch sort {

        case .recentlyAdded:
            return papers.sorted {
                $0.addedAt != $1.addedAt
                    ? $0.addedAt > $1.addedAt
                    : titleOrder($0, $1)
            }

        case .recentlyOpened:
            // Never-opened papers go last.
            return papers.sorted {
                switch ($0.lastOpenedAt, $1.lastOpenedAt) {
                case let (a?, b?):
                    return a != b ? a > b : titleOrder($0, $1)
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    return titleOrder($0, $1)
                }
            }

        case .titleAZ:
            return papers.sorted(by: titleOrder)

        case .yearNewest:
            // Papers with no year (0 or less) go last.
            return papers.sorted {
                if $0.year != $1.year {
                    if $0.year <= 0 { return false }
                    if $1.year <= 0 { return true }
                    return $0.year > $1.year
                }
                return titleOrder($0, $1)
            }

        case .yearOldest:
            return papers.sorted {
                if $0.year != $1.year {
                    if $0.year <= 0 { return false }
                    if $1.year <= 0 { return true }
                    return $0.year < $1.year
                }
                return titleOrder($0, $1)
            }

        case .highestRated:
            return papers.sorted {
                $0.rating != $1.rating
                    ? $0.rating > $1.rating
                    : titleOrder($0, $1)
            }
        }
    }

    // MARK: Search Text

    /// Lower-cased text a search term is matched against. A paper
    /// matches when every whitespace-separated term appears somewhere
    /// in it.
    private static func searchableText(for paper: PaperRecord) -> String {
        [
            paper.title,
            paper.authors,
            paper.venue,
            paper.tagsText,
            paper.abstractText,
            paper.doi,
            paper.citationKey,
            paper.year > 0 ? String(paper.year) : ""
        ]
        .joined(separator: " ")
        .lowercased()
    }

    // MARK: Helpers

    /// Every distinct tag across the given papers, case-insensitively
    /// de-duplicated and sorted.
    static func allTags(in papers: [PaperRecord]) -> [String] {

        var seen: [String: String] = [:]

        for paper in papers {
            for tag in paper.tags {
                let key = tag.lowercased()
                if seen[key] == nil { seen[key] = tag }
            }
        }

        return seen.values.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    /// Number of papers per reading status, ignoring every other
    /// filter, for the counts shown on the status chips.
    static func count(
        for status: PaperStatusFilter,
        in papers: [PaperRecord]
    ) -> Int {
        papers.filter { status.matches($0.readingStatus) }.count
    }
}
