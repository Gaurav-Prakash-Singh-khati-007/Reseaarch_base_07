//
//  BibValidatorTests.swift
//  ResearchBase
//
//  Created by Gaurav Khati on 21/10/26.
//


//
//  BibValidatorTests.swift
//  ResearchBaseTests
//
//  Owner: Agent 25 · Features: L-06
//
//  Pure text in, plain values out: no library, no files, no network.
//

import XCTest
@testable import ResearchBase

@MainActor
final class BibValidatorTests: XCTestCase {

    // MARK: Fixtures

    private let goodArticle = """
    @article{smith2020word,
      author  = {Smith, Jane and Lee, Wei},
      title   = {A Study of Words},
      journal = {Journal of Words},
      year    = {2020},
      doi     = {10.1000/xyz123}
    }
    """

    private func kinds(_ report: BibValidationReport) -> [BibIssueKind] {
        report.issues.map(\.kind)
    }

    private func issues(_ report: BibValidationReport, _ kind: BibIssueKind) -> [BibIssue] {
        report.issues.filter { $0.kind == kind }
    }

    // MARK: Parsing

    func testCleanEntryHasNoIssues() {
        let report = BibValidator.validate(goodArticle)

        XCTAssertEqual(report.entryCount, 1)
        XCTAssertTrue(report.isClean, report.issues.map(\.message).joined(separator: "; "))
        XCTAssertEqual(report.entries[0].status, .ok)
        XCTAssertEqual(report.entries[0].key, "smith2020word")
        XCTAssertEqual(report.entries[0].type, "article")
        XCTAssertEqual(report.entries[0].value(of: "TITLE"), "A Study of Words")
        XCTAssertTrue(report.summary.contains("1 entry"))
    }

    func testParsesBracesQuotesNumbersAndConcatenation() {
        let text = """
        @string{jw = "Journal of Words"}
        @article{a2020,
          author = "Smith, Jane",
          title = {A {Nested} Title},
          journal = jw,
          year = 2020,
          month = jan # "~1",
        }
        """

        let report = BibValidator.validate(text)
        let entry = report.entries[0]

        XCTAssertEqual(entry.value(of: "author"), "Smith, Jane")
        XCTAssertEqual(entry.value(of: "title"), "A {Nested} Title")
        XCTAssertEqual(entry.value(of: "journal"), "Journal of Words")
        XCTAssertEqual(entry.value(of: "year"), "2020")
        XCTAssertEqual(entry.value(of: "month"), "jan~1")
        XCTAssertTrue(report.isClean, report.issues.map(\.message).joined(separator: "; "))
    }

    func testIgnoresCommentsPreambleAndTextBetweenEntries() {
        let text = """
        This file is mine. Write to me@example.com for questions.
        @comment{ @article{ignored, title = {x}} }
        @preamble{ "\\newcommand{\\noopsort}[1]{}" }
        \(goodArticle)
        """

        let report = BibValidator.validate(text)

        XCTAssertEqual(report.entryCount, 1)
        XCTAssertEqual(report.entries[0].key, "smith2020word")
    }

    func testParenthesesAreAllowedAsEntryDelimiters() {
        let report = BibValidator.validate("@misc(note2020, title = {Hello})")

        XCTAssertEqual(report.entryCount, 1)
        XCTAssertEqual(report.entries[0].key, "note2020")
        XCTAssertTrue(report.isClean)
    }

    func testByteOrderMarkIsIgnored() {
        let report = BibValidator.validate("\u{FEFF}" + goodArticle)

        XCTAssertEqual(report.entryCount, 1)
    }

    func testLineNumbersAreOneBasedAndPointAtTheRightPlace() {
        let text = """
        % header

        @article{a,
          author = {A, B},
          title = {T},
          journal = {J},
          year = {20x0}
        }
        """

        let report = BibValidator.validate(text)

        XCTAssertEqual(report.entries[0].line, 3)
        XCTAssertEqual(report.entries[0].endLine, 8)
        XCTAssertEqual(issues(report, .badYear).first?.line, 7)
    }

