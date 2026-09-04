import AppKit
import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

/// Renders every supported interface language offscreen; no foreground input.
@Suite("Localized settings", .serialized)
@MainActor
struct LocalizationRenderTests {
    @Test func settingsInFourLanguages() async throws {
        let previous = UserDefaults.standard.object(forKey: AppLanguage.defaultsKey)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: AppLanguage.defaultsKey) }
            else { UserDefaults.standard.removeObject(forKey: AppLanguage.defaultsKey) }
        }
        for language in AppLanguage.allCases where language != .system {
            AppLanguage.selected = language
            let view = GeneralSettingsView(
                settingsStore: nil, credentialStore: nil, textAssistant: nil,
                themes: ThemeStore(), swipes: nil
            ).environment(\.locale, language.locale)
            let bitmap = try #require(Render.snapshot(
                view, named: "settings-\(language.rawValue)",
                size: CGSize(width: 760, height: 730), theme: .tinta
            ))
            #expect(bitmap.pixelsWide == 760)
            #expect(bitmap.pixelsHigh == 730)
            let store = MailStore(source: InMemoryMailSource.fixtures)
            await store.load()
            let inbox = InboxScreen(store: store)
                .environment(ThemeStore())
                .environment(\.locale, language.locale)
            _ = try #require(Render.snapshot(
                inbox, named: "inbox-\(language.rawValue)",
                size: CGSize(width: 1200, height: 916), theme: .tinta
            ))
            let calendar = CalendarScreen(store: store, now: Fixtures.nowMinute, anchor: Fixtures.today)
                .environment(ThemeStore())
                .environment(\.locale, language.locale)
            _ = try #require(Render.snapshot(
                calendar, named: "calendar-\(language.rawValue)",
                size: CGSize(width: 1200, height: 916), theme: .tinta
            ))
        }
    }
}
