import Foundation
import PDFKit
import Vision
import ImageIO

/// Local, user-provided context for one meeting. Originals never leave the
/// meeting directory and are not uploaded by this type.
struct MeetingSupplementalMaterial: Codable, Equatable, Identifiable {
    enum Status: String, Codable { case ready, partial, failed }
    struct Section: Codable, Equatable, Identifiable {
        let id: String
        let locator: String
        let text: String
    }
    let id: String
    let name: String
    var note: String
    var included: Bool
    let status: Status
    let error: String?
    let sections: [Section]
    let addedAt: Date
    let originalRelativePath: String?
}

struct MeetingSupplementalMaterials {
    enum Error: Swift.Error, LocalizedError {
        case emptyText, unsupportedType, tooLarge, unreadable, invalidMeetingID, extractionLimit
        var errorDescription: String? {
            switch self { case .emptyText: return "補足の本文が空です"; case .unsupportedType: return "このファイル形式には対応していません"; case .tooLarge: return "ファイルは50MB以下で追加してください"; case .unreadable: return "資料を読み取れませんでした"; case .invalidMeetingID: return "会議の識別子が不正です"; case .extractionLimit: return "読み取り上限に達しました。資料を分割してください" }
        }
    }

    private let store: MeetingStore
    private let fm = FileManager.default
    private let maxBytes = 50 * 1024 * 1024
    private let maxCharacters = 1_000_000
    private let maxSections = 500
    private static let manifestLock = NSLock()

    init(store: MeetingStore = MeetingStore()) { self.store = store }

    func load(meetingID: String) -> [MeetingSupplementalMaterial] {
        guard validID(meetingID) else { return [] }
        let url = manifestURL(meetingID)
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let values = try? decoder.decode([MeetingSupplementalMaterial].self, from: data) else { return [] }
        return values
    }

