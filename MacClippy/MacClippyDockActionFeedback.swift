import AppKit
import Foundation
import MacClippyCore
import MacClippyPlatform
import SwiftUI

enum MacClippyDockActionFeedback: Equatable {
    case copied(plain: Bool)
    case pasted(manual: Bool)
    case pinChanged(boardName: String, isPinned: Bool)
    case pinnedTo(boardName: String)
    case snippetCreated
    case deleted
    // P1 transient feedback for a mixed multi-paste that was NOT injected
    // because the selection contained at least one non-text-compatible record.
    // supportedCount/unsupportedCount name exactly what was not pasted so
    // nothing is silently dropped.
    case multiPasteMixed(
        supportedCount: Int, unsupportedCount: Int, unsupportedKinds: [MacClippyDockMultiPastePolicy.Kind])
    // P1 transient feedback for a multi-paste that was NOT injected because at
    // least one text-compatible record (text/html/rtf) had an unavailable or
    // undecodable plain-text payload (e.g. malformed RTF). availableCount
    // decoded (possibly to "") and unavailableCount did not; the unavailable
    // kinds name exactly which records could not be pasted. No paste occurred
    // so a nil payload is never silently merged as an empty piece.
    case multiPasteUnavailable(
        availableCount: Int, unavailableCount: Int, unavailableKinds: [MacClippyDockMultiPastePolicy.Kind])
    // P1 transient feedback for a batch delete/pin that partially succeeded:
    // some IDs were not found. succeeded is the count that acted, unsupported
    // is the count that were missing.
    case batchPartial(succeeded: Int, unsupported: Int)
    // P2a transient feedback for a rename. cleared is true when the name was
    // blanked (set to nil), false when a non-empty name was saved.
    case nameSaved(cleared: Bool)
    // Transformed copy/paste feedback. Mirrors .copied / .pasted(manual:) but
    // names the transform that was applied so the user can tell a transformed
    // result apart from a plain copy/paste. manual is true when the paste
    // required a manual Cmd+V (Accessibility unavailable), matching .pasted.
    case transformedCopied(name: String)
    case transformedPasted(name: String, manual: Bool)
    // Mixed-content sequential queue paste feedback. Distinct from Paste all
    // (which merges homogeneous text into one paste): Queue paste injects a
    // separate Cmd+V per record in visual order so mixed selections can each
    // be consumed by the target app. Full success closes the dock via the
    // existing completion; partial/manual outcomes keep the dock open so the
    // explicit result is visible.
    //
    // .queuePasteCompleted is full success: every selected record was either
    // injected or explicitly unavailable, and no manual-paste stop occurred.
    // injectedCount records were actually pasted (frequency bumped).
    // unavailableCount records were missing/malformed and reported explicitly;
    // when unavailableCount is 0 this is a clean full success.
    case queuePasteCompleted(injectedCount: Int, unavailableCount: Int)
    // .queuePastePartial is partial completion: some records were injected and
    // some were unavailable, but the queue finished without a manual stop. The
    // dock stays open so the user can see exactly what was not pasted.
    case queuePastePartial(
        injectedCount: Int, unavailableCount: Int, unavailableKinds: [MacClippyDockMultiPastePolicy.Kind])
    // .queuePasteManualStop is a manual-paste stop: the injector prepared the
    // current record but could not post its Cmd+V event, so the queue stopped without
    // claiming the current or any remaining ID injected. remainingCount is the
    // current ID plus every not-yet-attempted ID. The dock stays open so the
    // user can see the unconsumed IDs.
    case queuePasteManualStop(injectedCount: Int, remainingCount: Int)
    case queuePasteCancelled(injectedCount: Int, remainingCount: Int)

    var title: String {
        switch self {
        case .copied(let plain): plain ? "Copied plain" : "Copied"
        case .pasted(let manual): manual ? "Copied — press ⌘V to paste" : "Pasted"
        case .pinChanged(let boardName, let isPinned): isPinned ? "Pinned to \(boardName)" : "Unpinned"
        case .pinnedTo(let boardName): "Pinned to \(boardName)"
        case .snippetCreated: "Snippet saved"
        case .deleted: "Deleted"
        case .multiPasteMixed(let supportedCount, let unsupportedCount, _):
            "\(unsupportedCount) of \(supportedCount + unsupportedCount) unsupported"
        case .multiPasteUnavailable(let availableCount, let unavailableCount, _):
            "\(unavailableCount) of \(availableCount + unavailableCount) undecodable"
        case .batchPartial(let succeeded, let unsupported):
            "\(succeeded) done, \(unsupported) not found"
        case .nameSaved(let cleared): cleared ? "Name cleared" : "Name saved"
        case .transformedCopied(let name): "Copied \(name)"
        case .transformedPasted(let name, let manual):
            manual ? "Copied — press ⌘V to paste" : "Pasted \(name)"
        case .queuePasteCompleted(let injectedCount, let unavailableCount):
            unavailableCount == 0
                ? "Queued \(injectedCount)" : "Queued \(injectedCount), \(unavailableCount) unavailable"
        case .queuePastePartial(let injectedCount, let unavailableCount, _):
            "Queued \(injectedCount), \(unavailableCount) unavailable"
        case .queuePasteManualStop(let injectedCount, let remainingCount):
            "Queued \(injectedCount), \(remainingCount) need manual paste"
        case .queuePasteCancelled(let injectedCount, let remainingCount):
            "Stopped after \(injectedCount), \(remainingCount) remain"
        }
    }

    var systemImage: String {
        switch self {
        case .copied, .pasted, .pinChanged, .pinnedTo, .snippetCreated, .deleted, .nameSaved,
            .transformedCopied, .transformedPasted,
            .queuePasteCompleted:
            "checkmark.circle.fill"
        case .multiPasteMixed, .multiPasteUnavailable, .batchPartial,
            .queuePastePartial, .queuePasteManualStop, .queuePasteCancelled:
            "exclamationmark.triangle.fill"
        }
    }

    // True for copy-style feedback that should surface as a screen-level toast
    // instead of the in-panel overlay (mirrors paste's on-screen indicator).
    var isCopyFeedback: Bool {
        switch self {
        case .copied, .transformedCopied:
            true
        default:
            false
        }
    }

    var isScreenToastFeedback: Bool {
        if isCopyFeedback { return true }
        return switch self {
        case .pasted, .transformedPasted, .queuePasteCompleted: true
        default: false
        }
    }

    var toastDuration: TimeInterval {
        switch self {
        case .pasted(manual: true), .transformedPasted(_, manual: true): 4
        default: 1.2
        }
    }
}
