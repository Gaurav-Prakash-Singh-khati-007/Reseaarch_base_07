//
//  ZoteroMendeleyImporterTests.swift
//  ResearchBase
//
//  Created by Gaurav Khati on 20/10/26.
//


//
//  ZoteroMendeleyImporterTests.swift
//  ResearchBaseTests
//
//  Owner: Agent 12 · F-19
//

import XCTest
import SQLite3
@testable import ResearchBase

final class ZoteroMendeleyImporterTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("rbA12test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Helpers

    private func makeDatabase(named name: String, sql: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "?"
            sqlite3_free(error)
            XCTFail("SQL failed: \(message)")
        }
        return url
    }

    // MARK: CSL JSON

    func testCSLJSON() {
        let json = """
        [
          {"id": "a1", "type": "article-journal", "title": "Deep Learning",
           "author": [{"family": "Smith", "given": "Jane"}, {"family": "Gogh", "given": "Vincent", "non-dropping-particle": "van"}],
           "editor": [{"literal": "The Society"}],
           "issued": {"date-parts": [[2020, 5]]}, "container-title": "Nature",
           "volume": 5, "issue": "2", "page": "10-20", "DOI": "10.1000/ABC"},
          {"id": "a2", "type": "article", "title": "A Preprint", "author": [{"family": "Lee", "given": "Ann"}],
           "issued": {"raw": "2023-01-02"}, "archive": "arXiv", "archive_location": "2301.12345"},
          {"id": "a3", "type": "podcast-episode", "author": [{"family": "X"}]}
        ]
        """
        let r = ZoteroMendeleyImporter.parse(cslJSON: Data(json.utf8))
        XCTAssertEqual(r.format, .cslJSON)
        XCTAssertEqual(r.entryCount, 2)
        XCTAssertEqual(r.skipped.count, 1)

        let a = r.entries[0]
        XCTAssertEqual(a.sourceID, "a1")
        XCTAssertEqual(a.item.type, .article)
        XCTAssertEqual(a.item.year, 2020)
        XCTAssertEqual(a.item.volume, "5")
        XCTAssertEqual(a.item.doi, "10.1000/abc")
        XCTAssertEqual(a.item.creators.map(\.family), ["Smith", "van Gogh", "The Society"])
        XCTAssertEqual(a.item.creators[2].role, .editor)
        XCTAssertTrue(a.item.creators[2].isOrganisation)
        XCTAssertEqual(a.item.sourceKind, .import)
        XCTAssertEqual(a.item.reviewState, .inbox)

        let b = r.entries[1]
        XCTAssertEqual(b.item.type, .preprint)
        XCTAssertEqual(b.item.arxivID, "2301.12345")
        XCTAssertEqual(b.item.year, 2023)
    }

    func testCSLInvalid() {
        XCTAssertEqual(ZoteroMendeleyImporter.parse(cslJSON: Data("not json".utf8)).skipped.count, 1)
        XCTAssertEqual(ZoteroMendeleyImporter.parse(cslJSON: Data("[]".utf8)).entryCount, 0)
    }

    // MARK: Zotero RDF

    func testZoteroRDF() throws {
        let rdf = """
        <?xml version="1.0"?>
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
         xmlns:z="http://www.zotero.org/namespaces/export#" xmlns:dc="http://purl.org/dc/elements/1.1/"
         xmlns:dcterms="http://purl.org/dc/terms/" xmlns:bib="http://purl.org/net/biblio#"
         xmlns:foaf="http://xmlns.com/foaf/0.1/" xmlns:prism="http://prismstandard.org/namespaces/1.2/basic/"
         xmlns:link="http://purl.org/rss/1.0/modules/link/">
          <bib:Article rdf:about="https://doi.org/10.1000/abc">
            <z:itemType>journalArticle</z:itemType>
            <dcterms:isPartOf><bib:Journal><prism:volume>5</prism:volume><prism:number>2</prism:number><dc:title>Nature</dc:title></bib:Journal></dcterms:isPartOf>
            <bib:authors><rdf:Seq>
              <rdf:li><foaf:Person><foaf:surname>Smith</foaf:surname><foaf:givenName>Jane</foaf:givenName></foaf:Person></rdf:li>
              <rdf:li><foaf:Person><foaf:surname>Doe</foaf:surname><foaf:givenName>John</foaf:givenName></foaf:Person></rdf:li>
            </rdf:Seq></bib:authors>
            <dc:title>Deep Learning</dc:title>
            <dc:date>2020-05-12</dc:date>
            <dc:identifier><dcterms:URI><rdf:value>https://doi.org/10.1000/abc</rdf:value></dcterms:URI></dc:identifier>
            <dc:identifier>DOI 10.1000/ABC</dc:identifier>
            <dcterms:abstract>An abstract.</dcterms:abstract>
            <dc:subject>ml</dc:subject>
            <link:link rdf:resource="#item_2"/>
          </bib:Article>
          <z:Attachment rdf:about="#item_2">
            <z:itemType>attachment</z:itemType>
            <rdf:resource rdf:resource="files/2/paper.pdf"/>
            <dc:title>PDF</dc:title>
          </z:Attachment>
          <bib:Memo rdf:about="#item_3"><z:itemType>note</z:itemType><rdf:value>a note</rdf:value></bib:Memo>
        </rdf:RDF>
        """
        let base = URL(fileURLWithPath: "/tmp/export")
        let r = ZoteroMendeleyImporter.parse(zoteroRDF: Data(rdf.utf8), baseURL: base)
        XCTAssertEqual(r.entryCount, 1)
        let e = r.entries[0]
        XCTAssertEqual(e.item.title, "Deep Learning")
        XCTAssertEqual(e.item.type, .article)
        XCTAssertEqual(e.item.venue, "Nature")
        XCTAssertEqual(e.item.volume, "5")
        XCTAssertEqual(e.item.issue, "2")
        XCTAssertEqual(e.item.year, 2020)
        XCTAssertEqual(e.item.doi, "10.1000/abc")
        XCTAssertEqual(e.item.url, "https://doi.org/10.1000/abc")
        XCTAssertEqual(e.item.abstract, "An abstract.")
        XCTAssertEqual(e.item.creators.map(\.family), ["Smith", "Doe"])
        XCTAssertEqual(e.tags, ["ml"])
        XCTAssertEqual(e.attachmentHints, ["/tmp/export/files/2/paper.pdf"])
        XCTAssertTrue(e.warnings.isEmpty)
    }

    func testBrokenXML() {
        let r = ZoteroMendeleyImporter.parse(zoteroRDF: Data("not xml at all".utf8))
        XCTAssertEqual(r.entryCount, 0)
        XCTAssertFalse(r.skipped.isEmpty)
    }

    // MARK: Zotero library

    private let zoteroSQL = """
    CREATE TABLE items (itemID INTEGER PRIMARY KEY, itemTypeID INT, "key" TEXT);
    CREATE TABLE itemTypes (itemTypeID INTEGER PRIMARY KEY, typeName TEXT);
    CREATE TABLE fields (fieldID INTEGER PRIMARY KEY, fieldName TEXT);
    CREATE TABLE itemDataValues (valueID INTEGER PRIMARY KEY, value TEXT);
    CREATE TABLE itemData (itemID INT, fieldID INT, valueID INT);
    CREATE TABLE creators (creatorID INTEGER PRIMARY KEY, firstName TEXT, lastName TEXT, fieldMode INT);
    CREATE TABLE creatorTypes (creatorTypeID INTEGER PRIMARY KEY, creatorType TEXT);
    CREATE TABLE itemCreators (itemID INT, creatorID INT, creatorTypeID INT, orderIndex INT);
    CREATE TABLE deletedItems (itemID INTEGER PRIMARY KEY);
    CREATE TABLE tags (tagID INTEGER PRIMARY KEY, name TEXT);
    CREATE TABLE itemTags (itemID INT, tagID INT);
    CREATE TABLE itemAttachments (itemID INTEGER PRIMARY KEY, parentItemID INT, path TEXT);

    INSERT INTO itemTypes VALUES (1, 'journalArticle'), (2, 'attachment'), (3, 'note');
    INSERT INTO fields VALUES (1, 'title'), (2, 'publicationTitle'), (3, 'date'), (4, 'DOI'), (5, 'volume');
    INSERT INTO creatorTypes VALUES (1, 'author'), (2, 'editor');

    INSERT INTO items VALUES (1, 1, 'AAAA1111'), (2, 2, 'BBBB2222'), (3, 1, 'CCCC3333'), (4, 3, 'DDDD4444');
    INSERT INTO itemDataValues VALUES (1, 'Deep Learning'), (2, 'Nature'), (3, '2020-05-12 2020-05-12'), (4, '10.1000/ABC'), (5, '7'), (6, 'Trashed paper');
    INSERT INTO itemData VALUES (1,1,1), (1,2,2), (1,3,3), (1,4,4), (1,5,5), (3,1,6);
    INSERT INTO creators VALUES (1, 'Jane', 'Smith', 0), (2, NULL, 'World Health Organization', 1);
    INSERT INTO itemCreators VALUES (1, 1, 1, 0), (1, 2, 2, 1);
    INSERT INTO deletedItems VALUES (3);
    INSERT INTO tags VALUES (1, 'ml');
    INSERT INTO itemTags VALUES (1, 1);
    INSERT INTO itemAttachments VALUES (2, 1, 'storage:paper.pdf');
    """

    func testZoteroLibraryFileAndFolder() throws {
        let url = try makeDatabase(named: "zotero.sqlite", sql: zoteroSQL)

        XCTAssertEqual(try ZoteroMendeleyImporter.detectFormat(fileAt: url), .zoteroLibrary)

        for source in [url, folder!] {
            let r = try ZoteroMendeleyImporter.parse(fileAt: source)
            XCTAssertEqual(r.format, .zoteroLibrary)
            XCTAssertEqual(r.entryCount, 1, "trashed items, notes and attachments are not items")
            let e = r.entries[0]
            XCTAssertEqual(e.sourceID, "AAAA1111")
            XCTAssertEqual(e.item.title, "Deep Learning")
            XCTAssertEqual(e.item.venue, "Nature")
            XCTAssertEqual(e.item.year, 2020)
            XCTAssertEqual(e.item.volume, "7")
            XCTAssertEqual(e.item.doi, "10.1000/abc")
            XCTAssertEqual(e.item.creators.map(\.family), ["Smith", "World Health Organization"])
            XCTAssertEqual(e.item.creators[1].role, .editor)
            XCTAssertTrue(e.item.creators[1].isOrganisation)
            XCTAssertEqual(e.tags, ["ml"])
            XCTAssertEqual(e.attachmentHints.count, 1)
            XCTAssertTrue(e.attachmentHints[0].hasSuffix("/storage/BBBB2222/paper.pdf"))
        }
    }

    // MARK: Mendeley library

    func testMendeleyLibrary() throws {
        let sql = """
        CREATE TABLE Documents (id INTEGER PRIMARY KEY, uuid TEXT, type TEXT, title TEXT, abstract TEXT, year INT,
            volume TEXT, issue TEXT, pages TEXT, publication TEXT, publisher TEXT, doi TEXT, arxiv TEXT,
            websites TEXT, deletionPending TEXT);
        CREATE TABLE DocumentContributors (id INTEGER PRIMARY KEY, documentId INT, contribution TEXT, firstNames TEXT, lastName TEXT);
        CREATE TABLE DocumentTags (documentId INT, tag TEXT);
        CREATE TABLE DocumentFiles (documentId INT, hash TEXT);
        CREATE TABLE Files (hash TEXT, localUrl TEXT);

        INSERT INTO Documents (id, uuid, type, title, year, publication, doi, deletionPending)
            VALUES (1, 'u-1', 'JournalArticle', 'Deep Learning', 2020, 'Nature', '10.1000/abc', 'false');
        INSERT INTO Documents (id, uuid, type, title, year, deletionPending)
            VALUES (2, 'u-2', 'Book', 'Gone', 2001, 'true');
        INSERT INTO Documents (id, uuid, type, title, year, deletionPending)
            VALUES (3, 'u-3', 'Hologram', 'Odd', 2002, 'false');
        INSERT INTO DocumentContributors (documentId, contribution, firstNames, lastName)
            VALUES (1, 'DocumentAuthor', 'Jane', 'Smith'), (1, 'DocumentEditor', 'Ed', 'Itor');
        INSERT INTO DocumentTags VALUES (1, 'ml');
        INSERT INTO DocumentFiles VALUES (1, 'h1');
        INSERT INTO Files VALUES ('h1', 'file:///Users/me/My%20Papers/deep.pdf');
        """
        let url = try makeDatabase(named: "me@example.com@www.mendeley.com.sqlite", sql: sql)

        XCTAssertEqual(try ZoteroMendeleyImporter.detectFormat(fileAt: url), .mendeleyLibrary)
        let r = try ZoteroMendeleyImporter.parse(fileAt: url, reviewState: .accepted)
        XCTAssertEqual(r.entryCount, 2)
        let e = r.entries[0]
        XCTAssertEqual(e.item.title, "Deep Learning")
        XCTAssertEqual(e.item.type, .article)
        XCTAssertEqual(e.item.reviewState, .accepted)
        XCTAssertEqual(e.item.creators.map(\.role), [.author, .editor])
        XCTAssertEqual(e.attachmentHints, ["/Users/me/My Papers/deep.pdf"])
        XCTAssertEqual(e.tags, ["ml"])
        XCTAssertTrue(r.entries[1].warnings.contains { $0.contains("Hologram") })
    }

    // MARK: Detection and errors

    func testDetectCSLAndRDFFiles() throws {
        let json = folder.appendingPathComponent("lib.json")
        try Data("[{\"title\":\"T\"}]".utf8).write(to: json)
        XCTAssertEqual(try ZoteroMendeleyImporter.detectFormat(fileAt: json), .cslJSON)
        XCTAssertEqual(try ZoteroMendeleyImporter.parse(fileAt: json).entryCount, 1)

        let rdf = folder.appendingPathComponent("lib.rdf")
        try Data("<?xml version=\"1.0\"?><rdf:RDF></rdf:RDF>".utf8).write(to: rdf)
        XCTAssertEqual(try ZoteroMendeleyImporter.detectFormat(fileAt: rdf), .zoteroRDF)
    }

    func testUnrecognisedAndMissingFiles() throws {
        let txt = folder.appendingPathComponent("x.txt")
        try Data("just words".utf8).write(to: txt)
        XCTAssertThrowsError(try ZoteroMendeleyImporter.detectFormat(fileAt: txt)) {
            XCTAssertEqual($0 as? ZMImportError, .unrecognisedFormat)
        }
        XCTAssertThrowsError(try ZoteroMendeleyImporter.parse(fileAt: folder.appendingPathComponent("nope.sqlite")))

        let otherDB = try makeDatabase(named: "other.sqlite", sql: "CREATE TABLE t (a INT);")
        XCTAssertThrowsError(try ZoteroMendeleyImporter.detectFormat(fileAt: otherDB)) {
            XCTAssertEqual($0 as? ZMImportError, .unrecognisedFormat)
        }
    }
}