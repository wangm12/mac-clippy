import AppKit
import CoreGraphics
import Foundation
import MacClippyCore
import MacClippyPlatform

extension MacClippyRuntime {
    /// P1 ordered multi-paste: resolve the selection through the pure
    /// MacClippyDockMultiPastePolicy. For a homogeneous text-compatible
    /// selection, merge the plain-text payloads in visual order with a newline
    /// delimiter and inject a single paste (preserving the target app). For a
    /// mixed selection, never paste a subset: return an explicit
    /// manualPasteRequired result carrying the supported and unsupported IDs so
    /// the caller can report exactly what was not pasted. No item is silently
    /// dropped. The frequency of every pasted (text-merged) record is bumped.
    @discardableResult
    func pasteOrdered(
        ids: [RecordID],
        sideEffectGate: MacClippyPasteInjectionGate? = nil
    ) throws -> MacClippyMultiPasteResult {
        try measureDiagnosticMetric("paste_ordered") {
            let resolution = try resolveOrderedMultiSelection(ids: ids)

            switch resolution {
            case let .mergedText(text):
                let injection = injectPasteboardContent(
                    .text(text),
                    frequencyIDs: ids,
                    sideEffectGate: sideEffectGate
                )
                return .merged(injected: injection == .injected)
            case let .mixed(supportedIDs, unsupportedIDs, unsupportedKinds):
                return .mixed(
                    supportedIDs: supportedIDs,
                    unsupportedIDs: unsupportedIDs,
                    unsupportedKinds: unsupportedKinds
                )
            case let .textUnavailable(availableIDs, unavailableIDs, unavailableKinds):
                // No paste and no frequency bump: an unavailable/undecodable
                // payload must not be silently merged as an empty piece, and the
                // available records must not be pasted as a partial selection.
                return .textUnavailable(
                    availableIDs: availableIDs,
                    unavailableIDs: unavailableIDs,
                    unavailableKinds: unavailableKinds
                )
            }
        }
    }

    /// P1 ordered multi-copy: resolve the selection through the SAME pure
    /// MacClippyDockMultiPastePolicy as pasteOrdered (shared resolution, no
    /// classification duplication), then for a homogeneous text-compatible
    /// selection prepare the merged text on the pasteboard WITHOUT injecting
    /// any keyboard event. Copy all must never post a paste keystroke. The
    /// mixed/unavailable cases mirror pasteOrdered so the dock shows the same
    /// no-silent-data-loss feedback and never prepares a subset. Copy never
    /// bumps frequency (matching the single copy(id:) path); only paste bumps
    /// frequency.
    @discardableResult
    func copyOrdered(
        ids: [RecordID],
        sideEffectGate: MacClippyPasteInjectionGate? = nil
    ) throws -> MacClippyMultiCopyResult {
        let resolution = try resolveOrderedMultiSelection(ids: ids)

        switch resolution {
        case let .mergedText(text):
            // Prepare the pasteboard only; never inject a Cmd+V keystroke.
            // The pasteInjector's prepare path uses the writeSentinel so Mac
            // Clippy's own write is suppressed by the observer, exactly like
            // the single copy(id:) path.
            let prepared = pasteInjector.prepare(.text(text), gate: sideEffectGate)
            return .merged(prepared: prepared)
        case let .mixed(supportedIDs, unsupportedIDs, unsupportedKinds):
            return .mixed(
                supportedIDs: supportedIDs,
                unsupportedIDs: unsupportedIDs,
                unsupportedKinds: unsupportedKinds
            )
        case let .textUnavailable(availableIDs, unavailableIDs, unavailableKinds):
            // No pasteboard write: an unavailable/undecodable payload must not
            // be silently merged as an empty piece, and the available records
            // must not be copied as a partial selection.
            return .textUnavailable(
                availableIDs: availableIDs,
                unavailableIDs: unavailableIDs,
                unavailableKinds: unavailableKinds
            )
        }
    }

}
