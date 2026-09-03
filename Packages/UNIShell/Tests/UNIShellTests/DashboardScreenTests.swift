import AppKit
import Foundation
import os
import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

/// A porta de envio espiã: guarda o que saiu pela fila, sem rede nenhuma.
/// É ela que prova o ruling de 2026-09-03 — o que **não** pode ter saído, e o
/// que saiu com `In-Reply-To` quando a pessoa clicou.
private final class SendPortSpy: MailSendPort, @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [OutgoingMessage] = []
    var sent: [OutgoingMessage] {
        lock.lock(); defer { lock.unlock() }
        return _sent
    }

    func send(_ message: OutgoingMessage) throws {
        lock.lock(); defer { lock.unlock() }
        _sent.append(message)
    }
}

/// O espião do assistente: qualquer chamada aqui é a IA sendo consultada — e
/// o Enviar do dashboard **nunca** pode chegar nele.
private final class DashboardSpyAssistant: TextAssisting, Sendable {
    let modelVersion = "spy/dashboard-08"
    private let contadores = OSAllocatedUnfairLock(initialState: (answers: 0, transforms: 0))
    var answers: Int { contadores.withLock { $0.answers } }
    var transforms: Int { contadores.withLock { $0.transforms } }

    func availability() async -> AppleIntelligenceAvailability { .available }

    func answer(
        question: String, in conversation: AssistantConversationSnapshot
    ) async throws -> String {
        contadores.withLock { $0.answers += 1 }
        return "resposta"
    }

    func transform(
        _ text: String, using action: WritingAction, context: AssistantMailContext?
    ) async throws -> String {
        contadores.withLock { $0.transforms += 1 }
        return "rascunho"
    }
}

/// Espião das ações rápidas: o `ContextCommand` que a linha emite, sem
/// executar nada.
@MainActor
private final class CommandSpy {
    var commands: [ContextCommand] = []
}

/// Caixa de seleção alcançável por `Binding` — ver a nota na versão antiga
/// desta suíte: o `CliqueDeEnsaio` roda tudo na main, e o `@unchecked` é
/// honesto por isso.
private final class CaixaDeSelecao: @unchecked Sendable {
    var selecionado: String?
    var lendo: String?
    var descartados: [String] = []
    var perguntou = false
}

// MARK: - A fixture: a caixa do dono em 3 de setembro de 2026

/// Os sete emails que motivaram o redesenho, como o `DayPlanTests` de UNICore
/// os escreve — aqui montados num `MailStore` de verdade, com as três contas
/// e a agenda do dia.
@MainActor
enum DiaDoDono {

    /// Quinta, 3 de setembro de 2026, 10:00.
    static let agora: Date = {
        var partes = DateComponents()
        partes.year = 2026; partes.month = 9; partes.day = 3; partes.hour = 10
        return Calendar.current.date(from: partes)!
    }()
    static let agoraMinuto = 600

    static let contas = [
        Account(
            id: "vantion", address: "contato@vantion.com.br", displayName: "Vantion",
            provider: .imap, host: "vantion", tintLightHex: "#3D6FA5", tintDarkHex: "#6FA8DC"
        ),
        Account(
            id: "okamiops", address: "marcos@okamiops.com", displayName: "Okamiops",
            provider: .imap, host: "okamiops", tintLightHex: "#2F8659", tintDarkHex: "#6CC894"
        ),
        Account(
            id: "gmail", address: "msant262@gmail.com", displayName: "Gmail",
            provider: .gmail, host: "gmail", tintLightHex: "#B26A2B", tintDarkHex: "#F0A060"
        ),
    ]

    private static func data(diasAtras: Int, hora: Int = 14, minuto: Int = 12) -> Date {
        let calendario = Calendar.current
        let dia = calendario.date(byAdding: .day, value: -diasAtras, to: agora)!
        return calendario.date(bySettingHour: hora, minute: minuto, second: 0, of: dia)!
    }

    private static func hoje(hora: Int, minuto: Int = 0) -> Date {
        Calendar.current.date(bySettingHour: hora, minute: minuto, second: 0, of: agora)!
    }

