import AppKit
import SwiftUI

import MacClippyCore

// Bounded thumbnail rendering keeps image decoding off the main thread and
// prevents a large image payload from changing card geometry. Equality is
// item-ID only so search highlighting can update without redrawing the image.
struct MacClippyCardImageThumbnail: View, Equatable {
    nonisolated let itemID: RecordID
    let load: @MainActor @Sendable (RecordID) async -> CGImage?

    let cached: @MainActor @Sendable (RecordID) -> CGImage?
    @State private var image: CGImage?
    @State private var loadedIdentity: String?

    init(
        itemID: RecordID,
        load: @escaping @MainActor @Sendable (RecordID) async -> CGImage?,
        cached: @escaping @MainActor @Sendable (RecordID) -> CGImage? = { _ in nil }
    ) {
        self.itemID = itemID
        self.load = load
        self.cached = cached
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.itemID == rhs.itemID
    }

    private var identity: String { itemID.rawValue }

    var body: some View {
        let displayed = MacClippyThumbnailDisplayPolicy.displayed(
            loadedIdentity: loadedIdentity,
            currentIdentity: identity,
            image: image,
            cached: cached(itemID)
        )
        Group {
            if let displayed {
                Image(decorative: displayed, scale: 1, orientation: .up)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: MacClippyDockCardMetrics.imagePreviewRadius,
                            style: .continuous
                        )
                    )
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .overlay {
                        Image(systemName: "photo")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .task(id: itemID) {
            if MacClippyThumbnailRetainPolicy.shouldClearDisplayedImage(
                displayedIdentity: loadedIdentity,
                loadingIdentity: identity
            ) {
                image = nil
            }
            loadedIdentity = identity
            guard MacClippyThumbnailCachePolicy.shouldDecode(isCardVisible: true) else { return }
            let loaded = await load(itemID)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}
