import AppKit
import Carbon
import Foundation

extension MacClippyPasteInjector {
    static func isOptionalSidecarPromiseUTI(_ typeName: String) -> Bool {
        typeName == "Apple files promise pasteboard type"
            || typeName == "NSFilesPromisePboardType"
            || typeName == "public.file-url-promise"
            || typeName.hasPrefix("com.apple.pasteboard.promised-")
            || typeName.hasPrefix("org.nspasteboard.")
    }

    func captureSnapshotItem(
        _ item: NSPasteboardItem,
        maxBytes: Int?,
        policy: MacClippyPasteSnapshotPolicy,
        isComplete: inout Bool
    ) -> [(type: NSPasteboard.PasteboardType, data: Data)]? {
        guard let typeNames = try? MacClippyNativePasteboard.types(of: item) else {
            if case .strict = policy { isComplete = false }
            return nil
        }
        var captured: [(type: NSPasteboard.PasteboardType, data: Data)] = []
        var hadUnexpectedMissingType = false
        for typeName in typeNames {
            let type = NSPasteboard.PasteboardType(typeName)
            guard let data = try? MacClippyNativePasteboard.data(from: item, forType: type) else {
                if !Self.isOptionalSidecarPromiseUTI(typeName) {
                    hadUnexpectedMissingType = true
                }
                continue
            }
            if let maxBytes, data.count > maxBytes {
                continue
            }
            captured.append((type: type, data: data))
        }
        if case .strict = policy {
            if hadUnexpectedMissingType || (captured.isEmpty && !typeNames.isEmpty) {
                isComplete = false
            }
        }
        return captured.isEmpty && !typeNames.isEmpty ? nil : captured
    }

    @discardableResult
    public static func refreshPasteVirtualKeyCodeOnMain() -> CGKeyCode {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                _ = refreshPasteVirtualKeyCodeOnMain()
            }
            return PasteVirtualKeyCodeCache.shared.get() ?? CGKeyCode(kVK_ANSI_V)
        }
        var resolved = CGKeyCode(kVK_ANSI_V)
        if let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
           let rawData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) {
            let layoutData = Unmanaged<CFData>.fromOpaque(rawData).takeUnretainedValue() as Data
            if let keyCode = virtualKeyCode(for: "v", layoutData: layoutData) {
                resolved = keyCode
            }
        }
        PasteVirtualKeyCodeCache.shared.set(resolved)
        return resolved
    }
}

private final class PasteVirtualKeyCodeCache: @unchecked Sendable {
    static let shared = PasteVirtualKeyCodeCache()
    private let lock = NSLock()
    private var keyCode: CGKeyCode?

    func get() -> CGKeyCode? {
        lock.lock()
        defer { lock.unlock() }
        return keyCode
    }

    func set(_ newValue: CGKeyCode) {
        lock.lock()
        keyCode = newValue
        lock.unlock()
    }
}

package extension MacClippyPasteInjector {
    static func virtualKeyCode(for targetCharacter: Character, layoutData: Data) -> CGKeyCode? {
        let target = String(targetCharacter).lowercased()
        guard !target.isEmpty else { return nil }
        return layoutData.withUnsafeBytes { rawBuffer -> CGKeyCode? in
            guard let layoutPtr = rawBuffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else {
                return nil
            }
            let keyboardType = UInt32(LMGetKbdType())
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 8)
            for keyCode in UInt16(0)..<UInt16(128) {
                var actualLength = 0
                deadKeyState = 0
                let status = UCKeyTranslate(
                    layoutPtr,
                    keyCode,
                    UInt16(kUCKeyActionDisplay),
                    0,
                    keyboardType,
                    OptionBits(kUCKeyTranslateNoDeadKeysMask),
                    &deadKeyState,
                    chars.count,
                    &actualLength,
                    &chars
                )
                guard status == noErr, actualLength > 0 else { continue }
                let decoded = String(utf16CodeUnits: chars, count: actualLength).lowercased()
                if decoded == target {
                    return CGKeyCode(keyCode)
                }
            }
            return nil
        }
    }
}
