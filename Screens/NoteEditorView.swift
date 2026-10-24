//
//  NoteEditorView.swift
//  ResearchBase
//
//  Created by Gaurav Khati on 27/09/26.
//


import SwiftUI
import SwiftData

struct NoteEditorView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let note: ResearchNote?
    let preselectedPaper: PaperRecord?

    @State private var title: String
    @State private var content: String
    @State private var noteType: ResearchNoteType
    @State private var tagsText: String
    @State private var linkedPapers: [PaperRecord]

    @State private var showingPaperPicker = false
    @State private var showingDeleteConfirm = false
    @State private var errorMessage: String?

    init(note: ResearchNote?, preselectedPaper: PaperRecord?) {

        self.note = note
        self.preselectedPaper = preselectedPaper

        _title = State(initialValue: note?.title ?? "")
        _content = State(initialValue: note?.content ?? "")
        _noteType = State(initialValue: note?.noteType ?? .concept)
        _tagsText = State(initialValue: note?.tagsText ?? "")

        var initialPapers = note?.linkedPapers ?? []

        if let preselectedPaper,
           !initialPapers.contains(where: { $0.id == preselectedPaper.id }) {
            initialPapers.append(preselectedPaper)
        }

        _linkedPapers = State(initialValue: initialPapers)
    }

    private var isEditing: Bool { note != nil }

    var body: some View {

        VStack(spacing: 0) {

            header

            Divider().overlay(RBColor.border)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    titleField
                    typeField
                    contentField
                    tagsField
                    linkedPapersSection
                }
                .padding(20)
            }

            Divider().overlay(RBColor.border)

            footer
        }
        .frame(width: 540, height: 640)
        .background(RBColor.elevatedSurface)
        .sheet(isPresented: $showingPaperPicker) {
            PaperLinkPickerView(linkedPapers: $linkedPapers)
        }
        .alert(
            "Delete Note?",
            isPresented: $showingDeleteConfirm
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                deleteNote()
            }
        } message: {
            Text("This will permanently delete this research note. This cannot be undone.")
        }
        .alert(
            "Could Not Save Note",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: Header

    private var header: some View {

        HStack {

            VStack(alignment: .leading, spacing: 4) {

                Text(isEditing ? "Edit Note" : "New Research Note")
                    .font(RBFont.section(.semibold))
                    .foregroundStyle(RBColor.primaryText)

                Text("Turn what you've read into structured knowledge.")
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.secondaryText)
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(RBColor.mutedText)
            }
            .buttonStyle(.plain)
            .rbHover(cornerRadius: RBRadius.field)
            .help("Close")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    // MARK: Title

    private var titleField: some View {

        VStack(alignment: .leading, spacing: 7) {

            Text("Title")
                .font(RBFont.secondary())
                .foregroundStyle(RBColor.secondaryText)

            TextField("", text: $title)
                .textFieldStyle(.plain)
                .font(RBFont.body())
                .foregroundStyle(RBColor.primaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(RBColor.inputBackground)
                .clipShape(RoundedRectangle(cornerRadius: RBRadius.field))
                .overlay(
                    RoundedRectangle(cornerRadius: RBRadius.field)
                        .stroke(RBColor.border)
                )
        }
    }

    // MARK: Type

    private var typeField: some View {

        VStack(alignment: .leading, spacing: 7) {

            Text("Note Type")
                .font(RBFont.secondary())
                .foregroundStyle(RBColor.secondaryText)

            Picker("", selection: $noteType) {
                ForEach(ResearchNoteType.allCases, id: \.self) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            .labelsHidden()
            .frame(width: 220)
        }
    }

    // MARK: Content

    private var contentField: some View {

        VStack(alignment: .leading, spacing: 7) {

            Text("Content")
                .font(RBFont.secondary())
                .foregroundStyle(RBColor.secondaryText)

            TextEditor(text: $content)
                .font(RBFont.body())
                .rbTextEditorStyle(minHeight: 160)
        }
    }

    // MARK: Tags

    private var tagsField: some View {

        VStack(alignment: .leading, spacing: 7) {

            Text("Tags")
                .font(RBFont.secondary())
                .foregroundStyle(RBColor.secondaryText)

            TextField("comma, separated, tags", text: $tagsText)
                .textFieldStyle(.plain)
                .font(RBFont.body())
                .foregroundStyle(RBColor.primaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(RBColor.inputBackground)
                .clipShape(RoundedRectangle(cornerRadius: RBRadius.field))
                .overlay(
                    RoundedRectangle(cornerRadius: RBRadius.field)
                        .stroke(RBColor.border)
                )
        }
    }

    // MARK: Linked Papers

    private var linkedPapersSection: some View {

        VStack(alignment: .leading, spacing: 10) {

            HStack {

                Text("Linked Papers")
                    .font(RBFont.secondary())
                    .foregroundStyle(RBColor.secondaryText)

                Spacer()

                Button {
                    showingPaperPicker = true
                } label: {
                    Label("Add Paper", systemImage: "plus")
                }
                .buttonStyle(RBGhostButtonStyle())
            }

            if linkedPapers.isEmpty {

                RBCard {
                    Text("No papers linked yet.")
                        .font(RBFont.secondary())
                        .foregroundStyle(RBColor.mutedText)
                }

            } else {

                VStack(spacing: 8) {
                    ForEach(linkedPapers) { paper in

                        HStack {

                            Image(systemName: "doc.text")
                                .foregroundStyle(RBColor.accent)

                            Text(paper.title)
                                .font(RBFont.body())
                                .foregroundStyle(RBColor.primaryText)
                                .lineLimit(1)

                            Spacer()

                            Button {
                                linkedPapers.removeAll { $0.id == paper.id }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(RBColor.mutedText)
                            }
                            .buttonStyle(.plain)
                            .rbHover(cornerRadius: RBRadius.field)
                            .help("Remove paper")
                        }
                        .padding(12)
                        .background(RBColor.card)
                        .clipShape(RoundedRectangle(cornerRadius: RBRadius.panel))
                        .overlay(
                            RoundedRectangle(cornerRadius: RBRadius.panel)
                                .stroke(RBColor.border)
                        )
                    }
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {

        HStack {

            if isEditing {
                Button(role: .destructive) {
                    showingDeleteConfirm = true
                } label: {
                    Text("Delete Note")
                }
                .buttonStyle(.plain)
                .rbHover(cornerRadius: RBRadius.field)
                .foregroundStyle(RBColor.error)
            }

            Spacer()

            Button("Cancel") { dismiss() }
                .buttonStyle(RBGhostButtonStyle())

            Button(isEditing ? "Save Changes" : "Create Note") {
                save()
            }
            .buttonStyle(RBPrimaryButtonStyle())
            .disabled(
                title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: Save

    private func save() {

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedTitle.isEmpty else { return }

        let tags =
            tagsText
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

        let store = ResearchDataStore(modelContext: modelContext)

        do {

            if let note {

                try store.updateResearchNote(
                    note,
                    title: trimmedTitle,
                    content: content,
                    type: noteType,
                    tags: tags
                )

                let currentIDs = Set(note.linkedPapers.map { $0.id })
                let desiredIDs = Set(linkedPapers.map { $0.id })

                for paper in note.linkedPapers where !desiredIDs.contains(paper.id) {
                    try store.unlinkResearchNoteFromPaper(note, paper: paper)
                }

                for paper in linkedPapers where !currentIDs.contains(paper.id) {
                    try store.linkResearchNoteToPaper(note, paper: paper)
                }

            } else {

                try store.createResearchNote(
                    title: trimmedTitle,
                    content: content,
                    type: noteType,
                    tags: tags,
                    linkedPapers: linkedPapers
                )
            }

            dismiss()

        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Delete

    private func deleteNote() {

        guard let note else { return }

        do {
            try ResearchDataStore(modelContext: modelContext)
                .deleteResearchNote(note)

            dismiss()

        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
