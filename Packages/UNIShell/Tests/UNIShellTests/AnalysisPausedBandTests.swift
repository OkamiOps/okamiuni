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

    @Test("o destino da análise vem da rota, não do provedor interativo")
    func destinationComesFromTheRoute() {
        var settings = AssistantSettings(
            provider: .providerOAuth,
            providerOAuth: .init(kind: .xAI, model: "grok-4", credentialID: "c")
        )
        #expect(settings.automaticAnalysisDestination.isLocal)
        #expect(ReaderPane.summaryCaption(for: settings.automaticAnalysisDestination)
            == "TL;DR · neste Mac")

        settings.automaticAnalysis = .configuredProvider
        #expect(!settings.automaticAnalysisDestination.isLocal)
        #expect(settings.automaticAnalysisDestination.label == "Grok · xAI")
    }
}
