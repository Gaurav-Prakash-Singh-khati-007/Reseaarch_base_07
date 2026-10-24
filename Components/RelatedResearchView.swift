//
//  RelatedResearchView.swift
//  ResearchBase
//
//  Phase 12 — Search, Linking & Cross-Module Intelligence
//
//  A reusable "Related Research" section for detail views. Shows
//  only relationships that already exist on the record (supplied by
//  ResearchDataStore.relatedResearch(for:)) and lets the researcher
//  click through to any related item. This view never links, unlinks
//  or creates anything — it is read/navigate-only. Projects already
//  have their own link-management sheet (ProjectResearchLinkView);
//  this component only ever displays what already exists and hands
//  off navigation.
//

import SwiftUI

struct RelatedResearchView: View {

    let groups: [ResearchDataStore.RelatedGroup]
    let onNavigate: (NavigationTarget) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RBSectionLabel(text: "RELATED RESEARCH")

            if groups.isEmpty {
                RB9InlineEmptyNote(
                    icon: "point.3.connected.trianglepath.dotted",
                    title: "Nothing Connected Yet",
                    message: "Related papers, findings, gaps, problems, ideas, experiments, writing and projects will appear here once they're linked."
                )
            } else {
                countsGrid

                VStack(alignment: .leading, spacing: 14) {
                    ForEach(groups) { group in
                        groupSection(group)
                    }
                }
            }
        }
    }

    // MARK: - Counts Grid

    private var countsGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 110, maximum: 150), spacing: 10)],
            spacing: 10
        ) {
            ForEach(groups) { group in
                RBCard(padding: 10) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(group.count)")
                            .font(RBFont.detail(.semibold))
                            .foregroundStyle(RBColor.primaryText)

                        Text(group.label)
                            .font(RBFont.label(.medium))
                            .foregroundStyle(RBColor.secondaryText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: - Group Section

    private func groupSection(_ group: ResearchDataStore.RelatedGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            RBSectionLabel(text: "\(group.label.uppercased()) (\(group.count))")

            VStack(spacing: 6) {
                ForEach(group.items) { item in
                    RelatedResearchRow(item: item) {
                        onNavigate(item.target)
                    }
                }
            }
        }
    }
}

// MARK: - Row

/// A single clickable related-item row, with hover feedback matching
/// the rest of the app's row components.
private struct RelatedResearchRow: View {
    let item: ResearchDataStore.GlobalSearchResult
    let action: () -> Void

    var body: some View {
        RBRow(isSelected: false, action: action) {
            HStack(spacing: 10) {
                Image(systemName: item.target.iconName)
                    .font(RBFont.label(.medium))
                    .foregroundStyle(RBColor.accent)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(RBFont.secondary(.medium))
                        .foregroundStyle(RBColor.primaryText)
                        .lineLimit(1)

                    if !item.subtitle.isEmpty {
                        Text(item.subtitle)
                            .font(RBFont.label())
                            .foregroundStyle(RBColor.mutedText)
                            .lineLimit(1)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(RBFont.label(.medium))
                    .foregroundStyle(RBColor.mutedText)
            }
        }
    }
}


// MARK: - Drawer

/// Collapsible bottom panel wrapping `RelatedResearchView` for screens
/// whose detail area is a fixed-height editor (Writing, Experiments).
/// Collapsed by default so the editor keeps its space; expanded, it
/// scrolls inside a capped height instead of pushing content off screen.
struct RelatedResearchDrawer: View {

    let groups: [ResearchDataStore.RelatedGroup]
    let onNavigate: (NavigationTarget) -> Void

    @State private var isExpanded = false

    private var totalCount: Int {
        groups.reduce(0) { $0 + $1.count }
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider().overlay(RBColor.border)

            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(RBFont.label(.semibold))
                        .foregroundStyle(RBColor.mutedText)
                        .frame(width: 12)

                    RBSectionLabel(text: "RELATED RESEARCH")

                    RBBadge(text: "\(totalCount)", tone: .neutral)

                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .rbHover(cornerRadius: RBRadius.field)

            if isExpanded {
                ScrollView {
                    RelatedResearchView(
                        groups: groups,
                        onNavigate: onNavigate
                    )
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                }
                .frame(maxHeight: 260)
            }
        }
        .background(RBColor.background)
    }
}
