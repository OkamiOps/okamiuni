import AppKit
import Foundation
import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

/// Uma porta de corpo que segura a resposta até mandarem — é a única forma de
/// o estado "carregando" existir por tempo suficiente para ser desenhado.
private actor PortaSegurada: BodyFetching {
    private var avisaEntrada: CheckedContinuation<Void, Never>?
    private var entrou = false
    private var liberacao: CheckedContinuation<Void, Never>?
    private var liberada = false
    private let erro: (any Error)?

    init(falhandoCom erro: (any Error)? = nil) { self.erro = erro }

    func fetchBody(accountID: String, messageID: String) async throws -> FetchedBody {
        entrou = true
        avisaEntrada?.resume()
        avisaEntrada = nil
        if let erro { throw erro }
        if !liberada {
            await withCheckedContinuation { continuation in liberacao = continuation }
        }
        return FetchedBody(paragraphs: ["Chegou."])
    }

    func esperaEntrada() async {
        guard !entrou else { return }
        await withCheckedContinuation { continuation in avisaEntrada = continuation }
    }

    func libera() {
        liberada = true
        liberacao?.resume()
        liberacao = nil
    }
}

private struct FalhaDoServidor: LocalizedError {
    var errorDescription: String? { "A conexão com o servidor caiu." }
}

@Suite("ReaderPane: a mensagem sem corpo nunca fica muda")
struct ReaderBodyStateTests {
    private static let conta = Account(
        id: "a", address: "conta@dominio.com", displayName: "Conta",
        provider: .imap, host: "host", tintLightHex: "#3E6FA8", tintDarkHex: "#7BA8D9"
    )

    @MainActor
    private func store(porta: (any BodyFetching)?) async -> MailStore {
        let mensagem = Message(
            id: "m", accountID: "a",
            from: Contact(name: "Quem", address: "quem@exemplo.com"),
            receivedAt: .now, subject: "Assunto", snippet: "Trecho",
            body: [], tags: [], bucket: .today, isRead: false,
            summary: nil, detectedEvent: nil
        )
        let fonte = InMemoryMailSource(
            accounts: [Self.conta], messages: [mensagem], agenda: []
        )
        let store = MailStore(source: fonte, bodyPort: porta)
        await store.load()
        store.select(message: "m")
        return store
    }

    @MainActor
    private func desenha(_ store: MailStore) -> NSBitmapImageRep? {
        Render.bitmap(
            ReaderPane(store: store), size: CGSize(width: 760, height: 700), theme: .tinta
        )
    }

    /// **Prova por mutação da faixa.** As três telas — sem porta, carregando e
    /// falhou — têm o mesmo cabeçalho, o mesmo assunto e o mesmo remetente: a
    /// única coisa que pode diferir entre elas é o que a coluna do corpo diz.
    /// Um `ReaderPane` que continuasse desenhando nada nos dois estados novos
    /// (o vazio mudo que esta tarefa veio consertar) renderizaria os três
    /// idênticos, pixel a pixel.
    @Test("Carregando e falhou desenham coisas diferentes — e diferentes do vazio de antes")
    @MainActor
    func osTresEstadosSaoVisiveis() async throws {
        let mudo = try #require(desenha(await store(porta: nil)))

        let lenta = PortaSegurada()
        let comEspera = await store(porta: lenta)
        let busca = Task { await comEspera.loadBodyIfNeeded("m") }
        await lenta.esperaEntrada()
        let carregando = try #require(desenha(comEspera))
        await lenta.libera()
        await busca.value

        let quebrada = await store(porta: PortaSegurada(falhandoCom: FalhaDoServidor()))
        await quebrada.loadBodyIfNeeded("m")
        let falhou = try #require(desenha(quebrada))

        #expect(
            carregando.pixelsDiffering(from: mudo) > 0,
            "o leitor não mostrou nada enquanto o corpo baixava — é o vazio mudo de antes"
        )
        #expect(
            falhou.pixelsDiffering(from: carregando) > 0,
            "a falha desenhou igual à espera — a pessoa esperaria para sempre por algo que já morreu"
        )
        #expect(
            falhou.pixelsDiffering(from: mudo) > 0,
            "a falha não desenhou nada: erro sem saída é o mesmo vazio com mais tempo perdido"
        )
    }

    @Test("A mensagem que de fato não tem texto diz isso, em vez de nada")
    @MainActor
    func semTextoTambemFala() async throws {
        let mudo = try #require(desenha(await store(porta: nil)))

        let vazia = await store(porta: PortaVazia())
        await vazia.loadBodyIfNeeded("m")
        #expect(vazia.bodyLoad(for: "m") == .buscado)
        let buscado = try #require(desenha(vazia))

        #expect(buscado.pixelsDiffering(from: mudo) > 0)
    }

    @Test("As frases que a pessoa lê")
    func asFrases() {
        // Elas são comportamento, e é por isso que estão afirmadas: "…" e não
        // "...", e o "corpo" que a spec usa em vez de "conteúdo".
        #expect(ReaderPane.carregandoCorpo == "Carregando corpo…")
        #expect(ReaderPane.semTexto == "Esta mensagem não tem texto.")
    }

    /// A diferença não é só de texto: o estado de rede do corpo precisa ter a
    /// roda nativa, para não parecer uma legenda estática enquanto o fetch
    /// está em andamento.
    @Test("A espera do corpo usa a roda nativa")
    @MainActor
    func esperaTemSpinner() throws {
        let nota = try #require(Render.bitmap(
            ReaderNote(ReaderPane.carregandoCorpo),
            size: CGSize(width: 620, height: 90), theme: .tinta
        ))
        let espera = try #require(Render.bitmap(
            ReaderSpinnerNote(ReaderPane.carregandoCorpo),
            size: CGSize(width: 620, height: 90), theme: .tinta
        ))
        #expect(
            espera.pixelsDiffering(from: nota) > 0,
            "o carregamento do corpo perdeu a roda e voltou a parecer texto estático"
        )
    }
}

/// A mensagem sem parte de texto nenhuma: um convite de calendário, um anexo
/// sozinho. Lista vazia é resposta, não erro.
private struct PortaVazia: BodyFetching {
    func fetchBody(accountID: String, messageID: String) async throws -> FetchedBody {
        FetchedBody(paragraphs: [])
    }
}
