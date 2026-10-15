#if MACCLIPPY_E2E
import AppKit

/// Explicitly requested GUI fixture; background/soak runs never create it.
/// Keeps a native AX window available after the transient Dock and toast close.
@MainActor
final class MacClippyE2ENativeHost {
    private let window: NSWindow
    private let textView = NSTextView()

    init() {
        MacClippyE2EUIInteractionProbe.shared.start()
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 440),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "MacClippy E2E Recipient"
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        textView.textContainerInset = NSSize(width: 20, height: 20)
        textView.setAccessibilityLabel("Isolated paste recipient")
        textView.setAccessibilityHelp("Synthetic test content from this run's named pasteboard")
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 440))
        scrollView.hasVerticalScroller = true
        scrollView.autoresizingMask = [.width, .height]
        textView.frame = scrollView.contentSize == .zero
            ? scrollView.bounds : NSRect(origin: .zero, size: scrollView.contentSize)
        textView.autoresizingMask = [.width]
        scrollView.documentView = textView
        window.contentView = scrollView
        window.center()
    }

    var isVisible: Bool { window.isVisible }
    var isKeyWindow: Bool { window.isKeyWindow }

    func show(text: String) {
        display(text)
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func hide() {
        window.orderOut(nil)
    }

    func display(_ text: String) {
        textView.string = text
    }
}

struct MacClippyE2EUIInteractionSample: Codable, Sendable {
    let event: String
    let uptime: TimeInterval
    let applicationActive: Bool
    let eventAgeMS: Double?
    let sinceMouseDownMS: Double?
    let sinceMouseUpMS: Double?
    var windowNumber: Int?
    var windowLocalX: Double?
    var windowLocalY: Double?
    var windowFrameX: Double?
    var windowFrameY: Double?
    var pointerX: Double?
    var pointerY: Double?
    var primaryScreenMaxY: Double?
    var buttonNumber: Int?
    var clickCount: Int?
    var pressedMouseButtons: Int?
    var modifierFlags: UInt?
    var hitViewClass: String?
    var hitViewFrame: String?
}

/// Measures in-app event and presentation timing; never generates input.
/// Only the explicitly requested native GUI fixture installs these monitors.
@MainActor
final class MacClippyE2EUIInteractionProbe {
    static let shared = MacClippyE2EUIInteractionProbe()
    private(set) var samples: [MacClippyE2EUIInteractionSample] = []
    private var mouseMonitor: Any?
    private var menuObserver: NSObjectProtocol?
    private var mouseDown: TimeInterval?
    private var mouseUp: TimeInterval?

    func start() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            self?.recordMouse(event)
            return event
        }
        menuObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.mark("menu-tracking") }
        }
    }

    private func recordMouse(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            mouseDown = event.timestamp
            mouseUp = nil
        } else {
            mouseUp = event.timestamp
        }
        mark(event.type == .leftMouseDown ? "mouse-down" : "mouse-up", event: event)
    }

    func mark(_ name: String, event: NSEvent? = nil) {
        guard mouseMonitor != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        var sample = MacClippyE2EUIInteractionSample(
            event: name, uptime: now, applicationActive: NSApp.isActive,
            eventAgeMS: event.map { (now - $0.timestamp) * 1_000 },
            sinceMouseDownMS: mouseDown.map { (now - $0) * 1_000 },
            sinceMouseUpMS: mouseUp.map { (now - $0) * 1_000 })
        if let event {
            sample.windowNumber = event.windowNumber
            sample.windowLocalX = Double(event.locationInWindow.x)
            sample.windowLocalY = Double(event.locationInWindow.y)
            sample.windowFrameX = event.window.map { Double($0.frame.minX) }
            sample.windowFrameY = event.window.map { Double($0.frame.minY) }
            sample.pointerX = Double(NSEvent.mouseLocation.x)
            sample.pointerY = Double(NSEvent.mouseLocation.y)
            sample.primaryScreenMaxY = NSScreen.screens.first.map { Double($0.frame.maxY) }
            sample.buttonNumber = event.buttonNumber
            sample.clickCount = event.clickCount
            sample.pressedMouseButtons = Int(NSEvent.pressedMouseButtons)
            sample.modifierFlags = event.modifierFlags.rawValue
            if let content = event.window?.contentView {
                let point = content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
                if let hit = content.hitTest(point) {
                    sample.hitViewClass = NSStringFromClass(type(of: hit))
                    sample.hitViewFrame = NSStringFromRect(hit.frame)
                }
            }
        }
        samples.append(sample)
        if samples.count > 128 { samples.removeFirst(samples.count - 128) }
    }
}
#endif
