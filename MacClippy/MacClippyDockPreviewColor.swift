import Foundation
import MacClippyCore
import SwiftUI

struct MacClippyDockPreviewColor: View {
    let value: String
    let swatch: MacClippyColorSwatch

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    private var swatchColor: Color {
        Color(
            red: Double(swatch.rgb.red) / 255,
            green: Double(swatch.rgb.green) / 255,
            blue: Double(swatch.rgb.blue) / 255
        )
    }

    private var overlayTextColor: Color {
        MacClippyDockPreviewColorContrast.prefersDarkText(for: swatch.rgb) ? .black : .white
    }

    private var borderOpacity: Double {
        colorSchemeContrast == .increased || differentiateWithoutColor ? 0.45 : 0.22
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(swatchColor)
                .overlay(alignment: .bottomLeading) {
                    Text(swatch.hex)
                        .font(.title2.weight(.semibold).monospaced())
                        .foregroundStyle(overlayTextColor)
                        .padding(16)
                        .textSelection(.enabled)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.primary.opacity(borderOpacity), lineWidth: 1)
                }
                .frame(maxWidth: .infinity, minHeight: 180, maxHeight: 260)

            VStack(alignment: .leading, spacing: 6) {
                caption("HEX", swatch.hex)
                caption("RGB", "rgb(\(swatch.rgb.red), \(swatch.rgb.green), \(swatch.rgb.blue))")
                caption("HSL", swatch.hslDisplay)
                if value.trimmingCharacters(in: .whitespacesAndNewlines) != swatch.hex {
                    caption("Original", value)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Color \(swatch.hex)")
    }

    private func caption(_ label: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.caption.weight(.semibold).monospaced())
                .foregroundStyle(MacClippyDockTheme.contentMutedColor)
                .frame(width: 56, alignment: .leading)
            Text(text)
                .font(.caption.monospaced())
                .foregroundStyle(MacClippyDockTheme.contentTextColor)
                .textSelection(.enabled)
        }
    }
}

enum MacClippyDockPreviewColorContrast {
    static func prefersDarkText(for rgb: MacClippyRGB) -> Bool {
        luminanceComponent(rgb.red) * 0.2126
            + luminanceComponent(rgb.green) * 0.7152
            + luminanceComponent(rgb.blue) * 0.0722 > 0.56
    }

    private static func luminanceComponent(_ value: Int) -> Double {
        let channel = Double(value) / 255
        if channel <= 0.03928 {
            return channel / 12.92
        }
        return pow((channel + 0.055) / 1.055, 2.4)
    }
}
