import SwiftUI
import SwiftData

struct KnowledgeView: View {

    @EnvironmentObject private var router: NavigationRouter

    @Query(
        sort: [
            SortDescriptor(\ResearchNote.updatedAt, order: .reverse)
        ]
    )
    private var allNotes: [ResearchNote]

    @State private var searchText = ""
    @State private var selectedType: ResearchNoteType?
    @State private var sortOption: NoteSortOption = .recentlyUpdated

    @State private var showingNewNote = false
    @State private var editingNote: ResearchNote?

    enum NoteSortOption: String, CaseIterable {
        case recentlyUpdated = "Recently Updated"
        case recentlyCreated = "Recently Created"
        case oldest = "Oldest"
        case titleAZ = "Title A–Z"
        case titleZA = "Title Z–A"
    }

    // MARK: - Filtered Notes

    private var filteredNotes: [ResearchNote] {

        var notes = allNotes

        if let selectedType {
            notes = notes.filter { $0.noteType == selectedType }
        }

        let trimmed =
            searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if !trimmed.isEmpty {
            notes = notes.filter {
                $0.title.lowercased().contains(trimmed) ||
                $0.content.lowercased().contains(trimmed) ||
                $0.tagsText.lowercased().contains(trimmed)
            }
        }

        switch sortOption {

        case .recentlyUpdated:
            notes.sort { $0.updatedAt > $1.updatedAt }

        case .recentlyCreated:
            notes.sort { $0.createdAt > $1.createdAt }

        case .oldest:
            notes.sort { $0.createdAt < $1.createdAt }

        case .titleAZ:
            notes.sort {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }

        case .titleZA:
            notes.sort {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedDescending
            }
        }

        return notes
    }

    private func count(for type: ResearchNoteType) -> Int {
        allNotes.filter { $0.noteType == type }.count
    }

    // MARK: - Body

    var body: some View {

        VStack(spacing: 0) {

            VStack(alignment: .leading, spacing: 14) {
                header

                if !allNotes.isEmpty {
                    toolbar
                    summaryBar
                }
            }
            .rbResponsiveContentPadding([.horizontal, .top])
            .padding(.bottom, 14)

            Divider().overlay(RBColor.border)

            if allNotes.isEmpty {
                emptyState
            } else if filteredNotes.isEmpty {
                noResultsState
            } else {
                notesList
            }
        }
        .background(RBColor.background)
        .sheet(isPresented: $showingNewNote) {
            NoteEditorView(note: nil, preselectedPaper: nil)
        }
        .sheet(item: $editingNote) { note in
            NoteEditorView(note: note, preselectedPaper: nil)
        }
        // Phase 14 — Quick Add → Note. Also runs on appear because
        // ContentView sets the request before this screen exists.
        .onAppear { consumeQuickAdd() }
        .onChange(of: router.createRequestCount) { consumeQuickAdd() }
    }

    /// Opens the existing New Note editor for a `.note` Quick Add
    /// request, then clears the request so it is handled exactly once.
    private func consumeQuickAdd() {
        guard router.pendingCreate == .note else { return }
        router.pendingCreate = nil
        showingNewNote = true
    }

    // MARK: - Header

    private var header: some View {

        RBPageHeader(title: "Knowledge", subtitle: subtitle) {
            Button {
                showingNewNote = true
            } label: {
                Label("New Note", systemImage: "plus")
            }
            .buttonStyle(RBPrimaryButtonStyle())
        }
    }

                    private var subtitle: String {

                        if allNotes.isEmpty {
                            return "Turn research papers into structured knowledge."
                        }

                        let isFiltering = selectedType != nil ||
                            !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

                        if isFiltering {
                            return "Showing \(filteredNotes.count) of \(allNotes.count) notes"
                        }

                        return allNotes.count == 1
                            ? "1 note in your knowledge base"
                            : "\(allNotes.count) notes in your knowledge base"
                    }
    // MARK: - Toolbar