    func testEmptyTextGivesAnEmptyCleanReport() {
        let report = BibValidator.validate("")

        XCTAssertEqual(report.entryCount, 0)
        XCTAssertTrue(report.isClean)
        XCTAssertEqual(report.summary, "0 entries, nothing to fix.")
    }

    // MARK: Syntax errors

    func testUnclosedEntryIsAnErrorAndLaterEntriesAreStillFound() {
        let text = """
        @article{broken,
          author = {Smith, Jane},
          title = {Never closed

        @article{fine2020,
          author = {Lee, Wei},
          title = {Fine},
          journal = {J},
          year = {2020}
        }
        """

        let report = BibValidator.validate(text)

        XCTAssertFalse(report.isBuildable)
        XCTAssertTrue(report.issues.contains { $0.kind == .syntax && $0.severity == .error })
        XCTAssertTrue(report.entries.contains { $0.key == "fine2020" })
    }

    func testMissingCommaBetweenFieldsIsReportedButBothFieldsAreKept() {
        let text = """
        @article{a2020,
          author = {Smith, Jane}
          title = {Missing comma above},
          journal = {J},
          year = {2020}
        }
        """

        let report = BibValidator.validate(text)

        XCTAssertEqual(issues(report, .syntax).count, 1)
        XCTAssertTrue(report.entries[0].has("author"))
        XCTAssertTrue(report.entries[0].has("title"))
    }

    func testFieldWithoutEqualsSignIsReported() {
        let report = BibValidator.validate("""
        @misc{a2020,
          title {No equals},
          year = {2020}
        }
        """)

        XCTAssertEqual(issues(report, .syntax).count, 1)
        XCTAssertEqual(report.entries.first?.value(of: "year"), "2020")
    }

