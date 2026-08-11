import AppKit

enum MacClippyPresentationPreferences {
    static let hideFromMenuBarKey = "com.macallyouneed.macclippy.presentation.hideFromMenuBar"
    static let hideDockIconKey = "com.macallyouneed.macclippy.presentation.hideDockIcon"
}

/// Pure presentation decisions shared by Settings and AppDelegate.
/// Menu-bar visibility and Dock activation remain independent preferences.
enum MacClippyPresentationPolicy {
    struct State: Equatable {
        let showsMenuBarIcon: Bool
        let activationPolicy: NSApplication.ActivationPolicy
    }

    static func state(hideFromMenuBar: Bool, hideDockIcon: Bool) -> State {
        State(
            showsMenuBarIcon: !hideFromMenuBar,
            activationPolicy: activationPolicy(hideDockIcon: hideDockIcon)
        )
    }

    static func activationPolicy(hideDockIcon: Bool) -> NSApplication.ActivationPolicy {
        hideDockIcon ? .accessory : .regular
    }
}