    private static func email(
        id: String, conta: String, de: Contact, recebido: Date,
        assunto: String, trecho: String, corpo: [String],
        lido: Bool = true, resumo: String? = nil,
        triagem: MessageTriage? = nil, marcas: BulkMailMarks = []
    ) -> Message {
        Message(
            id: id, accountID: conta, from: de, receivedAt: recebido,
            subject: assunto, snippet: trecho, body: corpo,
            tags: [], bucket: .today, isRead: lido,
            summary: resumo, detectedEvent: nil,
            // O Message-ID do cabeçalho: é dele que o In-Reply-To da resposta
            // nasce (M3-9) — sem ele a resposta abriria conversa nova.
            triage: triagem, rfcMessageID: "<\(id)@exemplo>", bulkMarks: marcas
        )
    }

    static var jack: Message {
        email(
            id: "jack", conta: "okamiops",
            de: Contact(name: "Jack Whitmore", address: "jack@whitmore.dev"),
            recebido: data(diasAtras: 7),
            assunto: "Okami Tally doesn't show up for \"tally\"",
            trecho: "I can't find Okami Tally when I search for \"tally\". "
                + "Does the page require a login?",
            corpo: [
                "Hi Marcos,",
                "I can't find Okami Tally when I search for \"tally\". "
                    + "Does the page require a login?",
                "Thanks, Jack",
            ],
            resumo: "Não encontra o Okami Tally e pergunta se a página exige login.",
            triagem: MessageTriage(needsReply: true, intent: .request, urgency: .normal)
        )
    }

    static var jayden: Message {
        email(
            id: "jayden", conta: "gmail",
            de: Contact(name: "Jayden Sutherland", address: "jayden@consult.example"),
            recebido: data(diasAtras: 2),
            assunto: "Paid Consultation Opportunity: Endpoint Operating Systems",
            trecho: "Please share two windows that work for you this week.",
            corpo: ["Please share two windows that work for you this week."],
            resumo: "Pede dois horários seus para uma consultoria paga.",
            triagem: MessageTriage(
                needsReply: true, intent: .scheduling, urgency: .high,
                deadline: DetectedDeadline(
                    date: hoje(hora: 18), evidence: "confirmar até hoje às 18h"
                )
            )
        )
    }

    static var cats9th: Message {
        email(
            id: "cats9th", conta: "gmail",
            de: Contact(name: "Cats9th", address: "editor@cats9th.example"),
            recebido: data(diasAtras: 5),
            assunto: "Re: Check out your chapter page and personal bio",
            trecho: "Atualize seu perfil quando puder.",
            corpo: ["Atualize seu perfil quando puder."],
            resumo: "Pede para atualizar seu perfil no site deles.",
            triagem: MessageTriage(needsReply: true, intent: .request, urgency: .low)
        )
    }

    static var abacus: Message {
        email(
            id: "abacus", conta: "gmail",
            de: Contact(name: "Abacus AI", address: "no-reply@abacus.ai"),
            recebido: hoje(hora: 9, minuto: 54),
            assunto: "Erinnerung: Ihre 6,000 Bonus-Credits laufen in wenigen Tagen ab",
            trecho: "Ihre Bonus-Credits laufen ab.",
            corpo: ["Ihre Bonus-Credits laufen ab."],
            lido: false,
            triagem: MessageTriage(
                needsReply: true, intent: .transactional, urgency: .normal,
                deadline: DetectedDeadline(
                    date: data(diasAtras: -2, hora: 23, minuto: 59),
                    evidence: "6.000 créditos expiram sábado"
                )
            ),
            marcas: [.listUnsubscribe]
        )
    }

    static var maria: Message {
        email(
            id: "maria", conta: "vantion",
            de: Contact(name: "Maria Exemplo", address: "maria@exemplo.com.br"),
            recebido: data(diasAtras: 1, hora: 16, minuto: 3),
            assunto: "Orçamento de identidade visual",
            trecho: "Gostaria de um orçamento de identidade visual.",
            corpo: ["Gostaria de um orçamento de identidade visual."],
            lido: false,
            resumo: "Pediu orçamento de identidade visual pelo formulário do site.",
            triagem: MessageTriage(needsReply: true, intent: .lead, urgency: .high)
        )
    }

