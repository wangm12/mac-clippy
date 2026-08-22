import AppKit
import AVFoundation
import AVKit
import SwiftUI

import MacClippyCore

extension MacClippyDockPreviewFileSurface {
    /// Finder movies get an always-visible transport bar. Preview.app chrome
    /// lives in a key window; our Space panel cannot become key, so Quick
    /// Look hides its own controls.
    static func usesInlineVideoControls(for url: URL) -> Bool {
        MacClippyFilePresentation.mediaKind(for: url) == .movie
    }
}

/// AppKit `AVPlayerView` plus a transport bar that stays visible in a
/// non-key preview panel. Do not use SwiftUI `VideoPlayer`.
struct MacClippyAVPlayerPreview: NSViewRepresentable {
    let url: URL
    var autostarts: Bool

    func makeNSView(context: Context) -> MacClippyVideoHostView {
        let host = MacClippyVideoHostView()
        host.configure(url: url, autostarts: autostarts)
        return host
    }

    func updateNSView(_ host: MacClippyVideoHostView, context: Context) {
        host.configure(url: url, autostarts: autostarts)
    }

    static func dismantleNSView(_ host: MacClippyVideoHostView, coordinator: ()) {
        host.teardown()
    }
}

final class MacClippyVideoHostView: NSView {
    private let playerView = AVPlayerView()
    private let playButton = NSButton(title: "", target: nil, action: nil)
    private let elapsedLabel = NSTextField(labelWithString: "0:00")
    private let remainingLabel = NSTextField(labelWithString: "0:00")
    private let slider = NSSlider()
    private let transport = NSVisualEffectView()

    private var player: AVPlayer?
    private var currentPath: String?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var isScrubbing = false
    private var scrubEndWork: DispatchWorkItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        playerView.controlsStyle = .none
        playerView.videoGravity = .resizeAspect
        playerView.updatesNowPlayingInfoCenter = false
        playerView.allowsPictureInPicturePlayback = false
        playerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(playerView)

        transport.material = .headerView
        transport.blendingMode = .withinWindow
        transport.state = .active
        transport.translatesAutoresizingMaskIntoConstraints = false
        addSubview(transport)

        playButton.bezelStyle = .regularSquare
        playButton.isBordered = false
        playButton.imagePosition = .imageOnly
        playButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play")
        playButton.target = self
        playButton.action = #selector(togglePlay)
        playButton.setButtonType(.momentaryChange)
        playButton.translatesAutoresizingMaskIntoConstraints = false

        slider.minValue = 0
        slider.maxValue = 1
        slider.doubleValue = 0
        slider.target = self
        slider.action = #selector(sliderChanged)
        slider.isEnabled = false
        slider.translatesAutoresizingMaskIntoConstraints = false
        if let cell = slider.cell as? NSSliderCell {
            cell.isContinuous = true
        }

        configureTimeLabel(elapsedLabel)
        configureTimeLabel(remainingLabel)
        slider.sendAction(on: [.leftMouseDown, .leftMouseDragged, .leftMouseUp])

        let stack = NSStackView(views: [playButton, elapsedLabel, slider, remainingLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        transport.addSubview(stack)

        NSLayoutConstraint.activate([
            playerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            playerView.topAnchor.constraint(equalTo: topAnchor),
            playerView.bottomAnchor.constraint(equalTo: transport.topAnchor),

            transport.leadingAnchor.constraint(equalTo: leadingAnchor),
            transport.trailingAnchor.constraint(equalTo: trailingAnchor),
            transport.bottomAnchor.constraint(equalTo: bottomAnchor),
            transport.heightAnchor.constraint(equalToConstant: 40),

            stack.leadingAnchor.constraint(equalTo: transport.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: transport.trailingAnchor),
            stack.topAnchor.constraint(equalTo: transport.topAnchor),
            stack.bottomAnchor.constraint(equalTo: transport.bottomAnchor),

            playButton.widthAnchor.constraint(equalToConstant: 22),
            playButton.heightAnchor.constraint(equalToConstant: 22),
            elapsedLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 36),
            remainingLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 36)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { false }

    func configure(url: URL, autostarts: Bool) {
        let path = url.path
        if currentPath == path, player != nil {
            return
        }
        teardown()
        currentPath = path
        let player = AVPlayer(url: url)
        player.actionAtItemEnd = .pause
        self.player = player
        playerView.player = player
        installObservers(on: player)
        refreshTransport()
        if autostarts {
            player.play()
        }
    }

    func teardown() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        playerView.player = nil
        player = nil
        currentPath = nil
        isScrubbing = false
        slider.doubleValue = 0
        slider.isEnabled = false
        elapsedLabel.stringValue = MacClippyVideoClock.string(0)
        remainingLabel.stringValue = MacClippyVideoClock.string(0)
        scrubEndWork?.cancel()
        scrubEndWork = nil
        playButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play")
    }

    private func installObservers(on player: AVPlayer) {
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshTransport()
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.player?.seek(to: .zero)
                self?.player?.pause()
                self?.refreshTransport()
            }
        }
    }

    private func refreshTransport() {
        guard !isScrubbing, let player else { return }
        let elapsed = Self.seconds(player.currentTime())
        let duration = Self.seconds(player.currentItem?.duration)
        elapsedLabel.stringValue = MacClippyVideoClock.string(elapsed)
        remainingLabel.stringValue = MacClippyVideoClock.string(duration)
        if duration > 0 {
            slider.maxValue = duration
            slider.doubleValue = min(max(elapsed, 0), duration)
            slider.isEnabled = true
        } else {
            slider.maxValue = 1
            slider.doubleValue = 0
            slider.isEnabled = false
        }
        let playing = player.rate > 0
        playButton.image = NSImage(
            systemSymbolName: playing ? "pause.fill" : "play.fill",
            accessibilityDescription: playing ? "Pause" : "Play"
        )
    }

    @objc
    private func togglePlay() {
        guard let player else { return }
        if player.rate > 0 {
            player.pause()
        } else {
            let elapsed = Self.seconds(player.currentTime())
            let duration = Self.seconds(player.currentItem?.duration)
            if duration > 0, elapsed >= duration - 0.05 {
                player.seek(to: .zero)
            }
            player.play()
        }
        refreshTransport()
    }

    @objc
    private func sliderChanged() {
        guard let player, slider.isEnabled else { return }
        isScrubbing = true
        scrubEndWork?.cancel()
        let seconds = slider.doubleValue
        elapsedLabel.stringValue = MacClippyVideoClock.string(seconds)
        player.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        let work = DispatchWorkItem { [weak self] in
            self?.isScrubbing = false
        }
        scrubEndWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func configureTimeLabel(_ label: NSTextField) {
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private static func seconds(_ time: CMTime?) -> Double {
        guard let time, time.isNumeric else { return 0 }
        let value = time.seconds
        return value.isFinite ? max(value, 0) : 0
    }

}

enum MacClippyVideoClock {
    static func string(_ seconds: Double) -> String {
        let total = Int(max(seconds, 0).rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remainder = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%d:%02d", minutes, remainder)
    }
}
