import AppKit

extension MacClippyDockController {
    func traceE2EFocus(_ event: String, location: NSPoint) {
        #if MACCLIPPY_E2E
        let detail = "event=\(event) active=\(NSApp.isActive) key=\(panel?.isKeyWindow == true) "
            + "pointer=\(location) frame=\(panel?.frame ?? .zero) mode=\(interactionMode)"
        e2eFocusDiagnostic?(detail)
        #endif
    }
}
