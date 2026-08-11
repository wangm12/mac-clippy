import AppKit
import SwiftUI

import MacClippyCore

// Bounded thumbnail rendering keeps image decoding off the main thread and
// prevents a large image payload from changing card geometry.
struct MacClippyCardImageThumbnail: View {
    let item: MacClippyHistoryEntry
    @ObservedObject var model: MacClippyDockModel

    @State private var image: CGImage?
    @State private var loadedItemID: RecordID?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1, orientation: .up)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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
        .task(id: item.id) {
            guard item.contentKind == .image else { return }
            let itemID = item.id
            loadedItemID = itemID
            image = nil
            model.loadImageThumbnail(for: itemID) { result in
                guard loadedItemID == itemID else { return }
                image = result
            }
        }
    }
}
