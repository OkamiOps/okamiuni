import Foundation

/// Dados do protótipo, para desenvolver e testar a UI antes dos backends.
///
/// As contas aqui são **exemplos** que o designer usou — não o escopo do
/// produto, que aceita quantas contas o usuário quiser, de qualquer provedor
/// e qualquer domínio. Nenhum teste deve afirmar a quantidade destas contas.
public enum Fixtures {

    public static let accounts: [Account] = [
        Account(id: "zoho", address: "ricardo@empresa.com",
                displayName: "Empresa", provider: .imap, tintLightHex: "#3F6AA1", tintDarkHex: "#8CBAF7"),
        Account(id: "gmail", address: "ricardo@gmail.com",
                displayName: "Pessoal", provider: .gmail, tintLightHex: "#725B9A", tintDarkHex: "#C2A7F4"),
        Account(id: "host", address: "contato@meusite.com",
                displayName: "Site", provider: .imap, tintLightHex: "#397852", tintDarkHex: "#88D1A2"),
        Account(id: "icloud", address: "ricardo@icloud.com",
                displayName: "iCloud", provider: .imap, tintLightHex: "#298084", tintDarkHex: "#71D0D5"),
    ]

    /// Âncora fixa para os testes não dependerem do relógio.
    /// Terça, 25 de agosto de 2026, meio-dia — o "hoje" do protótipo.
    ///
    /// Sem fuso explícito, de propósito: tudo que lê esta data (o cabeçalho da
    /// agenda, os horários das mensagens) formata com `Calendar.current`. Fixá-la
    /// num fuso faria o dia e a hora renderizados variarem conforme a máquina —
    /// era esse o bug que trocava o meio-dia por 17:00 em Berlim.
    public static let today: Date = {
        var c = DateComponents()
        c.year = 2026; c.month = 8; c.day = 25
        c.hour = 12; c.minute = 0
        return Calendar(identifier: .gregorian).date(from: c)!
    }()

    /// Meio-dia em minutos desde a meia-noite, como `AgendaItem` modela horário.
    /// Literal em vez de derivado de `today`: horário de parede não deveria
    /// precisar de uma conversão que pode errar.
    public static let nowMinute: Int = 720

    private static func at(_ hour: Int, _ minute: Int) -> Date {
        Calendar.current.date(
            bySettingHour: hour, minute: minute, second: 0, of: today
        ) ?? today
    }

    public static let messages: [Message] = [
        Message(
            id: "m1", accountID: "zoho",
            from: Contact(name: "Marina Duarte", address: "marina@clientepremium.com"),
            receivedAt: at(9, 42),
            subject: "Revisão do contrato — podemos fechar quinta?",
            snippet: "Revisei as cláusulas 4 e 7. Consigo assinar se conseguirmos uma call quinta às 15h para alinhar o escopo de suporte.",
            body: [
                "Ricardo, tudo bem?",
                "Revisei as cláusulas 4 e 7 com o jurídico. A única pendência real é o escopo de suporte — queremos deixar claro o SLA de resposta em horário comercial.",
                "Consigo assinar ainda esta semana se conseguirmos uma call na quinta às 15h.",
            ],
            tags: [
                Tag(name: "Precisa resposta", tintHex: "#A8722B"),
                Tag(name: "Compromisso", tintHex: "#3F6AA1"),
            ],
            bucket: .today, isRead: false,
            summary: "Marina fecha o contrato com dois ajustes no escopo de suporte e pede uma call na quinta às 15h. Assinatura precisa sair até sexta — ela viaja depois.",
            detectedEvent: DetectedEvent(
                label: "Call de contrato · qui 27, 15:00",
                start: Calendar.current.date(byAdding: .day, value: 2, to: at(15, 0))!,
                duration: 3600
            )
        ),
        Message(
            id: "m2", accountID: "zoho",
            from: Contact(name: "Equipe Produto", address: "produto@empresa.com"),
            receivedAt: at(8, 30),
            subject: "Notas do standup — bloqueio no deploy",
            snippet: "Deu problema no certificado SSL de madrugada. Precisamos de uma decisão sua hoje.",
            body: [
                "Bom dia,",
                "O certificado SSL expirou às 03h. Subimos o provisório, mas a renovação definitiva precisa da sua aprovação.",
            ],
            tags: [
                Tag(name: "Precisa resposta", tintHex: "#A8722B"),
                Tag(name: "Equipe", tintHex: "#3F6AA1"),
            ],
            bucket: .today, isRead: false, summary: nil, detectedEvent: nil
        ),
        Message(
            id: "m3", accountID: "host",
            from: Contact(name: "Formulário do site", address: "contato@meusite.com"),
            receivedAt: at(7, 15),
            subject: "Novo lead: consultoria para 40 pessoas",
            snippet: "Empresa de logística, 40 funcionários, quer proposta de consultoria até o fim do mês.",
            body: [
                "Nome: Transportadora TransRota",
                "Mensagem: Precisamos de uma proposta de consultoria em segurança para 40 funcionários.",
            ],
            tags: [
                Tag(name: "Lead", tintHex: "#397852"),
                Tag(name: "Prazo", tintHex: "#A8722B"),
            ],
            bucket: .later, isRead: true, summary: nil, detectedEvent: nil
        ),
        Message(
            id: "m4", accountID: "gmail",
            from: Contact(name: "Boletim Swift", address: "news@swiftweekly.dev"),
            receivedAt: at(6, 0),
            subject: "Swift 6.3 e o que mudou em concorrência",
            snippet: "Resumo das mudanças de isolamento e o que quebra em projetos existentes.",
            body: ["Edição desta semana."],
            tags: [Tag(name: "Leitura", tintHex: nil)],
            bucket: .archived, isRead: true, summary: nil, detectedEvent: nil
        ),
    ]

    /// A trilha de "Terça, 25 de agosto" do protótipo, em minutos desde a meia-noite.
    public static let agenda: [AgendaItem] = [
        AgendaItem(id: "e1", title: "Standup produto",
                   startMinute: 570, endMinute: 600, accountID: "zoho"),
        AgendaItem(id: "e2", title: "1:1 Marina Duarte",
                   startMinute: 660, endMinute: 705, accountID: "zoho"),
        AgendaItem(id: "e3", title: "Almoço — bloqueado",
                   startMinute: 750, endMinute: 810, accountID: "icloud"),
        AgendaItem(id: "e4", title: "Revisão do contrato",
                   startMinute: 840, endMinute: 900, accountID: "zoho"),
        AgendaItem(id: "e5", title: "Foco: proposta TransRota",
                   startMinute: 990, endMinute: 1080, accountID: "host"),
    ]

    /// Itens pendentes detectados nos emails, para a seção "Vindo do email" da trilha.
    public static let pendingItems: [PendingItem] = [
        PendingItem(id: "p1", text: "Confirmar call de contrato com Marina — quinta 15h", accountID: "zoho"),
        PendingItem(id: "p2", text: "Renovar domínio meusite.com antes de 06/09", accountID: "host"),
    ]
}

/// Um item pendente detectado num email, para agendamento ou follow-up.
public struct PendingItem: Sendable, Hashable, Identifiable {
    public let id: String
    public let text: String
    public let accountID: String

    public init(id: String, text: String, accountID: String) {
        self.id = id
        self.text = text
        self.accountID = accountID
    }
}
