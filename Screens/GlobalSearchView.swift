//
//  GlobalSearchView.swift
//  ResearchBase
//
//  Created by Gaurav Khati on 28/09/26.
//


//
//  GlobalSearchView.swift
//  ResearchBase
//
//  Phase 12 — Search, Linking & Cross-Module Intelligence
//
//  Searches real, persisted SwiftData records across all nine entity
//  types via ResearchDataStore.globalSearch(_:). An empty query shows
//  a real empty state — never "everything" and never fake results.
//

import SwiftUI
import SwiftData

struct GlobalSearchView: View {

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var router: NavigationRouter

    @State private var query: String = ""
    @State private var results: [ResearchDataStore.GlobalSearchResult] = []
    @State private var errorMessage: String?
    @FocusState private var searchFocused: Bool

    private var store: ResearchDataStore {
        ResearchDataStore(modelContext: modelContext)
    }

    private var groupedResults: [(label: String, items: [ResearchDataStore.GlobalSearchResult])] {
        let grouped = Dictionary(grouping: results) { $0.target.kindLabel }
        return grouped
            .map { (label: $0.key, items: $0.value) }
            .sorted { $0.label < $1.label }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider().overlay(RBColor.border)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        RB9InlineEmptyNote(
                            icon: "magnifyingglass",
                            title: "Search ResearchBase",
                            message: "Find papers, notes, findings, gaps, problems, ideas, experiments, writing and projects."
                        )
                    } else if results.isEmpty {
                        RB9InlineEmptyNote(
                            icon: "magnifyingglass",
                            title: "No Results",
                            message: "Nothing matches \"\(query)\"."
                        )
                    } else {
                        ForEach(groupedResults, id: \.label) { group in
                            resultGroup(group)
                        }
                    }
                }
                .padding(20)
            }
        }
        .background(RBColor.background)
        .onChange(of: query) { _, newValue in
            runSearch(newValue)
        }
        .onAppear {
            if let pending = router.pendingSearchQuery {
                query = pending
                router.pendingSearchQuery = nil
            }
            searchFocused = true
        }
    }

    private var header: some View {
        RBSearchField(
            placeholder: "Search papers, notes, findings, gaps, ideas, experiments, writing, projects…",
            text: $query
        )
        .focused($searchFocused)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func resultGroup(_ group: (label: String, items: [ResearchDataStore.GlobalSearchResult])) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            RBSectionLabel(text: "\(group.label.uppercased()) (\(group.items.count))")

            VStack(spacing: 6) {
                ForEach(group.items) { item in
                    RBRow(isSelected: false, action: { router.open(item.target) }) {
                        HStack(spacing: 10) {
                            Image(systemName: item.target.iconName)
                                .font(RBFont.label(.medium))
                                .foregroundStyle(RBColor.accent)
                                .frame(width: 16)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(RBFont.body(.medium))
                                    .foregroundStyle(RBColor.primaryText)
                                    .lineLimit(1)

                                if !item.subtitle.isEmpty {
                                    Text(item.subtitle)
                                        .font(RBFont.caption())
                                        .foregroundStyle(RBColor.mutedText)
                                        .lineLimit(1)
                                }
                            }

                            Spacer()
                        }
                    }
                }
            }
        }
    }

    private func runSearch(_ text: String) {
        do {
            results = try store.globalSearch(text)
        } catch {
            results = []
            errorMessage = error.localizedDescription
        }
    }
}
