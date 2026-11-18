import SwiftUI

struct MacClippyCardQuickActions<More: View>: View {
    let onCopy: () -> Void
    @ViewBuilder let more: () -> More
    @Environment(\.macClippyCardHovered) private var isHovered
    @FocusState private var focusedAction: Action?

    private enum Action: Hashable {
        case copy
        case more
    }

    private var isVisible: Bool { isHovered || focusedAction != nil }

    var body: some View {
        HStack(spacing: 8) {
            Button("Copy", action: onCopy)
                .buttonStyle(.plain)
                .focused($focusedAction, equals: .copy)
                .accessibilityLabel("Copy item")
                .help("Copy · ⌘C")
            Menu(content: more) { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 24)
                .focused($focusedAction, equals: .more)
                .accessibilityLabel("More item actions")
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 10).frame(height: 26)
        .background(MacClippyDockTheme.panelStrongColor, in: Capsule())
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .accessibilityHidden(!isVisible)
    }
}