    @discardableResult
    func importFile(_ url: URL, meetingID: String) throws -> MeetingSupplementalMaterial {
        guard validID(meetingID) else { throw Error.invalidMeetingID }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) <= maxBytes else { throw Error.tooLarge }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let ext = url.pathExtension.lowercased()
        // Callers that own a UI queue should invoke this API asynchronously.
        let extracted = try extract(data: data, ext: ext)
        let id = UUID().uuidString
        let stamped = stamp(extracted, materialID: id)
        let safeName = sanitizedFilename(url.lastPathComponent)
        let relative = "supplemental-originals/\(id)-\(safeName)"
        let destination = store.directory(for: meetingID).appendingPathComponent(relative)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
        let material = MeetingSupplementalMaterial(id: id, name: url.lastPathComponent, note: "", included: true,
            status: stamped.status, error: stamped.error, sections: stamped.sections,
            addedAt: Date(), originalRelativePath: relative)
        Self.manifestLock.lock(); defer { Self.manifestLock.unlock() }
        var all = load(meetingID: meetingID); all.append(material); try save(all, meetingID: meetingID)
        return material
    }

    @discardableResult
    func addText(_ text: String, name: String, note: String, meetingID: String) throws -> MeetingSupplementalMaterial {
        guard validID(meetingID) else { throw Error.invalidMeetingID }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw Error.emptyText }
        guard clean.count <= maxCharacters else { throw Error.extractionLimit }
        let materialID = UUID().uuidString
        let material = MeetingSupplementalMaterial(id: materialID, name: name.isEmpty ? "Text" : name,
            note: note, included: true, status: .ready, error: nil,
            sections: [MeetingSupplementalMaterial.Section(id: "mat-\(materialID.lowercased())-0", locator: "text", text: clean)], addedAt: Date(), originalRelativePath: nil)
        Self.manifestLock.lock(); defer { Self.manifestLock.unlock() }
        var all = load(meetingID: meetingID); all.append(material); try save(all, meetingID: meetingID); return material
    }

    func update(_ material: MeetingSupplementalMaterial, meetingID: String) throws {
        guard validID(meetingID) else { throw Error.invalidMeetingID }
        Self.manifestLock.lock(); defer { Self.manifestLock.unlock() }
        var all = load(meetingID: meetingID); guard let index = all.firstIndex(where: { $0.id == material.id }) else { throw Error.unreadable }
        let old = all[index]
        guard material.sections == old.sections, material.name == old.name, material.status == old.status,
              material.error == old.error, abs(material.addedAt.timeIntervalSince(old.addedAt)) < 1,
              material.originalRelativePath == old.originalRelativePath else { throw Error.unreadable }
        all[index].note = material.note; all[index].included = material.included; try save(all, meetingID: meetingID)
    }

    func remove(id: String, meetingID: String) throws {
        guard validID(meetingID) else { throw Error.invalidMeetingID }
        Self.manifestLock.lock(); defer { Self.manifestLock.unlock() }
        var all = load(meetingID: meetingID); guard let material = all.first(where: { $0.id == id }) else { return }
        all.removeAll { $0.id == id }; try save(all, meetingID: meetingID)
        if let url = safeOriginalURL(material, meetingID: meetingID) { try? fm.removeItem(at: url) }
    }

    func originalURL(for material: MeetingSupplementalMaterial, meetingID: String) -> URL? {
        guard validID(meetingID), let url = safeOriginalURL(material, meetingID: meetingID) else { return nil }
        return fm.fileExists(atPath: url.path) ? url : nil
    }

    private func save(_ values: [MeetingSupplementalMaterial], meetingID: String) throws {
        try fm.createDirectory(at: store.directory(for: meetingID), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(values).write(to: manifestURL(meetingID), options: .atomic)
    }
    private func manifestURL(_ id: String) -> URL { store.directory(for: id).appendingPathComponent("supplemental-materials.json") }
    private func validID(_ id: String) -> Bool { !id.isEmpty && id != "." && id != ".." && id.range(of: "^[A-Za-z0-9_-]+(?:\\.[A-Za-z0-9_-]+)*$", options: .regularExpression) != nil }
    private func safeOriginalURL(_ material: MeetingSupplementalMaterial, meetingID: String) -> URL? {
        guard validID(meetingID), let relative = material.originalRelativePath, relative.hasPrefix("supplemental-originals/"), !relative.contains("..") else { return nil }
        let root = store.directory(for: meetingID).appendingPathComponent("supplemental-originals", isDirectory: true).standardizedFileURL
        let url = store.directory(for: meetingID).appendingPathComponent(relative).standardizedFileURL
        return url.path.hasPrefix(root.path + "/") ? url : nil
    }
    private func sanitizedFilename(_ value: String) -> String { let base = URL(fileURLWithPath: value).lastPathComponent; return base.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression) }

    private struct Extraction { let status: MeetingSupplementalMaterial.Status; let error: String?; let sections: [MeetingSupplementalMaterial.Section] }
    private func stamp(_ extraction: Extraction, materialID: String) -> Extraction {
        var used = 0; var out: [MeetingSupplementalMaterial.Section] = []; var limited = false
        for (index, section) in extraction.sections.prefix(maxSections).enumerated() {
            guard used < maxCharacters else { limited = true; break }
            let remaining = maxCharacters - used; let text = String(section.text.prefix(remaining)); used += text.count
            if text.count < section.text.count { limited = true }
            out.append(.init(id: "mat-\(materialID.lowercased())-\(index)", locator: section.locator, text: text))
        }
        if extraction.sections.count > maxSections { limited = true }
        let partial = extraction.status == .ready && limited ? .partial : extraction.status
        let error = limited ? Error.extractionLimit.localizedDescription : extraction.error
        return Extraction(status: partial, error: error, sections: out)
    }
    private func extract(data: Data, ext: String) throws -> Extraction {
        if ["txt", "md", "markdown", "text"].contains(ext) { return textExtraction(String(decoding: data, as: UTF8.self)) }
        if ext == "pdf" { return pdfExtraction(data) }
        if ["png", "jpg", "jpeg", "heic"].contains(ext) { return imageExtraction(data) }
        if ext == "docx" || ext == "pptx" { return try officeExtraction(data, presentation: ext == "pptx") }
        throw Error.unsupportedType
    }
    private func textExtraction(_ text: String) -> Extraction {
        let clean = String(text.prefix(maxCharacters)); let truncated = text.count > clean.count
        guard !clean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return Extraction(status: .failed, error: Error.emptyText.localizedDescription, sections: []) }
        return Extraction(status: truncated ? .partial : .ready, error: truncated ? Error.extractionLimit.localizedDescription : nil,
            sections: [MeetingSupplementalMaterial.Section(id: "pending", locator: "text", text: clean)])
    }
    private func imageExtraction(_ data: Data) -> Extraction {
        guard let image = CGImageSourceCreateWithData(data as CFData, nil), let cg = CGImageSourceCreateImageAtIndex(image, 0, nil) else { return Extraction(status: .failed, error: Error.unreadable.localizedDescription, sections: []) }
        do { let text = try recognize(cg); return text.isEmpty ? Extraction(status: .partial, error: "Image contained no readable text (charts/diagrams may be present)", sections: []) : textExtraction(text) }
        catch { return Extraction(status: .failed, error: String(describing: error), sections: []) }
    }
    private func pdfExtraction(_ data: Data) -> Extraction {
        guard let doc = PDFDocument(data: data) else { return Extraction(status: .failed, error: Error.unreadable.localizedDescription, sections: []) }
        var sections: [MeetingSupplementalMaterial.Section] = []; var failed = false
        for index in 0..<min(doc.pageCount, maxSections) {
            guard let page = doc.page(at: index) else { failed = true; continue }
            let direct = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var text = direct
            if text.isEmpty {
                let thumbnail = page.thumbnail(of: CGSize(width: 1600, height: 1600), for: .mediaBox)
                var rect = CGRect.zero
                if let image = thumbnail.cgImage(forProposedRect: &rect, context: nil, hints: nil) { text = (try? recognize(image)) ?? "" }
            }
            if !text.isEmpty { sections.append(.init(id: "page-\(index + 1)", locator: "page:\(index + 1)", text: text)) } else { failed = true }
        }
        if sections.isEmpty { return Extraction(status: .failed, error: Error.unreadable.localizedDescription, sections: []) }
        let capped = doc.pageCount > maxSections
        return Extraction(status: failed || capped ? .partial : .ready, error: failed ? "Some pages contained no readable text" : (capped ? Error.extractionLimit.localizedDescription : nil), sections: sections)
    }
    private func recognize(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.usesLanguageCorrection = true
        let supported = try request.supportedRecognitionLanguages()
        request.recognitionLanguages = ["ja-JP", "en-US"].filter { supported.contains($0) }
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    private func officeExtraction(_ data: Data, presentation: Bool) throws -> Extraction {
        let temp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip"); defer { try? fm.removeItem(at: temp) }; try data.write(to: temp)
        let listed = try unzipList(temp).filter { presentation ? ($0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml")) : ($0 == "word/document.xml") }
        let names = presentation ? presentationOrder(temp, fallback: listed) : listed
        guard !names.isEmpty else { throw Error.unreadable }
        var sections: [MeetingSupplementalMaterial.Section] = []
        var incomplete = false
        for (index, name) in names.prefix(maxSections).enumerated() {
            let xml = try unzip(temp, name: name)
            var text = XMLTextParser.parse(xml)
            let xmlText = String(decoding: xml, as: UTF8.self)
            if xmlText.contains("<a:blip") || xmlText.contains("graphicData") || text.isEmpty { incomplete = true }
            if presentation {
                let n = naturalNumber(name)
                if let rel = try? unzip(temp, name: "ppt/slides/_rels/slide\(n).xml.rels"), let noteName = XMLRelationshipParser.notesTarget(rel) {
                    if let note = try? unzip(temp, name: noteName) { let noteText = XMLTextParser.parse(note); if !noteText.isEmpty { text += "\nSpeaker notes: " + noteText } }
                }
            }
            if !text.isEmpty { sections.append(.init(id: "section-\(index)", locator: name, text: text)) }
        }
        guard !sections.isEmpty else { return Extraction(status: .failed, error: Error.unreadable.localizedDescription, sections: []) }
        return Extraction(status: incomplete || names.count > maxSections ? .partial : .ready, error: names.count > maxSections ? Error.extractionLimit.localizedDescription : (incomplete ? "図・画像など文字だけでは読み取れない部分があります" : nil), sections: sections)
    }
    private func unzipList(_ zip: URL) throws -> [String] { try runUnzip(["-Z1", zip.path]).split(separator: "\n").map(String.init) }
    private func unzip(_ zip: URL, name: String) throws -> Data { try runUnzipData(["-p", zip.path, name]) }
    private func runUnzip(_ args: [String]) throws -> String { String(decoding: try runUnzipData(args), as: UTF8.self) }
    private func runUnzipData(_ args: [String]) throws -> Data {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice; try p.run()
        let timeout = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeout)
        var data = Data(); var exceeded = false
        while p.isRunning {
            let chunk = out.fileHandleForReading.readData(ofLength: 64 * 1024); if chunk.isEmpty { continue }
            let room = max(0, 8 * 1024 * 1024 - data.count); data.append(chunk.prefix(room)); if chunk.count > room { exceeded = true; if p.isRunning { p.terminate() } }
        }
        while true { let chunk = out.fileHandleForReading.readData(ofLength: 64 * 1024); if chunk.isEmpty { break }; let room = max(0, 8 * 1024 * 1024 - data.count); data.append(chunk.prefix(room)); if chunk.count > room { exceeded = true; if p.isRunning { p.terminate() } } }
        p.waitUntilExit(); timeout.cancel(); guard p.terminationStatus == 0, !exceeded else { throw exceeded ? Error.extractionLimit : Error.unreadable }; return data
    }
    private func naturalNumber(_ name: String) -> Int {
        guard let match = name.range(of: "[0-9]+", options: .regularExpression) else { return 0 }
        return Int(name[match]) ?? 0
    }
    private func presentationOrder(_ zip: URL, fallback: [String]) -> [String] {
        guard let presentation = try? unzip(zip, name: "ppt/presentation.xml"), let rels = try? unzip(zip, name: "ppt/_rels/presentation.xml.rels") else { return fallback.sorted { naturalNumber($0) < naturalNumber($1) } }
        let ids = XMLSlideOrderParser.ids(presentation)
        let targets = XMLRelationshipParser.targets(rels)
        let ordered = ids.compactMap { targets[$0] }.map { target in
            target.hasPrefix("/") ? String(target.dropFirst()) : "ppt/" + target
        }.filter { fallback.contains($0) }
        return ordered + fallback.filter { !ordered.contains($0) }.sorted { naturalNumber($0) < naturalNumber($1) }
    }
}

private final class XMLTextParser: NSObject, XMLParserDelegate {
    private var text = ""; private var active = false
    static func parse(_ data: Data) -> String { let parser = XMLParser(data: data); let delegate = XMLTextParser(); parser.delegate = delegate; guard parser.parse() else { return "" }; return delegate.text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines) }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) { active = elementName == "t" || elementName == "a:t" || elementName.hasSuffix(":t") }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if active { text += string } }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { if elementName == "p" || elementName.hasSuffix(":p") { text += "\n" }; active = false }
}

