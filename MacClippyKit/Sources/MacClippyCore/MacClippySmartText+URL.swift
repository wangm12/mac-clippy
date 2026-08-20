import Foundation

extension MacClippySmartText {
    public static func matchesURL(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.contains(where: { $0.isWhitespace }),
              let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased() else {
            return false
        }
        return ["http", "https"].contains(scheme) && !(components.host?.isEmpty ?? true)
    }
}
