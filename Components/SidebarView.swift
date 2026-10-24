import SwiftUI

/// Shared sidebar widths. `ContentView` uses the same values for the
/// expanded sidebar and the rail in its HStack layout.
enum SidebarMetrics {
    static let expandedWidth: CGFloat = 245
    static let collapsedWidth: CGFloat = 58
}

struct SidebarView: View {

    @Binding var selectedScreen: ResearchScreen

    /// Phase 14 — true shows the narrow icon rail.
    var isCollapsed: Bool = false
    /// Phase 14 — toggles collapsed/expanded (owned by ContentView so ⌘B
    /// and the footer control share one code path).
    var onToggleCollapse: () -> Void = {}

    /// True when ContentView shows the expanded sidebar floating over
    /// the content (narrow windows). It gets a solid background and a
    /// shadow, and the footer control reads "Close".
    var isOverlay: Bool = false

    /// Called after any item is picked, so ContentView can close the
    /// overlay. Does nothing by default.
    var onNavigate: () -> Void = {}

    /// Real counts, supplied by ContentView. Zero hides the badge.
    var inboxCount: Int = 0
    var openTaskCount: Int = 0

    private func badgeText(_ n: Int) -> String? { n > 0 ? String(n) : nil }

    private let researchItems: [(String, String, ResearchScreen, String?)] = [
        ("Inbox", "tray", .inbox, nil),
        ("Library", "books.vertical", .library, nil),
        ("Knowledge", "brain", .knowledge, nil),
        ("Literature Review", "text.magnifyingglass", .literatureReview, nil),
        ("Research Ideas", "lightbulb", .researchIdeas, nil),
        ("Experiments", "flask", .experiments, nil),
        ("Results", "chart.bar", .results, nil)
    ]

    private let writingItems: [(String, String, ResearchScreen, String?)] = [
        ("Writing", "pencil", .writing, nil),
        ("References", "link", .references, nil),
        ("Submissions", "paperplane", .submissions, nil)
    ]

    private var width: CGFloat {
        isCollapsed ? SidebarMetrics.collapsedWidth : SidebarMetrics.expandedWidth
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {

                sidebarSection("HOME", isFirst: true)

                sidebarItem(
                    title: "Home",
                    icon: "house",
                    screen: .home
                )

                sidebarItem(
                    title: "Search",
                    icon: "magnifyingglass",
                    screen: .search
                )

                sidebarSection("RESEARCH", hint: "What I read & develop")

                ForEach(researchItems, id: \.0) { item in
                    sidebarItem(
                        title: item.0,
                        icon: item.1,
                        screen: item.2,
                        badge: item.2 == .inbox ? badgeText(inboxCount) : item.3
                    )
                }

                sidebarSection("WRITING", hint: "What I produce")

                ForEach(writingItems, id: \.0) { item in
                    sidebarItem(
                        title: item.0,
                        icon: item.1,
                        screen: item.2,
                        badge: item.3
                    )
                }

                sidebarSection("PROJECT")

                sidebarItem(
                    title: "Projects",
                    icon: "square.grid.2x2",
                    screen: .projects
                )

                sidebarItem(
                    title: "Tasks",
                    icon: "checkmark.square",
                    screen: .tasks,
                    badge: badgeText(openTaskCount)
                )

                sidebarItem(
                    title: "Timeline",
                    icon: "calendar",
                    screen: .timeline
                )
            }
            .padding(.horizontal, 10)
        }
        .scrollIndicators(isCollapsed ? .hidden : .automatic)

