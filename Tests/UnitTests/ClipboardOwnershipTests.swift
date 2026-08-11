import XCTest
import AppKit
@testable import ClawGate

final class ClipboardOwnershipTests: XCTestCase {
    private let watcher = ClipboardWatcher.shared
    private let pasteboard = NSPasteboard.general

    override func setUp() {
        super.setUp()
        watcher.stop()
        watcher.onOffer = nil
        pasteboard.clearContents()
    }

    override func tearDown() {
        watcher.stop()
        watcher.onOffer = nil
        pasteboard.clearContents()
        super.tearDown()
    }

    func testOwnedTemporaryWriteAndRestoreEmitNoClipboardOffer() {
        var offers = 0
        watcher.onOffer = { _ in offers += 1 }
        pasteboard.setString("https://example.com/original", forType: .string)
        let saved = pasteboard.string(forType: .string)

        watcher.start()
        let ownedChangeCount = AXActions.writeTemporaryClipboardForTesting(
            "https://example.com/temporary",
            pasteboard: pasteboard
        )
        watcher.checkForTesting()
        _ = AXActions.restoreClipboardIfUnchangedForTesting(
            savedText: saved,
            expectedChangeCount: ownedChangeCount,
            pasteboard: pasteboard
        )
        watcher.checkForTesting()

        XCTAssertEqual(pasteboard.string(forType: .string), saved)
        XCTAssertEqual(offers, 0)
    }

    func testUserCopyBeforeRestoreIsPreservedAndOfferedOnce() {
        var offers = 0
        watcher.onOffer = { _ in offers += 1 }
        pasteboard.setString("https://example.com/original", forType: .string)
        let saved = pasteboard.string(forType: .string)

        watcher.start()
        let ownedChangeCount = AXActions.writeTemporaryClipboardForTesting(
            "https://example.com/temporary",
            pasteboard: pasteboard
        )
        watcher.checkForTesting()

        pasteboard.clearContents()
        pasteboard.setString("https://example.com/user-copy", forType: .string)
        watcher.checkForTesting()
        XCTAssertFalse(AXActions.restoreClipboardIfUnchangedForTesting(
            savedText: saved,
            expectedChangeCount: ownedChangeCount,
            pasteboard: pasteboard
        ))
        watcher.checkForTesting()

        XCTAssertEqual(pasteboard.string(forType: .string), "https://example.com/user-copy")
        XCTAssertEqual(offers, 1)
    }

    func testStopAndStartClearOwnedStateBeforeNextUserCopy() {
        var offers = 0
        watcher.onOffer = { _ in offers += 1 }
        watcher.start()
        _ = AXActions.writeTemporaryClipboardForTesting(
            "https://example.com/stale-owned",
            pasteboard: pasteboard
        )
        watcher.stop()
        watcher.start()

        pasteboard.clearContents()
        pasteboard.setString("https://example.com/user-copy", forType: .string)
        watcher.checkForTesting()
        watcher.checkForTesting()

        XCTAssertEqual(offers, 1)
    }

    func testOwnedMutationBlocksConcurrentCheckUntilRegistration() {
        var offers = 0
        watcher.onOffer = { _ in offers += 1 }
        watcher.start()

        let mutationStarted = DispatchSemaphore(value: 0)
        let allowMutation = DispatchSemaphore(value: 0)
        let mutationFinished = DispatchSemaphore(value: 0)
        let checkFinished = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            _ = self.watcher.performOwnedMutation(on: self.pasteboard) {
                self.pasteboard.clearContents()
                mutationStarted.signal()
                _ = allowMutation.wait(timeout: .now() + 2)
                self.pasteboard.setString("https://example.com/atomic", forType: .string)
            }
            mutationFinished.signal()
        }

        XCTAssertEqual(mutationStarted.wait(timeout: .now() + 2), .success)
        DispatchQueue.global().async {
            self.watcher.checkForTesting()
            checkFinished.signal()
        }
        XCTAssertEqual(checkFinished.wait(timeout: .now() + 0.1), .timedOut)

        allowMutation.signal()
        XCTAssertEqual(mutationFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(checkFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(offers, 0)
    }

    func testConcurrentOwnedMutationAndCheckStressRemainsOfferFree() {
        watcher.start()
        let group = DispatchGroup()

        for index in 0..<100 {
            group.enter()
            DispatchQueue.global().async {
                _ = self.watcher.performOwnedMutation(on: self.pasteboard) {
                    self.pasteboard.clearContents()
                    self.pasteboard.setString("https://example.com/owned-\(index)", forType: .string)
                }
                group.leave()
            }
            group.enter()
            DispatchQueue.global().async {
                self.watcher.checkForTesting()
                group.leave()
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        watcher.checkForTesting()
    }

    func testC3OwnedCallsitesUseAtomicMutationWithoutRegisterGap() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for relativePath in [
            "ClawGate/Automation/AX/AXActions.swift",
            "ClawGate/UI/Pet/PetModel.swift",
            "ClawGate/UI/Pet/PetBubbleView.swift",
        ] {
            let source = try String(
                contentsOf: root.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            XCTAssertTrue(
                source.contains("performOwnedMutation") || source.contains("writeOwnedString"),
                "missing atomic API in \(relativePath)"
            )
            XCTAssertFalse(source.contains("registerOwnedCurrentChange"), "registration gap remains in \(relativePath)")
        }
    }

    func testProductionGeneralPasteboardWritesUseAtomicOwnership() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ClawGate")
        let allowedFiles: Set<String> = [
            "ClawGate/Core/ClipboardWatcher.swift",
            "ClawGate/Automation/AX/AXActions.swift",
        ]
        let mutationTokens = [
            "clearContents(",
            "setString(",
            "setData(",
            "writeObjects(",
            "declareTypes(",
        ]
        let files = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        )?.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        let offenders = files.filter { file in
            let relative = file.path.replacingOccurrences(of: root.deletingLastPathComponent().path + "/", with: "")
            return !allowedFiles.contains(relative)
        }.flatMap { file -> [String] in
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { return [] }
            return source.split(separator: "\n").enumerated().compactMap { index, line in
                mutationTokens.contains { line.contains($0) }
                    ? "\(file.path):\(index + 1)"
                    : nil
            }
        }
        XCTAssertTrue(offenders.isEmpty, "direct general pasteboard writes: \(offenders)")
    }
}
