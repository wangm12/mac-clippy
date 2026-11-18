#if MACCLIPPY_E2E
import Foundation

struct MacClippyE2EPasteboardProof: Codable, Equatable, Sendable {
    let itemIndex: Int
    let uti: String
    let byteCount: Int
    let sha256: String
}

struct MacClippyE2EPasteProbeEvidence: Codable, Sendable {
    let cancellationResult: String
    let cancellationReachedAdmission: Bool
    let cancellationPostedEventPairs: Int
    let cancellationRestoredOriginals: Bool
    let foreignGenerationResult: String
    let foreignGenerationReachedAdmission: Bool
    let foreignGenerationPostedEventPairs: Int
    let foreignGenerationPreserved: Bool
    let admittedResult: String
    let admittedPostedEventPairs: Int
    let admittedCompletionCount: Int
    let admittedPreparedClipboardLeftInPlace: Bool
    let originalRepresentations: [MacClippyE2EPasteboardProof]
    let cancellationRepresentations: [MacClippyE2EPasteboardProof]
    let foreignRepresentations: [MacClippyE2EPasteboardProof]
    let postRaceForeignRepresentations: [MacClippyE2EPasteboardProof]
    let admittedRepresentations: [MacClippyE2EPasteboardProof]
    let namedPasteboardsOnly: Bool
    let realKeyEventsPosted: Bool
    let allPassed: Bool
}
#endif