    static var carol: Message {
        email(
            id: "carol", conta: "gmail",
            de: Contact(name: "Carol da Zoho", address: "carol@campanhas.zoho.example"),
            recebido: data(diasAtras: 1, hora: 11),
            assunto: "Zoho One: 30% off para novas equipes",
            trecho: "Aproveite a promoção.", corpo: ["Aproveite a promoção."],
            lido: false,
            triagem: MessageTriage(needsReply: true, intent: .lead, urgency: .normal),
            marcas: [.listUnsubscribe]
        )
    }

    static var resend: Message {
        email(
            id: "resend", conta: "gmail",
            de: Contact(name: "Resend", address: "no-reply@resend.example"),
            recebido: data(diasAtras: 3, hora: 8),
            assunto: "Welcome to Resend",
            trecho: "Obrigado por criar sua conta.", corpo: ["Obrigado por criar sua conta."],
            lido: false,
            triagem: MessageTriage(needsReply: true, intent: .newsletter, urgency: .low),
            marcas: [.listUnsubscribe]
        )
    }

    static var seteEmails: [Message] { [jack, jayden, cats9th, abacus, maria, carol, resend] }

    static var agenda: [AgendaItem] {
        [
            AgendaItem(
                id: "odette", title: "Termin de Odette",
                startMinute: 570, endMinute: 600, accountID: "gmail"
            ),
            AgendaItem(
                id: "aitherion", title: "Aitherion Labs · Estratégia Econômica",
                startMinute: 600, endMinute: 720, accountID: "gmail"
            ),
            AgendaItem(
                id: "almoco", title: "Almoço",
                startMinute: 720, endMinute: 780, accountID: "gmail"
            ),
        ]
    }

    static func draft(_ message: Message, _ texto: String) -> ReadyDraft {
        ReadyDraft(
            messageID: message.id, text: texto,
            contentHash: ReadyDraft.contentHash(for: message),
            modelVersion: "foundation-1",
            usedAgenda: message.triage?.intent == .scheduling
        )
    }

    static var rascunhos: [String: ReadyDraft] {
        [
            "jack": draft(
                jack,
                "Oi Jack,\n\nSim — hoje a página exige login, por isso a busca não acha. "
                    + "Libero a pública até sexta.\n\nAbraço,\nMarcos"
            ),
            "jayden": draft(
                jayden,
                "Oi Jayden,\n\nTerça 9/9 ou quinta 11/9, das 15h às 17h.\n\nAbraço,\nMarcos"
            ),
            "maria": draft(
                maria,
                "Oi Maria,\n\nObrigado pelo contato — posso te ligar amanhã às 10h?"
                    + "\n\nAbraço,\nMarcos"
            ),
        ]
    }

    static func loja(
        mensagens: [Message]? = nil,
        agenda agendaDoDia: [AgendaItem]? = nil,
        sendPort: MailSendPort? = nil
    ) async -> MailStore {
        let hoje = agora
        let store = MailStore(
            source: InMemoryMailSource(
                accounts: contas,
                messages: mensagens ?? seteEmails,
                agenda: agendaDoDia ?? agenda
            ),
            sendPort: sendPort,
            agendaReferenceDay: { hoje }
        )
        await store.load()
        return store
    }
}

// MARK: - A suíte

@Suite("Dashboard 08")
@MainActor
struct DashboardScreenTests {

    /// 1440 × 852 — o conteúdo sob o chrome de 64, como a tabela de medidas.
    private static let size = CGSize(width: 1_440, height: 852)

    private func inertConversation() -> AssistantConversation {
        AssistantConversation(
            scope: .email,
            context: .init(subject: "Caixa e agenda de hoje"),
            destination: .init(label: "Codex · ChatGPT", detail: "", isLocal: false),
            engine: AssistantEngine(supportsDraftReply: false) { _ in "" }
        )
    }

