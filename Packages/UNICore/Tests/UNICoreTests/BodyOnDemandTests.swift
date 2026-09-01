import Foundation
import Testing
@testable import UNICore

/// Uma porta de corpo que o teste conduz: ela avisa quando foi chamada e só
/// responde quando mandarem.
///
/// Existe porque o estado "carregando" só é observável **durante** a espera —
/// e uma porta que responde na hora torna "esperou" e "não precisou esperar"
/// indistinguíveis, que é exatamente o que não pode acontecer aqui.
private actor PortaConduzida: BodyFetching {
    private var chamadas: [String] = []
    private var resposta: Result<FetchedBody, any Error>
    private var avisaEntrada: CheckedContinuation<Void, Never>?
    private var entrou = false
    private var liberacao: CheckedContinuation<Void, Never>?
    private var liberada: Bool

    init(resposta: Result<FetchedBody, any Error>, seguraAResposta: Bool = false) {
        self.resposta = resposta
        self.liberada = !seguraAResposta
    }

    func fetchBody(accountID: String, messageID: String) async throws -> FetchedBody {
        chamadas.append(messageID)
        entrou = true
        avisaEntrada?.resume()
        avisaEntrada = nil
        if !liberada {
            await withCheckedContinuation { continuation in liberacao = continuation }
        }
        return try resposta.get()
    }

    func esperaEntrada() async {
        guard !entrou else { return }
        await withCheckedContinuation { continuation in avisaEntrada = continuation }
    }

    func libera(respondendo novo: Result<FetchedBody, any Error>? = nil) {
        if let novo { resposta = novo }
        liberada = true
        liberacao?.resume()
        liberacao = nil
    }

    var quantasChamadas: Int { chamadas.count }
}

private struct FalhaDoServidor: LocalizedError {
    var errorDescription: String? { "A conexão com o servidor caiu." }
}

@Suite("O corpo por demanda, do lado do MailStore")
@MainActor
struct BodyOnDemandTests {
    private func store(
        corpo: [String] = [], porta: (any BodyFetching)? = nil,
        html: String? = ""
    ) -> MailStore {
        let mensagem = Message(
            id: "m1", accountID: "conta-a",
            from: Contact(name: "Marina", address: "marina@x.com"),
            receivedAt: Date(timeIntervalSince1970: 1_800_000_000),
            subject: "Revisão do contrato", snippet: "Revisão do contrato",
            body: corpo, tags: [], bucket: .today, isRead: false,
            summary: nil, detectedEvent: nil, bodyHTML: html
        )
        let fonte = InMemoryMailSource(
            accounts: [Account(
                id: "conta-a", address: "eu@x.com", displayName: "Eu",
                provider: .imap, host: "x", tintLightHex: "#3F6AA1", tintDarkHex: "#8CBAF7"
            )],
            messages: [mensagem], agenda: []
        )
        return MailStore(source: fonte, bodyPort: porta)
    }

    @Test("Mensagem sem corpo: a porta é chamada, o estado passa por `carregando`, o texto chega")
    func caminhoFeliz() async throws {
        let porta = PortaConduzida(
            resposta: .success(FetchedBody(paragraphs: ["A revisão do contrato ficou pronta."])), seguraAResposta: true
        )
        let store = store(porta: porta)
        await store.load()
        #expect(store.bodyLoad(for: "m1") == nil)

        let busca = Task { await store.loadBodyIfNeeded("m1") }
        await porta.esperaEntrada()
        // **Prova por mutação da espera.** Um `loadBodyIfNeeded` que buscasse
        // sem anunciar deixaria o leitor com a coluna em branco enquanto a rede
        // trabalha — que é o vazio mudo que esta tarefa veio consertar, só que
        // por alguns segundos em vez de para sempre.
        #expect(store.bodyLoad(for: "m1") == .carregando)

        await porta.libera()
        await busca.value

        #expect(store.bodyLoad(for: "m1") == .buscado)
        #expect(store.message("m1")?.body == ["A revisão do contrato ficou pronta."])
        #expect(await porta.quantasChamadas == 1)
    }

    @Test("O assistente lê o HTML hidratado, não o snippet da lista")
    func assistantUsesHydratedHTMLNotListSnippet() async throws {
        let html = "<p>Hi Marcos,</p><p>1. What is/was your role with IGEL OS?</p>"
        let porta = PortaConduzida(resposta: .success(
            FetchedBody(
                paragraphs: ["Hi Marcos, I'm reaching out to gauge your interest."],
                html: html
            )
        ))
        let store = store(porta: porta, html: nil)
        await store.load()
        await store.loadBodyIfNeeded("m1")

        #expect(store.messages.first?.body.isEmpty == true)
        #expect(store.messages.first?.hasHTML == false)
        #expect(store.message("m1")?.bodyHTML == html)

        guard case let .email(context) = store.assistantMailContext(for: "m1") else {
            Issue.record("Esperava contexto de um email hidratado")
            return
        }
        #expect(context.html == html)
        #expect(context.body.contains("Hi Marcos"))
        #expect(OnDeviceAssistantEmailContext(message: store.messages.first!).html == nil)
    }

