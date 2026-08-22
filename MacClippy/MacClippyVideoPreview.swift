import MacClippyCore
import SwiftUI

// Finder movie copies use the AppKit player with a visible transport bar.
// Do not import SwiftUI VideoPlayer.
struct MacClippyVideoPreview: View {
    let url: URL
    let reduceMotion: Bool

    var body: some View {
        MacClippyAVPlayerPreview(url: url, autostarts: !reduceMotion)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel(MacClippyFilePresentation.displayName(for: url))
    }
}
