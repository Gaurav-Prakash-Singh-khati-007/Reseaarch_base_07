//
//  PaperRowCard.swift
//  ResearchBase
//
//  Phase 13 — Papers workspace
//
//  One paper in the Papers list. Shows only metadata that is really
//  stored on the PaperRecord, and the real state of its PDF file.
//  Uses RBColor tokens only, so it follows the selected theme.
//

import SwiftUI

struct PaperRowCard: View {

    let paper: PaperRecord
    let onOpen: () -> Void

    var body: some View {

        Button(action: onOpen) {

            HStack(alignment: .top, spacing: 16) {

                thumbnail

                VStack(alignment: .leading, spacing: 7) {

                    Text(paper.title.isEmpty ? "Untitled paper" : paper.title)
                        .font(RBFont.section(.semibold))
                        .foregroundStyle(RBColor.primaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    Text(paper.authors.isEmpty ? "Unknown authors" : paper.authors)
                        .font(RBFont.secondary())
                        .foregroundStyle(RBColor.secondaryText)
                        .lineLimit(1)

                    metadataLine

                    badgeRow

                    if !paper.tags.isEmpty {
                        tagRow
                    }
                }

                Spacer(minLength: 8)

                trailing
            }
            .padding(18)
            .background(RBColor.card)
            .overlay(
                RoundedRectangle(cornerRadius: RBRadius.panel)
                    .stroke(RBColor.border)
            )
            .clipShape(RoundedRectangle(cornerRadius: RBRadius.panel))
            .contentShape(RoundedRectangle(cornerRadius: RBRadius.panel))
        }
        .buttonStyle(.plain)
        .rbHover(cornerRadius: RBRadius.panel)
    }

    // MARK: - Thumbnail

    private var thumbnail: some View {

        ZStack {
            RoundedRectangle(cornerRadius: RBRadius.field)
                .fill(RBColor.surface)

            Image(systemName: "doc.richtext")
                .font(.system(size: 22))
                .foregroundStyle(RBColor.accent)
        }
        .frame(width: 52, height: 64)
    }

    // MARK: - Venue • Year

    @ViewBuilder
    private var metadataLine: some View {

        let venue = paper.venue.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts: [String] = [
            venue,
            paper.year > 0 ? String(paper.year) : ""
        ].filter { !$0.isEmpty }

        if !parts.isEmpty {
            Text(parts.joined(separator: " • "))
                .font(RBFont.caption())
                .foregroundStyle(RBColor.secondaryText)
                .lineLimit(1)
        }
    }

    // MARK: - Badges (status, PDF, citation key)

    private var badgeRow: some View {

        HStack(spacing: 6) {

            badge(
                paper.statusRawValue,
                color: statusColor(paper.readingStatus)
            )

            switch PaperPDFState.of(paper) {
            case .available:
                badge("PDF", icon: "doc.fill", color: RBColor.success)
            case .missing:
                badge("PDF missing", icon: "exclamationmark.triangle.fill", color: RBColor.warning)
            case .none:
                badge("No PDF", icon: "doc", color: RBColor.mutedText)
            }

            if !paper.citationKey.isEmpty {
                badge(paper.citationKey, icon: "quote.opening", color: RBColor.mutedText)
            }
        }
    }

    private func badge(
        _ text: String,
        icon: String? = nil,
        color: Color
    ) -> some View {

        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
            }
            Text(text)
                .font(RBFont.label(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.12))
        .clipShape(Capsule())
    }

    // MARK: - Tags

    private var tagRow: some View {

        HStack(spacing: 6) {
            ForEach(Array(paper.tags.prefix(4)), id: \.self) { tag in
                Text(tag)
                    .font(RBFont.label(.medium))
                    .foregroundStyle(RBColor.secondaryText)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(RBColor.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }

            if paper.tags.count > 4 {
                Text("+\(paper.tags.count - 4)")
                    .font(RBFont.label())
                    .foregroundStyle(RBColor.mutedText)
            }
        }
    }

    // MARK: - Trailing (rating + chevron)

    private var trailing: some View {

        VStack(alignment: .trailing, spacing: 8) {

            if paper.rating > 0 {
                HStack(spacing: 2) {
                    ForEach(1...5, id: \.self) { index in
                        Image(systemName: index <= paper.rating ? "star.fill" : "star")
                            .font(.system(size: 10))
                            .foregroundStyle(
                                index <= paper.rating
                                    ? RBColor.warning
                                    : RBColor.mutedText
                            )
                    }
                }
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 11))
                .foregroundStyle(RBColor.mutedText)
        }
    }

    // MARK: - Status Color

    private func statusColor(_ status: ReadingStatus) -> Color {
        switch status {
        case .unread: return RBColor.secondaryText
        case .reading: return RBColor.accent
        case .read: return RBColor.success
        }
    }
}
