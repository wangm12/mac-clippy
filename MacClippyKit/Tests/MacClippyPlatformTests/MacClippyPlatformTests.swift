import AppKit
import Carbon.HIToolbox
import Foundation
import XCTest

import MacClippyCore
import MacClippyPlatform

final class MacClippyPlatformTests: XCTestCase {
    func testDockFrameIsFullWidthAndBottomAnchored() {
        let frame = MacClippyDockFramePolicy.frame(
            for: CGRect(x: -1440, y: 0, width: 1440, height: 900),
            height: 340
        )

        XCTAssertEqual(frame, CGRect(x: -1440, y: 0, width: 1440, height: 340))
    }

    func testDockFrameClampsHeightToPolicyAndScreen() {
        XCTAssertEqual(
            MacClippyDockFramePolicy.frame(
                for: CGRect(x: 0, y: 0, width: 800, height: 300),
                height: 120
            ).height,
            220
        )
        XCTAssertEqual(
            MacClippyDockFramePolicy.frame(
                for: CGRect(x: 0, y: 0, width: 800, height: 200),
                height: 340
            ).height,
            200
        )
        // Upper clamp: a caller requesting more than the supported content
        // states is clamped back down to the single preferred height.
        XCTAssertEqual(
            MacClippyDockFramePolicy.frame(
                for: CGRect(x: 0, y: 0, width: 800, height: 900),
                height: 520
            ).height,
            MacClippyDockFramePolicy.preferredHeight
        )
        XCTAssertEqual(
            MacClippyDockFramePolicy.frame(
                for: CGRect(x: 0, y: 0, width: 800, height: 900)
            ).height,
            MacClippyDockFramePolicy.preferredHeight
        )
        XCTAssertEqual(
            MacClippyDockFramePolicy.frame(
                for: CGRect(x: 0, y: 0, width: 800, height: 900),
                hasMultipleSelection: true
            ).height,
            MacClippyDockFramePolicy.preferredHeight
        )
    }

    func testDisplaySelectionSupportsNegativeCoordinatesAndAdjacentBoundaries() {
        let left = CGRect(x: -1440, y: -200, width: 1440, height: 1100)
        let right = CGRect(x: 0, y: 0, width: 2560, height: 1440)

        XCTAssertEqual(
            MacClippyDisplayLayout.screenRect(containing: CGPoint(x: -100, y: 100), from: [right, left]),
            left
        )
        XCTAssertEqual(
            MacClippyDisplayLayout.screenRect(containing: CGPoint(x: 0, y: 100), from: [right, left]),
            right
        )
        XCTAssertEqual(
            MacClippyDisplayLayout.screenRect(containing: CGPoint(x: -1, y: 0), from: [right, left]),
            left
        )
    }

    func testDisplaySelectionUsesDeterministicFallback() {
        let left = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        let right = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        XCTAssertEqual(
            MacClippyDisplayLayout.screenRect(
                containing: CGPoint(x: 9000, y: 9000),
                from: [right, left],
                fallback: left
            ),
            left
        )
        XCTAssertEqual(
            MacClippyDisplayLayout.screenRect(
                containing: CGPoint(x: 9000, y: 9000),
                from: [right, left],
                fallback: nil
            ),
            left
        )
    }

    func testPreviewFrameStaysAboveDockAndInsideVisibleFrame() {
        let dock = CGRect(x: -1440, y: -900, width: 1440, height: 360)
        let visible = CGRect(x: -1440, y: -820, width: 1440, height: 790)
        let preferred = CGRect(x: -1300, y: -528, width: 440, height: 340)

        let frame = MacClippyDisplayLayout.clampedPreviewFrame(
            preferred,
            within: visible,
            above: dock
        )

        XCTAssertEqual(frame, CGRect(x: -1300, y: -528, width: 440, height: 340))
        XCTAssertTrue(frame.map { visible.contains(CGPoint(x: $0.minX, y: $0.minY)) } ?? false)
        XCTAssertTrue(frame.map { $0.minY >= dock.maxY + 12 } ?? false)
    }

    func testPreviewFrameClampsToDisplayEdges() {
        let dock = CGRect(x: -1440, y: -900, width: 1440, height: 360)
        let visible = CGRect(x: -1440, y: -820, width: 1440, height: 790)
        let preferred = CGRect(x: 2000, y: 2000, width: 440, height: 340)

        let frame = MacClippyDisplayLayout.clampedPreviewFrame(
            preferred,
            within: visible,
            above: dock
        )

        XCTAssertEqual(frame, CGRect(x: -440, y: -370, width: 440, height: 340))
        XCTAssertTrue(frame.map { visible.contains(CGPoint(x: $0.minX, y: $0.minY)) } ?? false)
        XCTAssertTrue(frame.map { visible.contains(CGPoint(x: $0.maxX - 1, y: $0.maxY - 1)) } ?? false)
    }

