//
//  HomeView.swift
//  ResearchBase
//
//  Phase 11 — Dashboard + Research Workflow / Projects
//
//  The Home/Dashboard screen. Every number and list here comes from
//  real stored data — nothing is hardcoded or simulated. Papers, notes,
//  findings, gaps and writing drafts come from the SQLite library (D1);
//  projects and experiments still come from SwiftData. This
//  view never infers or claims novelty, correctness, superiority,
//  significance or validity about the researcher's work; it only
//  summarizes counts, recency and status the researcher already
//  recorded elsewhere in the app.
//

import SwiftUI
import SwiftData

// ═══════════════════════════════════════════════════════════════
//  Owner: Agent 71 · Features: F-28 (reading stats), F-46 (upcoming deadlines)
//
//  PUBLIC API
//    RBA71HomeLogic.snapshot(model:scheduler:now:) -> RBA71HomeSnapshot
//    RBA71HomeLogic.dueLabel(daysLeft:) / hoursText(seconds:)
//    HomeView reads SQLite when `\.rbA70LibraryModel` (declared in
//    LibraryView.swift) is injected. Without it (previews) it falls back to
//    the old SwiftData queries.
//    HomeView(onSearch:onOpenItem:)   onOpenItem optional; gets a SQLite item id.
// ═══════════════════════════════════════════════════════════════

struct RBA71RecentPaper: Equatable, Identifiable {
    let id: String
    let title: String
    let authors: String
    let addedAt: Date
}

struct RBA71WritingRow: Equatable, Identifiable {
    let id: String
    let title: String
    let updatedAt: Date
}

struct RBA71ActivityRow: Equatable, Identifiable {
    let id: String
    let icon: String
    let typeLabel: String
    let title: String
    let updatedAt: Date
}

struct RBA71HomeSnapshot: Equatable {
    var stats: ReadingStats
    var queueTop: [ModelItem]
    var readThisWeek: Int
    var deadlines: [UpcomingDeadline]
    // Overview counts and lists, all from SQLite.
    var paperCount: Int = 0
    var findingCount: Int = 0
    var gapCount: Int = 0
    var writingCount: Int = 0
    var recentPapers: [RBA71RecentPaper] = []
    var writingInProgress: [RBA71WritingRow] = []
    var activity: [RBA71ActivityRow] = []
}

enum RBA71HomeLogic {

    /// Reads everything the two cards need. Each part fails on its own:
    /// a problem in one never blanks the other.
    static func snapshot(
        model: LibraryModel,
        scheduler: ReminderScheduler? = nil,
        now: Date = Date()
    ) -> RBA71HomeSnapshot {

        let queue = ReadingQueueStore(model: model)
        let stats = (try? queue.stats())
            ?? ReadingStats(unread: 0, reading: 0, read: 0, queued: 0, totalSeconds: 0)
        let top = Array(((try? queue.queue()) ?? []).prefix(3))
        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: now) ?? now
        let week = (try? queue.readCount(since: weekAgo)) ?? 0

        let reminders = scheduler ?? ReminderScheduler(model: model)
        let deadlines = Array(((try? reminders.upcoming(days: 7, includeOverdue: true, now: now)) ?? []).prefix(6))

        var snap = RBA71HomeSnapshot(stats: stats, queueTop: top, readThisWeek: week, deadlines: deadlines)

        // Overview counts. Each part also fails on its own.
        let thoughts = ThoughtStore(model: model)
        snap.paperCount = (try? model.items.count(reviewState: .accepted)) ?? 0
        snap.findingCount = (try? thoughts.count(kind: .finding)) ?? 0
        snap.gapCount = (try? thoughts.count(kind: .gap)) ?? 0

        let drafts = (try? DraftFolderStore(model: model).all()) ?? []
        snap.writingCount = drafts.count
        snap.writingInProgress = drafts
            .filter { $0.stage != .published }
            .prefix(3)
            .map { RBA71WritingRow(id: $0.id, title: $0.title, updatedAt: parseDate($0.updatedAt)) }

        // Recent papers (newest added first, library papers only).
        let recent = (try? model.items.list(reviewState: .accepted, limit: 3)) ?? []
        snap.recentPapers = recent.map { item in
            RBA71RecentPaper(
                id: item.id,
                title: item.title,
                authors: authors(of: item, model: model),
                addedAt: parseDate(item.addedAt)
            )
        }

