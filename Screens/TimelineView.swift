//
//  TimelineView.swift
//  ResearchBase
//
//  Phase 13C — Timeline
//

import SwiftUI
import SwiftData

// ═══════════════════════════════════════════════════════════════
//  Owner: Agent 78
//
//  PUBLIC API
//    TimelineView(onOpenItem:)    onOpenItem optional; gets a SQLite paper id
//    RBA78TimelineLogic.load(model:) -> Loaded   (SQLite events, pure, tested)
//
//  Reads BOTH stores: the SQLite library (papers, notes, findings, gaps,
//  problems, ideas, drafts) and SwiftData (experiments, projects, tasks, plus
//  any legacy record SQLite does not hold yet). A record present in both is
//  shown once, from SQLite (D1). Uses `\.rbA70LibraryModel` (declared in
//  LibraryView.swift). Without it, only SwiftData is read.
// ═══════════════════════════════════════════════════════════════

enum RBA78TimelineLogic {

    struct Loaded: Equatable {
        var events: [TimelineEvent] = []
        /// Record ids (uppercase UUID text) that SQLite holds, used to hide legacy twins.
        var recordIDs: Set<String> = []
    }

    static let maxRecords = 5000

    static func load(model: LibraryModel) -> Loaded {
        var out = Loaded()

        func add(_ kind: TimelineEventKind, id: String, created: String, updated: String,
                 createdAction: String, updatedAction: String, title: String,
                 target: (UUID) -> NavigationTarget) {
            out.recordIDs.insert(id.uppercased())
            let uuid = UUID(uuidString: id)
            let tgt = uuid.map(target)
            let shownTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = shownTitle.isEmpty ? "Untitled" : shownTitle
            let c = parseDate(created)
            let u = parseDate(updated)
            out.events.append(TimelineEvent(
                id: "\(kind.rawValue)-\(id)-added", date: c, kind: kind,
                action: createdAction, title: name, target: tgt))
            if u.timeIntervalSince(c) > TimelineBuilder.updateThreshold {
                out.events.append(TimelineEvent(
                    id: "\(kind.rawValue)-\(id)-updated", date: u, kind: kind,
                    action: updatedAction, title: name, target: tgt))
            }
        }

        // Each part fails on its own.
        for item in ((try? model.items.list(reviewState: .accepted, limit: maxRecords)) ?? []) {
            add(.paper, id: item.id, created: item.addedAt, updated: item.updatedAt,
                createdAction: "Paper added", updatedAction: "Paper updated",
                title: item.title, target: { .paper($0) })
        }

        for t in ((try? ThoughtStore(model: model).list(limit: maxRecords)) ?? []) {
            switch t.kind {
            case .note:
                add(.note, id: t.id, created: t.createdAt, updated: t.updatedAt,
                    createdAction: "Note created", updatedAction: "Note updated",
                    title: t.title, target: { .researchNote($0) })
            case .finding:
                add(.finding, id: t.id, created: t.createdAt, updated: t.updatedAt,
                    createdAction: "Finding created", updatedAction: "Finding updated",
                    title: t.title, target: { .literatureFinding($0) })
            case .gap:
                add(.gap, id: t.id, created: t.createdAt, updated: t.updatedAt,
                    createdAction: "Research gap created", updatedAction: "Research gap updated",
                    title: t.title, target: { .researchGap($0) })
            case .problem:
                add(.problem, id: t.id, created: t.createdAt, updated: t.updatedAt,
                    createdAction: "Research problem created", updatedAction: "Research problem updated",
                    title: t.title, target: { .researchProblem($0) })
            case .idea:
                add(.idea, id: t.id, created: t.createdAt, updated: t.updatedAt,
                    createdAction: "Research idea created", updatedAction: "Research idea updated",
                    title: t.title, target: { .researchIdea($0) })
            }
        }

        for d in ((try? DraftFolderStore(model: model).all(includeArchived: true)) ?? []) {
            add(.writing, id: d.id, created: d.createdAt, updated: d.updatedAt,
                createdAction: "Writing document created", updatedAction: "Writing document updated",
                title: d.title, target: { .writingDocument($0) })
        }
        return out
    }

    /// Library timestamps are ISO-8601 text, with or without fractional seconds.
    static func parseDate(_ text: String) -> Date {
        let a = ISO8601DateFormatter()
        a.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = a.date(from: text) { return d }
        let b = ISO8601DateFormatter()
        b.formatOptions = [.withInternetDateTime]
        return b.date(from: text) ?? .distantPast
    }

