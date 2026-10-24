//
//  PapersResearchConnectionsView.swift
//  ResearchBase
//
//  Created by Gaurav Khati on 28/09/26.
//


//
//  PapersResearchConnectionsView.swift
//  ResearchBase
//
//  Phase 13 — Paper Detail
//
//  Shows every real, stored connection a paper has to the rest of the
//  workspace, and lets the researcher click through to each item.
//
//  Nothing here is inferred. It reuses the existing
//  ResearchDataStore.relatedResearch(for:) (findings, gaps, problems,
//  ideas, experiments, writing, projects) and adds the two
//  connections that method does not cover:
//    - Tasks that link this paper (ResearchTask.papers)
//    - Literature reviews / themes that contain this paper
//      (PaperRecord.literatureReviews / literatureThemes)
//
//  Read/navigate only. It never links, unlinks or creates anything.
//  Literature reviews and themes have no navigation target, so they
//  are listed as plain, non-clickable rows.
//

import SwiftUI
import SwiftData

struct PapersResearchConnectionsView: View {

    let paperRecord: PaperRecord
    let onNavigate: (NavigationTarget) -> Void

    @Environment(\.modelContext)
    private var modelContext

    @State private var groups: [ResearchDataStore.RelatedGroup] = []
    @State private var loadFailed = false

    private var store: ResearchDataStore {
        ResearchDataStore(modelContext: modelContext)
    }

    // MARK: - Body

    var body: some View {

        VStack(alignment: .leading, spacing: 16) {

            if loadFailed {
                RB9InlineEmptyNote(
                    icon: "exclamationmark.triangle",
                    title: "Could Not Load Connections",
                    message: "Your data is unchanged. Try leaving and reopening this paper."
                )
            } else {
                RelatedResearchView(
                    groups: groups,
                    onNavigate: onNavigate
                )
            }

            if !reviewLines.isEmpty {
                reviewSection
            }
        }
        .task(id: paperRecord.id) {
            load()
        }
    }

    // MARK: - Load

    private func load() {

        do {
            var result = try store.relatedResearch(for: paperRecord)

            let tasks = try modelContext
                .fetch(FetchDescriptor<ResearchTask>())
                .filter { task in
                    task.papers.contains { $0.id == paperRecord.id }
                }
                .sorted {
                    $0.title.localizedStandardCompare($1.title) == .orderedAscending
                }

            if !tasks.isEmpty {
                result.append(
                    ResearchDataStore.RelatedGroup(
                        label: "Tasks",
                        items: tasks.map { task in
                            ResearchDataStore.GlobalSearchResult(
                                target: .task(task.id),
                                title: task.title,
                                subtitle: task.statusRawValue
                            )
                        }
                    )
                )
            }

            groups = result
            loadFailed = false

        } catch {
            groups = []
            loadFailed = true

            Swift.print(
                "ResearchBase: Failed to load paper connections: \(error)"
            )
        }
    }

    // MARK: - Literature Reviews / Themes (not navigable)

    private struct ReviewLine: Identifiable {
        let id: String
        let icon: String
        let title: String
        let subtitle: String
    }

    private var reviewLines: [ReviewLine] {

        let reviews = paperRecord.literatureReviews
            .sorted {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            .map {
                ReviewLine(
                    id: "review-\($0.id.uuidString)",
                    icon: "text.book.closed",
                    title: $0.title.isEmpty ? "Untitled review" : $0.title,
                    subtitle: "Literature Review"
                )
            }

        let themes = paperRecord.literatureThemes
            .sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            .map {
                ReviewLine(
                    id: "theme-\($0.id.uuidString)",
                    icon: "square.stack.3d.up",
                    title: $0.name.isEmpty ? "Untitled theme" : $0.name,
                    subtitle: $0.review.map {
                        "Theme in \($0.title.isEmpty ? "Untitled review" : $0.title)"
                    } ?? "Literature Theme"
                )
            }

        return reviews + themes
    }

    private var reviewSection: some View {

        VStack(alignment: .leading, spacing: 6) {

            RBSectionLabel(text: "LITERATURE REVIEWS & THEMES (\(reviewLines.count))")

            VStack(spacing: 6) {
                ForEach(reviewLines) { line in
                    RBCard(padding: 10) {
                        HStack(spacing: 10) {

                            Image(systemName: line.icon)
                                .font(RBFont.label(.medium))
                                .foregroundStyle(RBColor.accent)
                                .frame(width: 16)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(line.title)
                                    .font(RBFont.secondary(.medium))
                                    .foregroundStyle(RBColor.primaryText)
                                    .lineLimit(1)

                                Text(line.subtitle)
                                    .font(RBFont.label())
                                    .foregroundStyle(RBColor.mutedText)
                                    .lineLimit(1)
                            }

                            Spacer()
                        }
                    }
                }
            }
        }
    }
}
