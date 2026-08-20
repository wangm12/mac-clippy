import AppKit
import os.signpost
import SwiftUI

struct MacClippyDockScrollSignpostProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> MacClippyDockScrollSignpostView {
        MacClippyDockScrollSignpostView()
    }

    func updateNSView(_ nsView: MacClippyDockScrollSignpostView, context: Context) {}

    static func dismantleNSView(_ nsView: MacClippyDockScrollSignpostView, coordinator: ()) {
        nsView.teardown()
    }
}

final class MacClippyDockScrollSignpostView: NSView {
    nonisolated(unsafe) private var observation: NSObjectProtocol?
    nonisolated(unsafe) private var activeID: OSSignpostID?
    nonisolated(unsafe) private var endWork: DispatchWorkItem?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attachToEnclosingScrollView()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        attachToEnclosingScrollView()
    }

    private func attachToEnclosingScrollView() {
        guard observation == nil, let scrollView = enclosingScrollView else { return }
        scrollView.contentView.postsBoundsChangedNotifications = true
        observation = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            guard let view = self else { return }
            DispatchQueue.main.async {
                view.noteScroll()
            }
        }
    }

    private func noteScroll() {
        if activeID == nil {
            activeID = MacClippyPerformance.begin("card_scroll")
        }
        endWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let id = self.activeID else { return }
            MacClippyPerformance.end("card_scroll", id: id)
            self.activeID = nil
        }
        endWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: work)
    }

    deinit {
        teardown()
    }

    nonisolated func teardown() {
        if let observation {
            NotificationCenter.default.removeObserver(observation)
            self.observation = nil
        }
        endWork?.cancel()
        endWork = nil
        if let id = activeID {
            MacClippyPerformance.end("card_scroll", id: id)
            activeID = nil
        }
    }
}
