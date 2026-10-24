//
//  RBComponents.swift
//  ResearchBase
//
//  UI rebuild — shared kit
//
//  Reusable pieces that match the HTML prototype, so no screen builds
//  its own. Uses only RBColor / RBRadius / RBTint tokens, so it follows
//  the selected theme. No SwiftData and no navigation in this file.
//
//  Master / detail is NOT here: `RBMasterDetail` already lives in
//  AppTheme.swift (with the stacked mode below 640pt). Reuse it.
//

import SwiftUI

// MARK: - Hover + pointer

/// Fills the shape with the accent tint while the pointer is over the
/// view (or, with `border: true`, draws an accent border instead).
private struct RBHoverModifier: ViewModifier {

    let cornerRadius: CGFloat
    let border: Bool

    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(isHovering && !border ? RBColor.hoverTint : Color.clear)
                    .allowsHitTesting(false)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(isHovering && border ? RBColor.accent : Color.clear, lineWidth: 1)
                    .allowsHitTesting(false)
            )
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) {
                    isHovering = hovering
                }
            }
            .rbPointingHand()
    }
}

extension View {

    /// The one hover effect for the whole app. Never write your own
    /// `onHover` in a screen; use this or a kit component.
    func rbHover(
        cornerRadius: CGFloat = RBRadius.field,
        border: Bool = false
    ) -> some View {
        modifier(RBHoverModifier(cornerRadius: cornerRadius, border: border))
    }

    /// Pointing-hand cursor over clickable things (macOS 15 and later;
    /// older systems simply keep the arrow).
    @ViewBuilder
    func rbPointingHand() -> some View {
        if #available(macOS 15.0, *) {
            self.pointerStyle(.link)
        } else {
            self
        }
    }
}

// MARK: - Card

/// The HTML `.card`: card fill, 10pt radius, border.
struct RBCard<Content: View>: View {

    var padding: CGFloat = 14
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RBColor.card)
            .clipShape(RoundedRectangle(cornerRadius: RBRadius.panel))
            .overlay(
                RoundedRectangle(cornerRadius: RBRadius.panel)
                    .stroke(RBColor.border)
            )
    }
}

// MARK: - Row (clickable list item)

/// The HTML `.row`: a clickable list item with hover and a selected state.
struct RBRow<Content: View>: View {

    var isSelected: Bool = false
    let action: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        Button(action: action) {
            content()
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(isSelected ? RBColor.selectedTint : RBColor.card)
                .clipShape(RoundedRectangle(cornerRadius: RBRadius.field))
                .overlay(
                    RoundedRectangle(cornerRadius: RBRadius.field)
                        .stroke(isSelected ? RBColor.accent.opacity(0.6) : RBColor.border)
                )
                .contentShape(RoundedRectangle(cornerRadius: RBRadius.field))
        }
        .buttonStyle(.plain)
        .rbHover(cornerRadius: RBRadius.field)
    }
}

// MARK: - Chip (filter / tab pill)

struct RBChip: View {

    let text: String
    var isSelected: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(RBFont.caption(.medium))
                .foregroundStyle(isSelected ? RBColor.onAccent : RBColor.secondaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? RBColor.accent : RBColor.card)
                .clipShape(Capsule())
                .overlay(
                    Capsule().stroke(isSelected ? Color.clear : RBColor.border)
                )
        }
        .buttonStyle(.plain)
        .rbHover(cornerRadius: 999)
    }
}

// MARK: - Badge

enum RBBadgeTone {
    case accent
    case ok
    case warning
    case error
    case neutral
    case muted

    var color: Color {
        switch self {
        case .accent: return RBColor.accent
        case .ok: return RBColor.success
        case .warning: return RBColor.warning
        case .error: return RBColor.error
        case .neutral: return RBColor.secondaryText
        case .muted: return RBColor.mutedText
        }
    }
}

/// Small colored capsule. Takes a tone and text, never a model type,
/// so it can be used for any status.
struct RBBadge: View {

    let text: String
    var tone: RBBadgeTone = .accent
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
            }
            Text(text)
                .font(RBFont.label(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(tone.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tone.color.opacity(0.13))
        .clipShape(Capsule())
        .fixedSize()
    }
}

// MARK: - Progress bar

/// Thin rounded bar. `value` is 0...1.
struct RBProgressBar: View {

    let value: Double
    var height: CGFloat = 6
    var tint: Color = RBColor.accent

    var body: some View {
        GeometryReader { proxy in
            let clamped = min(max(value, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(RBColor.border)
                Capsule()
                    .fill(tint)
                    .frame(width: proxy.size.width * clamped)
            }
        }
        .frame(height: height)
    }
}

// MARK: - Buttons

private struct RBButtonBody: View {

    let configuration: ButtonStyleConfiguration
    let isPrimary: Bool

    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(RBFont.secondary(.semibold))
            .foregroundStyle(isPrimary ? RBColor.onAccent : RBColor.accent)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: RBRadius.field))
            .overlay(
                RoundedRectangle(cornerRadius: RBRadius.field)
                    .stroke(isPrimary ? Color.clear : RBColor.border)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) {
                    isHovering = hovering
                }
            }
            .rbPointingHand()
    }

    @ViewBuilder
    private var background: some View {
        if isPrimary {
            RBColor.accent
                .overlay(Color.white.opacity(isHovering ? 0.14 : 0))
        } else {
            (isHovering ? RBColor.hoverTint : Color.clear)
        }
    }
}

/// Filled accent button (HTML `.btn`).
/// A plain button (no chrome) that tints on hover, shows the pointing hand and
/// dims a little while pressed. Use instead of `.buttonStyle(.plain)` on clickable rows.
struct RBHoverPlainButtonStyle: ButtonStyle {

