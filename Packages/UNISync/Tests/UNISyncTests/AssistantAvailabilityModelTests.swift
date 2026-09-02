import Foundation
import Testing
@testable import UNISync
import UNICore

@Suite("Modelo observável de disponibilidade")
@MainActor
struct AssistantAvailabilityModelTests {
    private func store() throws -> AssistantSettingsStore {
        let suite = "okamiuni.assistant-availability-model.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return AssistantSettingsStore(defaults: defaults, key: "assistant")
    }

    private static let remoto = AssistantAvailability.needsSignIn(
        AssistantDestination(label: "Grok · xAI", detail: "Sai deste Mac para a xAI.", isLocal: false),
        provider: .xAI
    )

    @Test("salvar preferências dispara a sonda e troca o estado observado")
    func saveTriggersProbe() async throws {
        let store = try store()
        let sonda = SondaDeEnsaio(resultado: Self.remoto)
        let model = AssistantAvailabilityModel(
            settingsStore: store, probe: { await sonda.medir() }
        )
        #expect(model.availability == .ready(.onThisMac))

        try store.save(.init(provider: .providerOAuth, providerOAuth: .init(kind: .xAI, model: "grok-4.6")))
        await esperar { model.availability == Self.remoto }

        #expect(model.availability == Self.remoto)
        #expect(await sonda.chamadas == 1)
    }

    /// Coalescência: a sonda do Codex sobe um processo. Duas medidas pedidas
    /// ao mesmo tempo têm de virar duas medidas **em fila**, nunca duas ao
    /// mesmo tempo — e a segunda existe porque a primeira pode ter lido o
    /// estado de antes da mudança.
    @Test("duas medidas simultâneas nunca correm em paralelo")
    func refreshNeverRunsInParallel() async throws {
        let store = try store()
        let sonda = SondaDeEnsaio(resultado: Self.remoto)
        let model = AssistantAvailabilityModel(
            settingsStore: store, probe: { await sonda.medir() }
        )

        async let primeira: Void = model.refresh()
        async let segunda: Void = model.refresh()
        _ = await (primeira, segunda)
        await esperar { await sonda.chamadas == 2 }

        #expect(await sonda.simultaneasNoPico == 1)
        #expect(await sonda.chamadas == 2)
        #expect(model.availability == Self.remoto)
    }

    /// Espera ativa curta: o handler do cofre agenda uma `Task`, e o teste não
    /// pode adivinhar quando ela roda.
    private func esperar(_ condicao: () async -> Bool) async {
        for _ in 0..<400 {
            if await condicao() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// Conta chamadas e mede quantas correram ao mesmo tempo.
private actor SondaDeEnsaio {
    private let resultado: AssistantAvailability
    private(set) var chamadas = 0
    private(set) var simultaneasNoPico = 0
    private var emVoo = 0

    init(resultado: AssistantAvailability) { self.resultado = resultado }

    func medir() async -> AssistantAvailability {
        chamadas += 1
        emVoo += 1
        simultaneasNoPico = max(simultaneasNoPico, emVoo)
        // Uma suspensão real: sem ela duas chamadas nunca se encontrariam.
        try? await Task.sleep(for: .milliseconds(20))
        emVoo -= 1
        return resultado
    }
}