    func testPreviewFrameShrinksWhenVisibleFrameIsShort() {
        let dock = CGRect(x: 0, y: 0, width: 1920, height: 360)
        let visible = CGRect(x: 0, y: 360, width: 1920, height: 300)
        let preferred = CGRect(x: 740, y: 372, width: 440, height: 340)

        let frame = MacClippyDisplayLayout.clampedPreviewFrame(
            preferred,
            within: visible,
            above: dock
        )

        XCTAssertEqual(frame, CGRect(x: 740, y: 372, width: 440, height: 288))
        XCTAssertTrue(frame.map { visible.contains(CGPoint(x: $0.minX, y: $0.minY)) } ?? false)
        XCTAssertTrue(frame.map { $0.maxY <= visible.maxY } ?? false)
    }

    func testLargerQuickLookPreviewFrameStillClampsAboveDockAndInsideDisplay() {
        let dock = CGRect(x: 0, y: 0, width: 1920, height: 360)
        let visible = CGRect(x: 0, y: 0, width: 1920, height: 1200)
        let preferred = CGRect(x: 480, y: 372, width: 960, height: 720)

        let frame = MacClippyDisplayLayout.clampedPreviewFrame(
            preferred,
            within: visible,
            above: dock
        )

        XCTAssertEqual(frame, preferred)
        XCTAssertTrue(frame.map { visible.contains(CGPoint(x: $0.minX, y: $0.minY)) } ?? false)
        XCTAssertTrue(frame.map { visible.contains(CGPoint(x: $0.maxX - 1, y: $0.maxY - 1)) } ?? false)
        XCTAssertTrue(frame.map { $0.minY >= dock.maxY + 12 } ?? false)
    }

    func testDockLifecycleDismissesForEscapeAndOutsideClicks() {
        let frame = CGRect(x: 0, y: 0, width: 800, height: 360)
        XCTAssertTrue(MacClippyDockLifecyclePolicy.shouldDismissForKeyCode(53))
        XCTAssertTrue(
            MacClippyDockLifecyclePolicy.shouldDismissForOutsideClick(
                panelFrame: frame,
                clickLocation: CGPoint(x: 900, y: 200),
                ignoreUntil: .distantPast,
                now: Date()
            )
        )
        XCTAssertFalse(
            MacClippyDockLifecyclePolicy.shouldDismissForOutsideClick(
                panelFrame: frame,
                clickLocation: CGPoint(x: 900, y: 200),
                ignoreUntil: Date().addingTimeInterval(1),
                now: Date()
            )
        )
    }

    func testPlatformScaffoldImports() {
        XCTAssertEqual(MacClippyPlatform.version, MacClippyCore.version)
    }

    func testDefaultClipboardGlobalHotKeyDescriptor() {
        XCTAssertEqual(
            MacClippyGlobalHotKeyDescriptor.defaultClipboard,
            MacClippyGlobalHotKeyDescriptor(
                keyCode: UInt32(kVK_ANSI_V),
                modifiers: UInt32(cmdKey) | UInt32(shiftKey)
            )
        )
    }

    func testGlobalHotKeyDescriptorRoundTripsThroughIsolatedUserDefaults() {
        let suiteName = "MacClippyPlatformTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let descriptor = MacClippyGlobalHotKeyDescriptor(
            keyCode: UInt32(kVK_ANSI_B),
            modifiers: UInt32(cmdKey) | UInt32(optionKey)
        )

        MacClippyGlobalHotKeyDescriptor.save(descriptor, to: defaults)

