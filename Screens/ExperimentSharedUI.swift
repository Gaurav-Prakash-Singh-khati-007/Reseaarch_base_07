//
//  ExperimentSharedUI.swift
//  ResearchBase
//
//  Phase 9 — Experiments & Results
//
//  Small reusable UI atoms shared by ExperimentsView,
//  ExperimentDetailView, ResultsView, ExperimentRunEditorView and
//  MetricEditorView. Visually these follow exactly the same design
//  language as the fileprivate helpers in ResearchIdeasView.swift
//  (Phase 8) — same colors, spacing and card style — but are kept
//  as their own internal-scope copies here (prefixed RB9) so this
//  phase never has to modify the existing, working Phase 8 view
//  file to change its helpers' access level.
//

import SwiftUI

// MARK: - Status Pill

struct RB9StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(RBFont.label(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .clipShape(Capsule())
            .fixedSize()
    }
}

// MARK: - Text Field

struct RB9TextField: View {
    let label: String
    @Binding var text: String
    var placeholder: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(RBFont.label(.semibold))
                .tracking(0.6)
                .foregroundStyle(RBColor.mutedText)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(RBFont.body())
                .foregroundStyle(RBColor.primaryText)
                .padding(10)
                .background(RBColor.card)
                .overlay(RoundedRectangle(cornerRadius: RBRadius.field).stroke(RBColor.border))
        }
    }
}

// MARK: - Text Editor

struct RB9TextEditor: View {
    let label: String
    @Binding var text: String
    var minHeight: CGFloat = 80

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(RBFont.label(.semibold))
                .tracking(0.6)
                .foregroundStyle(RBColor.mutedText)

            TextEditor(text: $text)
                .font(RBFont.body())
                .foregroundStyle(RBColor.primaryText)
                .scrollContentBackground(.hidden)
                .frame(minHeight: minHeight)
                .padding(6)
                .background(RBColor.card)
                .overlay(RoundedRectangle(cornerRadius: RBRadius.field).stroke(RBColor.border))
        }
    }
}

// MARK: - Row Card (list item container with hover + selection)

struct RB9RowCard<Content: View>: View {
    let isSelected: Bool
    let action: () -> Void
    let content: Content

    init(
        isSelected: Bool,
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.isSelected = isSelected
        self.action = action
        self.content = content()
    }

    var body: some View {
        Button(action: action) {
            content
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(backgroundColor)
                .clipShape(RoundedRectangle(cornerRadius: RBRadius.field))
                .overlay(
                    RoundedRectangle(cornerRadius: RBRadius.field)
                        .stroke(isSelected ? RBColor.accent.opacity(0.6) : RBColor.border)
                )
        }
        .buttonStyle(.plain)
        .rbHover(cornerRadius: RBRadius.field)
    }

    private var backgroundColor: Color {
        if isSelected {
            return RBColor.selectedTint
        } else {
            return RBColor.card
        }
    }
}

// MARK: - Empty State

struct RB9EmptyState: View {
    let icon: String
    let title: String
    let message: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(RBColor.accent)

            Text(title)
                .font(RBFont.section(.semibold))
                .foregroundStyle(RBColor.primaryText)

            Text(message)
                .font(RBFont.secondary())
                .foregroundStyle(RBColor.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)

            Button(action: action) {
                Label(actionTitle, systemImage: "plus")
                    .font(RBFont.secondary(.medium))
            }
            .buttonStyle(RBPrimaryButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

// MARK: - Small Inline Empty Note (no action button)

struct RB9InlineEmptyNote: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(RBColor.mutedText)

            Text(title)
                .font(RBFont.body(.semibold))
                .foregroundStyle(RBColor.secondaryText)

            Text(message)
                .font(RBFont.caption())
                .foregroundStyle(RBColor.mutedText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
}

// MARK: - Detail Placeholder (no selection yet)

struct RB9DetailPlaceholder: View {
    let icon: String
    let text: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(RBColor.mutedText)

            Text(text)
                .font(RBFont.secondary())
                .foregroundStyle(RBColor.mutedText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RBColor.background)
    }
}

// MARK: - Detail Header (title + status pill + edit/delete)

struct RB9DetailHeader: View {
    let title: String
    let statusText: String
    let statusColor: Color
    let onEdit: () -> Void
    let onDelete: () -> Void

    private var titleAndStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(RBFont.detail(.semibold))
                .foregroundStyle(RBColor.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            RB9StatusPill(text: statusText, color: statusColor)
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            Button("Edit", action: onEdit)
                .buttonStyle(.bordered)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
        }
        .fixedSize()
    }

    var body: some View {
        // Wide panes: title on the left, buttons on the right.
        // Narrow panes: buttons drop below the title so the title
        // never gets squeezed into a one-letter-per-line column.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                titleAndStatus
                Spacer(minLength: 12)
                actionButtons
            }

            VStack(alignment: .leading, spacing: 12) {
                titleAndStatus
                actionButtons
            }
        }
    }
}

// MARK: - Detail Section (label + body text, hidden when empty)

struct RB9DetailSection: View {
    let title: String
    let text: String

    var body: some View {
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title.uppercased())
                    .font(RBFont.label(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(RBColor.mutedText)

                Text(text)
                    .font(RBFont.body())
                    .foregroundStyle(RBColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }
}

// MARK: - Section Label (small caps header, always visible)

struct RB9SectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(RBFont.label(.semibold))
            .tracking(0.6)
            .foregroundStyle(RBColor.mutedText)
    }
}

// MARK: - Field Row (label/value pair for Setup display)

struct RB9FieldRow: View {
    let label: String
    let value: String

