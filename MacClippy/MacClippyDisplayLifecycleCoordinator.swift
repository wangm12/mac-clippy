import AppKit
import Foundation

import MacClippyCore
import MacClippyPlatform

@MainActor
final class MacClippyDisplayLifecycleCoordinator {
    private var lastScreenFrames: [CGRect] = []
    private var observers: [NSObjectProtocol] = []
    var handler: ((MacClippyDisplayLifecycleEvent) -> Void)?

    func start() {
        stop()
        lastScreenFrames = NSScreen.screens.map(\.frame)
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(
            workspace.addObserver(
                forName: NSWorkspace.screensDidSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.note(.screensDidSleep)
                }
            }
        )
        observers.append(
            workspace.addObserver(
                forName: NSWorkspace.screensDidWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.note(.screensDidWake)
                }
            }
        )
        observers.append(
            workspace.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.note(.didWake)
                }
            }
        )
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.note(.screenParametersChanged)
                }
            }
        )
    }

    func stop() {
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }

    func note(_ event: MacClippyDisplayLifecycleEvent) {
        let environment = ProcessInfo.processInfo.environment
        if NSClassFromString("XCTestCase") != nil
            || environment["XCTestConfigurationFilePath"] != nil
            || environment["XCInjectBundleInto"] != nil {
            return
        }
        if event == .screenParametersChanged {
            let current = NSScreen.screens.map(\.frame)
            guard MacClippyDisplayGenerationPolicy.shouldTreatAsDisplayChange(
                previousFrames: lastScreenFrames,
                currentFrames: current
            ) else { return }
            lastScreenFrames = current
        } else if event == .didWake || event == .screensDidWake {
            lastScreenFrames = NSScreen.screens.map(\.frame)
        }
        let frames = NSScreen.screens
            .map { "\(Int($0.frame.width.rounded()))x\(Int($0.frame.height.rounded()))" }
            .joined(separator: ",")
        MacClippyLog.notice(
            category: .ui,
            code: .displayConfigurationChanged,
            operation: "display_\(event.rawValue)",
            impact: "screens=\(NSScreen.screens.count) frames=\(frames)"
        )
        handler?(event)
    }
}