        XCTAssertEqual(
            MacClippyGlobalHotKeyDescriptor.load(from: defaults),
            descriptor
        )
    }

    func testGlobalHotKeyDescriptorLoadFallsBackToDefaultForEmptyUserDefaults() {
        let suiteName = "MacClippyPlatformTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(
            MacClippyGlobalHotKeyDescriptor.load(from: defaults),
            .defaultClipboard
        )
    }

    func testSystemPasteboardReaderReadsTypesAndData() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MacClippyPlatformTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("hello", forType: .string))

        let change = SystemPasteboardReader(pasteboard: pasteboard, sourceAppBundleID: { "com.example.editor" }).read()

        XCTAssertEqual(change.items.count, 1)
        XCTAssertEqual(change.items[0].types, [NSPasteboard.PasteboardType.string.rawValue])
        XCTAssertEqual(change.items[0].string(forType: NSPasteboard.PasteboardType.string.rawValue), "hello")
        XCTAssertEqual(change.sourceAppBundleID, "com.example.editor")
    }

    func testPasteboardObserverUsesChangeCountAndExclusionRules() {
        // Safe default: concealed/transient/auto-generated UTIs are excluded.
        // Excluded app bundle IDs suppress delivery once the retry state has
        // nothing pending.
        let reader = TestPasteboardReader(change: PasteboardChange(
            changeCount: 1,
            items: [PasteboardItem(types: ["public.utf8-plain-text"], representations: ["public.utf8-plain-text": Data("first".utf8)])],
            sourceAppBundleID: "com.example.editor"
        ))
        let observer = PasteboardObserver(
            reader: reader,
            exclusionRules: CaptureExclusionRules(excludedAppBundleIDs: ["com.example.passwords"]),
            pollInterval: 1,
            retryState: MacClippyPasteboardReadRetryState(maxAttempts: 1)
        )
        var changes: [PasteboardChange] = []
        observer.start { changes.append($0) }

        observer.poll()
        XCTAssertTrue(changes.isEmpty)

        reader.change = PasteboardChange(
            changeCount: 2,
            items: [PasteboardItem(types: ["public.utf8-plain-text"], representations: ["public.utf8-plain-text": Data("second".utf8)])],
            sourceAppBundleID: "com.example.editor"
        )
        observer.poll()
        XCTAssertEqual(changes.map { $0.changeCount }, [2])

        // Excluded source app: delivery is suppressed by exclusionRules even
        // though the payload is fully available (no retry pending).
        reader.change = PasteboardChange(
            changeCount: 3,
            items: [PasteboardItem(types: ["public.utf8-plain-text"], representations: ["public.utf8-plain-text": Data("secret".utf8)])],
            sourceAppBundleID: "com.example.passwords"
        )
        observer.poll()
        XCTAssertEqual(changes.map { $0.changeCount }, [2])

        // A concealed-only change with an unavailable payload is withheld by
        // the retry state (budget=1), then suppressed by the safe default.
        reader.change = PasteboardChange(
            changeCount: 4,
            items: [PasteboardItem(types: ["org.nspasteboard.ConcealedType"])],
            sourceAppBundleID: "com.example.editor"
        )
        observer.poll()
        XCTAssertEqual(changes.map { $0.changeCount }, [2])

        observer.stop()
    }

    func testPasteboardObserverDoesNotMaterializeUnchangedContent() {
        let reader = CountingPasteboardReader(change: PasteboardChange(
            changeCount: 1,
            items: [PasteboardItem(
                types: ["public.utf8-plain-text"],
                representations: ["public.utf8-plain-text": Data("unchanged".utf8)]
            )]
        ))
        let observer = PasteboardObserver(reader: reader, pollInterval: 1)
        observer.start { _ in }
        // start() is deliberately asynchronous so a provider read cannot
        // block its caller; poll() is the serial-queue barrier for this test.
        observer.poll()

        let readsAfterStart = reader.fullReadCount
        observer.poll()

        XCTAssertEqual(reader.fullReadCount, readsAfterStart)
        XCTAssertGreaterThan(reader.changeCountReadCount, 1)

        reader.change = PasteboardChange(
            changeCount: 2,
            items: [PasteboardItem(
                types: ["public.utf8-plain-text"],
                representations: ["public.utf8-plain-text": Data("changed".utf8)]
            )]
        )
        observer.poll()
        XCTAssertEqual(reader.fullReadCount, readsAfterStart + 1)
        observer.stop()
    }

    func testPasteboardObserverUpdatesExclusionRulesWithoutRestarting() {
        let reader = TestPasteboardReader(change: PasteboardChange(
            changeCount: 1,
            items: [PasteboardItem(
                types: ["public.utf8-plain-text"],
                representations: ["public.utf8-plain-text": Data("initial".utf8)]
            )],
            sourceAppBundleID: "com.example.editor"
        ))
        let observer = PasteboardObserver(
            reader: reader,
            pollInterval: 1,
            retryState: MacClippyPasteboardReadRetryState(maxAttempts: 1)
        )
        var changes: [PasteboardChange] = []
        observer.start { changes.append($0) }
        observer.poll()

        reader.change = PasteboardChange(
            changeCount: 2,
            items: [PasteboardItem(
                types: ["public.utf8-plain-text"],
                representations: ["public.utf8-plain-text": Data("allowed".utf8)]
            )],
            sourceAppBundleID: "com.example.editor"
        )
        observer.poll()
        XCTAssertEqual(changes.map(\.changeCount), [2])

        observer.updateExclusionRules(CaptureExclusionRules(excludedAppBundleIDs: ["com.example.editor"]))
        reader.change = PasteboardChange(
            changeCount: 3,
            items: [PasteboardItem(
                types: ["public.utf8-plain-text"],
                representations: ["public.utf8-plain-text": Data("blocked".utf8)]
            )],
            sourceAppBundleID: "com.example.editor"
        )
        observer.poll()
        XCTAssertEqual(changes.map(\.changeCount), [2])

        observer.updateExclusionRules(CaptureExclusionRules())
        reader.change = PasteboardChange(
            changeCount: 4,
            items: [PasteboardItem(
                types: ["public.utf8-plain-text"],
                representations: ["public.utf8-plain-text": Data("allowed again".utf8)]
            )],
            sourceAppBundleID: "com.example.editor"
        )
        observer.poll()
        XCTAssertEqual(changes.map(\.changeCount), [2, 4])
        observer.stop()
    }

    func testPasteboardObserverAppliesRegexExclusionAndPrivacyPause() {
        let reader = TestPasteboardReader(change: PasteboardChange(
            changeCount: 1,
            items: [PasteboardItem(
                types: ["public.utf8-plain-text"],
                representations: ["public.utf8-plain-text": Data("initial".utf8)]
            )]
        ))
        let observer = PasteboardObserver(
            reader: reader,
            exclusionRules: CaptureExclusionRules(excludedTextPatterns: ["token\\s*="]),
            pollInterval: 1,
            retryState: MacClippyPasteboardReadRetryState(maxAttempts: 1)
        )
        var changes: [PasteboardChange] = []
        observer.start { changes.append($0) }
        observer.poll()

        reader.change = PasteboardChange(
            changeCount: 2,
            items: [PasteboardItem(
                types: ["public.utf8-plain-text"],
                representations: ["public.utf8-plain-text": Data("token = secret".utf8)]
            )]
        )
        observer.poll()
        XCTAssertTrue(changes.isEmpty)

        observer.updateExclusionRules(CaptureExclusionRules())
        observer.setCapturePaused(true)
        reader.change = PasteboardChange(
            changeCount: 3,
            items: [PasteboardItem(
                types: ["public.utf8-plain-text"],
                representations: ["public.utf8-plain-text": Data("paused".utf8)]
            )]
        )
        observer.poll()
        XCTAssertTrue(changes.isEmpty)

        observer.setCapturePaused(false)
        reader.change = PasteboardChange(
            changeCount: 4,
            items: [PasteboardItem(
                types: ["public.utf8-plain-text"],
                representations: ["public.utf8-plain-text": Data("resumed".utf8)]
            )]
        )
        observer.poll()
        XCTAssertEqual(changes.map(\.changeCount), [4])
        observer.stop()
    }

    func testPasteboardObserverDeliversUniversalClipboardText() {
        let remote = CaptureExclusionRules.remoteClipboardPasteboardType
        let textType = "public.utf8-plain-text"
        let reader = TestPasteboardReader(change: PasteboardChange(
            changeCount: 1,
            items: [PasteboardItem(
                types: [textType],
                representations: [textType: Data("seed".utf8)]
            )],
            sourceAppBundleID: "com.example.editor"
        ))
        let observer = PasteboardObserver(
            reader: reader,
            exclusionRules: CaptureExclusionRules(),
            pollInterval: 1,
            retryState: MacClippyPasteboardReadRetryState(maxAttempts: 1)
        )
        var changes: [PasteboardChange] = []
        observer.start { changes.append($0) }
        observer.poll()
        XCTAssertTrue(changes.isEmpty)

        reader.change = PasteboardChange(
            changeCount: 2,
            items: [PasteboardItem(
                types: [remote, textType],
                representations: [
                    remote: Data(),
                    textType: Data("iphone copy".utf8)
                ]
            )],
            sourceAppBundleID: "com.example.editor"
        )
        observer.poll()
        XCTAssertEqual(changes.map(\.changeCount), [2])
        XCTAssertEqual(changes[0].items[0].string(forType: textType), "iphone copy")
        XCTAssertTrue(changes[0].pasteboardTypes.contains(remote))
        observer.stop()
    }

    private final class TestPasteboardReader: PasteboardReading {
        var change: PasteboardChange

        init(change: PasteboardChange) {
            self.change = change
        }

        func read() -> PasteboardChange {
            change
        }
    }

    private final class CountingPasteboardReader: PasteboardReading {
        var change: PasteboardChange
        var fullReadCount = 0
        var changeCountReadCount = 0

        init(change: PasteboardChange) {
            self.change = change
        }

        func currentChangeCount() -> Int {
            changeCountReadCount += 1
            return change.changeCount
        }

        func read() -> PasteboardChange {
            fullReadCount += 1
            return change
        }
    }
}
