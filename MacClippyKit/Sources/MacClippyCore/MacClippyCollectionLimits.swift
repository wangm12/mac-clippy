import Foundation

/// Bounds for user-authored collections. These values protect the encrypted
/// pinboard and snippet envelopes from becoming an unbounded memory or storage
/// surface while leaving normal productivity content unconstrained in practice.
public enum MacClippyCollectionLimits {
    public static let maxNameUTF8Bytes = 256
    public static let maxSnippetBodyUTF8Bytes = 1 * 1_024 * 1_024
    public static let maxSnippetTriggerUTF8Bytes = 128
    public static let maxOCRTextUTF8Bytes = 1 * 1_024 * 1_024
    public static let maxPinboardItems = 10_000
    public static let maxPinboards = 512
    public static let maxSnippets = 512
    public static let maxColorUTF8Bytes = 64
}
