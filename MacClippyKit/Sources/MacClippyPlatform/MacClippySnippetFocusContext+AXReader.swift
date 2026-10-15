import AppKit
import ApplicationServices
import Foundation

extension MacClippySnippetFocusContextMonitor {
    struct AXFocusSample: @unchecked Sendable {
        let context: MacClippySnippetFocusContext
        let processIdentifier: pid_t
        let applicationElement: AXUIElement
        let focusedElement: AXUIElement
    }

    static func readFrontmostFocusContext() -> MacClippySnippetFocusContext? {
        readFrontmostAXElements()?.context
    }

    static func readFrontmostAXElements() -> AXFocusSample? {
        guard AXIsProcessTrusted(),
              let application = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        let processIdentifier = application.processIdentifier
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        var focusedElement: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            applicationElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        ) == .success,
        let focusedElement,
        CFGetTypeID(focusedElement) == AXUIElementGetTypeID() else {
            return nil
        }

        let focusedUIElement = unsafeDowncast(focusedElement, to: AXUIElement.self)
        let identity = MacClippySnippetFocusIdentity(
            processIdentifier: processIdentifier,
            elementIdentity: UInt64(CFHash(focusedUIElement))
        )
        let selection = selectedTextRange(of: focusedUIElement)
        return AXFocusSample(
            context: MacClippySnippetFocusContext(identity: identity, selection: selection),
            processIdentifier: processIdentifier,
            applicationElement: applicationElement,
            focusedElement: focusedUIElement
        )
    }

    static func selectedTextRange(of element: AXUIElement) -> MacClippySnippetTextSelection? {
        var selectedRange: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRange
        ) == .success,
        let selectedRange,
        CFGetTypeID(selectedRange) == AXValueGetTypeID() else { return nil }
        let value = unsafeDowncast(selectedRange, to: AXValue.self)
        guard AXValueGetType(value) == .cfRange else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(value, .cfRange, &range), range.location >= 0, range.length >= 0 else {
            return nil
        }
        return MacClippySnippetTextSelection(location: range.location, length: range.length)
    }
}
