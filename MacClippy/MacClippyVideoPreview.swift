import AVFoundation
import AVKit
import SwiftUI

// Video preview for a single pasted movie URL. Uses AVKit.VideoPlayer with an
// AVPlayer bounded to the existing preview content area; native playback
// controls remain available. The player is created on appear and autoplays if
// practical, and is paused on disappear so leaving the preview never leaves a
// movie playing. Playback is preview-only: it does not touch the pasteboard or
// the store, so paste/storage behavior is unaffected.
struct MacClippyVideoPreview: View {
    let url: URL
    let reduceMotion: Bool
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: url) {
            // Preview navigation can replace the URL while the view identity
            // remains stable. Replace the player on URL change so the previous
            // asset cannot keep decoding/playing in the background.
            player?.pause()
            let next = AVPlayer(url: url)
            player = next
            if !accessibilityReduceMotion && !reduceMotion {
                next.play()
            }
        }
        .onChange(of: accessibilityReduceMotion) { _, reduceMotion in
            guard let player else { return }
            if reduceMotion || accessibilityReduceMotion {
                player.pause()
            } else {
                player.play()
            }
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
}