private final class XMLRelationshipParser: NSObject, XMLParserDelegate {
    private var values: [String: String] = [:]
    private var note: String?
    static func targets(_ data: Data) -> [String: String] {
        let parser = XMLParser(data: data); let delegate = XMLRelationshipParser(); parser.delegate = delegate
        return parser.parse() ? delegate.values : [:]
    }
    static func notesTarget(_ data: Data) -> String? {
        let parser = XMLParser(data: data); let delegate = XMLRelationshipParser(); parser.delegate = delegate
        guard parser.parse(), let target = delegate.note else { return nil }
        let base = URL(fileURLWithPath: "/ppt/slides/")
        let resolved = URL(fileURLWithPath: target, relativeTo: base).standardizedFileURL.path
        guard resolved.hasPrefix("/ppt/notesSlides/") else { return nil }
        return String(resolved.dropFirst())
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes attrs: [String: String]) {
        guard name.hasSuffix("Relationship"), attrs["TargetMode"] != "External", let id = attrs["Id"], let target = attrs["Target"] else { return }
        values[id] = target
        if attrs["Type"]?.hasSuffix("/notesSlide") == true { note = target }
    }
}

private final class XMLSlideOrderParser: NSObject, XMLParserDelegate {
    private var order: [String] = []
    static func ids(_ data: Data) -> [String] {
        let parser = XMLParser(data: data); let delegate = XMLSlideOrderParser(); parser.delegate = delegate
        return parser.parse() ? delegate.order : []
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes attrs: [String: String]) {
        if name == "sldId" || name.hasSuffix(":sldId"), let id = attrs["r:id"] { order.append(id) }
    }
}
