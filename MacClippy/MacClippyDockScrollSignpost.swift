import AppKit
import os.signpost
import SwiftUI

struct MacClippyDockScrollSignpostProbe: NSViewRepresentable {
    var onScrollingChange: ((Bool) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onScrollingChange: onScrollingChange)
    }

    func makeNSView(context: Context) -> MacClippyDockScrollSignpostView {
        let view = MacClippyDockScrollSignpostView()
        view.onScrollingChange = { [weak coordinator = context.coordinator] scrolling in
            coordinator?.setScrolling(scrolling)
        }
        return view
    }

    func updateNSView(_ nsView: MacClippyDockScrollSignpostView, context: Context) {
        context.coordinator.onScrollingChange = onScrollingChange
        nsView.onScrollingChange = { [weak coordinator = context.coordinator] scrolling in
            coordinator?.setScrolling(scrolling)
        }
    }

    static func dismantleNSView(_ nsView: MacClippyDockScrollSignpostView, coordinator: Coordinator) {
        nsView.teardown()
    }

    final class Coordinator {
        var onScrollingChange: ((Bool) -> Void)?
        private var isScrolling = false

        init(onScrollingChange: ((Bool) -> Void)?) {
            self.onScrollingChange = onScrollingChange
        }

        func setScrolling(_ scrolling: Bool) {
            guard isScrolling != scrolling else { return }
            isScrolling = scrolling
            onScrollingChange?(scrolling)
        }
    }
}

final class MacClippyDockScrollSignpostView: NSView {
    var onScrollingChange: ((Bool) -> Void)?
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
            onScrollingChange?(true)
        }
        endWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let id = self.activeID else { return }
            MacClippyPerformance.end("card_scroll", id: id)
            self.activeID = nil
            self.onScrollingChange?(false)
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
