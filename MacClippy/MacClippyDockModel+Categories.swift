import Foundation

import MacClippyCore

extension MacClippyDockModel {
    func rebuildCategoryMembershipIndex() {
        var index: [RecordID: [MacClippyDockCategoryPresentation]] = [:]

        for pinboard in pinboards {
            let category = MacClippyDockCategoryPresentation(
                id: pinboard.id,
                name: pinboard.name,
                colorHex: pinboard.colorHex
            )
            for itemID in pinboard.board.itemIDs
            where !index[itemID, default: []].contains(where: { $0.id == category.id }) {
                index[itemID, default: []].append(category)
            }
        }

        categoryMembershipsByItemID = index
    }

    func categories(for itemID: RecordID) -> [MacClippyDockCategoryPresentation] {
        categoryMembershipsByItemID[itemID] ?? []
    }
}
