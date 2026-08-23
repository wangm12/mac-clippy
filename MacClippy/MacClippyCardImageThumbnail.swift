import AppKit
import SwiftUI

import MacClippyCore

// Bounded thumbnail rendering keeps image decoding off the main thread and
// prevents a large image payload from changing card geometry. Equality is
// item-ID only so search highlighting can update without redrawing the image.
struct MacClippyCardImageThumbnail: View, Equatable {
    nonisolated let itemID: RecordID
    let load: @MainActor @Sendable (RecordID) async -> CGImage?

    @State private var image: CGImage?

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.itemID == rhs.itemID
    }

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1, orientation: .up)
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
            image = nil
            let loaded = await load(itemID)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}
