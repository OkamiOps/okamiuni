import Foundation
import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

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

    // MARK: - A noite do dono: a captura que abriu esta onda

    /// 3 de setembro de 2026, **21h40** — a hora da captura dele.
    static let noite: Date = {
        var partes = DateComponents()
        partes.year = 2026; partes.month = 9; partes.day = 3
        partes.hour = 21; partes.minute = 40
        return Calendar.current.date(from: partes)!
    }()
    static let noiteMinuto = 1_300

    /// O formulário de teste do site: o remetente é ele mesmo. Ninguém é lead
    /// de si próprio, e a captura tinha isto etiquetado "LEAD NOVO".
    static var formulario: Message {
        email(
            id: "formulario", conta: "okamiops",
            de: Contact(name: "Marcos Santos", address: "marcos@okamiops.com"),
            recebido: data(diasAtras: 0, hora: 15, minuto: 20),
            assunto: "Novo contato pelo site — teste",
            trecho: "Testando o formulário de contato do site.",
            corpo: ["Testando o formulário de contato do site."],
            lido: false,
            resumo: "Teste do formulário de contato do próprio site.",
            triagem: MessageTriage(needsReply: true, intent: .lead, urgency: .high)
        )
    }

    /// A frase longa que a captura mostrava cortada em "Okami Tally está fora
    /// dos top 200…".
    static var tally: Message {
        email(
            id: "tally", conta: "okamiops",
            de: Contact(name: "Bruno Aoki", address: "bruno@parceiro.example"),
            recebido: data(diasAtras: 4, hora: 11, minuto: 30),
            assunto: "Okami Tally sumiu da busca",
            trecho: "Okami Tally está fora dos top 200 resultados para a "
                + "palavra que ele mesmo carrega no nome.",
            corpo: [
                "Okami Tally está fora dos top 200 resultados para a palavra "
                    + "que ele mesmo carrega no nome. Dá para olhar esta semana?",
            ],
            lido: false,
            resumo: "Okami Tally está fora dos top 200 resultados para a "
                + "palavra que ele mesmo carrega no nome.",
            triagem: MessageTriage(needsReply: true, intent: .request, urgency: .normal)
        )
    }

    /// Os seis azulejos da captura: quatro pedidos, um lead de verdade e o
    /// formulário do próprio dono. As máquinas (Abacus, Carol, Resend) entram
    /// para o excedente contar certo.
    static var seisAzulejos: [Message] {
        [jack, jayden, cats9th, maria, formulario, tally, abacus, carol, resend]
    }

    /// A agenda que o eixo de 09–19 escondia: uma reunião à 01 h e um voo às
    /// 23h30, com o dia normal no meio.
    static var agendaDaNoite: [AgendaItem] {
        [
            AgendaItem(
                id: "madrugada", title: "Call com Tóquio",
                startMinute: 60, endMinute: 120, accountID: "gmail"
            ),
            AgendaItem(
                id: "manha", title: "Aitherion Labs · Estratégia Econômica",
                startMinute: 570, endMinute: 600, accountID: "gmail"
            ),
            AgendaItem(
                id: "voo", title: "Voo GRU · Lisboa",
                startMinute: 1_410, endMinute: 1_440, accountID: "vantion"
            ),
        ]
    }

    /// Mais uma promessa sua, para encher a coluna "Você deve".
    static func promessaExtra(_ n: Int) -> PendingItem {
        PendingItem(
            id: "extra-p\(n)",
            text: "Prometido número \(n) — mando até o fim da semana",
            accountID: "vantion",
            dueDate: Calendar.current.date(byAdding: .day, value: n, to: noite)
        )
    }

    /// Mais um pedido de gente, para encher a coluna até ela passar do pé.
    static func extra(_ n: Int) -> Message {
        email(
            id: "extra\(n)", conta: "vantion",
            de: Contact(name: "Pessoa \(n)", address: "pessoa\(n)@exemplo.com.br"),
            recebido: data(diasAtras: 3, hora: 9, minuto: n),
            assunto: "Assunto número \(n) que ocupa uma linha inteira da coluna",
            trecho: "Uma pergunta curta que ainda assim ocupa duas linhas "
                + "inteiras do azulejo, como as da captura.",
            corpo: ["Uma pergunta curta."],
            lido: false,
            triagem: MessageTriage(needsReply: true, intent: .request, urgency: .normal)
        )
    }

    /// A caixa da captura: seis azulejos, o dia inteiro na agenda, 21h40 no
    /// relógio e **nenhuma** resposta pronta.
    static func lojaDaNoite(
        mensagens: [Message]? = nil, pendentes: [PendingItem] = []
    ) async -> MailStore {
        let quando = noite
        let store = MailStore(
            source: InMemoryMailSource(
                accounts: contas,
                messages: mensagens ?? seisAzulejos,
                agenda: agendaDaNoite,
                pendingItems: pendentes
            ),
            agendaReferenceDay: { quando }
        )
        await store.load()
        return store
    }

    /// A mesma caixa com o dobro de gente esperando — é o que faz a lista
    /// passar do pé da coluna e obriga a rolagem a existir.
    static var caixaLonga: [Message] {
        var todas = seteEmails
        for n in 1...6 {
            todas.append(email(
                id: "extra\(n)", conta: "vantion",
                de: Contact(name: "Pessoa \(n)", address: "pessoa\(n)@exemplo.com.br"),
                recebido: data(diasAtras: 3, hora: 9, minuto: n),
                assunto: "Assunto número \(n) que ocupa uma linha inteira da coluna da lista",
                trecho: "Uma pergunta curta.", corpo: ["Uma pergunta curta."],
                lido: false,
                triagem: MessageTriage(needsReply: true, intent: .request, urgency: .normal)
            ))
        }
        return todas
    }

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

    /// As duas promessas do dono, com o prazo que o email dele afirma — é
    /// delas que sai "Você deve" e o bloco de 45 min da linha do tempo.
    static var promessas: [PendingItem] {
        [
            PendingItem(
                id: "p-marina",
                text: "Proposta para a Marina — \"mando até quinta\"",
                accountID: "vantion", dueDate: hoje(hora: 18)
            ),
            PendingItem(
                id: "p-tally",
                text: "Liberar o Tally público — prometido ao Jack",
                accountID: "okamiops", dueDate: data(diasAtras: -2, hora: 12)
            ),
        ]
    }

    static func loja(
        mensagens: [Message]? = nil,
        agenda agendaDoDia: [AgendaItem]? = nil,
        pendentes: [PendingItem]? = nil,
        sendPort: MailSendPort? = nil
    ) async -> MailStore {
        let hoje = agora
        let store = MailStore(
            source: InMemoryMailSource(
                accounts: contas,
                messages: mensagens ?? seteEmails,
                agenda: agendaDoDia ?? agenda,
                pendingItems: pendentes ?? promessas
            ),
            sendPort: sendPort,
            agendaReferenceDay: { hoje }
        )
        await store.load()
        return store
    }
}