    /// Newest first; ties broken by id so the order is stable.
    static func sorted(_ events: [TimelineEvent]) -> [TimelineEvent] {
        events.sorted { $0.date != $1.date ? $0.date > $1.date : $0.id < $1.id }
    }

    /// One flat list (day headings and events) so the spine can run unbroken.
    struct Entry: Identifiable, Equatable {
        let id: String
        let day: Date?
        let event: TimelineEvent?
    }

    static func entries(_ days: [TimelineDay]) -> [Entry] {
        var list: [Entry] = []
        for day in days {
            list.append(Entry(id: "day-\(day.day.timeIntervalSince1970)", day: day.day, event: nil))
            for e in day.events { list.append(Entry(id: e.id, day: nil, event: e)) }
        }
        return list
    }
}

struct TimelineView: View {

    @EnvironmentObject private var router: NavigationRouter

    @Query private var papers: [PaperRecord]
    @Query private var notes: [ResearchNote]
    @Query private var findings: [LiteratureFinding]
    @Query private var gaps: [ResearchGap]
    @Query private var problems: [ResearchProblem]
    @Query private var ideas: [ResearchIdea]
    @Query private var experiments: [Experiment]
    @Query private var writingDocuments: [WritingDocument]
    @Query private var projects: [ResearchProject]
    @Query private var tasks: [ResearchTask]

    @Environment(\.rbA70LibraryModel) private var rbA70Model
    @State private var sqlite = RBA78TimelineLogic.Loaded()

    /// Optional. Called with a SQLite paper id; otherwise the router opens it.
    let onOpenItem: ((String) -> Void)?

    init(onOpenItem: ((String) -> Void)? = nil) {
        self.onOpenItem = onOpenItem
    }

    @State private var kindFilter: TimelineEventKind?
    @State private var includeUpdates = false
    @State private var visibleLimit = TimelineView.pageSize

    private static let pageSize = 150

    private var filteredEvents: [TimelineEvent] {
        let known = sqlite.recordIDs
        let legacy = TimelineBuilder.buildEvents(
            papers: papers.filter { !known.contains($0.id.uuidString) },
            notes: notes.filter { !known.contains($0.id.uuidString) },
            findings: findings.filter { !known.contains($0.id.uuidString) },
            gaps: gaps.filter { !known.contains($0.id.uuidString) },
            problems: problems.filter { !known.contains($0.id.uuidString) },
            ideas: ideas.filter { !known.contains($0.id.uuidString) },
            experiments: experiments,
            writingDocuments: writingDocuments.filter { !known.contains($0.id.uuidString) },
            projects: projects,
            tasks: tasks,
            includeUpdates: includeUpdates
        )
        let fromSQLite = includeUpdates
            ? sqlite.events
            : sqlite.events.filter { !$0.id.hasSuffix("-updated") }

        let events = RBA78TimelineLogic.sorted(legacy + fromSQLite)

        guard let kindFilter else { return events }
        return events.filter { $0.kind == kindFilter }
    }

    private func reloadSQLite() {
        guard let model = rbA70Model else { sqlite = .init(); return }
        sqlite = RBA78TimelineLogic.load(model: model)
    }

    private func open(_ event: TimelineEvent) {
        guard let target = event.target else { return }
        if event.kind == .paper, let onOpenItem, sqlite.recordIDs.contains(target.recordID.uuidString) {
            onOpenItem(target.recordID.uuidString)
        } else {
            router.open(target)
        }
    }