    private var toolbar: some View {

        HStack(spacing: 10) {

            RBSearchField(placeholder: "Search notes...", text: $searchText)

            Menu {

                Button("All") { selectedType = nil }

                    Divider()

                    ForEach(ResearchNoteType.allCases, id: \.self) { type in
                        Button(type.rawValue) { selectedType = type }
                    }

                } label: {
                    toolbarChip(
                        icon: "line.3.horizontal.decrease.circle",
                        text: selectedType?.rawValue ?? "All Types",
                        isActive: selectedType != nil
                    )
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Filter by note type")

                Menu {

                    ForEach(NoteSortOption.allCases, id: \.self) { option in
                        Button(option.rawValue) { sortOption = option }
                    }

                } label: {
                    toolbarChip(
                        icon: "arrow.up.arrow.down",
                        text: sortOption.rawValue,
                        isActive: false
                    )
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Sort notes")
            }
        }

        private func toolbarChip(icon: String, text: String, isActive: Bool) -> some View {

            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(text)
                    .font(RBFont.secondary(.medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(isActive ? RBColor.accent : RBColor.secondaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(isActive ? RBColor.selectedTint : RBColor.card)
            .clipShape(Capsule())
            .overlay(
                Capsule().stroke(isActive ? RBColor.accent.opacity(0.6) : RBColor.border)
            )
            .rbHover(cornerRadius: 999)
        }

    // MARK: - Summary Bar

    private var summaryBar: some View {

        let typeCounts =
            ResearchNoteType.allCases
                .map { (type: $0, count: count(for: $0)) }
                .filter { $0.count > 0 }
        return ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {

                        Text("\(allNotes.count) Notes")
                            .font(RBFont.secondary(.semibold))
                            .foregroundStyle(RBColor.primaryText)

                        ForEach(typeCounts, id: \.type) { entry in
                            Text("\(entry.count) \(entry.type.rawValue)\(entry.count == 1 ? "" : "s")")
                                .font(RBFont.secondary())
                                .foregroundStyle(RBColor.secondaryText)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

    // MARK: - Notes List

    private var notesList: some View {

        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(filteredNotes) { note in
                    noteCard(note)
                }
            }
            .rbResponsiveContentPadding()
        }
    }

    private func noteCard(_ note: ResearchNote) -> some View {

        RBRow(action: { editingNote = note }) {

            HStack(alignment: .top, spacing: 12) {

                Text("✺")
                    .font(RBFont.section(.semibold))
                    .foregroundStyle(RBColor.accent)

            VStack(alignment: .leading, spacing: 6) {

                HStack(alignment: .top) {

                    Text(note.title)
                        .font(RBFont.section(.semibold))
                        .foregroundStyle(RBColor.primaryText)
                        .lineLimit(1)

                    Spacer()

                    RBBadge(text: note.noteType.rawValue)
                }

                if !note.content.isEmpty {
                    Text(note.content)
                        .font(RBFont.body())
                        .foregroundStyle(RBColor.secondaryText)
                        .lineLimit(2)
                }

                if !note.tags.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(note.tags.prefix(5), id: \.self) { tag in
                            Text("#\(tag)")
                                .font(RBFont.label(.medium))
                                .foregroundStyle(RBColor.secondaryText)
                        }
                    }
                }

                let paperCount = note.linkedPapers.count

                Text(
                    "Updated \(note.updatedAt.formatted(date: .abbreviated, time: .omitted)) · "
                    + (paperCount == 0
                       ? "no papers linked"
                       : "linked to \(paperCount) paper\(paperCount == 1 ? "" : "s")")
                )
                .font(RBFont.caption())
                .foregroundStyle(RBColor.mutedText)
            }
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {

        VStack(spacing: 16) {

            Spacer()

            Image(systemName: "brain")
                            .font(.system(size: 40))
                            .foregroundStyle(RBColor.mutedText)
            Text("Knowledge Base")
                .font(RBFont.detail(.semibold))
                .foregroundStyle(RBColor.primaryText)

            Text("Your research knowledge starts here.\nCreate notes from concepts, methods, findings,\ndefinitions, research gaps and insights.")
                .font(RBFont.body())
                .foregroundStyle(RBColor.secondaryText)
                .multilineTextAlignment(.center)

            Button {
                showingNewNote = true
            } label: {
                Label("Create Your First Note", systemImage: "plus")
            }
            .buttonStyle(RBPrimaryButtonStyle())
            .padding(.top, 6)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - No Results State

    private var noResultsState: some View {

            VStack(spacing: 14) {

                Spacer()

                Image(systemName: "magnifyingglass")
                    .font(.system(size: 40))
                    .foregroundStyle(RBColor.mutedText)

                Text("No Matching Notes")
                    .font(RBFont.detail(.semibold))
                    .foregroundStyle(RBColor.primaryText)

                Text("None of your \(allNotes.count) notes match the current search or filter.")
                    .font(RBFont.body())
                    .foregroundStyle(RBColor.secondaryText)
                    .multilineTextAlignment(.center)

                Button("Clear Filters") {
                    searchText = ""
                    selectedType = nil
                }
                .buttonStyle(RBGhostButtonStyle())

                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(24)
        }
    }