    func testUndefinedStringNameIsAnError() {
        let report = BibValidator.validate("""
        @article{a2020,
          author = {A, B}, title = {T}, year = {2020},
          journal = nosuchmacro
        }
        """)

        let found = issues(report, .undefinedString)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.severity, .error)
        XCTAssertEqual(found.first?.field, "journal")
    }

    func testMonthNamesNeedNoDefinition() {
        let report = BibValidator.validate("""
        @misc{a2020, title = {T}, month = mar, year = {2020}}
        """)

        XCTAssertTrue(issues(report, .undefinedString).isEmpty)
    }

    // MARK: Keys

    func testMissingKeyIsAnError() {
        let report = BibValidator.validate("@misc{, title = {T}}")

        XCTAssertEqual(issues(report, .missingKey).count, 1)
        XCTAssertEqual(report.entries[0].status, .broken)
    }

    func testIllegalKeyCharactersAreErrors() {
        let report = BibValidator.validate("@misc{my key, title = {T}}\n@misc{a#b, title = {T}}")

        XCTAssertEqual(issues(report, .invalidKey).count, 2)
        XCTAssertTrue(issues(report, .invalidKey).allSatisfy { $0.severity == .error })
    }

    func testAccentedKeyIsOnlyAWarning() {
        let report = BibValidator.validate("@misc{müller2020, title = {T}}")

        let found = issues(report, .invalidKey)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.severity, .warning)
    }

    func testDuplicateKeysAreErrorsAndCaseOnlyDifferencesAreCaught() {
        let report = BibValidator.validate("""
        @misc{same, title = {One}}
        @misc{same, title = {Two}}
        @misc{Other, title = {Three}}
        @misc{other, title = {Four}}
        """)

        let duplicates = issues(report, .duplicateKey)
        XCTAssertEqual(duplicates.count, 2)
        XCTAssertEqual(duplicates.map(\.line), [2, 4])
        XCTAssertTrue(duplicates[1].message.contains("letter case"))
        XCTAssertTrue(duplicates.allSatisfy { $0.severity == .error })
    }

    // MARK: Required fields

    func testMissingRequiredFieldsAreWarningsAndListedOnTheEntry() {
        let report = BibValidator.validate("""
        @article{a2020,
          author = {Smith, Jane},
          title = {T}
        }
        """)

        let missing = issues(report, .missingField)
        XCTAssertEqual(missing.count, 2)
        XCTAssertEqual(Set(missing.compactMap(\.field)), ["journal", "year"])
        XCTAssertTrue(missing.allSatisfy { $0.severity == .warning })
        XCTAssertEqual(report.entries[0].status, .incomplete)
        XCTAssertEqual(report.entries[0].missingFields, ["journal", "year"])
        XCTAssertTrue(report.isBuildable)
        XCTAssertFalse(report.isClean)
    }

    func testAlternativesSatisfyRequirements() {
        let report = BibValidator.validate("""
        @article{a2020,
          author = {A, B}, title = {T},
          journaltitle = {J}, date = {2020-05-17}
        }
        @book{b2020, editor = {A, B}, title = {T}, publisher = {P}, year = {2020}}
        """)

        XCTAssertTrue(report.isClean, report.issues.map(\.message).joined(separator: "; "))
    }

    func testEmptyRequiredFieldIsReportedAsEmptyNotMissing() {
        let report = BibValidator.validate("""
        @article{a2020,
          author = {}, title = {T}, journal = {J}, year = {2020}
        }
        """)

        XCTAssertEqual(issues(report, .emptyField).count, 1)
        XCTAssertEqual(issues(report, .missingField).count, 0)
        XCTAssertEqual(report.entries[0].missingFields, ["author"])
    }

    func testEmptyOptionalFieldIsAWarning() {
        let report = BibValidator.validate("""
        @misc{a2020, title = {T}, note = {   }}
        """)

        let found = issues(report, .emptyField)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.field, "note")
    }

    func testMiscNeedsNothingAndUnknownTypesAreFlagged() {
        let report = BibValidator.validate("@misc{a, }\n@spaceship{b, title = {T}}")

        XCTAssertTrue(issues(report, .missingField).isEmpty)
        XCTAssertEqual(issues(report, .unknownType).count, 1)
        XCTAssertEqual(issues(report, .unknownType).first?.line, 2)
    }

    func testCrossrefSuppliesInheritedFields() {
        let report = BibValidator.validate("""
        @inproceedings{paper2020,
          author = {A, B}, title = {T}, crossref = {conf2020}
        }
        @proceedings{conf2020,
          title = {Proceedings of Things}, year = {2020}, booktitle = {Things}
        }
        """)

        XCTAssertTrue(issues(report, .missingField).isEmpty, report.issues.map(\.message).joined(separator: "; "))
        XCTAssertTrue(issues(report, .missingCrossref).isEmpty)
    }

    func testCrossrefToNothingIsAWarning() {
        let report = BibValidator.validate("""
        @inproceedings{paper2020,
          author = {A, B}, title = {T}, booktitle = {B}, year = {2020}, crossref = {nowhere}
        }
        """)

        XCTAssertEqual(issues(report, .missingCrossref).count, 1)
    }

    // MARK: Values

    func testRepeatedFieldIsAWarning() {
        let report = BibValidator.validate("""
        @misc{a2020, title = {One}, title = {Two}}
        """)

        XCTAssertEqual(issues(report, .duplicateField).count, 1)
        XCTAssertEqual(report.entries[0].value(of: "title"), "One")
    }

    func testOddYearsAreWarnedAndWordYearsAreFine() {
        func yearIssues(_ year: String) -> Int {
            let report = BibValidator.validate("@misc{a, title = {T}, year = {\(year)}}")
            return issues(report, .badYear).count
        }

        XCTAssertEqual(yearIssues("2020"), 0)
        XCTAssertEqual(yearIssues("2020a"), 0)
        XCTAssertEqual(yearIssues("in press"), 0)
        XCTAssertEqual(yearIssues("forthcoming"), 0)
        XCTAssertEqual(yearIssues("20"), 1)
        XCTAssertEqual(yearIssues("two thousand"), 1)
        XCTAssertEqual(yearIssues("1066"), 1)
        XCTAssertEqual(yearIssues("2999"), 1)
    }

    func testDOIChecks() {
        func result(_ doi: String) -> (kind: BibIssueSeverity?, count: Int) {
            let report = BibValidator.validate("@misc{a, title = {T}, doi = {\(doi)}}")
            let found = issues(report, .badDOI)
            return (found.first?.severity, found.count)
        }

        XCTAssertEqual(result("10.1038/nature12373").count, 0)
        XCTAssertEqual(result("https://doi.org/10.1038/nature12373").kind, .info)
        XCTAssertEqual(result("not a doi").kind, .warning)
    }

    func testAuthorListProblems() {
        func count(_ authors: String) -> Int {
            let report = BibValidator.validate("@misc{a, title = {T}, author = {\(authors)}}")
            return issues(report, .badAuthors).count
        }

        XCTAssertEqual(count("Smith, Jane and Lee, Wei"), 0)
        XCTAssertEqual(count("Smith, Jane and others"), 0)
        XCTAssertEqual(count("{World Health Organization}"), 0)
        XCTAssertEqual(count("Smith, Jane and"), 1)
        XCTAssertEqual(count("and Smith, Jane"), 1)
        XCTAssertEqual(count("Smith, Jane and and Lee, Wei"), 1)
        XCTAssertEqual(count("Smith, Jane; Lee, Wei"), 1)
        XCTAssertEqual(count("Smith, J., Lee, W., Park, K."), 1)
    }

    func testUnescapedSpecialCharactersAreWarned() {
        func count(_ title: String) -> Int {
            let report = BibValidator.validate("@misc{a, title = {\(title)}}")
            return issues(report, .specialCharacter).count
        }

        XCTAssertEqual(count("Plain title"), 0)
        XCTAssertEqual(count("Up 50% in a year"), 1)
        XCTAssertEqual(count("Up 50\\% in a year"), 0)
        XCTAssertEqual(count("Tom & Jerry"), 1)
        XCTAssertEqual(count("Tom \\& Jerry"), 0)
        XCTAssertEqual(count("The $O(n)$ bound"), 0)
        XCTAssertEqual(count("Costs $5 today"), 1)
    }

    func testUrlsMayContainPercentAndAmpersand() {
        let report = BibValidator.validate("@misc{a, title = {T}, url = {https://x.org/a?b=1&c=2%20d}}")

        XCTAssertTrue(issues(report, .specialCharacter).isEmpty)
    }

    // MARK: Cited keys

    func testCitedKeysNotInTheFileAreErrorsAndUncitedEntriesAreInfo() {
        let text = """
        @misc{used2020, title = {Used}}
        @misc{unused2020, title = {Unused}}
        """

        let report = BibValidator.validate(text, citedKeys: ["used2020", "ghost2020"])

        let missing = issues(report, .citedKeyMissing)
        XCTAssertEqual(missing.count, 1)
        XCTAssertEqual(missing.first?.entryKey, "ghost2020")
        XCTAssertEqual(missing.first?.line, 0)
        XCTAssertEqual(missing.first?.severity, .error)

        let uncited = issues(report, .uncitedEntry)
        XCTAssertEqual(uncited.count, 1)
        XCTAssertEqual(uncited.first?.entryKey, "unused2020")
        XCTAssertEqual(uncited.first?.severity, .info)
    }

    func testCitedKeyMatchingIgnoresLetterCase() {
        let report = BibValidator.validate("@misc{Smith2020, title = {T}}", citedKeys: ["smith2020"])

        XCTAssertTrue(issues(report, .citedKeyMissing).isEmpty)
        XCTAssertTrue(issues(report, .uncitedEntry).isEmpty)
    }

    func testNoCitedKeysMeansNoCitationChecks() {
        let report = BibValidator.validate("@misc{a, title = {T}}")

        XCTAssertTrue(issues(report, .citedKeyMissing).isEmpty)
        XCTAssertTrue(issues(report, .uncitedEntry).isEmpty)
    }

    func testWholeFileIssuesSortLast() {
        let report = BibValidator.validate("@misc{a, title = {T}, year = {20}}", citedKeys: ["ghost"])

        XCTAssertEqual(report.issues.last?.kind, .citedKeyMissing)
    }

    // MARK: Report helpers

    func testIssuesCanBeLookedUpByKeyAndLine() {
        let report = BibValidator.validate("""
        @article{Smith2020, author = {A, B}}
        @misc{other, title = {T}}
        """)

        XCTAssertFalse(report.issues(forKey: "smith2020").isEmpty)
        XCTAssertTrue(report.issues(forKey: "other").isEmpty)
        XCTAssertFalse(report.issues(onLine: 1).isEmpty)
        XCTAssertTrue(report.issues(onLine: 2).isEmpty)
    }

    func testWorstSeverityByLinePicksTheWorst() {
        let report = BibValidator.validate("""
        @misc{dup, title = {One}}
        @misc{dup, title = {Two}, year = {20}}
        """)

        let byLine = report.worstSeverityByLine
        XCTAssertEqual(byLine[2], .error)
        XCTAssertNil(byLine[1])
    }

    func testIssueIdsAreUniqueAndStableBetweenRuns() {
        let text = """
        @article{a, author = {A, B}}
        @article{a, author = {A, B}}
        """

        let first = BibValidator.validate(text).issues.map(\.id)
        let second = BibValidator.validate(text).issues.map(\.id)

        XCTAssertEqual(first, second)
        XCTAssertEqual(Set(first).count, first.count)
    }

    func testRequiredFieldGroupsAndKnownTypesArePublic() {
        XCTAssertEqual(BibValidator.requiredFieldGroups(for: "MISC"), [])
        XCTAssertEqual(BibValidator.requiredFieldGroups(for: "inproceedings").count, 4)
        XCTAssertTrue(BibValidator.isKnownEntryType("Article"))
        XCTAssertTrue(BibValidator.isKnownEntryType("mvbook"))
        XCTAssertFalse(BibValidator.isKnownEntryType("spaceship"))
    }

    func testSummaryCountsErrorsAndWarnings() {
        let report = BibValidator.validate("""
        @misc{dup, title = {One}}
        @misc{dup, title = {Two}, year = {20}}
        """)

        XCTAssertEqual(report.errorCount, 1)
        XCTAssertEqual(report.warningCount, 1)
        XCTAssertEqual(report.summary, "1 error, 1 warning in 2 entries.")
    }

    // MARK: Files

    func testValidateFileReadsUTF8AndFallsBackToLatin1() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("BibValidatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }

        let utf8 = folder.appendingPathComponent("utf8.bib")
        try "@misc{a2020, title = {Café}}".write(to: utf8, atomically: true, encoding: .utf8)

        let latin1 = folder.appendingPathComponent("latin1.bib")
        try XCTUnwrap("@misc{b2020, title = {Café}}".data(using: .isoLatin1)).write(to: latin1)

        XCTAssertEqual(try BibValidator.validateFile(at: utf8).entries.first?.value(of: "title"), "Café")
        XCTAssertEqual(try BibValidator.validateFile(at: latin1).entries.first?.value(of: "title"), "Café")

        XCTAssertThrowsError(try BibValidator.validateFile(at: folder.appendingPathComponent("missing.bib")))
    }

    // MARK: Speed

    func testAThousandEntriesIsFast() {
        var text = ""
        for n in 0..<1_000 {
            text += """
            @article{key\(n),
              author = {Smith, Jane and Lee, Wei},
              title = {Title number \(n)},
              journal = {Journal},
              year = {2020}
            }

            """
        }

        measure {
            let report = BibValidator.validate(text)
            XCTAssertEqual(report.entryCount, 1_000)
            XCTAssertTrue(report.isClean)
        }
    }
}