    var body: some View {

        let events = filteredEvents
        let shown = Array(events.prefix(visibleLimit))
        let entries = RBA78TimelineLogic.entries(TimelineBuilder.groupByDay(shown))

        VStack(spacing: 0) {

            header
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 14)

            Divider().overlay(RBColor.border)

            if events.isEmpty {
                emptyState
            } else {
                // The list lives in an overlay of a flexible clear view,
                // so its tall content height can never be reported to
                // the window (that pushed the sidebar and header up).
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {

                                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                                    entryRow(
                                        entry,
                                        isFirst: index == 0,
                                        isLast: index == entries.count - 1
                                    )
                                }

                                if events.count > shown.count {
                                    Button {
                                        visibleLimit += Self.pageSize
                                    } label: {
                                        Text("Show More (\(events.count - shown.count) older)")
                                            .font(RBFont.secondary(.medium))
                                    }
                                    .buttonStyle(RBGhostButtonStyle())
                                    .frame(maxWidth: .infinity)
                                    .padding(.top, 14)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .rbResponsiveContentPadding()
                        }
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        // D4: no solid fill; ContentView draws the theme gradient.
        .onAppear { reloadSQLite() }
        .onChange(of: kindFilter) { visibleLimit = Self.pageSize }
        .onChange(of: includeUpdates) { visibleLimit = Self.pageSize }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {

            Text("Timeline")
                .font(RBFont.title(.semibold))
                .foregroundStyle(RBColor.primaryText)

            Text("When things were added. Only the latest edit is kept.")
                .font(RBFont.caption())
                .foregroundStyle(RBColor.secondaryText)
                .lineLimit(1)

            HStack(spacing: 14) {
                typeMenu
                updatesToggle
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var typeMenu: some View {
        rb9FilterMenu(
            label: kindFilter?.rawValue ?? "All Types",
            selection: $kindFilter,
            allCases: TimelineEventKind.allCases
        )
    }

    private var updatesToggle: some View {
        Toggle("Include updates", isOn: $includeUpdates)
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(RBColor.accent)
            .font(RBFont.secondary())
            .foregroundStyle(RBColor.secondaryText)
            .fixedSize()
    }

    // MARK: Empty State

    private var emptyState: some View {
        RB9InlineEmptyNote(
            icon: "clock",
            title: kindFilter == nil ? "No Activity Yet" : "No Matching Activity",
            message: kindFilter == nil
                ? "As you add papers, notes, experiments, tasks and more, they will appear here."
                : "Nothing of this type has been recorded yet."
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Spine rows

    @ViewBuilder
    private func entryRow(_ entry: RBA78TimelineLogic.Entry, isFirst: Bool, isLast: Bool) -> some View {
        if let day = entry.day {
            HStack {
                RB9SectionLabel(text: dayTitle(day))
                Spacer(minLength: 0)
            }
            .padding(.leading, 28)
            .padding(.top, isFirst ? 0 : 12)
            .padding(.bottom, 2)
            .frame(minHeight: 28)
            .background(alignment: .leading) {
                RBA78Spine(isFirst: isFirst, isLast: isLast, showsDot: false)
            }
        } else if let event = entry.event {
            TimelineRow(event: event) { open(event) }
                .padding(.vertical, 4)
                .padding(.leading, 28)
                .background(alignment: .leading) {
                    RBA78Spine(isFirst: isFirst, isLast: isLast, showsDot: true)
                }
        }
    }

    private func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }

        return day.formatted(
            .dateTime.weekday(.wide).day().month(.abbreviated).year()
        )
    }
}


// MARK: - Timeline Row

private struct TimelineRow: View {

    let event: TimelineEvent
    let onOpen: () -> Void



    private var rowButton: some View {
        Button(action: onOpen) {
            HStack(alignment: .center, spacing: 12) {

                ZStack {
                    Circle()
                        .fill(RBColor.hoverTint)
                        .frame(width: 30, height: 30)

                    Image(systemName: event.kind.iconName)
                        .font(.system(size: 13))
                        .foregroundStyle(RBColor.accent)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(event.action)
                        .font(RBFont.caption())
                        .foregroundStyle(RBColor.mutedText)

                    Text(event.title)
                        .font(RBFont.body(.medium))
                        .foregroundStyle(RBColor.primaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 8)

                Text(event.date.formatted(date: .omitted, time: .shortened))
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.mutedText)
                    .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RBColor.card)
            .clipShape(RoundedRectangle(cornerRadius: RBRadius.field))
            .overlay(
                RoundedRectangle(cornerRadius: RBRadius.field)
                    .stroke(RBColor.border)
            )
            .contentShape(RoundedRectangle(cornerRadius: RBRadius.field))
        }
        .buttonStyle(.plain)
        .disabled(event.target == nil)
    }

    var body: some View {
        if event.target != nil {
            rowButton.rbHover(cornerRadius: RBRadius.field)
        } else {
            rowButton
        }
    }
}


// MARK: - Spine

/// The vertical line with a dot. Each row draws its own piece of the line, so the
/// line is unbroken from the first row to the last without any shared geometry.
private struct RBA78Spine: View {

    let isFirst: Bool
    let isLast: Bool
    let showsDot: Bool

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(isFirst ? Color.clear : RBColor.border)
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
                Rectangle()
                    .fill(isLast ? Color.clear : RBColor.border)
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
            }

            if showsDot {
                Circle()
                    .fill(RBColor.accent)
                    .frame(width: 10, height: 10)
            }
        }
        .frame(width: 16)
    }
}
