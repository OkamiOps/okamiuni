import AppKit
import CoreText
import os

/// Tracks which of the design's font families are actually installed.
///
/// The design calls for Newsreader, Space Grotesk, Inter, Inter Tight,
/// IBM Plex Mono and JetBrains Mono. Until those faces are bundled,
/// `FontFamily.font(size:weight:)` falls back to the system face rather than
/// silently rendering in Helvetica.
public enum FontRegistry {
    private static let cache = OSAllocatedUnfairLock<[String: Bool]>(initialState: [:])

    /// Families the design references, in the order it prefers them.
    public static let required = [
        "Newsreader",
        "Space Grotesk",
        "Inter",
        "Inter Tight",
        "IBM Plex Mono",
        "JetBrains Mono",
    ]

    public static func isAvailable(_ family: String) -> Bool {
        cache.withLock { cache in
            if let known = cache[family] { return known }
            let found = NSFontManager.shared.availableFontFamilies.contains(family)
            cache[family] = found
            return found
        }
    }

    /// Registers every font in the given bundle's `Fonts/` directory.
    /// Safe to call more than once.
    @discardableResult
    public static func registerBundledFonts(in bundle: Bundle = .main) -> [String] {
        let urls = bundle.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? []
        let otf = bundle.urls(forResourcesWithExtension: "otf", subdirectory: "Fonts") ?? []
        var registered: [String] = []

        for url in urls + otf {
            var error: Unmanaged<CFError>?
            if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                registered.append(url.lastPathComponent)
            } else if let error = error?.takeRetainedValue() {
                let code = CFErrorGetCode(error)
                // kCTFontManagerErrorAlreadyRegistered
                if code != 105 {
                    print("[UNIDesign] failed to register \(url.lastPathComponent): \(error)")
                }
            }
        }

        if !registered.isEmpty {
            cache.withLock { $0.removeAll() }
        }
        return registered
    }

    /// Families the design wants that are not installed. Empty means the app
    /// renders exactly as designed.
    public static var missing: [String] {
        required.filter { !isAvailable($0) }
    }
}
