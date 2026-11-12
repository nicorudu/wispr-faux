import AppKit
import CoreGraphics
import Testing
@testable import InsertionKit

/// A pasteboard of its own, so tests never touch the user's clipboard.
@MainActor
private func withScratchPasteboard(_ body: (NSPasteboard) async throws -> Void) async rethrows {
    let pasteboard = NSPasteboard(name: .init("com.example.wisprfaux.tests.\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    try await body(pasteboard)
}

/// A tiny 1×1 PNG, standing in for a copied image.
private let pngData: Data = {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    return rep.representation(using: .png, properties: [:])!
}()

/// Writes an image item plus a second text item, like a rich copy from some apps.
@MainActor
private func writeImageAndText(to pasteboard: NSPasteboard) {
    pasteboard.clearContents()
    let image = NSPasteboardItem()
    image.setData(pngData, forType: .png)
    image.setString("alt text", forType: .string)
    let text = NSPasteboardItem()
    text.setString("<b>hi</b>", forType: .html)
    text.setString("hi", forType: .string)
    pasteboard.writeObjects([image, text])
}

/// Stands in for the real ⌘V: records what the "focused app" would have pasted.
@MainActor
private final class FakeKeySender: PasteKeySender {
    var canPost = true
    var pasted: [String?] = []
    let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
    }

    func sendPaste() async -> CGKeyCode {
        pasted.append(pasteboard.string(forType: .string))
        return 9
    }
}

@Suite("PasteboardSnapshot")
@MainActor
struct PasteboardSnapshotTests {
    @Test func roundTripsEveryItemAndType() async {
        await withScratchPasteboard { pasteboard in
            writeImageAndText(to: pasteboard)
            let snapshot = PasteboardSnapshot(capturing: pasteboard)

            pasteboard.clearContents()
            pasteboard.setString("something else", forType: .string)
            #expect(snapshot.write(to: pasteboard))

            #expect(PasteboardSnapshot(capturing: pasteboard) == snapshot)
            #expect(pasteboard.pasteboardItems?.count == 2)
            #expect(pasteboard.pasteboardItems?.first?.data(forType: .png) == pngData)
        }
    }

    @Test func summarizesWithoutContent() async {
        await withScratchPasteboard { pasteboard in
            writeImageAndText(to: pasteboard)
            let summary = PasteboardSnapshot(capturing: pasteboard).summary

            #expect(summary.itemCount == 2)
            #expect(summary.typeCount == 4)
            #expect(summary.containsImage)
            #expect(summary.containsText)
            #expect(summary.description.hasPrefix("image, 2 items, 4 types"))
        }
    }

    @Test func skipsFilePromises() async {
        await withScratchPasteboard { pasteboard in
            pasteboard.clearContents()
            let item = NSPasteboardItem()
            item.setString("public.png", forType: .init("com.apple.pasteboard.promised-file-content-type"))
            item.setString("report.pdf", forType: .string)
            pasteboard.writeObjects([item])

            let types = PasteboardSnapshot(capturing: pasteboard).items.flatMap(\.representations).map(\.type)
            #expect(types == [.string])
        }
    }

    @Test func emptySnapshotLeavesPasteboardEmpty() async {
        await withScratchPasteboard { pasteboard in
            pasteboard.clearContents()
            let snapshot = PasteboardSnapshot(capturing: pasteboard)
            #expect(snapshot.isEmpty)
            #expect(snapshot.summary.description == "empty")

            pasteboard.setString("temporary", forType: .string)
            snapshot.write(to: pasteboard)
            #expect(pasteboard.pasteboardItems?.isEmpty ?? true)
        }
    }
}

@Suite("TextInserter")
@MainActor
struct TextInserterTests {
    @Test func pastesTextThenRestoresTheClipboard() async throws {
        try await withScratchPasteboard { pasteboard in
            writeImageAndText(to: pasteboard)
            let original = PasteboardSnapshot(capturing: pasteboard)
            let keys = FakeKeySender(pasteboard: pasteboard)
            let inserter = TextInserter(pasteboard: pasteboard, keySender: keys, restoreDelay: .seconds(60))
            inserter.verifiesRestore = true

            let report = try await inserter.insert("Hello, café ✓")

            #expect(keys.pasted == ["Hello, café ✓"])
            #expect(pasteboard.types?.contains(.transient) == true)
            #expect(report.backup == original.summary)
            #expect(!report.reusedPendingBackup)
            #expect(inserter.hasPendingRestore)

            #expect(inserter.restoreNow() == .restored(original.summary, verified: true))
            #expect(PasteboardSnapshot(capturing: pasteboard) == original)
            #expect(!inserter.hasPendingRestore)
        }
    }

    @Test func restoresOnItsOwnAfterTheDelay() async throws {
        try await withScratchPasteboard { pasteboard in
            pasteboard.clearContents()
            pasteboard.setString("user's text", forType: .string)
            let inserter = TextInserter(
                pasteboard: pasteboard, keySender: FakeKeySender(pasteboard: pasteboard), restoreDelay: .milliseconds(50)
            )
            var outcomes: [TextInserter.RestoreOutcome] = []
            inserter.onRestore = { outcomes.append($0) }

            try await inserter.insert("dictated")
            try await Task.sleep(for: .milliseconds(300))

            #expect(outcomes.count == 1)
            #expect(pasteboard.string(forType: .string) == "user's text")
        }
    }

    @Test func leavesANewCopyAlone() async throws {
        try await withScratchPasteboard { pasteboard in
            pasteboard.clearContents()
            pasteboard.setString("old", forType: .string)
            let inserter = TextInserter(
                pasteboard: pasteboard, keySender: FakeKeySender(pasteboard: pasteboard), restoreDelay: .seconds(60)
            )

            try await inserter.insert("dictated")
            // The user copies something before the restore runs.
            pasteboard.clearContents()
            pasteboard.setString("new copy", forType: .string)

            #expect(inserter.restoreNow() == .skippedClipboardChanged)
            #expect(pasteboard.string(forType: .string) == "new copy")
        }
    }

    @Test func backToBackInsertsKeepTheOriginalBackup() async throws {
        try await withScratchPasteboard { pasteboard in
            writeImageAndText(to: pasteboard)
            let original = PasteboardSnapshot(capturing: pasteboard)
            let keys = FakeKeySender(pasteboard: pasteboard)
            let inserter = TextInserter(pasteboard: pasteboard, keySender: keys, restoreDelay: .seconds(60))

            try await inserter.insert("first")
            let second = try await inserter.insert("second")

            #expect(keys.pasted == ["first", "second"])
            #expect(second.reusedPendingBackup)
            inserter.restoreNow()
            #expect(PasteboardSnapshot(capturing: pasteboard) == original)
        }
    }

    @Test func emptyClipboardStaysEmpty() async throws {
        try await withScratchPasteboard { pasteboard in
            pasteboard.clearContents()
            let inserter = TextInserter(
                pasteboard: pasteboard, keySender: FakeKeySender(pasteboard: pasteboard), restoreDelay: .seconds(60)
            )

            try await inserter.insert("dictated")
            inserter.restoreNow()

            #expect(pasteboard.pasteboardItems?.isEmpty ?? true)
        }
    }

    @Test func refusesWithoutEventAccessAndLeavesTheClipboard() async {
        await withScratchPasteboard { pasteboard in
            pasteboard.clearContents()
            pasteboard.setString("untouched", forType: .string)
            let changeCount = pasteboard.changeCount
            let keys = FakeKeySender(pasteboard: pasteboard)
            keys.canPost = false
            let inserter = TextInserter(pasteboard: pasteboard, keySender: keys, restoreDelay: .seconds(60))

            await #expect(throws: TextInserter.InsertionError.notAllowedToPostEvents) {
                try await inserter.insert("dictated")
            }
            #expect(pasteboard.changeCount == changeCount)
            #expect(keys.pasted.isEmpty)
            #expect(!inserter.isInserting)
        }
    }
}

@Suite("KeyboardLayout")
@MainActor
struct KeyboardLayoutTests {
    @Test(arguments: [
        ("com.apple.keylayout.US", CGKeyCode(9)),
        ("com.apple.keylayout.French", 9), // AZERTY: V doesn't move
        ("com.apple.keylayout.Dvorak", 47), // V sits on QWERTY's "."
        ("com.apple.keylayout.DVORAK-QWERTYCMD", 9), // QWERTY while ⌘ is held
    ])
    func findsVForLayout(_ layoutID: String, expected: CGKeyCode) {
        #expect(KeyboardLayout.keyCode(for: "v", inputSourceID: layoutID) == expected)
    }

    @Test func findsVInTheCurrentLayout() {
        #expect(KeyboardLayout.keyCode(for: "v") != nil)
    }
}