    @Test("Mensagem que já tem corpo e já foi decodificada não gasta viagem nenhuma")
    func comCorpoNaoBusca() async throws {
        let porta = PortaConduzida(resposta: .success(FetchedBody(paragraphs: ["não devia ser pedido"])))
        let store = store(corpo: ["Já está aqui."], porta: porta)
        await store.load()
        await store.loadBodyIfNeeded("m1")
        #expect(await porta.quantasChamadas == 0)
        #expect(store.bodyLoad(for: "m1") == nil)
    }

    @Test("Sem porta, nada acontece — as fixtures do Marco 1 continuam idênticas")
    func semPorta() async throws {
        let store = store()
        await store.load()
        await store.loadBodyIfNeeded("m1")
        #expect(store.bodyLoad(for: "m1") == nil)
        #expect(store.messages.first?.body.isEmpty == true)
    }

    @Test("A falha vira estado com causa, e não some")
    func falha() async throws {
        let porta = PortaConduzida(resposta: .failure(FalhaDoServidor()))
        let store = store(porta: porta)
        await store.load()
        await store.loadBodyIfNeeded("m1")

        #expect(store.bodyLoad(for: "m1") == .falhou("A conexão com o servidor caiu."))
        // A falha **para** as tentativas automáticas: abrir e fechar a mensagem
        // dez vezes não pode virar dez conexões contra um servidor que já
        // recusou. Quem volta a tentar é a pessoa.
        await store.loadBodyIfNeeded("m1")
        #expect(await porta.quantasChamadas == 1)
    }

    @Test("`Tentar de novo` limpa a falha e busca outra vez")
    func tentarDeNovo() async throws {
        let porta = PortaConduzida(resposta: .failure(FalhaDoServidor()))
        let store = store(porta: porta)
        await store.load()
        await store.loadBodyIfNeeded("m1")
        #expect(store.bodyLoad(for: "m1") == .falhou("A conexão com o servidor caiu."))

        await porta.libera(respondendo: .success(FetchedBody(paragraphs: ["Agora foi."])))
        await store.retryBody("m1")

        #expect(store.bodyLoad(for: "m1") == .buscado)
        #expect(store.message("m1")?.body == ["Agora foi."])
        #expect(await porta.quantasChamadas == 2)
    }

    @Test("Corpo que volta vazio é resposta, não erro — e não vira laço")
    func corpoVazio() async throws {
        // Um convite de calendário, um anexo sozinho: existem mensagens sem
        // texto nenhum. Sem o estado `buscado`, o leitor pediria o corpo de
        // novo a cada redesenho, para sempre.
        let porta = PortaConduzida(resposta: .success(FetchedBody(paragraphs: [])))
        let store = store(porta: porta)
        await store.load()
        await store.loadBodyIfNeeded("m1")
        #expect(store.bodyLoad(for: "m1") == .buscado)

        await store.loadBodyIfNeeded("m1")
        #expect(await porta.quantasChamadas == 1)
    }

    @Test("Corpo gravado por uma versão que jogava o HTML fora: uma rebusca, e só uma")
    func htmlNaoResolvidoRebusca() async throws {
        // O caso do banco do dono: 44 mensagens com corpo em texto e nenhuma
        // linha de HTML, porque quem as gravou não guardava HTML nenhum. Elas
        // não são "sem corpo" — a guarda antiga saía na primeira linha e a
        // pessoa continuaria vendo prosa seca onde havia um email desenhado.
        let porta = PortaConduzida(resposta: .success(
            FetchedBody(paragraphs: ["A revisão."], html: "<p>A revisão.</p>")
        ))
        let store = store(corpo: ["A revisão."], porta: porta, html: nil)
        await store.load()
        await store.loadBodyIfNeeded("m1")

        #expect(await porta.quantasChamadas == 1)
        #expect(store.message("m1")?.bodyHTML == "<p>A revisão.</p>")

        // E **uma** vez: a resposta ficou no retrato, `htmlResolved` passa a
        // dizer sim, e reabrir a mensagem — mesmo depois de limpar o estado da
        // busca, que é tudo o que "Tentar de novo" faz — não paga outra viagem.
        await store.retryBody("m1")
        await store.loadBodyIfNeeded("m1")
        #expect(await porta.quantasChamadas == 1)
    }

