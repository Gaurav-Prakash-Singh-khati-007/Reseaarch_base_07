import Foundation
import SwiftData
import CoreGraphics

final class ResearchDataStore {

    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }


    // =========================================================
    // MARK: - CREATE PAPER
    // =========================================================

    @discardableResult
    func createPaper(
        pdfURL: URL,
        title: String,
        authors: String,
        venue: String,
        year: Int,
        abstractText: String,
        doi: String,
        urlString: String,
        tags: [String],
        status: ReadingStatus,
        rating: Int
    ) throws -> PaperRecord {

        let filePath =
            pdfURL.standardizedFileURL.path

        let descriptor =
            FetchDescriptor<PaperRecord>(
                predicate:
                    #Predicate<PaperRecord> {
                        $0.pdfFilePath == filePath
                    }
            )

        if let existingPaper =
            try modelContext.fetch(descriptor).first {

            Swift.print(
                "ResearchBase: Paper already exists."
            )

            return existingPaper
        }

        let newPaper =
            PaperRecord(
                pdfFilePath: filePath,
                title: title,
                authors: authors,
                venue: venue,
                year: year,
                abstractText: abstractText,
                doi: doi,
                urlString: urlString,
                tagsText: tags.joined(separator: ", "),
                statusRawValue: status.rawValue,
                rating: max(0, min(rating, 5)),
                addedAt: Date(),
                lastOpenedAt: nil
            )

        modelContext.insert(newPaper)

        Swift.print(
            "ResearchBase: Object inserted into context."
        )

        Swift.print(
            "ResearchBase: Context has changes = \(modelContext.hasChanges)"
        )

        try modelContext.save()

        Swift.print(
            "ResearchBase: Save completed."
        )

        return newPaper
    }


    // =========================================================
    // MARK: - GET OR CREATE PAPER
    // =========================================================

    func getOrCreatePaper(
        pdfURL: URL,
        paper: Paper
    ) throws -> PaperRecord {

        let filePath =
            pdfURL.standardizedFileURL.path

        let descriptor =
            FetchDescriptor<PaperRecord>(
                predicate:
                    #Predicate<PaperRecord> {
                        $0.pdfFilePath == filePath
                    }
            )

        if let existingPaper =
            try modelContext.fetch(descriptor).first {

            return existingPaper
        }

        let newPaper =
            PaperRecord(
                id: paper.id,
                pdfFilePath: filePath,
                title: paper.title,
                authors: paper.authors,
                venue: paper.venue,
                year: paper.year,
                abstractText: paper.abstractText,
                doi: paper.doi,
                urlString: paper.urlString,
                tagsText: paper.tags.joined(separator: ", "),
                statusRawValue: paper.status.rawValue,
                rating: paper.rating,
                addedAt: paper.addedAt,
                lastOpenedAt: paper.lastOpenedAt
            )

        modelContext.insert(newPaper)

        try modelContext.save()

        return newPaper
    }


    // =========================================================
    // MARK: - FETCH PAPERS
    // =========================================================

    func fetchPapers() throws -> [PaperRecord] {

        let descriptor = FetchDescriptor<PaperRecord>()

        let records = try modelContext.fetch(descriptor)

        return records.sorted {
            $0.addedAt > $1.addedAt
        }
    }


    // =========================================================
    // MARK: - CONVERT RECORD TO PAPER
    // =========================================================

    func paperValue(from record: PaperRecord) -> Paper {

        Paper(
            id: record.id,
            title: record.title,
            authors: record.authors,
            venue: record.venue,
            year: record.year,
            tags: record.tags,
            status: record.readingStatus,
            rating: record.rating,
            abstractText: record.abstractText,
            doi: record.doi,
            urlString: record.urlString,
            pdfFilePath: record.pdfFilePath,
            addedAt: record.addedAt,
            lastOpenedAt: record.lastOpenedAt
        )
    }


    // =========================================================
    // MARK: - UPDATE LAST OPENED
    // =========================================================

    func updateLastOpened(_ paper: PaperRecord) throws {

        paper.lastOpenedAt = Date()

        try modelContext.save()
    }


    // =========================================================
    // MARK: - UPDATE PAPER
    // =========================================================

    func updatePaper(
        _ paper: PaperRecord,
        title: String,
        authors: String,
        venue: String,
        year: Int,
        abstractText: String,
        doi: String,
        urlString: String,
        tags: [String],
        status: ReadingStatus,
        rating: Int
    ) throws {

        paper.title = title
        paper.authors = authors
        paper.venue = venue
        paper.year = year

        paper.abstractText = abstractText

        paper.doi = doi
        paper.urlString = urlString

        paper.tagsText = tags.joined(separator: ", ")

        paper.statusRawValue = status.rawValue
        paper.rating = max(0, min(rating, 5))

        paper.updatedAt = Date()

        try modelContext.save()
    }


    // =========================================================
    // MARK: - REFERENCES & CITATION MANAGER
    // =========================================================

    // MARK: - Fetch Existing Citation Keys

    func fetchExistingCitationKeys(
        excluding paper: PaperRecord? = nil
    ) throws -> Set<String> {

        let allPapers = try fetchPapers()

        let keys =
            allPapers
                .filter { $0.id != paper?.id }
                .map { $0.citationKey }
                .filter { !$0.isEmpty }

        return Set(keys)
    }


    // MARK: - Suggest Citation Key

    func suggestCitationKey(
        for paper: PaperRecord
    ) throws -> String {

        let base =
            CitationFormatter.suggestedCitationKey(
                authors: paper.authors,
                year: paper.year,
                title: paper.title
            )

        let existingKeys =
            try fetchExistingCitationKeys(
                excluding: paper
            )

        return CitationFormatter.uniqueCitationKey(
            base: base,
            existingKeys: existingKeys
        )
    }


    // MARK: - Update Reference Metadata

    func updateReferenceMetadata(
        _ paper: PaperRecord,
        title: String,
        authors: String,
        venue: String,
        year: Int,
        doi: String,
        urlString: String,
        citationKey: String,
        publicationType: PublicationType,
        publisher: String,
        volume: String,
        issue: String,
        pages: String,
        edition: String,
        month: String
    ) throws {

        paper.title = title
        paper.authors = authors
        paper.venue = venue
        paper.year = year

        paper.doi = doi
        paper.urlString = urlString

        paper.citationKey = citationKey
        paper.publicationType = publicationType

        paper.publisher = publisher
        paper.volume = volume
        paper.issue = issue
        paper.pages = pages
        paper.edition = edition
        paper.month = month

        paper.updatedAt = Date()

        try modelContext.save()
    }


    // MARK: - Delete Reference / Paper

    func deletePaper(
        _ paper: PaperRecord
    ) throws {

        modelContext.delete(paper)

        try modelContext.save()
    }


    // =========================================================
    // MARK: - RESEARCH NOTES
    // =========================================================

    // MARK: - Create Research Note

    @discardableResult
    func createResearchNote(
        title: String,
        content: String,
        type: ResearchNoteType,
        tags: [String],
        linkedPapers: [PaperRecord] = []
    ) throws -> ResearchNote {

        let note =
            ResearchNote(
                title: title,
                content: content,
                typeRawValue: type.rawValue,
                tagsText: tags.joined(separator: ", "),
                linkedPapers: linkedPapers
            )

        modelContext.insert(note)

        Swift.print(
            "ResearchBase: ResearchNote inserted into context."
        )

        try modelContext.save()

        Swift.print(
            "ResearchBase: ResearchNote save completed."
        )

        return note
    }


    // MARK: - Fetch Research Notes

    func fetchResearchNotes() throws -> [ResearchNote] {

        let descriptor =
            FetchDescriptor<ResearchNote>(
                sortBy: [
                    SortDescriptor(
                        \.updatedAt,
                        order: .reverse
                    )
                ]
            )

        return try modelContext.fetch(descriptor)
    }


    // MARK: - Fetch Single Research Note

    func fetchResearchNote(
        id noteID: UUID
    ) throws -> ResearchNote? {

        let descriptor =
            FetchDescriptor<ResearchNote>(
                predicate:
                    #Predicate<ResearchNote> {
                        $0.id == noteID
                    }
            )

        return try modelContext.fetch(descriptor).first
    }


    // MARK: - Update Research Note

    func updateResearchNote(
        _ note: ResearchNote,
        title: String,
        content: String,
        type: ResearchNoteType,
        tags: [String]
    ) throws {

        note.title = title
        note.content = content
        note.typeRawValue = type.rawValue
        note.tagsText = tags.joined(separator: ", ")
        note.updatedAt = Date()

        try modelContext.save()
    }


    // MARK: - Delete Research Note

    func deleteResearchNote(
        _ note: ResearchNote
    ) throws {

        modelContext.delete(note)

        try modelContext.save()
    }


    // MARK: - Link Research Note To Paper

    func linkResearchNoteToPaper(
        _ note: ResearchNote,
        paper: PaperRecord
    ) throws {

        let alreadyLinked =
            note.linkedPapers.contains {
                $0.id == paper.id
            }

        guard !alreadyLinked else {
            return
        }

        note.linkedPapers.append(paper)
        note.updatedAt = Date()

        try modelContext.save()
    }


    // MARK: - Unlink Research Note From Paper

    func unlinkResearchNoteFromPaper(
        _ note: ResearchNote,
        paper: PaperRecord
    ) throws {

        note.linkedPapers.removeAll {
            $0.id == paper.id
        }

        note.updatedAt = Date()

        try modelContext.save()
    }


    // =========================================================
    // MARK: - PDF ANNOTATION NOTES
    // =========================================================

    // MARK: - Load Notes

    func loadNotes(
        for paper: PaperRecord
    ) -> [PDFNote] {

        paper.notes.map { record in

            PDFNote(
                id: record.id,
                text: record.text,
                note: record.note,
                pageNumber: record.pageNumber,
                bounds: CGRect(
                    x: record.boundsX,
                    y: record.boundsY,
                    width: record.boundsWidth,
                    height: record.boundsHeight
                )
            )
        }
    }


    // MARK: - Save Note

    func saveNote(
        _ note: PDFNote,
        to paper: PaperRecord
    ) throws {

        let record =
            PDFNoteRecord(
                id: note.id,
                text: note.text,
                note: note.note,
                pageNumber: note.pageNumber,
                boundsX: note.bounds.origin.x,
                boundsY: note.bounds.origin.y,
                boundsWidth: note.bounds.size.width,
                boundsHeight: note.bounds.size.height,
                createdAt: Date(),
                updatedAt: Date(),
                paper: paper
            )

        modelContext.insert(record)

        try modelContext.save()
    }


    // MARK: - Update Note

    func updateNote(
        _ note: PDFNote,
        newText: String
    ) throws {

        let noteID = note.id

        let descriptor =
            FetchDescriptor<PDFNoteRecord>(
                predicate:
                    #Predicate<PDFNoteRecord> {
                        $0.id == noteID
                    }
            )

        guard let record =
                try modelContext.fetch(descriptor).first
        else {

            throw NSError(
                domain: "ResearchBase",
                code: 404,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Note could not be found."
                ]
            )
        }

        record.note = newText
        record.updatedAt = Date()

        try modelContext.save()
    }


    // MARK: - Delete Note

    func deleteNote(
        _ note: PDFNote
    ) throws {

        let noteID = note.id

        let descriptor =
            FetchDescriptor<PDFNoteRecord>(
                predicate:
                    #Predicate<PDFNoteRecord> {
                        $0.id == noteID
                    }
            )

        guard let record =
                try modelContext.fetch(descriptor).first
        else {

            throw NSError(
                domain: "ResearchBase",
                code: 404,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Note could not be found."
                ]
            )
        }

        modelContext.delete(record)

        try modelContext.save()
    }


    // =========================================================
    // MARK: - LITERATURE REVIEWS — PHASE 7
    // =========================================================

    // MARK: - Create Literature Review

    @discardableResult
    func createLiteratureReview(
        title: String,
        description: String = "",
        researchQuestion: String = ""
    ) throws -> LiteratureReview {

        let review =
            LiteratureReview(
                title: title,
                descriptionText: description,
                researchQuestion: researchQuestion
            )

        modelContext.insert(review)

        try modelContext.save()

        return review
    }


    // MARK: - Fetch Literature Reviews

    func fetchLiteratureReviews()
        throws -> [LiteratureReview] {

        let descriptor =
            FetchDescriptor<LiteratureReview>(
                sortBy: [
                    SortDescriptor(
                        \.updatedAt,
                        order: .reverse
                    )
                ]
            )

        return try modelContext.fetch(descriptor)
    }


    // MARK: - Fetch Single Literature Review

    func fetchLiteratureReview(
        id reviewID: UUID
    ) throws -> LiteratureReview? {

        let descriptor =
            FetchDescriptor<LiteratureReview>(
                predicate:
                    #Predicate<LiteratureReview> {
                        $0.id == reviewID
                    }
            )

        return try modelContext.fetch(descriptor).first
    }


    // MARK: - Update Literature Review

    func updateLiteratureReview(
        _ review: LiteratureReview,
        title: String,
        description: String,
        researchQuestion: String
    ) throws {

        review.title = title
        review.descriptionText = description
        review.researchQuestion = researchQuestion
        review.updatedAt = Date()

        try modelContext.save()
    }


    // MARK: - Delete Literature Review

    func deleteLiteratureReview(
        _ review: LiteratureReview
    ) throws {

        modelContext.delete(review)

        try modelContext.save()
    }


    // MARK: - Add Paper To Literature Review

    func addPaper(
        _ paper: PaperRecord,
        to review: LiteratureReview
    ) throws {

        let alreadyAdded =
            review.papers.contains {
                $0.id == paper.id
            }

        guard !alreadyAdded else {
            return
        }

        review.papers.append(paper)
        review.updatedAt = Date()

        try modelContext.save()
    }


    // MARK: - Remove Paper From Literature Review

    func removePaper(
        _ paper: PaperRecord,
        from review: LiteratureReview
    ) throws {

        review.papers.removeAll {
            $0.id == paper.id
        }

        review.updatedAt = Date()

        try modelContext.save()
    }


    // MARK: - Create Literature Theme

    @discardableResult
    func createLiteratureTheme(
        name: String,
        description: String = "",
        in review: LiteratureReview
    ) throws -> LiteratureTheme {

        let theme =
            LiteratureTheme(
                name: name,
                descriptionText: description,
                review: review
            )

        modelContext.insert(theme)

        review.updatedAt = Date()

        try modelContext.save()

        return theme
    }


    // MARK: - Update Literature Theme

    func updateLiteratureTheme(
        _ theme: LiteratureTheme,
        name: String,
        description: String
    ) throws {

        theme.name = name
        theme.descriptionText = description
        theme.updatedAt = Date()

        if let review = theme.review {
            review.updatedAt = Date()
        }

        try modelContext.save()
    }


    // MARK: - Delete Literature Theme

    func deleteLiteratureTheme(
        _ theme: LiteratureTheme
    ) throws {

        if let review = theme.review {
            review.updatedAt = Date()
        }

        modelContext.delete(theme)

        try modelContext.save()
    }


    // MARK: - Add Paper To Theme

    func addPaper(
        _ paper: PaperRecord,
        to theme: LiteratureTheme
    ) throws {

        let alreadyAdded =
            theme.papers.contains {
                $0.id == paper.id
            }

        guard !alreadyAdded else {
            return
        }

        theme.papers.append(paper)
        theme.updatedAt = Date()

        if let review = theme.review {
            review.updatedAt = Date()
        }

        try modelContext.save()
    }


    // MARK: - Remove Paper From Theme

    func removePaper(
        _ paper: PaperRecord,
        from theme: LiteratureTheme
    ) throws {

        theme.papers.removeAll {
            $0.id == paper.id
        }

        theme.updatedAt = Date()

        if let review = theme.review {
            review.updatedAt = Date()
        }

        try modelContext.save()
    }


    // MARK: - Create Literature Finding

    @discardableResult
    func createLiteratureFinding(
        title: String,
        content: String,
        in review: LiteratureReview
    ) throws -> LiteratureFinding {

        let finding =
            LiteratureFinding(
                title: title,
                content: content,
                review: review
            )

        modelContext.insert(finding)

        review.updatedAt = Date()

        try modelContext.save()

        return finding
    }


    // MARK: - Update Literature Finding

    func updateLiteratureFinding(
        _ finding: LiteratureFinding,
        title: String,
        content: String
    ) throws {

        finding.title = title
        finding.content = content
        finding.updatedAt = Date()

        if let review = finding.review {
            review.updatedAt = Date()
        }

        try modelContext.save()
    }


    // MARK: - Delete Literature Finding

    func deleteLiteratureFinding(
        _ finding: LiteratureFinding
    ) throws {

        if let review = finding.review {
            review.updatedAt = Date()
        }

        modelContext.delete(finding)

        try modelContext.save()
    }


    // MARK: - Add Supporting Paper To Finding

    func addSupportingPaper(
        _ paper: PaperRecord,
        to finding: LiteratureFinding
    ) throws {

        let alreadyAdded =
            finding.supportingPapers.contains {
                $0.id == paper.id
            }

        guard !alreadyAdded else {
            return
        }

        finding.supportingPapers.append(paper)
        finding.updatedAt = Date()

        if let review = finding.review {
            review.updatedAt = Date()
        }

        try modelContext.save()
    }


    // MARK: - Remove Supporting Paper From Finding

    func removeSupportingPaper(
        _ paper: PaperRecord,
        from finding: LiteratureFinding
    ) throws {

        finding.supportingPapers.removeAll {
            $0.id == paper.id
        }

        finding.updatedAt = Date()

        if let review = finding.review {
            review.updatedAt = Date()
        }

        try modelContext.save()
    }


    // =========================================================
    // MARK: - LITERATURE COMPARISON
    // =========================================================

    // MARK: - Create Comparison Entry

    @discardableResult
    func createComparisonEntry(
        for paper: PaperRecord,
        in review: LiteratureReview,
        method: String = "",
        dataset: String = "",
        mainFinding: String = "",
        notes: String = ""
    ) throws -> LiteratureComparisonEntry {

        if let existing =
            review.comparisonEntries.first(
                where: {
                    $0.paper?.id == paper.id
                }
            ) {

            existing.method = method
            existing.dataset = dataset
            existing.mainFinding = mainFinding
            existing.notes = notes
            existing.createdAt = existing.createdAt

            review.updatedAt = Date()

            try modelContext.save()

            return existing
        }

        let entry =
            LiteratureComparisonEntry(
                method: method,
                dataset: dataset,
                mainFinding: mainFinding,
                notes: notes,
                review: review,
                paper: paper
            )

        modelContext.insert(entry)

        review.updatedAt = Date()

        try modelContext.save()

        return entry
    }


    // MARK: - Update Comparison Entry

    func updateComparisonEntry(
        _ entry: LiteratureComparisonEntry,
        method: String,
        dataset: String,
        mainFinding: String,
        notes: String
    ) throws {

        entry.method = method
        entry.dataset = dataset
        entry.mainFinding = mainFinding
        entry.notes = notes

        if let review = entry.review {
            review.updatedAt = Date()
        }

        try modelContext.save()
    }


    // MARK: - Delete Comparison Entry

    func deleteComparisonEntry(
        _ entry: LiteratureComparisonEntry
    ) throws {

        if let review = entry.review {
            review.updatedAt = Date()
        }

        modelContext.delete(entry)

        try modelContext.save()
    }


    // =========================================================
    // MARK: - LITERATURE SYNTHESIS
    // =========================================================

    // MARK: - Create Or Fetch Synthesis

    @discardableResult
    func synthesis(
        for review: LiteratureReview
    ) throws -> LiteratureSynthesis {

        if let existing = review.synthesis {
            return existing
        }

        let synthesis =
            LiteratureSynthesis(
                review: review
            )

        modelContext.insert(synthesis)

        review.updatedAt = Date()

        try modelContext.save()

        return synthesis
    }


    // MARK: - Update Synthesis

    func updateSynthesis(
        _ synthesis: LiteratureSynthesis,
        commonApproaches: String,
        majorFindings: String,
        areasOfAgreement: String,
        areasOfDisagreement: String,
        methodologicalDifferences: String,
        limitationsAcrossLiterature: String,
        overallSummary: String
    ) throws {

        synthesis.commonApproaches =
            commonApproaches

        synthesis.majorFindings =
            majorFindings

        synthesis.areasOfAgreement =
            areasOfAgreement

        synthesis.areasOfDisagreement =
            areasOfDisagreement

        synthesis.methodologicalDifferences =
            methodologicalDifferences

        synthesis.limitationsAcrossLiterature =
            limitationsAcrossLiterature

        synthesis.overallSummary =
            overallSummary

        synthesis.updatedAt = Date()

        if let review = synthesis.review {
            review.updatedAt = Date()
        }

        try modelContext.save()
    }


    // MARK: - Delete Synthesis

    func deleteSynthesis(
        _ synthesis: LiteratureSynthesis
    ) throws {

        if let review = synthesis.review {
            review.synthesis = nil
            review.updatedAt = Date()
        }

        modelContext.delete(synthesis)

        try modelContext.save()
    }


    // =========================================================
    // MARK: - RESEARCH GAPS — PHASE 8
    // =========================================================

    // MARK: - Create Research Gap

    @discardableResult
    func createResearchGap(
        title: String,
        description: String = "",
        gapType: ResearchGapType = .other,
        status: ResearchGapStatus = .identified,
        evidence: String = "",
        significance: String = "",
        papers: [PaperRecord] = [],
        findings: [LiteratureFinding] = []
    ) throws -> ResearchGap {

        let gap =
            ResearchGap(
                title: title,
                descriptionText: description,
                gapTypeRawValue: gapType.rawValue,
                statusRawValue: status.rawValue,
                evidence: evidence,
                significance: significance,
                papers: papers,
                findings: findings
            )

        modelContext.insert(gap)

        try modelContext.save()

        return gap
    }


    // MARK: - Create Research Gap From Finding

    /// Cross-links Phase 7 → Phase 8: creates a new gap that
    /// retains a link to the originating Literature Finding
    /// rather than duplicating its content.
    @discardableResult
    func createResearchGap(
        fromFinding finding: LiteratureFinding,
        title: String? = nil
    ) throws -> ResearchGap {

        try createResearchGap(
            title: title ?? finding.title,
            evidence: finding.content,
            findings: [finding]
        )
    }


    // MARK: - Fetch Research Gaps

    func fetchResearchGaps() throws -> [ResearchGap] {

        let descriptor =
            FetchDescriptor<ResearchGap>(
                sortBy: [
                    SortDescriptor(
                        \.updatedAt,
                        order: .reverse
                    )
                ]
            )

        return try modelContext.fetch(descriptor)
    }


    // MARK: - Update Research Gap

    func updateResearchGap(
        _ gap: ResearchGap,
        title: String,
        description: String,
        gapType: ResearchGapType,
        status: ResearchGapStatus,
        evidence: String,
        significance: String
    ) throws {

        gap.title = title
        gap.descriptionText = description
        gap.gapType = gapType
        gap.status = status
        gap.evidence = evidence
        gap.significance = significance
        gap.updatedAt = Date()

        try modelContext.save()
    }


    // MARK: - Delete Research Gap

    /// Removes only the gap itself. Linked papers, literature
    /// findings, research problems and research ideas are never
    /// deleted — only their relationship to this gap is dropped
    /// automatically by SwiftData's default nullify delete rule.
    func deleteResearchGap(
        _ gap: ResearchGap
    ) throws {

        modelContext.delete(gap)

        try modelContext.save()
    }


    // MARK: - Link / Unlink Paper To Gap

    func linkPaperToGap(
        _ paper: PaperRecord,
        to gap: ResearchGap
    ) throws {

        guard !gap.papers.contains(where: { $0.id == paper.id }) else {
            return
        }

        gap.papers.append(paper)
        gap.updatedAt = Date()

        try modelContext.save()
    }

    func unlinkPaperFromGap(
        _ paper: PaperRecord,
        from gap: ResearchGap
    ) throws {

        gap.papers.removeAll { $0.id == paper.id }
        gap.updatedAt = Date()

        try modelContext.save()
    }


    // MARK: - Link / Unlink Finding To Gap

    func linkFindingToGap(
        _ finding: LiteratureFinding,
        to gap: ResearchGap
    ) throws {

        guard !gap.findings.contains(where: { $0.id == finding.id }) else {
            return
        }

        gap.findings.append(finding)
        gap.updatedAt = Date()

        try modelContext.save()
    }

    func unlinkFindingFromGap(
        _ finding: LiteratureFinding,
        from gap: ResearchGap
    ) throws {

        gap.findings.removeAll { $0.id == finding.id }
        gap.updatedAt = Date()

        try modelContext.save()
    }


    // =========================================================
    // MARK: - RESEARCH PROBLEMS — PHASE 8
    // =========================================================

    // MARK: - Create Research Problem

    @discardableResult
    func createResearchProblem(
        title: String,
        problemStatement: String = "",
        background: String = "",
        motivation: String = "",
        significance: String = "",
        researchQuestion: String = "",
        objectives: String = "",
        hypotheses: String = "",
        status: ResearchProblemStatus = .draft,
        gaps: [ResearchGap] = [],
        papers: [PaperRecord] = []
    ) throws -> ResearchProblem {

        let problem =
            ResearchProblem(
                title: title,
                problemStatement: problemStatement,
                background: background,
                motivation: motivation,
                significance: significance,
                researchQuestion: researchQuestion,
                objectives: objectives,
                hypotheses: hypotheses,
                statusRawValue: status.rawValue,
                gaps: gaps,
                papers: papers
            )

        modelContext.insert(problem)

        try modelContext.save()

        return problem
    }


    // MARK: - Create Research Problem From Gap

    @discardableResult
    func createResearchProblem(
        fromGap gap: ResearchGap,
        title: String? = nil
    ) throws -> ResearchProblem {

        try createResearchProblem(
            title: title ?? gap.title,
            background: gap.descriptionText,
            gaps: [gap],
            papers: gap.papers
        )
    }


    // MARK: - Fetch Research Problems

    func fetchResearchProblems() throws -> [ResearchProblem] {

        let descriptor =
            FetchDescriptor<ResearchProblem>(
                sortBy: [
                    SortDescriptor(
                        \.updatedAt,
                        order: .reverse
                    )
                ]
            )

        return try modelContext.fetch(descriptor)
    }


    // MARK: - Update Research Problem

    func updateResearchProblem(
        _ problem: ResearchProblem,
        title: String,
        problemStatement: String,
        background: String,
        motivation: String,
        significance: String,
        researchQuestion: String,
        objectives: String,
        hypotheses: String,
        status: ResearchProblemStatus
    ) throws {

        problem.title = title
        problem.problemStatement = problemStatement
        problem.background = background
        problem.motivation = motivation
        problem.significance = significance
        problem.researchQuestion = researchQuestion
        problem.objectives = objectives
        problem.hypotheses = hypotheses
        problem.status = status
        problem.updatedAt = Date()

        try modelContext.save()
    }


    // MARK: - Delete Research Problem

    /// Removes only the problem itself. Linked gaps, papers and
    /// research ideas are never deleted — only the relationship
    /// to this problem is dropped.
    func deleteResearchProblem(
        _ problem: ResearchProblem
    ) throws {

        modelContext.delete(problem)

        try modelContext.save()
    }


    // MARK: - Link / Unlink Gap To Problem

    func linkGapToProblem(
        _ gap: ResearchGap,
        to problem: ResearchProblem
    ) throws {

        guard !problem.gaps.contains(where: { $0.id == gap.id }) else {
            return
        }

        problem.gaps.append(gap)
        problem.updatedAt = Date()

        try modelContext.save()
    }

    func unlinkGapFromProblem(
        _ gap: ResearchGap,
        from problem: ResearchProblem
    ) throws {

        problem.gaps.removeAll { $0.id == gap.id }
        problem.updatedAt = Date()

        try modelContext.save()
    }


    // MARK: - Link / Unlink Paper To Problem

    func linkPaperToProblem(
        _ paper: PaperRecord,
        to problem: ResearchProblem
    ) throws {

        guard !problem.papers.contains(where: { $0.id == paper.id }) else {
            return
        }

        problem.papers.append(paper)
        problem.updatedAt = Date()

        try modelContext.save()
    }

    func unlinkPaperFromProblem(
        _ paper: PaperRecord,
        from problem: ResearchProblem
    ) throws {

        problem.papers.removeAll { $0.id == paper.id }
        problem.updatedAt = Date()

        try modelContext.save()
    }


    // =========================================================
    // MARK: - RESEARCH IDEAS — PHASE 8
    // =========================================================

    // MARK: - Create Research Idea

    @discardableResult
    func createResearchIdea(
        title: String,
        summary: String = "",
        description: String = "",
        proposedApproach: String = "",
        expectedContribution: String = "",
        novelty: String = "",
        assumptions: String = "",
        limitations: String = "",
        status: ResearchIdeaStatus = .draft,
        problems: [ResearchProblem] = [],
        gaps: [ResearchGap] = [],
        papers: [PaperRecord] = [],
        notes: [ResearchNote] = []
    ) throws -> ResearchIdea {

        let idea =
            ResearchIdea(
                title: title,
                summary: summary,
                descriptionText: description,
                proposedApproach: proposedApproach,
                expectedContribution: expectedContribution,
                novelty: novelty,
                assumptions: assumptions,
                limitations: limitations,
                statusRawValue: status.rawValue,
                problems: problems,
                gaps: gaps,
                papers: papers,
                notes: notes
            )

        modelContext.insert(idea)

        try modelContext.save()

        return idea
    }


    // MARK: - Create Research Idea From Problem

    @discardableResult
    func createResearchIdea(
        fromProblem problem: ResearchProblem,
        title: String? = nil
    ) throws -> ResearchIdea {

        try createResearchIdea(
            title: title ?? problem.title,
            summary: problem.problemStatement,
            problems: [problem],
            gaps: problem.gaps,
            papers: problem.papers
        )
    }


    // MARK: - Fetch Research Ideas

    func fetchResearchIdeas() throws -> [ResearchIdea] {

        let descriptor =
            FetchDescriptor<ResearchIdea>(
                sortBy: [
                    SortDescriptor(
                        \.updatedAt,
                        order: .reverse
                    )
                ]
            )

        return try modelContext.fetch(descriptor)
    }


    // MARK: - Update Research Idea

    func updateResearchIdea(
        _ idea: ResearchIdea,
        title: String,
        summary: String,
        description: String,
        proposedApproach: String,
        expectedContribution: String,
        novelty: String,
        assumptions: String,
        limitations: String,
        status: ResearchIdeaStatus
    ) throws {

        idea.title = title
        idea.summary = summary
        idea.descriptionText = description
        idea.proposedApproach = proposedApproach
        idea.expectedContribution = expectedContribution
        idea.novelty = novelty
        idea.assumptions = assumptions
        idea.limitations = limitations
        idea.status = status
        idea.updatedAt = Date()

        try modelContext.save()
    }


    // MARK: - Delete Research Idea

    /// Removes only the idea itself. Linked problems, gaps,
    /// papers and notes are never deleted — only the
    /// relationship to this idea is dropped.
    func deleteResearchIdea(
        _ idea: ResearchIdea
    ) throws {

        modelContext.delete(idea)

        try modelContext.save()
    }


    // MARK: - Link / Unlink Problem To Idea

    func linkProblemToIdea(
        _ problem: ResearchProblem,
        to idea: ResearchIdea
    ) throws {

        guard !idea.problems.contains(where: { $0.id == problem.id }) else {
            return
        }

        idea.problems.append(problem)
        idea.updatedAt = Date()

        try modelContext.save()
    }

    func unlinkProblemFromIdea(
        _ problem: ResearchProblem,
        from idea: ResearchIdea
    ) throws {

        idea.problems.removeAll { $0.id == problem.id }
        idea.updatedAt = Date()

        try modelContext.save()
    }


    // MARK: - Link / Unlink Gap To Idea

    func linkGapToIdea(
        _ gap: ResearchGap,
        to idea: ResearchIdea
    ) throws {

        guard !idea.gaps.contains(where: { $0.id == gap.id }) else {
            return
        }

        idea.gaps.append(gap)
        idea.updatedAt = Date()

        try modelContext.save()
    }

    func unlinkGapFromIdea(
        _ gap: ResearchGap,
        from idea: ResearchIdea
    ) throws {

        idea.gaps.removeAll { $0.id == gap.id }
        idea.updatedAt = Date()

        try modelContext.save()
    }


    // MARK: - Link / Unlink Paper To Idea

    func linkPaperToIdea(
        _ paper: PaperRecord,
        to idea: ResearchIdea
    ) throws {

        guard !idea.papers.contains(where: { $0.id == paper.id }) else {
            return
        }

        idea.papers.append(paper)
        idea.updatedAt = Date()

        try modelContext.save()
    }

    func unlinkPaperFromIdea(
        _ paper: PaperRecord,
        from idea: ResearchIdea
    ) throws {

        idea.papers.removeAll { $0.id == paper.id }
        idea.updatedAt = Date()

        try modelContext.save()
    }


    // MARK: - Link / Unlink Note To Idea

    func linkNoteToIdea(
        _ note: ResearchNote,
        to idea: ResearchIdea
    ) throws {

        guard !idea.notes.contains(where: { $0.id == note.id }) else {
            return
        }

        idea.notes.append(note)
        idea.updatedAt = Date()

        try modelContext.save()
    }

    func unlinkNoteFromIdea(
        _ note: ResearchNote,
        from idea: ResearchIdea
    ) throws {

        idea.notes.removeAll { $0.id == note.id }
        idea.updatedAt = Date()

        try modelContext.save()
    }


    // =========================================================
    // MARK: - EXPERIMENTS — PHASE 9
    // =========================================================

    // MARK: - Create Experiment

    @discardableResult
    func createExperiment(
        name: String,
        status: ExperimentStatus = .draft,
        objective: String = "",
        hypothesis: String = "",
        description: String = "",
        dataset: String = "",
        datasetVersion: String = "",
        model: String = "",
        framework: String = "",
        hardware: String = "",
        operatingEnvironment: String = "",
        codeRepository: String = "",
        trainValidationTestSplit: String = "",
        seed: Int? = nil,
        batchSize: Int? = nil,
        learningRate: String = "",
        epochs: Int? = nil,
        optimizer: String = "",
        ideas: [ResearchIdea] = [],
        problems: [ResearchProblem] = [],
        gaps: [ResearchGap] = [],
        papers: [PaperRecord] = [],
        notes: [ResearchNote] = []
    ) throws -> Experiment {

        let experiment =
            Experiment(
                name: name,
                statusRawValue: status.rawValue,
                objective: objective,
                hypothesis: hypothesis,
                descriptionText: description,
                dataset: dataset,
                datasetVersion: datasetVersion,
                model: model,
                framework: framework,
                hardware: hardware,
                operatingEnvironment: operatingEnvironment,
                codeRepository: codeRepository,
                trainValidationTestSplit: trainValidationTestSplit,
                seed: seed,
                batchSize: batchSize,
                learningRate: learningRate,
                epochs: epochs,
                optimizer: optimizer,
                ideas: ideas,
                problems: problems,
                gaps: gaps,
                papers: papers,
                notes: notes
            )

        modelContext.insert(experiment)

        try modelContext.save()

        return experiment
    }


    // MARK: - Create Experiment From Research Idea

    /// Cross-links Phase 8 → Phase 9: creates a new experiment that
    /// references the originating idea (and, transitively, its
    /// problems/gaps/papers) rather than duplicating any of them.
    @discardableResult
    func createExperiment(
        fromIdea idea: ResearchIdea,
        name: String? = nil
    ) throws -> Experiment {

        try createExperiment(
            name: name ?? idea.title,
            objective: idea.summary,
            hypothesis: idea.proposedApproach,
            ideas: [idea],
            problems: idea.problems,
            gaps: idea.gaps,
            papers: idea.papers
        )
    }


    // MARK: - Create Experiment From Research Problem

    @discardableResult
    func createExperiment(
        fromProblem problem: ResearchProblem,
        name: String? = nil
    ) throws -> Experiment {

        try createExperiment(
            name: name ?? problem.title,
            objective: problem.problemStatement,
            hypothesis: problem.hypotheses,
            problems: [problem],
            gaps: problem.gaps,
            papers: problem.papers
        )
    }


    // MARK: - Fetch Experiments

    func fetchExperiments() throws -> [Experiment] {

        let descriptor =
            FetchDescriptor<Experiment>(
                sortBy: [
                    SortDescriptor(
                        \.updatedAt,
                        order: .reverse
                    )
                ]
            )

        return try modelContext.fetch(descriptor)
    }


    // MARK: - Fetch Single Experiment

    func fetchExperiment(
        id experimentID: UUID
    ) throws -> Experiment? {

        let descriptor =
            FetchDescriptor<Experiment>(
                predicate:
                    #Predicate<Experiment> {
                        $0.id == experimentID
                    }
            )

        return try modelContext.fetch(descriptor).first
    }


    // MARK: - Update Experiment (Overview)

    func updateExperiment(
        _ experiment: Experiment,
        name: String,
        status: ExperimentStatus,
        objective: String,
        hypothesis: String,
        description: String
    ) throws {

        experiment.name = name
        experiment.status = status
        experiment.objective = objective
        experiment.hypothesis = hypothesis
        experiment.descriptionText = description
        experiment.updatedAt = Date()

        try modelContext.save()
    }


    // MARK: - Update Experiment Setup

    func updateExperimentSetup(
        _ experiment: Experiment,
        dataset: String,
        datasetVersion: String,
        model: String,
        framework: String,
        hardware: String,
        operatingEnvironment: String,
        codeRepository: String,
        trainValidationTestSplit: String,
        seed: Int?,
        batchSize: Int?,
        learningRate: String,
        epochs: Int?,
        optimizer: String
    ) throws {

        experiment.dataset = dataset
        experiment.datasetVersion = datasetVersion
        experiment.model = model
        experiment.framework = framework
        experiment.hardware = hardware
        experiment.operatingEnvironment = operatingEnvironment
        experiment.codeRepository = codeRepository
        experiment.trainValidationTestSplit = trainValidationTestSplit
        experiment.seed = seed
        experiment.batchSize = batchSize
        experiment.learningRate = learningRate
        experiment.epochs = epochs
        experiment.optimizer = optimizer
        experiment.updatedAt = Date()

        try modelContext.save()
    }


    // MARK: - Update Experiment Results

    /// Updates only the researcher-authored interpretation and
    /// conclusion text. Baseline metrics and the best-run choice are
    /// managed separately below.
    func updateExperimentResults(
        _ experiment: Experiment,
        interpretation: String,
        conclusion: String
    ) throws {

        experiment.resultsInterpretation = interpretation
        experiment.resultsConclusion = conclusion
        experiment.updatedAt = Date()

        try modelContext.save()
    }


    // MARK: - Set Best Run

    /// Records which run the researcher considers best. Passing nil
    /// clears the selection. ResearchBase never chooses this itself.
    func setBestRun(
        _ run: ExperimentRun?,
        for experiment: Experiment
    ) throws {

        experiment.bestRunID = run?.id
        experiment.updatedAt = Date()

        try modelContext.save()
    }


    // MARK: - Delete Experiment

    /// Removes the experiment along with its own runs, run metrics
    /// and baseline metrics (cascade delete rules). Linked research
    /// ideas, problems, gaps, papers and notes are never deleted —
    /// only the relationship to this experiment is dropped.
    func deleteExperiment(
        _ experiment: Experiment
    ) throws {

        modelContext.delete(experiment)

        try modelContext.save()
    }


    // MARK: - Link / Unlink Idea To Experiment

    func linkIdeaToExperiment(
        _ idea: ResearchIdea,
        to experiment: Experiment
    ) throws {

        guard !experiment.ideas.contains(where: { $0.id == idea.id }) else {
            return
        }

        experiment.ideas.append(idea)
        experiment.updatedAt = Date()

        try modelContext.save()
    }

    func unlinkIdeaFromExperiment(
        _ idea: ResearchIdea,
        from experiment: Experiment
    ) throws {

        experiment.ideas.removeAll { $0.id == idea.id }
        experiment.updatedAt = Date()

        try modelContext.save()
    }


    // MARK: - Link / Unlink Problem To Experiment

    func linkProblemToExperiment(
        _ problem: ResearchProblem,
        to experiment: Experiment
    ) throws {

        guard !experiment.problems.contains(where: { $0.id == problem.id }) else {
            return
        }

        experiment.problems.append(problem)
        experiment.updatedAt = Date()

        try modelContext.save()
    }

    func unlinkProblemFromExperiment(
        _ problem: ResearchProblem,
        from experiment: Experiment
    ) throws {

        experiment.problems.removeAll { $0.id == problem.id }
        experiment.updatedAt = Date()

        try modelContext.save()
    }


    // MARK: - Link / Unlink Gap To Experiment

    func linkGapToExperiment(
        _ gap: ResearchGap,
        to experiment: Experiment
    ) throws {

        guard !experiment.gaps.contains(where: { $0.id == gap.id }) else {
            return
        }

        experiment.gaps.append(gap)
        experiment.updatedAt = Date()

        try modelContext.save()
    }

    func unlinkGapFromExperiment(
        _ gap: ResearchGap,
        from experiment: Experiment
    ) throws {

        experiment.gaps.removeAll { $0.id == gap.id }
        experiment.updatedAt = Date()

        try modelContext.save()
    }


    // MARK: - Link / Unlink Paper To Experiment

    func linkPaperToExperiment(
        _ paper: PaperRecord,
        to experiment: Experiment
    ) throws {

        guard !experiment.papers.contains(where: { $0.id == paper.id }) else {
            return
        }

        experiment.papers.append(paper)
        experiment.updatedAt = Date()

        try modelContext.save()
    }

    func unlinkPaperFromExperiment(
        _ paper: PaperRecord,
        from experiment: Experiment
    ) throws {

        experiment.papers.removeAll { $0.id == paper.id }
        experiment.updatedAt = Date()

        try modelContext.save()
    }


    // MARK: - Link / Unlink Note To Experiment

    func linkNoteToExperiment(
        _ note: ResearchNote,
        to experiment: Experiment
    ) throws {

        guard !experiment.notes.contains(where: { $0.id == note.id }) else {
            return
        }

        experiment.notes.append(note)
        experiment.updatedAt = Date()

        try modelContext.save()
    }

    func unlinkNoteFromExperiment(
        _ note: ResearchNote,
        from experiment: Experiment
    ) throws {

        experiment.notes.removeAll { $0.id == note.id }
        experiment.updatedAt = Date()

        try modelContext.save()
    }


    // =========================================================
    // MARK: - EXPERIMENT RUNS — PHASE 9
    // =========================================================

    // MARK: - Create Experiment Run

    @discardableResult
    func createExperimentRun(
        for experiment: Experiment,
        status: ExperimentRunStatus = .planned,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        seed: Int? = nil,
        configuration: String = "",
        notes: String = ""
    ) throws -> ExperimentRun {

        let nextRunNumber =
            (experiment.runs.map { $0.runNumber }.max() ?? 0) + 1

        let run =
            ExperimentRun(
                runNumber: nextRunNumber,
                statusRawValue: status.rawValue,
                startedAt: startedAt,
                completedAt: completedAt,
                seed: seed,
                configuration: configuration,
                notes: notes,
                experiment: experiment
            )

        modelContext.insert(run)

        experiment.runs.append(run)
        experiment.updatedAt = Date()

        try modelContext.save()

        return run
    }


    // MARK: - Fetch Runs

    func fetchRuns(
        for experiment: Experiment
    ) -> [ExperimentRun] {

        experiment.runs.sorted { $0.runNumber < $1.runNumber }
    }


    // MARK: - Update Experiment Run

    func updateExperimentRun(
        _ run: ExperimentRun,
        status: ExperimentRunStatus,
        startedAt: Date?,
        completedAt: Date?,
        seed: Int?,
        configuration: String,
        notes: String
    ) throws {

        run.status = status
        run.startedAt = startedAt
        run.completedAt = completedAt
        run.seed = seed
        run.configuration = configuration
        run.notes = notes
        run.updatedAt = Date()

        run.experiment?.updatedAt = Date()

        try modelContext.save()
    }


    // MARK: - Delete Experiment Run

    /// Removes only this run (and its own metrics, via cascade).
    /// The parent experiment is never deleted. If this run was
    /// marked as the experiment's best run, that selection is
    /// cleared so it never dangles.
    func deleteExperimentRun(
        _ run: ExperimentRun
    ) throws {

        if let experiment = run.experiment {
            if experiment.bestRunID == run.id {
                experiment.bestRunID = nil
            }
            experiment.runs.removeAll { $0.id == run.id }
            experiment.updatedAt = Date()
        }

        modelContext.delete(run)

        try modelContext.save()
    }


    // =========================================================
    // MARK: - RUN METRICS — PHASE 9
    // =========================================================

    // MARK: - Create Metric

    @discardableResult
    func createMetric(
        name: String,
        value: Double,
        unit: String = "",
        higherIsBetter: Bool = true,
        for run: ExperimentRun
    ) throws -> RunMetric {

        let metric =
            RunMetric(
                name: name,
                value: value,
                unit: unit,
                higherIsBetter: higherIsBetter,
                run: run
            )

        modelContext.insert(metric)

        run.metrics.append(metric)
        run.updatedAt = Date()
        run.experiment?.updatedAt = Date()

        try modelContext.save()

        return metric
    }


    // MARK: - Update Metric

    func updateMetric(
        _ metric: RunMetric,
        name: String,
        value: Double,
        unit: String,
        higherIsBetter: Bool
    ) throws {

        metric.name = name
        metric.value = value
        metric.unit = unit
        metric.higherIsBetter = higherIsBetter

        metric.run?.updatedAt = Date()
        metric.run?.experiment?.updatedAt = Date()

        try modelContext.save()
    }


    // MARK: - Delete Metric

    func deleteMetric(
        _ metric: RunMetric
    ) throws {

        let run = metric.run

        run?.metrics.removeAll { $0.id == metric.id }
        run?.updatedAt = Date()
        run?.experiment?.updatedAt = Date()

        modelContext.delete(metric)

        try modelContext.save()
    }


    // =========================================================
    // MARK: - BASELINE METRICS — PHASE 9
    // =========================================================

    // MARK: - Create Baseline Metric

    @discardableResult
    func createBaselineMetric(
        name: String,
        value: Double,
        unit: String = "",
        higherIsBetter: Bool = true,
        for experiment: Experiment
    ) throws -> BaselineMetric {

        let metric =
            BaselineMetric(
                name: name,
                value: value,
                unit: unit,
                higherIsBetter: higherIsBetter,
                experiment: experiment
            )

        modelContext.insert(metric)

        experiment.baselineMetrics.append(metric)
        experiment.updatedAt = Date()

        try modelContext.save()

        return metric
    }


    // MARK: - Update Baseline Metric

    func updateBaselineMetric(
        _ metric: BaselineMetric,
        name: String,
        value: Double,
        unit: String,
        higherIsBetter: Bool
    ) throws {

        metric.name = name
        metric.value = value
        metric.unit = unit
        metric.higherIsBetter = higherIsBetter

        metric.experiment?.updatedAt = Date()

        try modelContext.save()
    }


    // MARK: - Delete Baseline Metric

    func deleteBaselineMetric(
        _ metric: BaselineMetric
    ) throws {

        let experiment = metric.experiment

        experiment?.baselineMetrics.removeAll { $0.id == metric.id }
        experiment?.updatedAt = Date()

        modelContext.delete(metric)

        try modelContext.save()
    }


    // =========================================================
    // MARK: - WRITING DOCUMENTS — PHASE 10
    // =========================================================

    // MARK: - Create Writing Document

    @discardableResult
    func createWritingDocument(
        title: String,
        documentType: WritingDocumentType = .researchPaper,
        status: WritingDocumentStatus = .draft,
        problems: [ResearchProblem] = [],
        ideas: [ResearchIdea] = [],
        gaps: [ResearchGap] = [],
        experiments: [Experiment] = [],
        papers: [PaperRecord] = [],
        notes: [ResearchNote] = [],
        findings: [LiteratureFinding] = []
    ) throws -> WritingDocument {

        let document =
            WritingDocument(
                title: title,
                documentTypeRawValue: documentType.rawValue,
                statusRawValue: status.rawValue,
                problems: problems,
                ideas: ideas,
                gaps: gaps,
                experiments: experiments,
                papers: papers,
                notes: notes,
                findings: findings
            )

        modelContext.insert(document)

        try modelContext.save()

        return document
    }


    // MARK: - Fetch Writing Documents

    func fetchWritingDocuments() throws -> [WritingDocument] {

        let descriptor =
            FetchDescriptor<WritingDocument>(
                sortBy: [
                    SortDescriptor(
                        \.updatedAt,
                        order: .reverse
                    )
                ]
            )

        return try modelContext.fetch(descriptor)
    }


    // MARK: - Fetch Single Writing Document

    func fetchWritingDocument(
        id documentID: UUID
    ) throws -> WritingDocument? {

        let descriptor =
            FetchDescriptor<WritingDocument>(
                predicate:
                    #Predicate<WritingDocument> {
                        $0.id == documentID
                    }
            )

        return try modelContext.fetch(descriptor).first
    }


    // MARK: - Update Writing Document

    func updateWritingDocument(
        _ document: WritingDocument,
        title: String,
        documentType: WritingDocumentType,
        status: WritingDocumentStatus
    ) throws {

        document.title = title
        document.documentType = documentType
        document.status = status
        document.updatedAt = Date()

        try modelContext.save()
    }


    // MARK: - Delete Writing Document

    /// Removes the document along with its own sections (cascade
    /// delete rule). Linked research problems, ideas, gaps,
    /// experiments, papers, notes and literature findings are never
    /// deleted — only the relationship to this document is dropped.
    func deleteWritingDocument(
        _ document: WritingDocument
    ) throws {

        modelContext.delete(document)

        try modelContext.save()
    }


    // MARK: - Link / Unlink Problem To Writing Document

    func linkProblemToWritingDocument(
        _ problem: ResearchProblem,
        to document: WritingDocument
    ) throws {

        guard !document.problems.contains(where: { $0.id == problem.id }) else {
            return
        }

        document.problems.append(problem)
        document.updatedAt = Date()

        try modelContext.save()
    }

    func unlinkProblemFromWritingDocument(
        _ problem: ResearchProblem,
        from document: WritingDocument
    ) throws {

        document.problems.removeAll { $0.id == problem.id }
        document.updatedAt = Date()

        try modelContext.save()
    }


    // MARK: - Link / Unlink Idea To Writing Document

    func linkIdeaToWritingDocument(
        _ idea: ResearchIdea,
        to document: WritingDocument
    ) throws {

        guard !document.ideas.contains(where: { $0.id == idea.id }) else {
            return
        }

        document.ideas.append(idea)
        document.updatedAt = Date()

        try modelContext.save()
    }

    func unlinkIdeaFromWritingDocument(
        _ idea: ResearchIdea,
        from document: WritingDocument
    ) throws {

        document.ideas.removeAll { $0.id == idea.id }
        document.updatedAt = Date()

        try modelContext.save()
    }


    // MARK: - Link / Unlink Gap To Writing Document

    func linkGapToWritingDocument(
        _ gap: ResearchGap,
        to document: WritingDocument
    ) throws {

        guard !document.gaps.contains(where: { $0.id == gap.id }) else {
            return
        }

        document.gaps.append(gap)
        document.updatedAt = Date()

        try modelContext.save()
    }

    func unlinkGapFromWritingDocument(
        _ gap: ResearchGap,
        from document: WritingDocument
    ) throws {

        document.gaps.removeAll { $0.id == gap.id }
        document.updatedAt = Date()

        try modelContext.save()
    }


    // MARK: - Link / Unlink Experiment To Writing Document

    func linkExperimentToWritingDocument(
        _ experiment: Experiment,
        to document: WritingDocument
    ) throws {

        guard !document.experiments.contains(where: { $0.id == experiment.id }) else {
            return
        }

        document.experiments.append(experiment)
        document.updatedAt = Date()

        try modelContext.save()
    }

    func unlinkExperimentFromWritingDocument(
        _ experiment: Experiment,
        from document: WritingDocument
    ) throws {

        document.experiments.removeAll { $0.id == experiment.id }
        document.updatedAt = Date()

        try modelContext.save()
    }


    // MARK: - Link / Unlink Paper To Writing Document

    func linkPaperToWritingDocument(
        _ paper: PaperRecord,
        to document: WritingDocument
    ) throws {

        guard !document.papers.contains(where: { $0.id == paper.id }) else {
            return
        }

        document.papers.append(paper)
        document.updatedAt = Date()

        try modelContext.save()
    }

    func unlinkPaperFromWritingDocument(
        _ paper: PaperRecord,
        from document: WritingDocument
    ) throws {

        document.papers.removeAll { $0.id == paper.id }
        document.updatedAt = Date()

        try modelContext.save()
    }


    // MARK: - Link / Unlink Note To Writing Document

    func linkNoteToWritingDocument(
        _ note: ResearchNote,
        to document: WritingDocument
    ) throws {

        guard !document.notes.contains(where: { $0.id == note.id }) else {
            return
        }

        document.notes.append(note)
        document.updatedAt = Date()

        try modelContext.save()
    }

    func unlinkNoteFromWritingDocument(
        _ note: ResearchNote,
        from document: WritingDocument
    ) throws {

        document.notes.removeAll { $0.id == note.id }
        document.updatedAt = Date()

        try modelContext.save()
    }


    // MARK: - Link / Unlink Literature Finding To Writing Document

    func linkFindingToWritingDocument(
        _ finding: LiteratureFinding,
        to document: WritingDocument
    ) throws {

        guard !document.findings.contains(where: { $0.id == finding.id }) else {
            return
        }

        document.findings.append(finding)
        document.updatedAt = Date()

        try modelContext.save()
    }

    func unlinkFindingFromWritingDocument(
        _ finding: LiteratureFinding,
        from document: WritingDocument
    ) throws {

        document.findings.removeAll { $0.id == finding.id }
        document.updatedAt = Date()

        try modelContext.save()
    }


    // =========================================================
    // MARK: - WRITING SECTIONS — PHASE 10
    // =========================================================

    // MARK: - Create Writing Section

    @discardableResult
    func createWritingSection(
        title: String,
        sectionType: WritingSectionType = .custom,
        content: String = "",
        order: Int,
        for document: WritingDocument
    ) throws -> WritingSection {

        let section =
            WritingSection(
                title: title,
                sectionTypeRawValue: sectionType.rawValue,
                content: content,
                order: order,
                document: document
            )

        modelContext.insert(section)

        document.updatedAt = Date()

        try modelContext.save()

        return section
    }


    // MARK: - Update Writing Section

    /// Updates a section's title and content. Reordering is handled
    /// separately by `reorderWritingSections`, and the section type
    /// can be changed the same way by extending this call site later
    /// if the editor needs to let the researcher retype a section.
    func updateWritingSection(
        _ section: WritingSection,
        title: String,
        content: String
    ) throws {

        section.title = title
        section.content = content
        section.updatedAt = Date()

        section.document?.updatedAt = Date()

        try modelContext.save()
    }


    // MARK: - Delete Writing Section

    func deleteWritingSection(
        _ section: WritingSection
    ) throws {

        let document = section.document

        modelContext.delete(section)

        document?.updatedAt = Date()

        try modelContext.save()
    }


    // MARK: - Reorder Writing Sections

    /// Applies a new display order to a document's sections. Pass the
    /// sections in their desired order (e.g. after a drag-to-reorder
    /// interaction) — this assigns each one's `order` to match its
    /// index in the array.
    func reorderWritingSections(
        _ orderedSections: [WritingSection],
        in document: WritingDocument
    ) throws {

        for (index, section) in orderedSections.enumerated() {
            section.order = index
        }

        document.updatedAt = Date()

        try modelContext.save()
    }


    // MARK: - Default Section Templates

    /// The default (title, section type) pairs a freshly created
    /// document of this type should start with. `.custom` documents
    /// intentionally start with none — a custom structure is chosen
    /// entirely by the researcher via `createWritingSection`. This is
    /// pure data, never persisted directly; `createDefaultSections`
    /// below is what actually inserts `WritingSection` rows from it.
    func defaultSectionTemplates(
        for documentType: WritingDocumentType
    ) -> [(title: String, type: WritingSectionType)] {

        switch documentType {

        case .researchPaper, .conferencePaper, .journalPaper, .technicalReport:
            return [
                ("Abstract", .abstract),
                ("Introduction", .introduction),
                ("Related Work", .relatedWork),
                ("Problem Statement", .problemStatement),
                ("Methodology", .methodology),
                ("Experimental Setup", .experimentalSetup),
                ("Results", .results),
                ("Discussion", .discussion),
                ("Conclusion", .conclusion),
                ("Future Work", .futureWork),
                ("References", .references)
            ]

        case .thesisChapter, .thesis:
            return [
                ("Introduction", .introduction),
                ("Background", .relatedWork),
                ("Methodology", .methodology),
                ("Results", .results),
                ("Discussion", .discussion),
                ("Conclusion", .conclusion)
            ]

        case .literatureReview:
            return [
                ("Introduction", .introduction),
                ("Thematic Review", .relatedWork),
                ("Synthesis", .discussion),
                ("Conclusion", .conclusion),
                ("References", .references)
            ]

        case .custom:
            return []
        }
    }


    // MARK: - Create Default Sections

    /// Inserts the default section template for `documentType` into
    /// `document`, in order. Intended to be called once, immediately
    /// after `createWritingDocument` — it is never re-applied
    /// automatically later, so any sections the researcher has since
    /// added, renamed, reordered or deleted are never overwritten or
    /// duplicated.
    func createDefaultSections(
        for document: WritingDocument,
        matching documentType: WritingDocumentType
    ) throws {

        let templates = defaultSectionTemplates(for: documentType)

        for (index, template) in templates.enumerated() {

            let section =
                WritingSection(
                    title: template.title,
                    sectionTypeRawValue: template.type.rawValue,
                    content: "",
                    order: index,
                    document: document
                )

            modelContext.insert(section)
        }

        document.updatedAt = Date()

        try modelContext.save()
    }


    // =========================================================
    // MARK: - RESEARCH PROJECTS — PHASE 11
    // =========================================================

    // MARK: - Create Project

    @discardableResult
    func createProject(
        name: String,
        description: String = "",
        status: ResearchProjectStatus = .planning,
        papers: [PaperRecord] = [],
        notes: [ResearchNote] = [],
        findings: [LiteratureFinding] = [],
        gaps: [ResearchGap] = [],
        problems: [ResearchProblem] = [],
        ideas: [ResearchIdea] = [],
        experiments: [Experiment] = [],
        writingDocuments: [WritingDocument] = []
    ) throws -> ResearchProject {

        let project =
            ResearchProject(
                name: name,
                descriptionText: description,
                statusRawValue: status.rawValue,
                papers: papers,
                notes: notes,
                findings: findings,
                gaps: gaps,
                problems: problems,
                ideas: ideas,
                experiments: experiments,
                writingDocuments: writingDocuments
            )

        modelContext.insert(project)

        try modelContext.save()

        return project
    }


    // MARK: - Fetch Projects

    func fetchProjects() throws -> [ResearchProject] {

        let descriptor =
            FetchDescriptor<ResearchProject>(
                sortBy: [
                    SortDescriptor(
                        \.updatedAt,
                        order: .reverse
                    )
                ]
            )

        return try modelContext.fetch(descriptor)
    }


    // MARK: - Fetch Single Project

    func fetchProject(
        id projectID: UUID
    ) throws -> ResearchProject? {

        let descriptor =
            FetchDescriptor<ResearchProject>(
                predicate:
                    #Predicate<ResearchProject> {
                        $0.id == projectID
                    }
            )

        return try modelContext.fetch(descriptor).first
    }


    // MARK: - Update Project

    func updateProject(
        _ project: ResearchProject,
        name: String,
        description: String,
        status: ResearchProjectStatus
    ) throws {

        project.name = name
        project.descriptionText = description
        project.status = status
        project.updatedAt = Date()

        try modelContext.save()
    }


    // MARK: - Delete Project

    /// Removes the project itself. ResearchProject owns none of its
    /// linked objects (plain, unidirectional arrays — see
    /// ResearchProject.swift), so this never deletes a PaperRecord,
    /// ResearchNote, LiteratureFinding, ResearchGap, ResearchProblem,
    /// ResearchIdea, Experiment or WritingDocument — only the
    /// project's own row disappears.
    func deleteProject(
        _ project: ResearchProject
    ) throws {

        modelContext.delete(project)

        try modelContext.save()
    }


    // MARK: - Link / Unlink Paper To Project

    func linkPaperToProject(
        _ paper: PaperRecord,
        to project: ResearchProject
    ) throws {

        guard !project.papers.contains(where: { $0.id == paper.id }) else {
            return
        }

        project.papers.append(paper)
        project.updatedAt = Date()

        try modelContext.save()
    }

    func unlinkPaperFromProject(
        _ paper: PaperRecord,
        from project: ResearchProject
    ) throws {

        project.papers.removeAll { $0.id == paper.id }
        project.updatedAt = Date()

        try modelContext.save()
    }


    // MARK: - Link / Unlink Note To Project

    func linkNoteToProject(
        _ note: ResearchNote,
        to project: ResearchProject
    ) throws {

        guard !project.notes.contains(where: { $0.id == note.id }) else {
            return
        }

        project.notes.append(note)
        project.updatedAt = Date()

        try modelContext.save()
    }

    func unlinkNoteFromProject(
        _ note: ResearchNote,
        from project: ResearchProject
    ) throws {

        project.notes.removeAll { $0.id == note.id }
        project.updatedAt = Date()

        try modelContext.save()
    }


    // MARK: - Link / Unlink Finding To Project

    func linkFindingToProject(
        _ finding: LiteratureFinding,
        to project: ResearchProject
    ) throws {

        guard !project.findings.contains(where: { $0.id == finding.id }) else {
            return
        }

        project.findings.append(finding)
        project.updatedAt = Date()

        try modelContext.save()
    }

    func unlinkFindingFromProject(
        _ finding: LiteratureFinding,
        from project: ResearchProject
    ) throws {

        project.findings.removeAll { $0.id == finding.id }
        project.updatedAt = Date()

        try modelContext.save()
    }


    // MARK: - Link / Unlink Gap To Project

    func linkGapToProject(
        _ gap: ResearchGap,
        to project: ResearchProject
    ) throws {

        guard !project.gaps.contains(where: { $0.id == gap.id }) else {
            return
        }

        project.gaps.append(gap)
        project.updatedAt = Date()

        try modelContext.save()
    }

    func unlinkGapFromProject(
        _ gap: ResearchGap,
        from project: ResearchProject
    ) throws {

        project.gaps.removeAll { $0.id == gap.id }
        project.updatedAt = Date()

        try modelContext.save()
    }


    // MARK: - Link / Unlink Problem To Project

    func linkProblemToProject(
        _ problem: ResearchProblem,
        to project: ResearchProject
    ) throws {

        guard !project.problems.contains(where: { $0.id == problem.id }) else {
            return
        }

        project.problems.append(problem)
        project.updatedAt = Date()

        try modelContext.save()
    }

    func unlinkProblemFromProject(
        _ problem: ResearchProblem,
        from project: ResearchProject
    ) throws {

        project.problems.removeAll { $0.id == problem.id }
        project.updatedAt = Date()

        try modelContext.save()
    }


    // MARK: - Link / Unlink Idea To Project

    func linkIdeaToProject(
        _ idea: ResearchIdea,
        to project: ResearchProject
    ) throws {

        guard !project.ideas.contains(where: { $0.id == idea.id }) else {
            return
        }

        project.ideas.append(idea)
        project.updatedAt = Date()

        try modelContext.save()
    }

    func unlinkIdeaFromProject(
        _ idea: ResearchIdea,
        from project: ResearchProject
    ) throws {

        project.ideas.removeAll { $0.id == idea.id }
        project.updatedAt = Date()

        try modelContext.save()
    }


    // MARK: - Link / Unlink Experiment To Project

    func linkExperimentToProject(
        _ experiment: Experiment,
        to project: ResearchProject
    ) throws {

        guard !project.experiments.contains(where: { $0.id == experiment.id }) else {
            return
        }

        project.experiments.append(experiment)
        project.updatedAt = Date()

        try modelContext.save()
    }

    func unlinkExperimentFromProject(
        _ experiment: Experiment,
        from project: ResearchProject
    ) throws {

        project.experiments.removeAll { $0.id == experiment.id }
        project.updatedAt = Date()

        try modelContext.save()
    }


    // MARK: - Link / Unlink Writing Document To Project

    func linkWritingDocumentToProject(
        _ document: WritingDocument,
        to project: ResearchProject
    ) throws {

        guard !project.writingDocuments.contains(where: { $0.id == document.id }) else {
            return
        }

        project.writingDocuments.append(document)
        project.updatedAt = Date()

        try modelContext.save()
    }

    func unlinkWritingDocumentFromProject(
        _ document: WritingDocument,
        from project: ResearchProject
    ) throws {

        project.writingDocuments.removeAll { $0.id == document.id }
        project.updatedAt = Date()

        try modelContext.save()
    }


    // =========================================================
    // MARK: - GLOBAL SEARCH — PHASE 12
    // =========================================================

    // MARK: - Search Result

    /// One matched or related record, already resolved to a
    /// NavigationTarget. Search and "Related Research" both return
    /// these so the UI layer never has to know how to identify or
    /// open a record itself.
    struct GlobalSearchResult: Identifiable {
        let target: NavigationTarget
        let title: String
        let subtitle: String

        var id: String { target.id }
    }

    // MARK: - Related Group

    /// One labeled group of related items of the same kind, used by
    /// "Related Research" sections. Only ever built from
    /// relationships that already exist on the record — nothing here
    /// creates, infers or guesses a connection.
    struct RelatedGroup: Identifiable {
        let label: String
        let items: [GlobalSearchResult]

        var id: String { label }
        var count: Int { items.count }
    }

    // MARK: - Result Builders

    // One overload per entity type. Kept private and reused by both
    // globalSearch and every relatedResearch method below so the
    // "how do I describe this record" logic exists in exactly one
    // place per type.

    private func result(for paper: PaperRecord) -> GlobalSearchResult {
        GlobalSearchResult(
            target: .paper(paper.id),
            title: paper.title,
            subtitle: paper.authors
        )
    }

    private func result(for note: ResearchNote) -> GlobalSearchResult {
        GlobalSearchResult(
            target: .researchNote(note.id),
            title: note.title,
            subtitle: note.noteType.rawValue
        )
    }

    private func result(for finding: LiteratureFinding) -> GlobalSearchResult {
        GlobalSearchResult(
            target: .literatureFinding(finding.id),
            title: finding.title,
            subtitle: finding.review?.title ?? ""
        )
    }

    private func result(for gap: ResearchGap) -> GlobalSearchResult {
        GlobalSearchResult(
            target: .researchGap(gap.id),
            title: gap.title,
            subtitle: gap.gapType.rawValue
        )
    }

    private func result(for problem: ResearchProblem) -> GlobalSearchResult {
        GlobalSearchResult(
            target: .researchProblem(problem.id),
            title: problem.title,
            subtitle: problem.status.rawValue
        )
    }

    private func result(for idea: ResearchIdea) -> GlobalSearchResult {
        GlobalSearchResult(
            target: .researchIdea(idea.id),
            title: idea.title,
            subtitle: idea.status.rawValue
        )
    }

    private func result(for experiment: Experiment) -> GlobalSearchResult {
        GlobalSearchResult(
            target: .experiment(experiment.id),
            title: experiment.name,
            subtitle: experiment.status.rawValue
        )
    }

    private func result(for document: WritingDocument) -> GlobalSearchResult {
        GlobalSearchResult(
            target: .writingDocument(document.id),
            title: document.title,
            subtitle: document.status.rawValue
        )
    }

    private func result(for project: ResearchProject) -> GlobalSearchResult {
        GlobalSearchResult(
            target: .project(project.id),
            title: project.name,
            subtitle: project.status.rawValue
        )
    }

    // MARK: - Fetch-And-Filter Helper

    /// Fetches every persisted record of a type and keeps only the
    /// ones matching `predicate`. Used for the relationships that are
    /// only stored on one side (e.g. `Experiment.papers`), where the
    /// "which experiments reference this paper" direction has no
    /// SwiftData inverse to read directly.
    private func recordsReferencing<T: PersistentModel>(
        _ type: T.Type,
        where predicate: (T) -> Bool
    ) throws -> [T] {
        try modelContext.fetch(FetchDescriptor<T>()).filter(predicate)
    }

    // MARK: - Global Search

    /// Searches title/name and the most relevant free-text fields of
    /// every real, persisted record across all nine entity types.
    /// An empty or whitespace-only query returns no results — a real
    /// empty state, not a "show everything" fallback. Nothing here is
    /// fake, hardcoded, or a placeholder.
    func globalSearch(_ query: String) throws -> [GlobalSearchResult] {

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var results: [GlobalSearchResult] = []

        let papers = try modelContext.fetch(FetchDescriptor<PaperRecord>())
        for paper in papers where
            paper.title.localizedCaseInsensitiveContains(trimmed) ||
            paper.authors.localizedCaseInsensitiveContains(trimmed) ||
            paper.abstractText.localizedCaseInsensitiveContains(trimmed) ||
            paper.tagsText.localizedCaseInsensitiveContains(trimmed)
        {
            results.append(result(for: paper))
        }

        let notes = try modelContext.fetch(FetchDescriptor<ResearchNote>())
        for note in notes where
            note.title.localizedCaseInsensitiveContains(trimmed) ||
            note.content.localizedCaseInsensitiveContains(trimmed) ||
            note.tagsText.localizedCaseInsensitiveContains(trimmed)
        {
            results.append(result(for: note))
        }

        let findings = try modelContext.fetch(FetchDescriptor<LiteratureFinding>())
        for finding in findings where
            finding.title.localizedCaseInsensitiveContains(trimmed) ||
            finding.content.localizedCaseInsensitiveContains(trimmed)
        {
            results.append(result(for: finding))
        }

        let gaps = try modelContext.fetch(FetchDescriptor<ResearchGap>())
        for gap in gaps where
            gap.title.localizedCaseInsensitiveContains(trimmed) ||
            gap.descriptionText.localizedCaseInsensitiveContains(trimmed) ||
            gap.evidence.localizedCaseInsensitiveContains(trimmed)
        {
            results.append(result(for: gap))
        }

        let problems = try modelContext.fetch(FetchDescriptor<ResearchProblem>())
        for problem in problems where
            problem.title.localizedCaseInsensitiveContains(trimmed) ||
            problem.problemStatement.localizedCaseInsensitiveContains(trimmed) ||
            problem.researchQuestion.localizedCaseInsensitiveContains(trimmed)
        {
            results.append(result(for: problem))
        }

        let ideas = try modelContext.fetch(FetchDescriptor<ResearchIdea>())
        for idea in ideas where
            idea.title.localizedCaseInsensitiveContains(trimmed) ||
            idea.summary.localizedCaseInsensitiveContains(trimmed) ||
            idea.descriptionText.localizedCaseInsensitiveContains(trimmed)
        {
            results.append(result(for: idea))
        }

        let experiments = try modelContext.fetch(FetchDescriptor<Experiment>())
        for experiment in experiments where
            experiment.name.localizedCaseInsensitiveContains(trimmed) ||
            experiment.objective.localizedCaseInsensitiveContains(trimmed) ||
            experiment.hypothesis.localizedCaseInsensitiveContains(trimmed) ||
            experiment.dataset.localizedCaseInsensitiveContains(trimmed)
        {
            results.append(result(for: experiment))
        }

        let projects = try modelContext.fetch(FetchDescriptor<ResearchProject>())
        for project in projects where
            project.name.localizedCaseInsensitiveContains(trimmed) ||
            project.descriptionText.localizedCaseInsensitiveContains(trimmed)
        {
            results.append(result(for: project))
        }

        let writingDocuments = try modelContext.fetch(FetchDescriptor<WritingDocument>())
        for document in writingDocuments where
            document.title.localizedCaseInsensitiveContains(trimmed)
        {
            results.append(result(for: document))
        }

        return results
    }


    // =========================================================
    // MARK: - RELATED RESEARCH — PHASE 12
    // =========================================================

    // One method per entity type. Each only reports relationships
    // that already exist on the record; several are stored one-way
    // (e.g. an Experiment references its Papers but a PaperRecord has
    // no inverse array back to Experiments), so those directions are
    // resolved with `recordsReferencing` instead of a stored property.

    func relatedResearch(for paper: PaperRecord) throws -> [RelatedGroup] {
        let experiments = try recordsReferencing(Experiment.self) {
            $0.papers.contains { $0.id == paper.id }
        }
        let writingDocuments = try recordsReferencing(WritingDocument.self) {
            $0.papers.contains { $0.id == paper.id }
        }
        let projects = try recordsReferencing(ResearchProject.self) {
            $0.papers.contains { $0.id == paper.id }
        }

        return [
            RelatedGroup(label: "Findings", items: paper.literatureFindings.map(result(for:))),
            RelatedGroup(label: "Research Gaps", items: paper.linkedResearchGaps.map(result(for:))),
            RelatedGroup(label: "Research Problems", items: paper.linkedResearchProblems.map(result(for:))),
            RelatedGroup(label: "Research Ideas", items: paper.linkedResearchIdeas.map(result(for:))),
            RelatedGroup(label: "Experiments", items: experiments.map(result(for:))),
            RelatedGroup(label: "Writing", items: writingDocuments.map(result(for:))),
            RelatedGroup(label: "Projects", items: projects.map(result(for:)))
        ].filter { !$0.items.isEmpty }
    }

    func relatedResearch(for finding: LiteratureFinding) throws -> [RelatedGroup] {
        let writingDocuments = try recordsReferencing(WritingDocument.self) {
            $0.findings.contains { $0.id == finding.id }
        }
        let projects = try recordsReferencing(ResearchProject.self) {
            $0.findings.contains { $0.id == finding.id }
        }

        return [
            RelatedGroup(label: "Supporting Papers", items: finding.supportingPapers.map(result(for:))),
            RelatedGroup(label: "Research Gaps", items: finding.researchGaps.map(result(for:))),
            RelatedGroup(label: "Writing", items: writingDocuments.map(result(for:))),
            RelatedGroup(label: "Projects", items: projects.map(result(for:)))
        ].filter { !$0.items.isEmpty }
    }

    func relatedResearch(for gap: ResearchGap) throws -> [RelatedGroup] {
        let experiments = try recordsReferencing(Experiment.self) {
            $0.gaps.contains { $0.id == gap.id }
        }
        let writingDocuments = try recordsReferencing(WritingDocument.self) {
            $0.gaps.contains { $0.id == gap.id }
        }
        let projects = try recordsReferencing(ResearchProject.self) {
            $0.gaps.contains { $0.id == gap.id }
        }

        return [
            RelatedGroup(label: "Papers", items: gap.papers.map(result(for:))),
            RelatedGroup(label: "Findings", items: gap.findings.map(result(for:))),
            RelatedGroup(label: "Research Problems", items: gap.linkedProblems.map(result(for:))),
            RelatedGroup(label: "Research Ideas", items: gap.linkedIdeas.map(result(for:))),
            RelatedGroup(label: "Experiments", items: experiments.map(result(for:))),
            RelatedGroup(label: "Writing", items: writingDocuments.map(result(for:))),
            RelatedGroup(label: "Projects", items: projects.map(result(for:)))
        ].filter { !$0.items.isEmpty }
    }

    func relatedResearch(for problem: ResearchProblem) throws -> [RelatedGroup] {
        let experiments = try recordsReferencing(Experiment.self) {
            $0.problems.contains { $0.id == problem.id }
        }
        let writingDocuments = try recordsReferencing(WritingDocument.self) {
            $0.problems.contains { $0.id == problem.id }
        }
        let projects = try recordsReferencing(ResearchProject.self) {
            $0.problems.contains { $0.id == problem.id }
        }

        return [
            RelatedGroup(label: "Research Gaps", items: problem.gaps.map(result(for:))),
            RelatedGroup(label: "Papers", items: problem.papers.map(result(for:))),
            RelatedGroup(label: "Research Ideas", items: problem.linkedIdeas.map(result(for:))),
            RelatedGroup(label: "Experiments", items: experiments.map(result(for:))),
            RelatedGroup(label: "Writing", items: writingDocuments.map(result(for:))),
            RelatedGroup(label: "Projects", items: projects.map(result(for:)))
        ].filter { !$0.items.isEmpty }
    }

    func relatedResearch(for idea: ResearchIdea) throws -> [RelatedGroup] {
        let experiments = try recordsReferencing(Experiment.self) {
            $0.ideas.contains { $0.id == idea.id }
        }
        let writingDocuments = try recordsReferencing(WritingDocument.self) {
            $0.ideas.contains { $0.id == idea.id }
        }
        let projects = try recordsReferencing(ResearchProject.self) {
            $0.ideas.contains { $0.id == idea.id }
        }

        return [
            RelatedGroup(label: "Research Problems", items: idea.problems.map(result(for:))),
            RelatedGroup(label: "Research Gaps", items: idea.gaps.map(result(for:))),
            RelatedGroup(label: "Papers", items: idea.papers.map(result(for:))),
            RelatedGroup(label: "Research Notes", items: idea.notes.map(result(for:))),
            RelatedGroup(label: "Experiments", items: experiments.map(result(for:))),
            RelatedGroup(label: "Writing", items: writingDocuments.map(result(for:))),
            RelatedGroup(label: "Projects", items: projects.map(result(for:)))
        ].filter { !$0.items.isEmpty }
    }

    func relatedResearch(for experiment: Experiment) throws -> [RelatedGroup] {
        let writingDocuments = try recordsReferencing(WritingDocument.self) {
            $0.experiments.contains { $0.id == experiment.id }
        }
        let projects = try recordsReferencing(ResearchProject.self) {
            $0.experiments.contains { $0.id == experiment.id }
        }

        return [
            RelatedGroup(label: "Research Ideas", items: experiment.ideas.map(result(for:))),
            RelatedGroup(label: "Research Problems", items: experiment.problems.map(result(for:))),
            RelatedGroup(label: "Research Gaps", items: experiment.gaps.map(result(for:))),
            RelatedGroup(label: "Papers", items: experiment.papers.map(result(for:))),
            RelatedGroup(label: "Research Notes", items: experiment.notes.map(result(for:))),
            RelatedGroup(label: "Writing", items: writingDocuments.map(result(for:))),
            RelatedGroup(label: "Projects", items: projects.map(result(for:)))
        ].filter { !$0.items.isEmpty }
    }

    func relatedResearch(for document: WritingDocument) -> [RelatedGroup] {
        [
            RelatedGroup(label: "Research Problems", items: document.problems.map(result(for:))),
            RelatedGroup(label: "Research Ideas", items: document.ideas.map(result(for:))),
            RelatedGroup(label: "Research Gaps", items: document.gaps.map(result(for:))),
            RelatedGroup(label: "Experiments", items: document.experiments.map(result(for:))),
            RelatedGroup(label: "Papers", items: document.papers.map(result(for:))),
            RelatedGroup(label: "Research Notes", items: document.notes.map(result(for:))),
            RelatedGroup(label: "Findings", items: document.findings.map(result(for:)))
        ].filter { !$0.items.isEmpty }
    }

    func relatedResearch(for project: ResearchProject) -> [RelatedGroup] {
        [
            RelatedGroup(label: "Papers", items: project.papers.map(result(for:))),
            RelatedGroup(label: "Research Notes", items: project.notes.map(result(for:))),
            RelatedGroup(label: "Findings", items: project.findings.map(result(for:))),
            RelatedGroup(label: "Research Gaps", items: project.gaps.map(result(for:))),
            RelatedGroup(label: "Research Problems", items: project.problems.map(result(for:))),
            RelatedGroup(label: "Research Ideas", items: project.ideas.map(result(for:))),
            RelatedGroup(label: "Experiments", items: project.experiments.map(result(for:))),
            RelatedGroup(label: "Writing", items: project.writingDocuments.map(result(for:)))
        ].filter { !$0.items.isEmpty }
    }
}
