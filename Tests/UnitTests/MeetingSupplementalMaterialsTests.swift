import AppKit
import PDFKit
import XCTest
@testable import ClawGate

final class MeetingSupplementalMaterialsTests: XCTestCase {
    private var root: URL!
    private var service: MeetingSupplementalMaterials!
    private let meetingID = "mtg-test-materials"

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        service = MeetingSupplementalMaterials(store: MeetingStore(root: root))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testTextMaterialPersistsAndAllowsNoteAndIncludedUpdate() throws {
        let created = try service.addText("decision: ship", name: "Notes", note: "initial", meetingID: meetingID)
        XCTAssertEqual(service.load(meetingID: meetingID).first?.sections.first?.text, "decision: ship")
        var changed = created
        changed.note = "reviewed"
        changed.included = false
        try service.update(changed, meetingID: meetingID)
        let loaded = try XCTUnwrap(service.load(meetingID: meetingID).first)
        XCTAssertEqual(loaded.note, "reviewed")
        XCTAssertFalse(loaded.included)
        XCTAssertEqual(loaded.sections, created.sections)
    }

    func testImportTextCopiesOriginalAndRemoveCleansIt() throws {
        let source = root.appendingPathComponent("agenda.md")
        try Data("# Agenda\n- launch".utf8).write(to: source)
        let material = try service.importFile(source, meetingID: meetingID)
        XCTAssertEqual(material.status, .ready)
        XCTAssertNotNil(service.originalURL(for: material, meetingID: meetingID))
        try service.remove(id: material.id, meetingID: meetingID)
        XCTAssertTrue(service.load(meetingID: meetingID).isEmpty)
        XCTAssertNil(service.originalURL(for: material, meetingID: meetingID))
    }

    func testPathTraversalMeetingIDDoesNotReadOrWrite() throws {
        XCTAssertThrowsError(try service.addText("x", name: "x", note: "", meetingID: "../escape"))
        XCTAssertThrowsError(try service.addText("x", name: "x", note: "", meetingID: "."))
        XCTAssertTrue(service.load(meetingID: "../escape").isEmpty)
    }

    func testSectionIDsAreMaterialScoped() throws {
        let first = try service.addText("one", name: "one", note: "", meetingID: meetingID)
        let second = try service.addText("two", name: "two", note: "", meetingID: meetingID)
        XCTAssertNotEqual(first.sections[0].id, second.sections[0].id)
        XCTAssertTrue(first.sections[0].id.hasPrefix("mat-\(first.id.lowercased())-"))
        XCTAssertTrue(second.sections[0].id.hasPrefix("mat-\(second.id.lowercased())-"))
    }

    func testLargeDocxDoesNotDeadlockPipe() throws {
        let work = root.appendingPathComponent("docx"); try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let word = work.appendingPathComponent("word"); try FileManager.default.createDirectory(at: word, withIntermediateDirectories: true)
        let payload = String(repeating: "x", count: 70_000)
        try Data("<w:document xmlns:w=\"urn\"><w:body><w:p><w:r><w:t>\(payload)</w:t></w:r></w:p></w:body></w:document>".utf8).write(to: word.appendingPathComponent("document.xml"))
        let archive = root.appendingPathComponent("large.docx"); let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); process.currentDirectoryURL = work; process.arguments = ["-qr", archive.path, "word"]; try process.run(); process.waitUntilExit()
        let material = try service.importFile(archive, meetingID: meetingID)
        XCTAssertEqual(material.status, .ready)
        XCTAssertEqual(material.sections.first?.text.count, 70_000)
    }
    func testPresentationOrderAndRelationshipLinkedNotes() throws {
        let work = root.appendingPathComponent("deck")
        let files = [
            "ppt/presentation.xml": "<p:presentation xmlns:p='urn:p' xmlns:r='urn:r'><p:sldIdLst><p:sldId r:id='second'/><p:sldId r:id='first'/></p:sldIdLst></p:presentation>",
            "ppt/_rels/presentation.xml.rels": "<Relationships><Relationship Target='slides/slide1.xml' Id='first'/><Relationship Target='slides/slide2.xml' Id='second'/></Relationships>",
            "ppt/slides/slide1.xml": "<a:p xmlns:a='urn:a'><a:r><a:t>First file</a:t></a:r></a:p>",
            "ppt/slides/slide2.xml": "<a:p xmlns:a='urn:a'><a:r><a:t>First shown</a:t></a:r></a:p>",
            "ppt/slides/_rels/slide2.xml.rels": "<Relationships><Relationship Id='note' Type='urn:rel/notesSlide' Target='../notesSlides/notesSlide7.xml'/></Relationships>",
            "ppt/notesSlides/notesSlide7.xml": "<a:p xmlns:a='urn:a'><a:r><a:t>Correct related note</a:t></a:r></a:p>"
        ]
        for (path, text) in files {
            let url = work.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        let archive = root.appendingPathComponent("deck.pptx")
        let zip = Process(); zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = work; zip.arguments = ["-qr", archive.path, "ppt"]
        try zip.run(); zip.waitUntilExit(); XCTAssertEqual(zip.terminationStatus, 0)
        let material = try service.importFile(archive, meetingID: meetingID)
        XCTAssertTrue(material.sections[0].text.hasPrefix("First shown"))
        XCTAssertTrue(material.sections[0].text.contains("Correct related note"))
        XCTAssertEqual(material.sections[1].text, "First file")
    }

    func testImageAndScannedPDFUseTextRecognition() throws {
        let image = NSImage(size: NSSize(width: 1000, height: 250))
        image.lockFocus()
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1000, height: 250).fill()
        ("MEETING AGENDA" as NSString).draw(at: NSPoint(x: 40, y: 100),
            withAttributes: [.font: NSFont.systemFont(ofSize: 64), .foregroundColor: NSColor.black])
        image.unlockFocus()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
        let png = root.appendingPathComponent("agenda.png")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: png)
        let picture = try service.importFile(png, meetingID: meetingID)
        XCTAssertTrue(picture.sections.map(\.text).joined().contains("MEETING AGENDA"))
        let doc = PDFDocument(); doc.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        let pdf = root.appendingPathComponent("scan.pdf")
        try XCTUnwrap(doc.dataRepresentation()).write(to: pdf)
        let scan = try service.importFile(pdf, meetingID: meetingID)
        XCTAssertTrue(scan.sections.map(\.text).joined().contains("MEETING AGENDA"))
        XCTAssertEqual(scan.sections.first?.locator, "page:1")
    }

}