        // Brand is pinned at the top and Settings at the bottom using
        // safe-area insets. The list itself fills whatever is left, so
        // nothing can be pushed off the top or bottom, and the top
        // inset starts below the window's traffic-light / toolbar strip.
        .safeAreaInset(edge: .top, spacing: 0) {
            brandHeader
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            settingsFooter
        }
        .frame(minWidth: width, idealWidth: width, maxWidth: width)
        .background(panelBackground)
        // 1pt line on the right edge, like the HTML's border-right.
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(RBColor.border)
                .frame(width: 1)
        }
        // Only the overlay version floats above the content.
        .shadow(color: isOverlay ? RBColor.scrim : .clear, radius: 24, x: 8, y: 0)
    }

    /// Lavender's sidebar color is see-through. When the sidebar floats
    /// over other content it needs a solid layer underneath.
    @ViewBuilder
    private var panelBackground: some View {
        if isOverlay {
            RBColor.background.overlay(RBColor.sidebar)
        } else {
            RBColor.sidebar
        }
    }

    // MARK: Brand (pinned top)

    private var brandHeader: some View {
        Button {
            selectedScreen = .home
            onNavigate()
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: RBRadius.sidebarItem)
                        .fill(RBColor.selectedTint)
                        .frame(width: 30, height: 30)

                    // Filled diamond, like the HTML's "◆" badge.
                    Image(systemName: "diamond.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(RBColor.accent)
                }

                if !isCollapsed {
                    Text("ResearchBase")
                        .font(RBFont.section(.semibold))
                        .foregroundStyle(RBColor.primaryText)

                    Spacer()
                }
            }
            .frame(
                maxWidth: .infinity,
                alignment: isCollapsed ? .center : .leading
            )
        }
        .buttonStyle(.plain)
        .rbHover(cornerRadius: RBRadius.sidebarItem)
        .help(isCollapsed ? "ResearchBase — Home" : "")
        .accessibilityLabel("ResearchBase Home")
        .padding(.horizontal, isCollapsed ? 10 : 18)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(panelBackground)
    }

    // MARK: Settings + collapse control (pinned bottom)

    private var settingsFooter: some View {
        VStack(spacing: 0) {
            Divider()
                .overlay(RBColor.border)
                .padding(.horizontal, 14)

            VStack(spacing: 4) {
                sidebarItem(
                    title: "Trash",
                    icon: "trash",
                    screen: .trash
                )

                sidebarItem(
                    title: "Settings",
                    icon: "gearshape",
                    screen: .settings
                )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
        }
        .background(panelBackground)
    }

    // MARK: Section

    @ViewBuilder
    private func sidebarSection(
        _ title: String,
        hint: String? = nil,
        isFirst: Bool = false
    ) -> some View {
        if isCollapsed {
            // Rail: no labels. A hairline separates groups instead.
            if isFirst {
                Color.clear.frame(height: 4)
            } else {
                Divider()
                    .overlay(RBColor.border)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(RBFont.label(.semibold))
                    .tracking(0.8)
                    .foregroundStyle(RBColor.mutedText)

                // Small italic hint under the label (from the HTML).
                if let hint {
                    Text(hint)
                        .font(RBFont.label(.regular).italic())
                        .foregroundStyle(RBColor.mutedText)
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .padding(.bottom, 6)
        }
    }

    // MARK: Item

    private func sidebarItem(
        title: String,
        icon: String,
        screen: ResearchScreen,
        badge: String? = nil
    ) -> some View {
        SidebarItemView(
            title: title,
            icon: icon,
            // `.papers` and `.library` both open the merged Library,
            // so the Library row stays highlighted for either one.
            isSelected: selectedScreen == screen
                || (screen == .library && selectedScreen == .papers),
            isCollapsed: isCollapsed,
            badge: badge,
            helpText: title
        ) {
            selectedScreen = screen
            onNavigate()
        }
    }
}

// MARK: - Sidebar Item Row

/// A single sidebar row with normal / hover / selected / selected+hover
/// states. Hover never overrides the selected indication — it only
/// deepens it slightly — and normal rows only ever show the subtle
/// `RBColor.hover` background on hover. In the collapsed rail only the
/// icon is shown (centered) and the title becomes a tooltip.
private struct SidebarItemView: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let isCollapsed: Bool
    var badge: String? = nil
    let helpText: String
    let action: () -> Void

    // True while the mouse is over the row.
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: isCollapsed ? 0 : 11) {

                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)

                if !isCollapsed {
                    Text(title)
                        // The selected row is semibold, like the HTML.
                        .font(isSelected ? RBFont.body().weight(.semibold) : RBFont.body())

                    Spacer()

                    if let badge, !badge.isEmpty {
                        Text(badge)
                            .font(RBFont.label(.bold))
                            .foregroundStyle(isSelected ? RBColor.accent : Color.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(
                                Capsule().fill(isSelected ? Color.white : RBColor.accentSecondary)
                            )
                    }
                }
            }
            .foregroundStyle(
                isSelected
                ? RBColor.primaryText
                : RBColor.secondaryText
            )
            .padding(.horizontal, isCollapsed ? 0 : 11)
            .frame(maxWidth: .infinity)
            .frame(height: RBLayout.sidebarItemHeight)
            // Makes the whole row clickable, including the empty part.
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: RBRadius.sidebarItem)
                    .fill(backgroundColor)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        // The tint fades over 0.12s instead of snapping.
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        .animation(.easeInOut(duration: 0.12), value: isSelected)
        .help(isCollapsed ? helpText : "")
        .accessibilityLabel(title)
    }

    private var backgroundColor: Color {
        // Selected wins over hover, so hovering never hides the selection.
        if isSelected {
            return RBColor.selectedTint
        } else if isHovering {
            return RBColor.hoverTint
        } else {
            return .clear
        }
    }
}

#Preview {
    HStack(spacing: 0) {
        SidebarView(selectedScreen: .constant(.home))
        SidebarView(selectedScreen: .constant(.library), isCollapsed: true)
    }
    .frame(height: 900)
}
