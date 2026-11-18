#if MACCLIPPY_E2E
import Foundation

extension MacClippyE2EIsolation {
    static func validateNoSymlinksBelow(_ rootURL: URL) throws {
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: []
        ) else {
            throw MacClippyE2EIsolationError.unsafeRootContents
        }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw MacClippyE2EIsolationError.unsafeRootContents
            }
        }
    }
}
#endif
