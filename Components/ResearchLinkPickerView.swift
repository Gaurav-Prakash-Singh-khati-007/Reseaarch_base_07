//
//  ResearchLinkPickerView.swift
//  ResearchBase
//
//  Created by Gaurav Khati on 27/09/26.
//


//
//  ResearchLinkPickerView.swift
//  ResearchBase
//
//  Phase 8 — Research Problems & Ideas
//
//  A generic, reusable multi-select picker sheet used to link
//  existing research objects (papers, literature findings,
//  research gaps, research problems, research notes) to a
//  Research Gap / Research Problem / Research Idea.
//
//  Mirrors the existing PaperLinkPickerView look and feel so the
//  Phase 8 workspace stays visually consistent with Phase 7.
//

import SwiftUI

struct ResearchLinkPickerView<Item: Identifiable>: View {

    let navTitle: String
    let items: [Item]

    @Binding var linkedIDs: Set<Item.ID>

    let title: (Item) -> String
    let subtitle: (Item) -> String
    let matches: (Item, String) -> Bool
    let emptyMessage: String

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    init(
        navTitle: String,
        items: [Item],
        linkedIDs: Binding<Set<Item.ID>>,
        emptyMessage: String,
        title: @escaping (Item) -> String,
        subtitle: @escaping (Item) -> String = { _ in "" },
        matches: @escaping (Item, String) -> Bool
    ) {
        self.navTitle = navTitle
        self.items = items
        self._linkedIDs = linkedIDs
        self.emptyMessage = emptyMessage
        self.title = title
        self.subtitle = subtitle
        self.matches = matches
    }

    private var filteredItems: [Item] {

        let query =
            searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !query.isEmpty else { return items }

        return items.filter { matches($0, query) }
    }

    private func isLinked(_ item: Item) -> Bool {
        linkedIDs.contains(item.id)
    }

    private func toggle(_ item: Item) {

        if isLinked(item) {
            linkedIDs.remove(item.id)
        } else {
            linkedIDs.insert(item.id)
        }
    }

    var body: some View {

        VStack(spacing: 0) {

            HStack {

                Text(navTitle)
                    .font(RBFont.detail(.semibold))
                    .foregroundStyle(RBColor.primaryText)

                Spacer()

                // Read-only count of what is currently linked.
                if !linkedIDs.isEmpty {
                    RBBadge(
                        text: "\(linkedIDs.count) linked",
                        tone: .neutral
                    )
                }

                Button("Done") { dismiss() }
                    .buttonStyle(RBPrimaryButtonStyle())
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)

            Divider().overlay(RBColor.border)

            RBSearchField(
                placeholder: "Search...",
                text: $searchText
            )
            .padding(.horizontal, 24)
            .padding(.vertical, 14)

            if items.isEmpty {

                Spacer()

                Text(emptyMessage)
                    .font(RBFont.body())
                    .foregroundStyle(RBColor.mutedText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                Spacer()

            } else {

                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(filteredItems) { item in

                            RBRow(
                                isSelected: isLinked(item),
                                action: { toggle(item) }
                            ) {

                                HStack(spacing: 12) {

                                    Image(
                                        systemName:
                                            isLinked(item)
                                            ? "checkmark.circle.fill"
                                            : "circle"
                                    )
                                    .foregroundStyle(
                                        isLinked(item)
                                        ? RBColor.accent
                                        : RBColor.mutedText
                                    )

                                    VStack(alignment: .leading, spacing: 3) {

                                        Text(title(item))
                                            .font(RBFont.body(.medium))
                                            .foregroundStyle(RBColor.primaryText)
                                            .lineLimit(1)

                                        let sub = subtitle(item)

                                        if !sub.isEmpty {
                                            Text(sub)
                                                .font(RBFont.caption())
                                                .foregroundStyle(RBColor.secondaryText)
                                                .lineLimit(1)
                                        }
                                    }

                                    Spacer()
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }
            }
        }
        .frame(width: 480, height: 560)
        .background(RBColor.background)
    }
}
