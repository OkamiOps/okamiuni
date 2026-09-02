import Foundation
import Testing
import UNICore
import UNISync
@testable import UNIShell

/// A cópia da ação de analisar o acervo, no cartão do provedor em Ajustes.
/// Ela é o único lugar em que a pessoa lê quantas mensagens sairão e para
/// onde, então a frase é comportamento, não decoração.
@Suite("O botão de analisar o acervo")
struct BacklogAnalysisSettingsTests {

    private func destino(_ label: String) -> AssistantDestination {
        AssistantDestination(label: label, detail: "Sai deste Mac.", isLocal: false)
    }

    @Test("o diálogo diz o número exato e nomeia o destino")
    func confirmationCopy() {
        let plano = BacklogAnalysisPlan(
            messageIDs: ["a", "b", "c", "d"],
            destination: destino("Grok · xAI"),
            modelVersion: "remoto/v1"
        )
        #expect(plano.count == 4)
        #expect(plano.confirmationText
            == "Isto envia 4 mensagens (assunto, remetente, data e corpo) "
                + "para Grok · xAI. Continuar?")
    }

    @Test("uma mensagem só não é 'mensagens'")
    func singularCopy() {
        let plano = BacklogAnalysisPlan(
            messageIDs: ["a"],
            destination: destino("Grok · xAI"),
            modelVersion: "remoto/v1"
        )
        #expect(plano.confirmationText
            == "Isto envia 1 mensagem (assunto, remetente, data e corpo) "
                + "para Grok · xAI. Continuar?")
    }

    @Test("os três rótulos da ação são os da decisão")
    func actionCopy() {
        #expect(BacklogAnalysisPlan.actionTitle == "Analisar as mensagens já recebidas")
        #expect(BacklogAnalysisPlan.confirmTitle == "Analisar")
        #expect(BacklogAnalysisPlan.cancelTitle == "Cancelar")
    }
}
