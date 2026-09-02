import AppKit
import SwiftUI
import Testing
import UNICore
import UNIDesign
import UNISync
@testable import UNIShell

@Suite("A fila de análise pausada na barra lateral")
@MainActor
struct AnalysisPausedBandTests {
    private let grok = AssistantDestination(
        label: "Grok · xAI", detail: "Sai deste Mac para a xAI.", isLocal: false
    )

    @Test("a faixa diz o que parou e oferece o religar")
    func copy() {
        #expect(AnalysisPausedBand.title == "ANÁLISE PAUSADA")
        #expect(AnalysisPausedBand.retryTitle == "Tentar de novo")
    }

    /// Sem pausa não há faixa: a barra da caixa cheia continua exatamente
    /// como estava, e o padrão do inicializador é justamente esse.
    @Test("a barra nasce sem faixa de pausa")
    func defaultsToNoBand() async {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        #expect(FolderSidebar(store: store).analysisPause == nil)
    }

    @Test("clicar em Tentar de novo entrega a intenção ao app")
    func retryCallsItsClosure() async {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        var retries = 0

        CliqueDeEnsaio.em(
            FolderSidebar(
                store: store,
                analysisPause: AnalysisPauseState(
                    reason: "A chave de API foi recusada."
                ) { retries += 1 }
            ),
            size: CGSize(width: FolderSidebar.expandedWidth, height: 620),
            aY: 520,
            x: 44
        )

        #expect(retries == 1)
    }

    /// A legenda do TL;DR é feita pela **fila**, não pelo assistente
    /// interativo: com o opt-in remoto ligado, prometer "neste Mac" seria
    /// mentira sobre onde a mensagem foi lida.
    @Test("a legenda do TL;DR nomeia o destino real da análise")
    func summaryCaptionFollowsTheAnalysisDestination() {
        #expect(ReaderPane.summaryCaption(for: .onThisMac) == "TL;DR · neste Mac")
        #expect(ReaderPane.summaryCaption(for: grok) == "TL;DR · Grok · xAI")
    }

    /// A legenda segue a **proveniência gravada**, não a rota atual: depois do
    /// opt-in o histórico continua tendo sido resumido neste Mac, e nomear o
    /// provedor em cima dele seria a mentira oposta à que a Task 13 fechou.
    @Test("a legenda segue o motor que gravou o resumo, não a rota de agora")
    func destinationComesFromTheStoredModelVersion() {
        var settings = AssistantSettings(
            provider: .providerOAuth,
            providerOAuth: .init(kind: .xAI, model: "grok-4", credentialID: "c")
        )
        settings.automaticAnalysis = .configuredProvider
        settings.automaticAnalysisSince = Date(timeIntervalSince1970: 0)

        // Resumo do histórico, gravado pelo motor local.
        let local = settings.automaticAnalysisDestination(
            forSummaryModelVersion: FoundationModelsMessageAnalyzer.currentModelVersion
        )
        #expect(local.isLocal)
        #expect(ReaderPane.summaryCaption(for: local) == "TL;DR · neste Mac")

        // Resumo gravado pelo provedor configurado, na versão de hoje.
        let v1 = settings.automaticAnalysisDestination(
            forSummaryModelVersion: TextAssistantMessageAnalyzer.currentModelVersion
        )
        #expect(!v1.isLocal)
        #expect(ReaderPane.summaryCaption(for: v1) == "TL;DR · Grok · xAI")

        // Uma versão futura do mesmo analisador. Decidir por igualdade exata
        // faria todo resumo v1 se apresentar como "neste Mac" no dia em que a
        // constante subir — a mentira que a Task 13 tirou da tela.
        let v2 = settings.automaticAnalysisDestination(
            forSummaryModelVersion: "text-assistant/message-analysis-v2"
        )
        #expect(!v2.isLocal)
        #expect(ReaderPane.summaryCaption(for: v2) == "TL;DR · Grok · xAI")

        // Sem resumo, ou vindo de fixtures: nada de nomear provedor nenhum.
        #expect(settings.automaticAnalysisDestination(forSummaryModelVersion: nil).isLocal)
        // Uma versão desconhecida que não é deste analisador continua local:
        // o motor no dispositivo é o único que grava versões assim.
        #expect(settings.automaticAnalysisDestination(
            forSummaryModelVersion: "foundation-models/message-analysis-v9"
        ).isLocal)
    }

    /// O resumo saiu daqui, mas o provedor de então não dá mais para
    /// determinar. Uma legenda neutra é a única saída honesta: dizer "neste
    /// Mac" seria mentira, e nomear o provedor de agora seria invenção.
    @Test("resumo remoto sem provedor determinável ganha legenda neutra")
    func remoteSummaryWithUnknownProviderGetsNeutralCaption() {
        // A pessoa voltou para o Foundation Models depois de o resumo ter sido
        // gravado por um provedor remoto.
        var voltou = AssistantSettings.default
        voltou.automaticAnalysis = .onDeviceOnly
        let destino = voltou.automaticAnalysisDestination(
            forSummaryModelVersion: TextAssistantMessageAnalyzer.currentModelVersion
        )
        #expect(!destino.isLocal)
        #expect(destino == .configuredProviderUnknown)
        #expect(ReaderPane.summaryCaption(for: destino) == "TL;DR · provedor configurado")
        #expect(!destino.detail.contains("Nada sai"))
    }
}
