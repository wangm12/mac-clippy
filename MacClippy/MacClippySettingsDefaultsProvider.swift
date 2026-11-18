import SwiftUI

@MainActor
final class MacClippySettingsDefaultsProvider: ObservableObject {
    @Published private(set) var defaults: UserDefaults?

    func install(_ defaults: UserDefaults) {
        self.defaults = defaults
    }
}

@MainActor
struct MacClippySettingsDefaultsHost: View {
    @ObservedObject var provider: MacClippySettingsDefaultsProvider

    var body: some View {
        if let defaults = provider.defaults {
            MacClippySettingsView(defaults: defaults)
                .defaultAppStorage(defaults)
        } else {
            ProgressView()
                .frame(
                    minWidth: MacClippySettingsMetrics.minWidth,
                    minHeight: MacClippySettingsMetrics.minHeight
                )
        }
    }
}
