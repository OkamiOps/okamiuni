import Foundation
import Testing

/// EventKit só apresenta a autorização de agenda no app assinado quando o
/// bundle declara a justificativa e as duas configurações de sandbox carregam
/// a capacidade. Esta prova é estática porque a suíte do pacote roda num
/// `xctest`, não dentro do bundle do OkamiUNI.
@Suite("Metadados de calendário do app")
struct CalendarCapabilityMetadataTests {
    /// `<raiz>/Packages/UNIShell/Tests/UNIShellTests/<este arquivo>`.
    private var raiz: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // UNIShellTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // UNIShell
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // raiz
    }

    @Test("Info.plist declara por que a Agenda precisa de acesso completo")
    func descricaoDeUso() throws {
        let info = try plist(named: "App/Info.plist")
        let texto = info["NSCalendarsFullAccessUsageDescription"] as? String
        #expect(texto?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
    }

    @Test("Release e Debug carregam a entitlement de Calendários")
    func entitlementNosDoisAlvos() throws {
        for caminho in ["App/OkamiUNI.entitlements", "App/OkamiUNI-Debug.entitlements"] {
            let entitlements = try plist(named: caminho)
            #expect(
                entitlements["com.apple.security.personal-information.calendars"] as? Bool == true,
                "faltou a entitlement de Calendários em \(caminho)"
            )
        }
    }

    private func plist(named caminho: String) throws -> [String: Any] {
        let data = try Data(contentsOf: raiz.appendingPathComponent(caminho))
        return try #require(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            "\(caminho) precisa conter um plist de dicionário"
        )
    }
}
