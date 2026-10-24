//
//  LatexSuggestionSourcesTests.swift
//  ResearchBase
//
//  Created by Gaurav Khati on 24/10/26.
//


//
//  LatexSuggestionSourcesTests.swift
//  ResearchBaseTests
//
//  Owner: Agent 39. Tests for the extra suggestion sources in LatexEditorView.swift:
//  names the draft defines itself, and packages read from a TeX `ls-R` listing.
//  Nothing here looks at the real TeX install of the machine running the tests.
//

import XCTest
@testable import ResearchBase

final class LatexSuggestionSourcesTests: XCTestCase {

    typealias A = LatexAutocomplete

    private func context(_ text: String) -> LatexCompletionContext? {
        A.completionContext(in: text, caret: (text as NSString).length)
    }

    // MARK: Defined commands

    func testDefinedCommandsFindsTheNewcommandFamily() {
        let text = #"""
        \newcommand{\Rn}{\mathbb{R}}
        \renewcommand\vecx[1]{\mathbf{#1}}
        \providecommand*{\mynorm}[1]{\lVert #1 \rVert}
        \DeclareMathOperator*{\argminx}{arg\,min}
        \def\oldstyle{x}
        """#
        XCTAssertEqual(A.definedCommands(in: text), ["Rn", "vecx", "mynorm", "argminx", "oldstyle"])
    }

    func testDefinedCommandsSkipCommentsAndDuplicates() {
        let text = #"""
        % \newcommand{\hidden}{}
        \newcommand{\shown}{}
        \renewcommand{\shown}{again}
        """#
        XCTAssertEqual(A.definedCommands(in: text), ["shown"])
    }

    func testDefaultIsNotMistakenForADefinition() {
        XCTAssertEqual(A.definedCommands(in: #"\default and \defaultfont"#), [])
    }

    // MARK: Defined environments

    func testDefinedEnvironments() {
        let text = #"""
        \newenvironment{boxed}{\begin{center}}{\end{center}}
        \newtheorem{claim}{Claim}
        \newtheorem*{fact}{Fact}
        \declaretheorem[style=plain]{remarkx}
        % \newtheorem{ignored}{Ignored}
        """#
        XCTAssertEqual(A.definedEnvironments(in: text), ["boxed", "claim", "fact", "remarkx"])
    }

    // MARK: In the suggestion lists

    func testCommandListIncludesTheDraftsOwnCommand() throws {
        let text = "\\newcommand{\\secretsauce}{x}\n\\secr"
        let c = try XCTUnwrap(context(text))
        XCTAssertTrue(A.nameSuggestions(for: c, in: text).contains("secretsauce"))
    }

    func testTheNameBeingTypedIsNotOfferedBackToTheUser() throws {
        let text = "\\def\\myc"
        let c = try XCTUnwrap(context(text))
        XCTAssertFalse(A.nameSuggestions(for: c, in: text).contains("myc"))
    }

    func testEnvironmentListIncludesTheDraftsOwnTheorem() throws {
        let text = "\\newtheorem{claim}{Claim}\n\\begin{cl"
        let c = try XCTUnwrap(context(text))
        XCTAssertTrue(A.nameSuggestions(for: c, in: text).contains("claim"))
    }

    func testPackageListUsesInstalledPackagesWhenGiven() throws {
        let text = "\\usepackage{zzfake"
        let c = try XCTUnwrap(context(text))
        XCTAssertFalse(A.nameSuggestions(for: c, in: text).contains("zzfakepkg"))
        XCTAssertTrue(A.nameSuggestions(for: c, in: text, installedPackages: ["zzfakepkg"]).contains("zzfakepkg"))
    }

    func testFixedPackagesStillOfferedWithInstalledOnes() throws {
        let text = "\\usepackage{amsm"
        let c = try XCTUnwrap(context(text))
        let names = A.nameSuggestions(for: c, in: text, installedPackages: ["amsmath", "amsmodern"])
        XCTAssertEqual(names.filter { $0 == "amsmath" }.count, 1, "no duplicates")
        XCTAssertTrue(names.contains("amsmodern"))
    }

    // MARK: ls-R listing

    func testParseListingKeepsOnlyLatexStyleFiles() {
        let listing = """
        %% ls-R -- filename database for kpathsea; do not change this line.
        ./:
        ls-R

        ./tex/latex/amsmath:
        amsmath.sty
        amsmath.dtx
        README

        ./tex/latex/foo/sub:
        foo-sub.sty
        .hidden.sty

        ./tex/generic/bar:
        bar.sty

        ./doc/latex/baz:
        baz.sty
        """
        XCTAssertEqual(LatexInstalledPackages.parseListing(listing), ["amsmath", "foo-sub"])
    }

    func testParseListingOfEmptyTextIsEmpty() {
        XCTAssertEqual(LatexInstalledPackages.parseListing(""), [])
    }

    func testNothingLoadedYetMeansAnEmptyList() {
        // A brand-new instance has not scanned anything.
        XCTAssertEqual(LatexInstalledPackages().packageNames, [])
    }
}