    var cornerRadius: CGFloat = RBRadius.field

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .rbHover(cornerRadius: cornerRadius)
    }
}

struct RBPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RBButtonBody(configuration: configuration, isPrimary: true)
    }
}

/// Outlined button (HTML `.gh`).
struct RBGhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RBButtonBody(configuration: configuration, isPrimary: false)
    }
}

// MARK: - Search field

struct RBSearchField: View {

    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(RBColor.mutedText)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(RBFont.body())
                .foregroundStyle(RBColor.primaryText)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(RBColor.mutedText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RBColor.inputBackground)
        .clipShape(RoundedRectangle(cornerRadius: RBRadius.field))
        .overlay(
            RoundedRectangle(cornerRadius: RBRadius.field)
                .stroke(RBColor.border)
        )
    }
}

// MARK: - Section label

/// Small uppercase heading (HTML `.lbl t7`).
struct RBSectionLabel: View {

    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(RBFont.label(.semibold))
            .tracking(0.6)
            .foregroundStyle(RBColor.mutedText)
    }
}

// MARK: - Page header

/// Title, optional subtitle, and an optional action on the right
/// (HTML `H(title, subtitle, action)`).
struct RBPageHeader<Trailing: View>: View {

    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(RBFont.title(.semibold))
                    .foregroundStyle(RBColor.primaryText)
                    .lineLimit(2)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(RBFont.secondary())
                        .foregroundStyle(RBColor.secondaryText)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 12)

            trailing()
        }
    }
}

extension RBPageHeader where Trailing == EmptyView {

    /// Header without a trailing action.
    init(title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = { EmptyView() }
    }
}

// MARK: - List pane (master column of every master/detail screen)

/// One set of measurements for the left-hand list column, so Experiments,
/// Results, Projects, Submissions, Literature Reviews, Gaps, Problems and
/// Ideas all line up.
enum RBListPaneMetrics {
    /// Left/right inset of the header, search field and filter rows.
    static let inset: CGFloat = 16
    /// Gap between list cards.
    static let rowSpacing: CGFloat = 8
    /// Padding around the scrolling list of cards.
    static let listPadding: CGFloat = 12

    /// "1 experiment" / "12 experiments" / "No experiments yet".
    static func count(_ n: Int, _ noun: String) -> String {
        switch n {
        case 0: return "No \(noun)s yet"
        case 1: return "1 \(noun)"
        default: return "\(n) \(noun)s"
        }
    }
}

/// Header of a list column: bold title, small subtitle, and one action
/// (normally a compact "+ New" button) on the right.
///
///     RBListPaneHeader(title: "Experiments", subtitle: "12 experiments") {
///         Button { ... } label: { Label("New", systemImage: "plus") }
///             .buttonStyle(RBPrimaryButtonStyle())
///     }
struct RBListPaneHeader<Trailing: View>: View {

    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(RBFont.detail(.bold))
                    .foregroundStyle(RBColor.primaryText)
                    .lineLimit(2)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(RBFont.caption())
                        .foregroundStyle(RBColor.secondaryText)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            trailing()
        }
        .padding(.horizontal, RBListPaneMetrics.inset)
        .padding(.top, RBListPaneMetrics.inset)
        .padding(.bottom, 10)
    }
}

extension RBListPaneHeader where Trailing == EmptyView {

    /// Header without an action.
    init(title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = { EmptyView() }
    }
}

/// The scrolling stack of cards inside a list column.
struct RBListColumn<Content: View>: View {

    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            LazyVStack(spacing: RBListPaneMetrics.rowSpacing) {
                content()
            }
            .padding(RBListPaneMetrics.listPadding)
        }
    }
}

extension View {

    /// Paints a list column the same way on every screen.
    func rbListPaneBackground() -> some View {
        background(RBColor.surface)
    }

    /// Insets a search field or filter row to line up with the header.
    func rbListPaneInset(bottom: CGFloat = 10) -> some View {
        padding(.horizontal, RBListPaneMetrics.inset)
            .padding(.bottom, bottom)
    }
}

// MARK: - Modal

/// Dimmed backdrop behind a modal card. Put it in a ZStack above the
/// screen, followed by an `RBModalCard`:
///
///     ZStack {
///         screen
///         if showModal {
///             RBModalBackdrop { showModal = false }
///             RBModalCard(title: "…", onClose: { showModal = false }) { … }
///         }
///     }
struct RBModalBackdrop: View {

    let onTap: () -> Void

    var body: some View {
        RBColor.scrim
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
    }
}

/// The HTML modal box: title, optional subtitle, content, close button.
struct RBModalCard<Content: View>: View {

    let title: String
    var subtitle: String? = nil
    let onClose: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(RBFont.section(.semibold))
                        .foregroundStyle(RBColor.primaryText)

                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(RBFont.caption())
                            .foregroundStyle(RBColor.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer()

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(RBColor.mutedText)
                }
                .buttonStyle(.plain)
                .help("Close")
            }

            content()
        }
        .padding(20)
        .frame(maxWidth: 460)
        .background(RBColor.elevatedSurface)
        .clipShape(RoundedRectangle(cornerRadius: RBRadius.manuscript))
        .overlay(
            RoundedRectangle(cornerRadius: RBRadius.manuscript)
                .stroke(RBColor.border)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 24, y: 8)
    }
}

// MARK: - Joined text

/// Joins several styled `Text` pieces into one line.
/// Replaces `Text + Text`, which is deprecated in macOS 26.
func rbJoinedText(_ parts: Text...) -> Text {
    parts.dropFirst().reduce(parts.first ?? Text("")) { Text("\($0)\($1)") }
}