    private func tela(
        _ store: MailStore,
        drafts: [String: ReadyDraft] = DiaDoDono.rascunhos,
        conversation: AssistantConversation? = nil,
        filter: DayPlan.Filter = .standard,
        selected: String? = nil,
        caixa: CaixaDeSelecao? = nil,
        commandSpy: CommandSpy? = nil,
        confirming: String? = nil
    ) -> some View {
        let caixa = caixa ?? CaixaDeSelecao()
        if let selected { caixa.selecionado = selected }
        return DashboardScreen(
            store: store,
            now: DiaDoDono.agoraMinuto,
            today: DiaDoDono.agora,
            drafts: drafts,
            conversation: conversation ?? inertConversation(),
            filter: .constant(filter),
            selectedMailID: Binding(
                get: { caixa.selecionado }, set: { caixa.selecionado = $0 }
            ),
            readingMailID: Binding(get: { caixa.lendo }, set: { caixa.lendo = $0 }),
            onCommand: { commandSpy?.commands.append($0) },
            onDiscardDraft: { caixa.descartados.append($0) },
            onAskAssistant: { caixa.perguntou = true },
            debugConfirmingSendID: confirming
        )
        .environment(ThemeStore())
    }

    // MARK: - Render: os estados do mockup, em okami e tinta