        // Activity: newest edits across papers, thoughts and drafts.
        var rows: [RBA71ActivityRow] = []
        for item in ((try? model.items.list(reviewState: .accepted, limit: 6)) ?? []) {
            rows.append(RBA71ActivityRow(id: "item-\(item.id)", icon: "doc.text", typeLabel: "Paper",
                                         title: item.title, updatedAt: parseDate(item.updatedAt)))
        }
        for t in ((try? thoughts.list(limit: 6)) ?? []) {
            let (icon, label) = thoughtLook(t.kind)
            rows.append(RBA71ActivityRow(id: "thought-\(t.id)", icon: icon, typeLabel: label,
                                         title: t.title, updatedAt: parseDate(t.updatedAt)))
        }
        for d in drafts.prefix(6) {
            rows.append(RBA71ActivityRow(id: "draft-\(d.id)", icon: "pencil", typeLabel: "Writing",
                                         title: d.title, updatedAt: parseDate(d.updatedAt)))
        }
        snap.activity = Array(rows.sorted { $0.updatedAt > $1.updatedAt }.prefix(6))

        return snap
    }

    /// First three authors, "Family, Given" joined with "; ". Empty when none.
    static func authors(of item: ModelItem, model: LibraryModel) -> String {
        let list = ((try? model.creators.creators(of: item.id)) ?? [])
            .filter { $0.role == .author }
            .map { $0.creator.displayName }
        guard !list.isEmpty else { return "" }
        let shown = list.prefix(3).joined(separator: "; ")
        return list.count > 3 ? shown + " et al." : shown
    }

    static func thoughtLook(_ kind: ThoughtKind) -> (icon: String, label: String) {
        switch kind {
        case .note: return ("note.text", "Note")
        case .finding: return ("text.magnifyingglass", "Finding")
        case .gap: return ("puzzlepiece", "Gap")
        case .problem: return ("questionmark.circle", "Problem")
        case .idea: return ("lightbulb", "Idea")
        }
    }

    /// Library timestamps are ISO-8601 text (with or without fractional seconds).
    /// Unreadable text becomes the distant past, so it sorts last instead of crashing.
    static func parseDate(_ text: String) -> Date {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: text) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text) ?? .distantPast
    }

    static func dueLabel(daysLeft: Int) -> String {
        switch daysLeft {
        case ..<(-1): return "\(-daysLeft) days overdue"
        case -1: return "1 day overdue"
        case 0: return "Today"
        case 1: return "Tomorrow"
        default: return "in \(daysLeft) days"
        }
    }

    static func hoursText(seconds: Int) -> String {
        if seconds < 60 { return "0 min" }
        if seconds < 3600 { return "\(seconds / 60) min" }
        let tenths = (seconds * 10 / 3600)
        return tenths % 10 == 0 ? "\(tenths / 10) h" : "\(tenths / 10).\(tenths % 10) h"
    }
}

// MARK: - Merged Activity Item

/// A single row in the "Research Activity" feed, built by merging
/// every entity type's own `updatedAt` and sorting by recency. Pure
/// display data — never persisted itself.
private struct DashboardActivityItem: Identifiable {
    let id = UUID()
    let icon: String
    let typeLabel: String
    let title: String
    let updatedAt: Date
}

struct HomeView: View {
    
    @Query(sort: [SortDescriptor(\ResearchProject.updatedAt, order: .reverse)])
    private var allProjects: [ResearchProject]
    
    @Query(sort: [SortDescriptor(\PaperRecord.addedAt, order: .reverse)])
    private var allPapers: [PaperRecord]
    
    @Query(sort: [SortDescriptor(\ResearchNote.updatedAt, order: .reverse)])
    private var allNotes: [ResearchNote]
    
    @Query(sort: [SortDescriptor(\LiteratureFinding.updatedAt, order: .reverse)])
    private var allFindings: [LiteratureFinding]
    
    @Query(sort: [SortDescriptor(\ResearchGap.updatedAt, order: .reverse)])
    private var allGaps: [ResearchGap]
    
    @Query(sort: [SortDescriptor(\ResearchProblem.updatedAt, order: .reverse)])
    private var allProblems: [ResearchProblem]
    
    @Query(sort: [SortDescriptor(\ResearchIdea.updatedAt, order: .reverse)])
    private var allIdeas: [ResearchIdea]
    
