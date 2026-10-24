//
//  PaperLinkPickerView.swift
//  ResearchBase
//
//  Created by Gaurav Khati on 27/09/26.
//


import SwiftUI
import SwiftData

struct PaperLinkPickerView: View {

    @Environment(\.dismiss) private var dismiss

    @Query(
        sort: [SortDescriptor(\PaperRecord.addedAt, order: .reverse)]
    )
    private var allPapers: [PaperRecord]

    @Binding var linkedPapers: [PaperRecord]

    @State private var searchText = ""

    private var filteredPapers: [PaperRecord] {

        let trimmed =
            searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        guard !trimmed.isEmpty else { return allPapers }

        return allPapers.filter {
            $0.title.lowercased().contains(trimmed) ||
            $0.authors.lowercased().contains(trimmed)
        }
    }

    private func isLinked(_ paper: PaperRecord) -> Bool {
        linkedPapers.contains { $0.id == paper.id }
    }

    private func toggle(_ paper: PaperRecord) {

        if isLinked(paper) {
            linkedPapers.removeAll { $0.id == paper.id }
        } else {
            linkedPapers.append(paper)
        }
    }

    var body: some View {

        VStack(spacing: 0) {

            HStack {

                Text("Link Papers")
                    .font(RBFont.detail(.semibold))
                    .foregroundStyle(RBColor.primaryText)

                Spacer()

                // Read-only count of what is currently linked.
                if !linkedPapers.isEmpty {
                    RBBadge(
                        text: "\(linkedPapers.count) linked",
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
                placeholder: "Search papers...",
                text: $searchText
            )
            .padding(.horizontal, 24)
            .padding(.vertical, 14)

            if allPapers.isEmpty {

                Spacer()

                Text("Your library is empty. Add papers first.")
                    .font(RBFont.body())
                    .foregroundStyle(RBColor.mutedText)

                Spacer()

            } else {

                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(filteredPapers) { paper in

                            RBRow(
                                isSelected: isLinked(paper),
                                action: { toggle(paper) }
                            ) {

                                HStack(spacing: 12) {

                                    Image(
                                        systemName:
                                            isLinked(paper)
                                            ? "checkmark.circle.fill"
                                            : "circle"
                                    )
                                    .foregroundStyle(
                                        isLinked(paper)
                                        ? RBColor.accent
                                        : RBColor.mutedText
                                    )

                                    VStack(alignment: .leading, spacing: 3) {

                                        Text(paper.title)
                                            .font(RBFont.body(.medium))
                                            .foregroundStyle(RBColor.primaryText)
                                            .lineLimit(1)

                                        Text(paper.authors.isEmpty ? "Unknown authors" : paper.authors)
                                            .font(RBFont.caption())
                                            .foregroundStyle(RBColor.secondaryText)
                                            .lineLimit(1)
                                    }

                                    Spacer(minLength: 8)

                                    // Year comes from the record; shown only when set.
                                    if paper.year > 0 {
                                        RBBadge(
                                            text: String(paper.year),
                                            tone: .neutral
                                        )
                                    }
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