    @Test("A mensagem que de fato é só-texto fica só-texto — a rebusca não vira laço")
    func soTextoNaoVolta() async throws {
        let porta = PortaConduzida(resposta: .success(
            FetchedBody(paragraphs: ["Bom dia."], html: "")
        ))
        let store = store(corpo: ["Bom dia."], porta: porta, html: nil)
        await store.load()
        await store.loadBodyIfNeeded("m1")
        #expect(store.message("m1")?.hasHTML == false)
        #expect(store.message("m1")?.htmlResolved == true)

        await store.retryBody("m1")
        await store.loadBodyIfNeeded("m1")
        #expect(await porta.quantasChamadas == 1)
    }

    @Test("A rebusca só pelo HTML não apaga o texto que já estava na tela")
    func rebuscaNaoApagaOTexto() async throws {
        let porta = PortaConduzida(resposta: .success(
            FetchedBody(paragraphs: [], html: "<p>Oi</p>")
        ))
        let store = store(corpo: ["O texto de antes."], porta: porta, html: nil)
        await store.load()
        await store.loadBodyIfNeeded("m1")
        #expect(store.message("m1")?.body == ["O texto de antes."])
        #expect(store.message("m1")?.bodyHTML == "<p>Oi</p>")
    }

    /// **A terceira razão para rebuscar, da M3-18.** A mensagem tem HTML — o
    /// `htmlResolved` diz sim, o texto está lá — e mesmo assim está incompleta:
    /// no lugar da foto ficou o vazio **marcado** que o Gmail deixa quando
    /// entrega a imagem embutida como `attachmentId`. É o email que o dono abriu
    /// com um buraco no meio, e a newsletter que abriu em branco.
    @Test("O HTML com imagem por buscar é rebuscado, mesmo já tendo HTML")
    func rebuscaOCorpoComImagemPendente() async throws {
        let completo = "<p>Oi</p><img src=\"data:image/png;base64,AAA\">"
        let porta = PortaConduzida(resposta: .success(
            FetchedBody(paragraphs: ["Oi"], html: completo)
        ))
        let comBuraco = "<p>Oi</p><img src=\"\(InlineImagePlaceholder.pendente)\">"
        let store = store(corpo: ["Oi"], porta: porta, html: comBuraco)
        await store.load()
        #expect(store.messages.first?.hasPendingInlineImages == true)

        await store.loadBodyIfNeeded("m1")
        #expect(await porta.quantasChamadas == 1)
        #expect(store.message("m1")?.bodyHTML == completo)
        #expect(store.message("m1")?.hasPendingInlineImages == false)
    }

    /// E o vazio de "não coube" **não** é rebuscado: ele não tem conserto, e
    /// pedi-lo de novo seria uma viagem por abertura da mensagem, para sempre.
    @Test("O vazio de `não coube` não faz o corpo ser pedido outra vez")
    func naoRebuscaOQueNaoCabe() async throws {
        let porta = PortaConduzida(resposta: .success(FetchedBody(paragraphs: ["Oi"])))
        let grandeDemais = "<p>Oi</p><img src=\"\(InlineImagePlaceholder.vazio)\">"
        let store = store(corpo: ["Oi"], porta: porta, html: grandeDemais)
        await store.load()

        await store.loadBodyIfNeeded("m1")
        #expect(await porta.quantasChamadas == 0)
    }

    @Test("Duas aberturas em cima da outra não viram duas viagens")
    func semViagemDuplicada() async throws {
        let porta = PortaConduzida(resposta: .success(FetchedBody(paragraphs: ["Um só."])), seguraAResposta: true)
        let store = store(porta: porta)
        await store.load()

        let primeira = Task { await store.loadBodyIfNeeded("m1") }
        await porta.esperaEntrada()
        await store.loadBodyIfNeeded("m1")
        await porta.libera()
        await primeira.value

        #expect(await porta.quantasChamadas == 1)
    }

    @Test("Buscar o corpo não apaga a página de Tudo")
    func corpoNaoInvalidaAPagina() async throws {
        let porta = PortaConduzida(
            resposta: .success(FetchedBody(paragraphs: ["texto"], html: "<p>texto</p>"))
        )
        let store = store(porta: porta, html: nil)
        await store.load()
        store.select(bucket: .all)
        _ = store.conversationPage(limit: 10)
        let montagens = store.conversationPageBuildCount
        await store.loadBodyIfNeeded("m1")
        store.select(bucket: .today)
        store.select(bucket: .all)
        #expect(store.conversationPageBuildCount == montagens)
        #expect(store.message("m1")?.bodyHTML == "<p>texto</p>")
    }
}