    var body: some View {
        if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            HStack(alignment: .top, spacing: 10) {
                Text(label)
                    .font(RBFont.caption(.medium))
                    .foregroundStyle(RBColor.mutedText)
                    .frame(width: 140, alignment: .leading)

                Text(value)
                    .font(RBFont.secondary())
                    .foregroundStyle(RBColor.primaryText)
                    .textSelection(.enabled)

                Spacer()
            }
        }
    }
}

// MARK: - Link Row (linked item with unlink button)

struct RB9LinkRow: View {
    let title: String
    let subtitle: String
    let onUnlink: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(RBFont.secondary(.medium))
                    .foregroundStyle(RBColor.primaryText)
                    .lineLimit(1)

                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(RBFont.caption())
                        .foregroundStyle(RBColor.mutedText)
                        .lineLimit(1)
                }
            }

            Spacer()

            Button(action: onUnlink) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(RBColor.mutedText)
            }
            .buttonStyle(.plain)
            .rbHover(cornerRadius: RBRadius.field)
        }
        .padding(10)
        .background(RBColor.card)
        .overlay(RoundedRectangle(cornerRadius: RBRadius.field).stroke(RBColor.border))
    }
}

// MARK: - Evidence / Link Section Header (label + "Link" button)

struct RB9LinkSectionHeader: View {
    let title: String
    let onLink: () -> Void

    var body: some View {
        HStack {
            RB9SectionLabel(text: title)

            Spacer()

            Button(action: onLink) {
                Label("Link", systemImage: "plus")
                    .font(RBFont.caption(.medium))
            }
            .buttonStyle(.plain)
            .rbHover(cornerRadius: RBRadius.field)
            .foregroundStyle(RBColor.accent)
        }
    }
}

// MARK: - Filter Menu

@ViewBuilder
func rb9FilterMenu<T: CaseIterable & RawRepresentable & Hashable>(
    label: String,
    selection: Binding<T?>,
    allCases: [T]
) -> some View where T.RawValue == String {
    Menu {
        Button("All") { selection.wrappedValue = nil }

        Divider()

        ForEach(allCases, id: \.self) { option in
            Button {
                selection.wrappedValue = option
            } label: {
                if selection.wrappedValue == option {
                    Label(option.rawValue, systemImage: "checkmark")
                } else {
                    Text(option.rawValue)
                }
            }
        }
    } label: {
        HStack(spacing: 4) {
            Text(label)
            Image(systemName: "chevron.down")
                .font(.system(size: 8))
        }
        .font(RBFont.caption(.medium))
        .foregroundStyle(selection.wrappedValue == nil ? RBColor.secondaryText : RBColor.accent)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RBColor.card)
        .overlay(RoundedRectangle(cornerRadius: RBRadius.field).stroke(RBColor.border))
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
}

// MARK: - Sort Menu

func rb9SortMenu<T: CaseIterable & RawRepresentable & Hashable>(
    selection: Binding<T>,
    allCases: [T]
) -> some View where T.RawValue == String {
    Menu {
        ForEach(allCases, id: \.self) { option in
            Button {
                selection.wrappedValue = option
            } label: {
                if selection.wrappedValue == option {
                    Label(option.rawValue, systemImage: "checkmark")
                } else {
                    Text(option.rawValue)
                }
            }
        }
    } label: {
        HStack(spacing: 4) {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 10))
            Text("Sort")
        }
        .font(RBFont.caption(.medium))
        .foregroundStyle(RBColor.secondaryText)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RBColor.card)
        .overlay(RoundedRectangle(cornerRadius: RBRadius.field).stroke(RBColor.border))
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
}

// MARK: - Generic Link Diffing Helper

/// Applies the difference between a picker's resulting id-set and
/// the currently linked items, calling `link`/`unlink` only for the
/// items that actually changed.
func rb9ApplyLinks<T: Identifiable>(
    newIDs: Set<T.ID>,
    current: [T],
    all: [T],
    link: (T) throws -> Void,
    unlink: (T) throws -> Void,
    onError: (String) -> Void
) {
    let currentIDs = Set(current.map { $0.id })

    let toLink = all.filter { newIDs.contains($0.id) && !currentIDs.contains($0.id) }
    let toUnlink = current.filter { !newIDs.contains($0.id) }

    do {
        for item in toLink {
            try link(item)
        }
        for item in toUnlink {
            try unlink(item)
        }
    } catch {
        onError(error.localizedDescription)
    }
}

// MARK: - Number Formatting

/// Compact display for a metric/baseline value: whole numbers show
/// with no decimal places, everything else keeps up to 4.
func rb9FormatMetricValue(_ value: Double) -> String {
    if value == value.rounded() && abs(value) < 1_000_000 {
        return String(format: "%.0f", value)
    }
    var text = String(format: "%.4f", value)
    while text.hasSuffix("0") {
        text.removeLast()
    }
    if text.hasSuffix(".") {
        text.removeLast()
    }
    return text
}

func rb9FormatMetric(_ metric: RunMetric) -> String {
    let value = rb9FormatMetricValue(metric.value)
    return metric.unit.isEmpty ? value : "\(value) \(metric.unit)"
}

func rb9FormatBaseline(_ metric: BaselineMetric) -> String {
    let value = rb9FormatMetricValue(metric.value)
    return metric.unit.isEmpty ? value : "\(value) \(metric.unit)"
}

/// Signed difference string for the results comparison table, e.g.
/// "+5.5" or "-4". Purely arithmetic — implies no judgment about
/// whether the change is good or meaningful.
func rb9FormatDifference(baseline: Double, current: Double, unit: String) -> String {
    let diff = current - baseline
    let sign = diff > 0 ? "+" : (diff < 0 ? "" : "±")
    let text = sign + rb9FormatMetricValue(diff)
    return unit.isEmpty ? text : "\(text) \(unit)"
}