    @Test("os seis estados do 08 desenham em okami e em tinta")
    func rendersTheStatesInBothThemes() async throws {
        let cheia = await DiaDoDono.loja()
        let semHeroi = await DiaDoDono.loja(
            mensagens: [DiaDoDono.carol, DiaDoDono.resend]
        )
        let diaLivre = await DiaDoDono.loja(agenda: [])

        let estados: [(String, MailStore, [String: ReadyDraft], DayPlan.Filter, String?)] = [
            ("com-heroi", cheia, DiaDoDono.rascunhos, .standard, nil),
            ("sem-heroi", semHeroi, [:], .standard, nil),
            ("rascunho-selecionado", cheia, DiaDoDono.rascunhos, .standard, "jack"),
            ("sem-rascunho", cheia, [:], .standard, "cats9th"),
            ("sem-gente", cheia, DiaDoDono.rascunhos,
             DayPlan.Filter(on: [.deadlines, .leads], accounts: []), nil),
            ("dia-livre", diaLivre, DiaDoDono.rascunhos, .standard, nil),
        ]

        for theme in [Theme.okami, Theme.tinta] {
            for (nome, store, drafts, filtro, selecionado) in estados {
                let rep = try #require(Render.snapshot(
                    tela(store, drafts: drafts, filter: filtro, selected: selecionado),
                    named: "tela08-\(nome)-\(theme.id)",
                    size: Self.size,
                    theme: theme
                ), "\(theme.id)/\(nome) não desenhou")
                #expect(rep.pixelsWide == 1_440)
                #expect(rep.pixelsHigh == 852)
                #expect(
                    rep.pixels(matching: theme.paper, tolerance: 0.01) > 100_000,
                    "\(theme.id)/\(nome) perdeu o fundo paper"
                )
                // A régua da tela inteira: com herói, exatamente **uma** caixa
                // de cor (accentSoft); sem herói, nenhuma.
                let caixaDeCor = rep.pixels(matching: theme.accentSoft, tolerance: 0.015)
                if nome == "sem-heroi" || nome == "sem-gente" {
                    // Desligar "Gente" tira a linha do herói do plano — e sem
                    // herói o bloco não aparece, sem placeholder.
                    #expect(caixaDeCor < 500, "\(theme.id)/\(nome) desenhou herói sem herói")
                } else {
                    #expect(caixaDeCor > 20_000, "\(theme.id)/\(nome) perdeu a caixa do herói")
                }
            }
        }
    }

    @Test("com e sem rascunho, a prévia muda — e a lista não")
    func draftCardLivesInThePreview() async throws {
        let store = await DiaDoDono.loja()
        func recorte(_ drafts: [String: ReadyDraft]) throws -> NSBitmapImageRep {
            try #require(Render.bitmap(
                tela(store, drafts: drafts, selected: "jack"),
                size: Self.size, theme: .okami
            ))
        }
        let com = try recorte(DiaDoDono.rascunhos)
        let sem = try recorte([:])
        // A prévia mora entre as hairlines (~700..1090): o cartão aparece lá.
        #expect(
            com.pixelsDiffering(from: sem, inColumns: 710..<1_080, rows: 300..<700) > 500,
            "o cartão do rascunho não apareceu na prévia"
        )
    }

    // MARK: - Cliques

    /// Onde está o centro de um aglomerado de pixels desta cor, dentro do
    /// recorte dado. É a régua que dispensa coordenadas chutadas: mede no
    /// desenho e clica no que mediu.
    private func centro(
        de token: TokenColor, em rep: NSBitmapImageRep,
        x: Range<Int>, y: Range<Int>, tolerance: Double = 0.06
    ) -> CGPoint? {
        guard let alvo = token.nsColor.usingColorSpace(.sRGB) else { return nil }
        var somaX = 0, somaY = 0, n = 0
        for py in y where py < rep.pixelsHigh {
            for px in x where px < rep.pixelsWide {
                guard let c = rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) else { continue }
                if abs(c.redComponent - alvo.redComponent) < tolerance,
                   abs(c.greenComponent - alvo.greenComponent) < tolerance,
                   abs(c.blueComponent - alvo.blueComponent) < tolerance {
                    somaX += px; somaY += py; n += 1
                }
            }
        }
        guard n > 8 else { return nil }
        return CGPoint(x: Double(somaX) / Double(n), y: Double(somaY) / Double(n))
    }

    /// As faixas verticais onde as ações em accent aparecem na lista — uma
    /// por linha com ação, de cima para baixo.
    private func faixasDeAcao(
        em rep: NSBitmapImageRep, cor: TokenColor, x: Range<Int>,
        aPartirDe y0: Int, ate y1: Int = .max
    ) -> [ClosedRange<Int>] {
        guard let alvo = cor.nsColor.usingColorSpace(.sRGB) else { return [] }
        func temCor(_ py: Int) -> Bool {
            for px in x {
                guard let c = rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) else { continue }
                if abs(c.redComponent - alvo.redComponent) < 0.06,
                   abs(c.greenComponent - alvo.greenComponent) < 0.06,
                   abs(c.blueComponent - alvo.blueComponent) < 0.06 { return true }
            }
            return false
        }
        var faixas: [ClosedRange<Int>] = []
        var inicio: Int?
        for py in y0..<min(y1, rep.pixelsHigh) {
            if temCor(py) {
                if inicio == nil { inicio = py }
            } else if let i = inicio {
                if py - i > 3 { faixas.append(i...(py - 1)) }
                inicio = nil
            }
        }
        return faixas
    }

    /// O y logo abaixo do herói (o fim da mancha `accentSoft`).
    private func fimDoHeroi(_ rep: NSBitmapImageRep, theme: Theme) -> Int {
        var fim = 0
        for py in 0..<300 {
            for px in 100..<1_300 {
                if let c = rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB),
                   let alvo = theme.accentSoft.nsColor.usingColorSpace(.sRGB),
                   abs(c.redComponent - alvo.redComponent) < 0.015,
                   abs(c.greenComponent - alvo.greenComponent) < 0.015,
                   abs(c.blueComponent - alvo.blueComponent) < 0.015 {
                    fim = py
                    break
                }
            }
        }
        return fim
    }

    /// **O ruling**: Enviar na linha NÃO envia. Um clique no Enviar da
    /// primeira linha não põe nada na porta de envio — ele só arma a
    /// confirmação (e seleciona a linha).
    @Test("Enviar na linha não envia sem a confirmação")
    func rowSendDoesNotSendWithoutConfirmation() async throws {
        let porta = SendPortSpy()
        let store = await DiaDoDono.loja(sendPort: porta)
        let caixa = CaixaDeSelecao()

        // Mede no desenho onde o Enviar da linha do Jack está.
        let rep = try #require(Render.bitmap(
            tela(store, caixa: caixa), size: Self.size, theme: .tinta
        ))
        let base = fimDoHeroi(rep, theme: .tinta) + 80
        let faixas = faixasDeAcao(em: rep, cor: Theme.tinta.accent, x: 300..<700, aPartirDe: base)
        let primeira = try #require(faixas.first, "não achei as ações da primeira linha")
        let alvo = try #require(centro(
            de: Theme.tinta.accent, em: rep,
            x: 300..<700, y: primeira.lowerBound..<(primeira.upperBound + 1)
        ))

        CliqueDeEnsaio.em(
            tela(store, caixa: caixa),
            size: Self.size, aY: alvo.y, x: alvo.x
        )
        #expect(porta.sent.isEmpty, "o Enviar da linha enviou sem confirmação")
        #expect(caixa.selecionado == "jayden", "o Enviar da linha não selecionou a linha")
    }

    /// A outra metade do ruling: com a confirmação armada, o Enviar **dela**
    /// envia pela fila de saída normal — com `In-Reply-To` — e consome o
    /// rascunho. A IA não é chamada.
    @Test("o Enviar da confirmação envia pela porta, com In-Reply-To")
    func confirmationSendGoesThroughThePort() async throws {
        let porta = SendPortSpy()
        let espiao = DashboardSpyAssistant()
        let store = await DiaDoDono.loja(sendPort: porta)
        let caixa = CaixaDeSelecao()
        let conversa = AssistantConversation(
            scope: .email,
            context: .init(subject: "Caixa"),
            destination: .init(label: "Neste Mac", detail: "", isLocal: true),
            engine: AssistantBridge.engine(
                using: espiao, supportsDraftReply: true,
                mailContext: { AssistantMailContext(message: DiaDoDono.jayden) }
            )
        )

        // A tela nasce com a confirmação armada (porta do harness) e o clique
        // cai no Enviar **da confirmação**.
        let armada = tela(
            store, conversation: conversa, selected: "jayden",
            caixa: caixa, confirming: "jayden"
        )
        let rep = try #require(Render.bitmap(armada, size: Self.size, theme: .tinta))
        let base = fimDoHeroi(rep, theme: .tinta) + 80
        let faixas = faixasDeAcao(em: rep, cor: Theme.tinta.accent, x: 300..<700, aPartirDe: base)
        let primeira = try #require(faixas.first)
        let alvo = try #require(centro(
            de: Theme.tinta.accent, em: rep,
            x: 300..<700, y: primeira.lowerBound..<(primeira.upperBound + 1)
        ))

        CliqueDeEnsaio.em(armada, size: Self.size, aY: alvo.y, x: alvo.x)

        #expect(porta.sent.count == 1, "o Enviar da confirmação não enviou")
        let saiu = try #require(porta.sent.first)
        #expect(saiu.to.map(\.address) == ["jayden@consult.example"])
        #expect(saiu.inReplyTo != nil, "a resposta saiu sem In-Reply-To")
        #expect(saiu.plainText.contains("Terça 9/9"))
        #expect(caixa.descartados == ["jayden"], "o rascunho enviado não foi consumido")
        #expect(espiao.answers == 0 && espiao.transforms == 0, "o Enviar falou com a IA")
    }

    /// **Na prévia o Enviar envia direto** — o rascunho inteiro está na tela.
    @Test("o Enviar da prévia envia direto pela porta e nunca chama a IA")
    func previewSendGoesStraightThroughThePort() async throws {
        let porta = SendPortSpy()
        let espiao = DashboardSpyAssistant()
        let store = await DiaDoDono.loja(sendPort: porta)
        let caixa = CaixaDeSelecao()
        let conversa = AssistantConversation(
            scope: .email,
            context: .init(subject: "Caixa"),
            destination: .init(label: "Neste Mac", detail: "", isLocal: true),
            engine: AssistantBridge.engine(
                using: espiao, supportsDraftReply: true,
                mailContext: { AssistantMailContext(message: DiaDoDono.jack) }
            )
        )

        let armada = tela(store, conversation: conversa, selected: "jack", caixa: caixa)
        let rep = try #require(Render.bitmap(armada, size: Self.size, theme: .tinta))
        // O único bloco sólido de accent na prévia é o botão Enviar do cartão.
        let alvo = try #require(centro(
            de: Theme.tinta.accent, em: rep, x: 720..<1_080, y: 200..<852
        ), "não achei o Enviar do cartão do rascunho")

        CliqueDeEnsaio.em(armada, size: Self.size, aY: alvo.y, x: alvo.x)

        #expect(porta.sent.count == 1, "o Enviar da prévia não enviou")
        #expect(porta.sent.first?.to.map(\.address) == ["jack@whitmore.dev"])
        #expect(caixa.descartados == ["jack"])
        #expect(espiao.answers == 0 && espiao.transforms == 0, "o Enviar da prévia chamou a IA")
    }

    /// "Arquivar e aprender" emite **os dois** comandos na mesma leva.
    @Test("Arquivar e aprender emite .move e .learnSender juntos")
    func archiveAndLearnEmitsBothCommands() async throws {
        let store = await DiaDoDono.loja()
        let espiao = CommandSpy()
        let caixa = CaixaDeSelecao()

        let armada = tela(store, caixa: caixa, commandSpy: espiao)
        let rep = try #require(Render.bitmap(armada, size: Self.size, theme: .tinta))
        let base = fimDoHeroi(rep, theme: .tinta) + 80
        let faixas = faixasDeAcao(em: rep, cor: Theme.tinta.accent, x: 300..<700, aPartirDe: base)
        // Jack, Jayden, Cats9th ("Sexta 9h"), Abacus ("Arquivar e aprender").
        #expect(faixas.count >= 4, "a lista não desenhou as quatro linhas com ação")
        let abacus = try #require(faixas.dropFirst(3).first)
        let alvo = try #require(centro(
            de: Theme.tinta.accent, em: rep,
            x: 300..<700, y: abacus.lowerBound..<(abacus.upperBound + 1)
        ))

        CliqueDeEnsaio.em(armada, size: Self.size, aY: alvo.y, x: alvo.x)

        #expect(espiao.commands == [
            .move(messageID: "abacus", to: .archived),
            .learnSender(address: "no-reply@abacus.ai", neverPriority: true),
        ], "a leva não saiu inteira: \(espiao.commands)")
    }

    /// "Reservar" cria o compromisso pelo caminho de agenda existente.
    @Test("Reservar cria o evento do bloco sugerido")
    func reserveCreatesTheAgendaItem() async throws {
        let store = await DiaDoDono.loja()
        #expect(store.agenda.count == 3)

        let armada = tela(store)
        let rep = try #require(Render.bitmap(armada, size: Self.size, theme: .tinta))
        // O "Reservar" é o aglomerado de accent mais baixo da coluna do dia
        // (abaixo do "Agora"; os prazos escrevem a hora em warn, não accent).
        let faixas = faixasDeAcao(
            em: rep, cor: Theme.tinta.accent, x: 1_140..<1_408,
            aPartirDe: fimDoHeroi(rep, theme: .tinta) + 40, ate: 760
        )
        let ultima = try #require(faixas.last, "não achei o Reservar na coluna do dia")
        let alvo = try #require(centro(
            de: Theme.tinta.accent, em: rep,
            x: 1_140..<1_408, y: ultima.lowerBound..<(ultima.upperBound + 1)
        ))

        CliqueDeEnsaio.em(armada, size: Self.size, aY: alvo.y, x: alvo.x)

        #expect(store.agenda.count == 4, "o Reservar não criou o compromisso")
        let novo = try #require(
            store.agenda.first { $0.title.hasPrefix("Responder") }
        )
        #expect(novo.startMinute == 780, "o bloco não caiu na folga das 13h")
        #expect(novo.durationMinutes == DayPlan.replyBlockMinutes)
    }

    /// O botão "Perguntar · ⌘J" abre o painel do assistente que já existe.
    @Test("o botão Perguntar abre o painel do assistente")
    func askButtonOpensTheAssistant() async throws {
        let store = await DiaDoDono.loja()
        let caixa = CaixaDeSelecao()

        CliqueDeEnsaio.em(
            tela(store, caixa: caixa),
            size: Self.size,
            aY: Self.size.height - DashboardMetrics.askButtonBottom
                - DashboardMetrics.askButtonHeight / 2,
            x: Self.size.width - DashboardMetrics.askButtonTrailing - 60
        )
        #expect(caixa.perguntou, "o botão Perguntar não abriu o painel")
    }

    /// **A queixa mais dura do dono**: clicar não abre. Um clique seleciona;
    /// abrir é 2× clique (e ⏎, provado em `DashboardKeys`).
    @Test("um clique seleciona a linha e não abre a folha")
    func clickSelectsWithoutOpening() async throws {
        let store = await DiaDoDono.loja()
        let caixa = CaixaDeSelecao()

        let rep = try #require(Render.bitmap(
            tela(store, caixa: caixa), size: Self.size, theme: .tinta
        ))
        let base = fimDoHeroi(rep, theme: .tinta) + 80
        let faixas = faixasDeAcao(em: rep, cor: Theme.tinta.accent, x: 300..<700, aPartirDe: base)
        let segunda = try #require(faixas.dropFirst().first)
        let y = CGFloat(segunda.lowerBound)

        CliqueDeEnsaio.em(tela(store, caixa: caixa), size: Self.size, aY: y, x: 150)
        #expect(caixa.selecionado == "cats9th", "o clique não selecionou a segunda linha")
        #expect(caixa.lendo == nil, "o clique abriu a folha do leitor")

        let caixa2 = CaixaDeSelecao()
        CliqueDeEnsaio.em(
            tela(store, caixa: caixa2), size: Self.size, aY: y, x: 150, cliques: 2
        )
        #expect(caixa2.lendo == "cats9th", "o duplo clique não abriu a folha")
    }

    /// ⏎ abre o selecionado, e só ele — a decisão pura, sem sintetizar tecla.
    @Test("⏎ abre o selecionado, e só ele")
    func enterOpensTheSelection() {
        #expect(DashboardKeys.opens(
            key: .enter, selectedID: "m1", readingID: nil, exists: true
        ) == "m1")
        #expect(DashboardKeys.opens(
            key: .enter, selectedID: nil, readingID: nil, exists: false
        ) == nil)
        #expect(DashboardKeys.opens(
            key: .enter, selectedID: "m1", readingID: "m1", exists: true
        ) == nil)
        for key in [BareKey.delete, .up, .down, .escape] {
            #expect(DashboardKeys.opens(
                key: key, selectedID: "m1", readingID: nil, exists: true
            ) == nil)
        }
    }

    /// O que o 08 mandou **remover** — caso de fonte, porque nenhum destes
    /// deixa rastro de pixel afirmável sozinho.
    @Test("o campo de pergunta, os chips e a barra lateral sumiram da fonte")
    func removedDecorations() throws {
        let raiz = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/UNIShell/Inbox")
        let arquivos = ["DashboardScreen.swift", "DashboardRow.swift",
                        "DashboardPreviewColumn.swift", "DashboardDayColumn.swift"]
        for nome in arquivos {
            let fonte = try String(
                contentsOf: raiz.appendingPathComponent(nome), encoding: .utf8
            )
            for proibido in [
                // O campo do rodapé saiu; o botão Perguntar o substitui.
                "DashboardAskField", "Pergunte sobre seus emails",
                // Chips e barra lateral da linha morreram com o 07.
                "TintChip", "chipRole", "accountBarWidth",
                // Só o herói tem cor; nenhum radiusLarge nesta tela.
                "radiusLarge",
            ] {
                #expect(!fonte.contains(proibido), "\(proibido) continua em \(nome)")
            }
        }
    }
}