    @Query(sort: [SortDescriptor(\Experiment.updatedAt, order: .reverse)])
    private var allExperiments: [Experiment]
    
    @Query(sort: [SortDescriptor(\WritingDocument.updatedAt, order: .reverse)])
    private var allWritingDocuments: [WritingDocument]
    
    /// Called when the user submits a query from the top search bar.
    let onSearch: (String) -> Void

    /// Optional. Called with a SQLite item id when a recent paper is clicked.
    /// Without it, the click falls back to `router.open(.paper(uuid))`.
    let onOpenItem: ((String) -> Void)?
    
    // Phase 14 — name + avatar for the greeting header.
    @EnvironmentObject private var profile: ProfileStore
    
    // Phase 14 — Quick Add requests go through the shared router.
    @EnvironmentObject private var router: NavigationRouter
    
    @State private var searchText = ""

    // Agent 71 — SQLite library cards (shown only when a LibraryModel is injected).
    @Environment(\.rbA70LibraryModel) private var rbA70Model
    @State private var librarySnapshot: RBA71HomeSnapshot?
    @FocusState private var searchFocused: Bool
    init(
        onSearch: @escaping (String) -> Void = { _ in },
        onOpenItem: ((String) -> Void)? = nil
    ) {
        self.onSearch = onSearch
        self.onOpenItem = onOpenItem
    }
    
    var body: some View {
        ZStack {
            // D4: ContentView draws the theme gradient; no solid fill here.
            Color.clear
            
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    
                    VStack(alignment: .leading, spacing: 14) {
                        welcomeSection
                        topBar
                    }
                    
                    
                    
                    overviewGrid

                    if rbA70Model != nil {
                        libraryHomeSection
                    }
                    
                    mainColumns
                    
//                    activeProjectsSection
                    
//                    lowerSection
                }
                .rbResponsiveContentPadding()
                .frame(maxWidth: 1250)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear { reloadLibrarySnapshot() }
    }
    
    // MARK: - Top Bar
    
