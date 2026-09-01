import AppKit
import SwiftUI
import UNIDesign

/// Lobo do OkamiUNI na barra de título, na escala de um item de toolbar —
/// a mesma linha do semáforo e do recolhe. Sem wordmark: o nome inteiro
/// desalinha a fileira e pesa na lateral.
struct BrandLockup: View {
    @Environment(\.theme) private var theme

    static let titlebarSize: CGFloat = 22

    static func markAssetName(isDark: Bool) -> String {
        isDark ? "uni-mark-dark" : "uni-mark-light"
    }

    var body: some View {
        let name = NSImage.Name(Self.markAssetName(isDark: theme.isDark))
        Image(nsImage: NSImage(named: name) ?? NSImage(size: CGSize(width: Self.titlebarSize, height: Self.titlebarSize)))
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: Self.titlebarSize, height: Self.titlebarSize)
            .accessibilityLabel("OkamiUNI")
            .allowsHitTesting(false)
    }
}