    private var topBar: some View {
        HStack(spacing: 14) {
            
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(RBColor.mutedText)
                
                TextField("Search papers, notes, ideas, experiments...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(RBFont.body())
                    .foregroundStyle(RBColor.primaryText)
                    .focused($searchFocused)
                    .onSubmit { submitSearch() }
                
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(RBColor.mutedText)
                    }
                    .buttonStyle(.plain)
                    .rbHover(cornerRadius: RBRadius.field)
                }
                
                Text("⌘ K")
                    .font(RBFont.caption(.medium))
                    .foregroundStyle(RBColor.mutedText)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: RBRadius.control)
                            .fill(RBColor.hover)
                    )
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(
                RoundedRectangle(cornerRadius: RBRadius.field)
                    .fill(RBColor.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RBRadius.field)
                    .stroke(RBColor.border, lineWidth: 1)
            )
            
            // Phase 14 — Quick Add. Each item only records the request
            // on the router; ContentView then shows the destination
            // screen. Nothing is created here.
            Menu {
                ForEach(QuickAddKind.allCases, id: \.self) { kind in
                    Button {
                        router.requestCreate(kind)
                    } label: {
                        Label(kind.menuLabel, systemImage: kind.iconName)
                    }
                }
            } label: {
                Label("Quick add", systemImage: "plus")
                    .font(RBFont.secondary(.medium))
                    .foregroundStyle(RBColor.primaryText)
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: RBRadius.field)
                            .fill(RBColor.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: RBRadius.field)
                            .stroke(RBColor.border, lineWidth: 1)
                    )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Quick Add")
        }
    }
    
    private func submitSearch() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        searchText = ""
        onSearch(query)
    }
    
    // MARK: - Welcome
    /// Time-based greeting (same hour ranges as before), now with the
    /// profile name: "Good evening, Gaurav". With no usable name it
    /// falls back to the old "Good evening."
    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let base: String
        switch hour {
        case 0..<12: base = "Good morning"
        case 12..<17: base = "Good afternoon"
        default: base = "Good evening"
        }
        
        if let name = profile.greetingName {
            return "\(base), \(name)"
        }
        return "\(base)."
    }
    
    private var welcomeSection: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(greeting)
                    .font(RBFont.title(.semibold))
                    .foregroundStyle(RBColor.primaryText)
                    .lineLimit(2)
                
                Text("Your research at a glance.")
                    .font(RBFont.body())
                    .foregroundStyle(RBColor.secondaryText)
            }
            
            Spacer(minLength: 12)
            
            ProfileAvatarView(
                image: profile.avatarImage,
                initial: profile.initial,
                size: 40
            )
        }
    }
    // MARK: - Library cards (F-28 reading, F-46 coming up)

    private var libraryHomeSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    readingCard.frame(minWidth: 300)
                    comingUpCard.frame(minWidth: 300)
                }
                VStack(alignment: .leading, spacing: 18) {
                    readingCard
                    comingUpCard
                }
            }
        }
    }

    private func reloadLibrarySnapshot() {
        guard let model = rbA70Model else { return }
        librarySnapshot = RBA71HomeLogic.snapshot(model: model)
    }

    private var readingCard: some View {

        let snap = librarySnapshot

        return VStack(alignment: .leading, spacing: 10) {
            RBSectionLabel(text: "READING")

            RBCard(padding: 14) {
                VStack(alignment: .leading, spacing: 12) {

                    HStack(spacing: 18) {
                        readingStat("Unread", snap?.stats.unread ?? 0)
                        readingStat("Reading", snap?.stats.reading ?? 0)
                        readingStat("Read", snap?.stats.read ?? 0)
                        readingStat("Queued", snap?.stats.queued ?? 0)
                    }

                    Text(readingSummary(snap))
                        .font(RBFont.caption())
                        .foregroundStyle(RBColor.secondaryText)

                    if let top = snap?.queueTop, !top.isEmpty {
                        Divider().overlay(RBColor.border)
                        Text("Up next")
                            .font(RBFont.caption(.medium))
                            .foregroundStyle(RBColor.mutedText)
                        ForEach(top, id: \.id) { item in
                            Text(item.title)
                                .font(RBFont.secondary(.medium))
                                .foregroundStyle(RBColor.primaryText)
                                .lineLimit(1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func readingStat(_ label: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(value)")
                .font(RBFont.detail(.semibold))
                .foregroundStyle(RBColor.primaryText)
            Text(label)
                .font(RBFont.caption())
                .foregroundStyle(RBColor.secondaryText)
        }
    }

    private func readingSummary(_ snap: RBA71HomeSnapshot?) -> String {
        guard let snap else { return "" }
        var parts = ["\(RBA71HomeLogic.hoursText(seconds: snap.stats.totalSeconds)) read in total"]
        if snap.readThisWeek > 0 { parts.append("\(snap.readThisWeek) finished this week") }
        return parts.joined(separator: " · ")
    }

    private var comingUpCard: some View {

        let deadlines = librarySnapshot?.deadlines ?? []

        return VStack(alignment: .leading, spacing: 10) {
            RBSectionLabel(text: "COMING UP")

            if deadlines.isEmpty {
                RB9InlineEmptyNote(
                    icon: "calendar",
                    title: "Nothing due this week",
                    message: "Task due dates and submission deadlines in the next 7 days appear here."
                )
            } else {
                VStack(spacing: 8) {
                    ForEach(deadlines) { deadline in
                        RBCard(padding: 14) {
                            HStack(spacing: 12) {
                                Image(systemName: deadline.kind == .submission ? "paperplane" : "checklist")
                                    .font(RBFont.secondary())
                                    .foregroundStyle(deadline.daysLeft < 0 ? RBColor.warning : RBColor.accent)
                                    .frame(width: 18)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(deadline.title)
                                        .font(RBFont.body(.medium))
                                        .foregroundStyle(RBColor.primaryText)
                                        .lineLimit(1)
                                    if !deadline.detail.isEmpty {
                                        Text(deadline.detail)
                                            .font(RBFont.caption())
                                            .foregroundStyle(RBColor.secondaryText)
                                            .lineLimit(1)
                                    }
                                }

                                Spacer()

                                Text(RBA71HomeLogic.dueLabel(daysLeft: deadline.daysLeft))
                                    .font(RBFont.caption(.medium))
                                    .foregroundStyle(deadline.daysLeft < 0 ? RBColor.warning : RBColor.secondaryText)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Overview Grid
    
    /// SQLite counts when the library is open; the old SwiftData counts only
    /// when no library is injected (previews). Experiments are not in SQLite yet.
    private var overviewItems: [(label: String, icon: String, count: Int)] {
        if rbA70Model != nil {
            let snap = librarySnapshot
            return [
                ("Papers", "doc.text", snap?.paperCount ?? 0),
                ("Findings", "text.magnifyingglass", snap?.findingCount ?? 0),
                ("Gaps", "puzzlepiece", snap?.gapCount ?? 0),
                ("Experiments", "flask", allExperiments.count),
                ("Writing", "pencil", snap?.writingCount ?? 0)
            ]
        }
        return [
            ("Papers", "doc.text", allPapers.count),
            ("Findings", "text.magnifyingglass", allFindings.count),
            ("Gaps", "puzzlepiece", allGaps.count),
            ("Experiments", "flask", allExperiments.count),
            ("Writing", "pencil", allWritingDocuments.count)
        ]
    }
    
    private var overviewGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            RBSectionLabel(text: "OVERVIEW")
            
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 12)],
                spacing: 12
            ) {
                ForEach(overviewItems, id: \.label) { item in
                    RBCard(padding: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: item.icon)
                            .font(RBFont.label(.medium))
                            .foregroundStyle(RBColor.accent)
                        
                        Text("\(item.count)")
                            .font(RBFont.detail(.semibold))
                            .foregroundStyle(RBColor.primaryText)
                        
                        Text(item.label)
                            .font(RBFont.caption())
                            .foregroundStyle(RBColor.secondaryText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
    
    // MARK: - Recent Papers
    
    private var recentPapersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            RBSectionLabel(text: "RECENT LITERATURE")
            
            if recentPaperRows.isEmpty {
                RB9InlineEmptyNote(
                    icon: "doc.text",
                    title: "No Papers Yet",
                    message: "Papers you add will show up here, most recent first."
                )
            } else {
                VStack(spacing: 8) {
                    ForEach(recentPaperRows) { paper in
                        Button { openPaper(id: paper.id) } label: {
                            recentPaperCard(paper)
                        }
                        .buttonStyle(.plain)
                        .rbHover(cornerRadius: RBRadius.panel)
                        .rbPointingHand()
                    }
                }
            }
        }
    }
    
    private var recentPaperRows: [RBA71RecentPaper] {
        if rbA70Model != nil { return librarySnapshot?.recentPapers ?? [] }
        return allPapers.prefix(3).map {
            RBA71RecentPaper(id: $0.id.uuidString, title: $0.title, authors: $0.authors, addedAt: $0.addedAt)
        }
    }

    private func openPaper(id: String) {
        if let onOpenItem { onOpenItem(id); return }
        if let uuid = UUID(uuidString: id) { router.open(.paper(uuid)) }
    }

    private func recentPaperCard(_ paper: RBA71RecentPaper) -> some View {
        RBCard(padding: 14) {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "doc.text")
                .font(RBFont.body())
                .foregroundStyle(RBColor.accent)
            
            VStack(alignment: .leading, spacing: 5) {
                Text(paper.title)
                    .font(RBFont.body(.medium))
                    .foregroundStyle(RBColor.primaryText)
                    .lineLimit(2)
                
                Text(paper.authors.isEmpty ? "Unknown authors" : paper.authors)
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.secondaryText)
                    .lineLimit(1)
            }
            
            Spacer()
            
            Text("Added \(paper.addedAt.formatted(date: .abbreviated, time: .omitted))")
                .font(RBFont.label())
                .foregroundStyle(RBColor.mutedText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    
    // MARK: - Papers In Progress

    private var writingRows: [RBA71WritingRow] {
        if rbA70Model != nil { return librarySnapshot?.writingInProgress ?? [] }
        return writingInProgress.prefix(3).map {
            RBA71WritingRow(id: $0.id.uuidString, title: $0.title, updatedAt: $0.updatedAt)
        }
    }

    private var papersInProgressSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            RBSectionLabel(text: "PAPERS IN PROGRESS")

            if writingRows.isEmpty {
                RB9InlineEmptyNote(
                    icon: "pencil",
                    title: "No Papers In Progress",
                    message: "Writing documents that aren't completed or archived will appear here."
                )
            } else {
                VStack(spacing: 8) {
                    ForEach(writingRows) { doc in
                        RBCard(padding: 14) {
                            HStack(spacing: 12) {
                                Image(systemName: "pencil")
                                    .font(RBFont.secondary())
                                    .foregroundStyle(RBColor.accent)
                                    .frame(width: 18)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(doc.title)
                                        .font(RBFont.body(.medium))
                                        .foregroundStyle(RBColor.primaryText)
                                        .lineLimit(1)

                                    Text("Updated \(doc.updatedAt.formatted(date: .abbreviated, time: .omitted))")
                                        .font(RBFont.caption())
                                        .foregroundStyle(RBColor.secondaryText)
                                }

                                Spacer()
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Main Columns

    private var mainColumns: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 20) {
                    recentPapersSection
                    papersInProgressSection
                }
                .frame(minWidth: 300)

                VStack(alignment: .leading, spacing: 20) {
                    activeProjectsSection
                    researchActivitySection
                }
                .frame(minWidth: 300)
            }

            VStack(alignment: .leading, spacing: 20) {
                recentPapersSection
                papersInProgressSection
                activeProjectsSection
                researchActivitySection
            }
        }
    }

    // MARK: - Active Projects
    
    private var activeProjects: [ResearchProject] {
        let active = allProjects.filter { $0.status == .active }
        return active.isEmpty ? Array(allProjects.prefix(3)) : Array(active.prefix(3))
    }
    
    private var activeProjectsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            RBSectionLabel(text: "ACTIVE PROJECTS")
            
            if allProjects.isEmpty {
                RB9InlineEmptyNote(
                    icon: "square.grid.2x2",
                    title: "No Projects Yet",
                    message: "Create a research project to start organizing your work."
                )
            } else {
                VStack(spacing: 8) {
                    ForEach(activeProjects, id: \.id) { project in
                        Button { router.open(.project(project.id)) } label: {
                            projectRow(project)
                        }
                        .buttonStyle(.plain)
                        .rbHover(cornerRadius: RBRadius.panel)
                        .rbPointingHand()
                    }
                }
            }
        }
    }
    
    private func projectRow(_ project: ResearchProject) -> some View {
        RBCard(padding: 14) {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(project.name)
                    .font(RBFont.body(.medium))
                    .foregroundStyle(RBColor.primaryText)
                    .lineLimit(1)
                
                Text("\(project.totalLinkedCount) linked item\(project.totalLinkedCount == 1 ? "" : "s") · Updated \(project.updatedAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.secondaryText)
            }
            
            Spacer()
            
            RBBadge(
                text: project.status.rawValue,
                tone: project.status == .active ? .ok : .muted
            )
        }
        }
    }
    
    // MARK: - Lower Section
    
    private var lowerSection: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 18) {
                researchActivitySection
                    .frame(minWidth: 300)
                
                needsAttentionSection
                    .frame(minWidth: 300)
            }
            
            VStack(alignment: .leading, spacing: 18) {
                researchActivitySection
                
                needsAttentionSection
            }
        }
    }
    
    // MARK: Research Activity
    
    private var activityFeed: [DashboardActivityItem] {
        var items: [DashboardActivityItem] = []
        
        items += allProjects.map {
            DashboardActivityItem(icon: "square.grid.2x2", typeLabel: "Project", title: $0.name, updatedAt: $0.updatedAt)
        }
        items += allExperiments.map {
            DashboardActivityItem(icon: "flask", typeLabel: "Experiment", title: $0.name, updatedAt: $0.updatedAt)
        }

        // Papers, notes, findings, gaps, problems, ideas and writing: SQLite.
        if rbA70Model != nil {
            items += (librarySnapshot?.activity ?? []).map {
                DashboardActivityItem(icon: $0.icon, typeLabel: $0.typeLabel, title: $0.title, updatedAt: $0.updatedAt)
            }
            return items
                .sorted { $0.updatedAt > $1.updatedAt }
                .prefix(6)
                .map { $0 }
        }

        items += allPapers.map {
            DashboardActivityItem(icon: "doc.text", typeLabel: "Paper", title: $0.title, updatedAt: $0.effectiveUpdatedAt)
        }
        items += allNotes.map {
            DashboardActivityItem(icon: "note.text", typeLabel: "Note", title: $0.title, updatedAt: $0.updatedAt)
        }
        items += allFindings.map {
            DashboardActivityItem(icon: "text.magnifyingglass", typeLabel: "Finding", title: $0.title, updatedAt: $0.updatedAt)
        }
        items += allGaps.map {
            DashboardActivityItem(icon: "puzzlepiece", typeLabel: "Gap", title: $0.title, updatedAt: $0.updatedAt)
        }
        items += allProblems.map {
            DashboardActivityItem(icon: "questionmark.circle", typeLabel: "Problem", title: $0.title, updatedAt: $0.updatedAt)
        }
        items += allIdeas.map {
            DashboardActivityItem(icon: "lightbulb", typeLabel: "Idea", title: $0.title, updatedAt: $0.updatedAt)
        }
        items += allWritingDocuments.map {
            DashboardActivityItem(icon: "pencil", typeLabel: "Writing", title: $0.title, updatedAt: $0.updatedAt)
        }
        
        return items
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(6)
            .map { $0 }
    }
    
    private var researchActivitySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            
            RBSectionLabel(text: "RESEARCH ACTIVITY")
            
            if activityFeed.isEmpty {
                RB9InlineEmptyNote(
                    icon: "clock",
                    title: "No Activity Yet",
                    message: "As you add papers, notes, experiments and more, they will appear here."
                )
            } else {
                RBCard(padding: 8) {
                VStack(spacing: 0) {
                    ForEach(activityFeed) { item in
                        activityRow(item)
                        
                        if item.id != activityFeed.last?.id {
                            Divider().overlay(RBColor.border)
                        }
                    }
                }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    private func activityRow(_ item: DashboardActivityItem) -> some View {
        HStack(spacing: 12) {
            
            Image(systemName: item.icon)
                .font(RBFont.secondary())
                .foregroundStyle(RBColor.accent)
                .frame(width: 18)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(RBFont.secondary())
                    .foregroundStyle(RBColor.secondaryText)
                    .lineLimit(1)
                
                Text(item.typeLabel)
                    .font(RBFont.label())
                    .foregroundStyle(RBColor.mutedText)
            }
            
            Spacer()
            
            Text(item.updatedAt.formatted(date: .abbreviated, time: .omitted))
                .font(RBFont.label())
                .foregroundStyle(RBColor.mutedText)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
    
    // MARK: Needs Attention
    
    private var openGaps: [ResearchGap] {
        allGaps.filter { $0.status != .addressed && $0.status != .archived }
    }
    
    private var activeExperiments: [Experiment] {
        allExperiments.filter { [.planned, .running, .analyzing].contains($0.status) }
    }
    
    private var writingInProgress: [WritingDocument] {
        allWritingDocuments.filter { $0.status != .completed && $0.status != .archived }
    }
    
    private var needsAttentionSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            
            RB9SectionLabel(text: "Needs Attention")
            
            VStack(alignment: .leading, spacing: 0) {
                
                attentionRow(
                    icon: "puzzlepiece",
                    title: "Open Research Gaps",
                    text: openGaps.isEmpty
                    ? "No open research gaps."
                    : "\(openGaps.count) open — most recent: \(openGaps.first?.title ?? "")"
                )
                
                Divider().overlay(RBColor.border)
                
                attentionRow(
                    icon: "flask",
                    title: "Active Experiments",
                    text: activeExperiments.isEmpty
                    ? "No active experiments."
                    : "\(activeExperiments.count) active — most recent: \(activeExperiments.first?.name ?? "")"
                )
                
                Divider().overlay(RBColor.border)
                
                attentionRow(
                    icon: "pencil",
                    title: "Writing In Progress",
                    text: writingInProgress.isEmpty
                    ? "No documents in progress."
                    : "\(writingInProgress.count) in progress — most recent: \(writingInProgress.first?.title ?? "")"
                )
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 11)
                    .fill(RBColor.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11)
                    .stroke(RBColor.border, lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    private func attentionRow(
        icon: String,
        title: String,
        text: String
    ) -> some View {
        
        HStack(alignment: .top, spacing: 12) {
            
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(RBColor.accent)
                .frame(width: 18)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(RBFont.secondary(.medium))
                    .foregroundStyle(RBColor.primaryText)
                
                Text(text)
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.secondaryText)
                    .lineLimit(2)
            }
            
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }    // MARK: - Shared Helpers
    
}

#Preview {
    HomeView()
        .environmentObject(ProfileStore())
        .environmentObject(NavigationRouter())
        .frame(width: 1150, height: 900)}
