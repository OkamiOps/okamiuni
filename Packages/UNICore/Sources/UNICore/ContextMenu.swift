import Foundation

/// O conteúdo dos menus de contexto do app, como **dado**.
///
/// Mora aqui, e não dentro das `View`, por dois motivos que já custaram caro
/// nesta base:
///
/// 1. `View` é `@MainActor` implícito no Swift 6, e um `static` lá dentro
///    herda o isolamento — um teste nonisolated que o chamasse trapa em
///    runtime (ver `docs/decisoes-de-engenharia.md`). É a mesma razão de
///    `AgendaSummary`, `PaneLayout` e `RichBody` viverem em `UNICore`.
/// 2. A regra do marco é **item morto não entra**: uma ação que não tem como
///    funcionar fica **fora** do menu, não desabilitada. Provar isso abrindo
///    menu não dá — o `NSMenu` que o `contextMenu` do SwiftUI monta não
///    aparece em renderização fora da tela. Provar sobre a lista de itens dá,
///    e é o que os testes fazem.
///
/// A `View` só traduz `[ContextMenuEntry]` para `contextMenu { … }`; nenhuma
/// decisão de conteúdo acontece lá.

// MARK: - O que um item dispara

/// A ação de um item de menu. É um valor, não um fechamento: assim o teste
/// compara o que o menu **vai fazer** sem precisar executar nada.
///
/// Nenhum caso presume conta, provedor ou domínio — os identificadores são os
/// que a mensagem, o compromisso e a conta trazem.
public enum ContextCommand: Sendable, Hashable {
    /// 05 Email em janela.
    case openMessageWindow(messageID: String)
    /// 03 Composer, respondendo esta mensagem. O mesmo caminho do botão
    /// "Responder" da fila de triagem e do ⌘R.
    case reply(messageID: String)
    /// Marca lida (`true`) ou não lida (`false`).
    case setRead(messageID: String, isRead: Bool)
    /// Triagem: move a mensagem de caixa.
    case move(messageID: String, to: TriageBucket)
    /// Percorre uma caixa marcando tudo como lido. `accountID` nulo = todas.
    case markAllRead(bucket: TriageBucket, accountID: String?)
    /// Liga o filtro de conta.
    case filterAccount(accountID: String)
    /// Desliga o filtro de conta.
    case clearAccountFilter
    /// 04 Detalhe do compromisso.
    case openEvent(itemID: String)
    /// Leva o leitor até a mensagem que originou o compromisso, trocando de
    /// aba se for preciso.
    case revealMessage(messageID: String)
    /// Área de transferência. O texto já vem pronto — quem executa não formata
    /// nada, e por isso o teste consegue afirmar o conteúdo copiado.
    case copy(String)
}

// MARK: - Atalho

/// O atalho que aparece ao lado do rótulo. Só existe quando a ação **tem** um
/// atalho de verdade em outro lugar do app: escrever um equivalente que o app
/// não escuta é a versão tipográfica do botão mudo.
public struct MenuShortcut: Sendable, Hashable {
    public struct Modifiers: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: 1 << 0)
        public static let shift = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
    }

    public let key: Character
    public let modifiers: Modifiers

    public init(key: Character, modifiers: Modifiers = .command) {
        self.key = key
        self.modifiers = modifiers
    }

    /// "⌘R". Ordem dos símbolos como o macOS escreve: ⌥ ⇧ ⌘.
    public var label: String {
        var text = ""
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + String(key).uppercased()
    }

    /// O ⌘R que o botão "Responder" do leitor já declara.
    public static let reply = MenuShortcut(key: "r")
}

// MARK: - Item e entrada

public struct ContextMenuItem: Sendable, Hashable {
    public let title: String
    public let command: ContextCommand
    public let shortcut: MenuShortcut?

    public init(_ title: String, _ command: ContextCommand, shortcut: MenuShortcut? = nil) {
        self.title = title
        self.command = command
        self.shortcut = shortcut
    }
}

/// Uma linha do menu. Separador é uma entrada como as outras para que a ordem
/// inteira caiba numa lista só — e para que o teste consiga afirmar que o menu
/// não começa nem termina com um traço.
public enum ContextMenuEntry: Sendable, Hashable {
    case item(ContextMenuItem)
    case submenu(title: String, items: [ContextMenuItem])
    case separator

    public var isSeparator: Bool {
        if case .separator = self { return true }
        return false
    }

    /// Os rótulos de primeiro nível, na ordem, sem os separadores.
    /// Existe para os testes lerem o menu como quem o lê na tela.
    public var title: String? {
        switch self {
        case .item(let item): item.title
        case .submenu(let title, _): title
        case .separator: nil
        }
    }
}

extension Array where Element == ContextMenuEntry {
    /// Os rótulos visíveis, na ordem.
    public var titles: [String] { compactMap(\.title) }

    /// Os comandos de primeiro nível, na ordem. Submenu não tem comando
    /// próprio: os dele estão em `submenuCommands`.
    public var commands: [ContextCommand] {
        compactMap {
            if case .item(let item) = $0 { return item.command }
            return nil
        }
    }

    /// Os comandos de um submenu, pelo rótulo dele.
    public func submenuCommands(_ title: String) -> [ContextCommand] {
        for case .submenu(let name, let items) in self where name == title {
            return items.map(\.command)
        }
        return []
    }

    /// Um menu bem formado não abre nem fecha com traço, e não tem dois
    /// traços seguidos — que é o que sobra quando um item condicional some.
    ///
    /// Não é cosmético: cada item deste marco pode desaparecer conforme o
    /// estado, e um menu que perde a única linha de um bloco ficaria com o
    /// separador órfão.
    public var tidied: [ContextMenuEntry] {
        var out: [ContextMenuEntry] = []
        for entry in self {
            if entry.isSeparator {
                guard let last = out.last, !last.isSeparator else { continue }
            }
            out.append(entry)
        }
        while out.last?.isSeparator == true { out.removeLast() }
        return out
    }
}

// MARK: - Os menus, por superfície

public enum ContextMenus {

    // MARK: Linha da lista de mensagens

    /// Protótipo de referência: Mail.app, Gmail e Outlook trazem, nesta ordem,
    /// abrir · responder · estado de leitura · mover · copiar.
    ///
    /// "Encaminhar" **não entra**: a janela 03 só tem os modos `.reply` e
    /// `.new`, e um item que abrisse uma resposta chamada "encaminhar" seria
    /// exatamente o botão mentiroso que a regra do marco proíbe.
    public static func messageRow(_ message: Message) -> [ContextMenuEntry] {
        var entries: [ContextMenuEntry] = [
            .item(ContextMenuItem("Abrir em janela", .openMessageWindow(messageID: message.id))),
            .item(ContextMenuItem("Responder", .reply(messageID: message.id), shortcut: .reply)),
            .separator,
            .item(readToggle(message)),
        ]
        if let move = moveSubmenu(message) { entries.append(move) }
        entries.append(.separator)
        entries.append(contentsOf: copyEntries(message))
        return entries.tidied
    }

    // MARK: Painel de leitura

    /// O corpo da mensagem.
    ///
    /// Ficaram **fora**, e cada um por um motivo medido no código:
    ///
    /// - **Copiar (seleção)** — o corpo é `Text`, sem `textSelection`. Não há
    ///   seleção para copiar, e um "Copiar" que copiasse o corpo inteiro sob
    ///   o nome de "seleção" mentiria sobre o que faz. O que existe de
    ///   verdade entrou com o nome certo: "Copiar texto da mensagem".
    /// - **Copiar link / Copiar endereço de email** — `Message.body` é
    ///   `[String]` de parágrafos sem marcação, e nenhuma das mensagens tem
    ///   URL. Não há o que o clique acerte.
    /// - **Colocar na agenda** — o `onAddEvent` do leitor é `{ _ in }` no
    ///   `InboxScreen`: o botão que já existe no cartão de resumo não faz
    ///   nada, e não há API de escrita na agenda neste marco. Repetir um
    ///   controle mudo dentro do menu é pior do que não ter o item.
    public static func reader(_ message: Message) -> [ContextMenuEntry] {
        var entries: [ContextMenuEntry] = [
            .item(ContextMenuItem("Copiar texto da mensagem", .copy(bodyText(message)))),
        ]
        entries.append(contentsOf: copyEntries(message))
        entries.append(.separator)
        entries.append(
            .item(ContextMenuItem("Responder", .reply(messageID: message.id), shortcut: .reply))
        )
        if message.bucket != .archived {
            entries.append(
                .item(ContextMenuItem("Arquivar", .move(messageID: message.id, to: .archived)))
            )
        }
        if let move = moveSubmenu(message) { entries.append(move) }
        entries.append(.separator)
        entries.append(.item(readToggle(message)))
        return entries.tidied
    }

    // MARK: Linha de caixa da barra lateral

    /// "Marcar tudo como lido" só aparece quando há o que marcar. Com a caixa
    /// inteira já lida o item some — desabilitado ele diria que a caixa tem
    /// não lidas.
    public static func bucketRow(
        _ bucket: TriageBucket,
        unread: Int,
        accountID: String?
    ) -> [ContextMenuEntry] {
        guard unread > 0 else { return [] }
        return [
            .item(ContextMenuItem(
                "Marcar tudo como lido",
                .markAllRead(bucket: bucket, accountID: accountID)
            ))
        ]
    }

    // MARK: Linha de conta da barra lateral

    /// O rótulo do filtro segue o estado: numa conta já filtrada ele diz
    /// "Limpar filtro", que é o que o clique nela faz (`select(account:)`
    /// desliga o filtro ao repetir a mesma conta).
    ///
    /// "Marcar tudo como lido" aqui vale a conta **inteira**, não a caixa
    /// aberta: a linha da conta não pertence a caixa nenhuma, e escondê-la
    /// porque as não lidas estão em "Depois" seria arbitrário.
    public static func accountRow(
        _ account: Account,
        isFiltered: Bool,
        unread: Int
    ) -> [ContextMenuEntry] {
        var entries: [ContextMenuEntry] = [
            .item(isFiltered
                ? ContextMenuItem("Limpar filtro", .clearAccountFilter)
                : ContextMenuItem("Filtrar só esta conta", .filterAccount(accountID: account.id)))
        ]
        entries.append(.separator)
        if unread > 0 {
            entries.append(.item(ContextMenuItem(
                "Marcar tudo como lido",
                .markAllRead(bucket: .all, accountID: account.id)
            )))
        }
        entries.append(.item(ContextMenuItem("Copiar endereço", .copy(account.address))))
        return entries.tidied
    }

    // MARK: Bloco de compromisso

    /// Vale nas quatro superfícies que desenham um compromisso: a trilha do
    /// email e as visões Dia, Semana e Mês.
    ///
    /// - `date` é o dia do compromisso já resolvido por quem desenha
    ///   (`anchor` + `dayOffset`). Nulo escreve o convite sem a linha da data,
    ///   em vez de inventar uma.
    /// - `originMessageID` vem de `originMessageID(for:in:)`. Nulo tira o
    ///   item: sem mensagem casada não há para onde ir.
    ///
    /// "Novo compromisso aqui", na célula vazia da grade, **não existe**: sem
    /// EventKit e sem escrita na agenda ele não teria retorno nenhum. A célula
    /// vazia continua sem menu.
    public static func agendaBlock(
        _ item: AgendaItem,
        detail: EventDetail,
        date: Date?,
        originMessageID: String?
    ) -> [ContextMenuEntry] {
        var entries: [ContextMenuEntry] = [
            .item(ContextMenuItem("Abrir detalhe", .openEvent(itemID: item.id))),
            .separator,
        ]
        if let link = detail.link, !link.isEmpty {
            entries.append(.item(ContextMenuItem("Copiar link da reunião", .copy(link))))
        }
        entries.append(.item(ContextMenuItem(
            "Copiar convite",
            .copy(inviteText(item, detail: detail, date: date))
        )))
        entries.append(.separator)
        if let originMessageID {
            entries.append(.item(ContextMenuItem(
                "Ir para o email de origem",
                .revealMessage(messageID: originMessageID)
            )))
        }
        return entries.tidied
    }

    // MARK: - Peças compartilhadas

    /// Só um dos dois rótulos existe por vez, e ele é o **contrário** do
    /// estado corrente: numa mensagem lida o menu oferece "Marcar como não
    /// lida". É a sinalização que o brief pede, e é o que dá para provar sem
    /// abrir menu nenhum.
    static func readToggle(_ message: Message) -> ContextMenuItem {
        message.isRead
            ? ContextMenuItem("Marcar como não lida", .setRead(messageID: message.id, isRead: false))
            : ContextMenuItem("Marcar como lida", .setRead(messageID: message.id, isRead: true))
    }

    /// "Mover para ▸", sem a caixa em que a mensagem já está — `move(_:to:)`
    /// retorna sem fazer nada quando a caixa é a mesma, e um item que não
    /// muda nada é item morto.
    ///
    /// `.all` também fica de fora: é uma **visão**, não um estado de triagem.
    /// Mover para "Tudo" não quer dizer nada.
    static func moveSubmenu(_ message: Message) -> ContextMenuEntry? {
        let targets = TriageBucket.allCases.filter { $0 != .all && $0 != message.bucket }
        guard !targets.isEmpty else { return nil }
        return .submenu(
            title: "Mover para",
            items: targets.map {
                ContextMenuItem($0.label, .move(messageID: message.id, to: $0))
            }
        )
    }

    /// Assunto vazio não vira item: copiar string vazia é o botão mudo com
    /// outra roupa.
    static func copyEntries(_ message: Message) -> [ContextMenuEntry] {
        var entries: [ContextMenuEntry] = []
        if !message.from.address.isEmpty {
            entries.append(.item(ContextMenuItem(
                "Copiar endereço do remetente", .copy(message.from.address)
            )))
        }
        if !message.subject.isEmpty {
            entries.append(.item(ContextMenuItem("Copiar assunto", .copy(message.subject))))
        }
        return entries
    }

    /// O corpo como texto simples, com linha em branco entre parágrafos — que
    /// é como o leitor os desenha (`spacing: 16`).
    public static func bodyText(_ message: Message) -> String {
        message.body.joined(separator: "\n\n")
    }

    /// O convite em texto: título, dia, horário, local, link e participantes.
    ///
    /// Sem `switch` sobre conta nem provedor: tudo sai do `AgendaItem` e do
    /// `EventDetail`. Linha que não tem conteúdo não é escrita em branco —
    /// um compromisso sem link não ganha uma linha vazia no meio do convite.
    public static func inviteText(
        _ item: AgendaItem,
        detail: EventDetail,
        date: Date?
    ) -> String {
        var lines: [String] = [item.title]
        if let date {
            lines.append("\(DateLabels.eventDate(date)) · \(item.rangeLabel)")
        } else {
            lines.append(item.rangeLabel)
        }
        if !detail.place.isEmpty { lines.append(detail.place) }
        if let link = detail.link, !link.isEmpty { lines.append(link) }

        let roster = detail.guests(me: "")
        if !roster.isEmpty {
            lines.append("")
            lines.append("Participantes:")
            for person in roster {
                lines.append("· \(person.name) <\(person.address)> — \(person.role)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Qual mensagem gerou este compromisso.
    ///
    /// A ligação existe no dado: a seção "o que gerou este compromisso"
    /// registra a linha de email com o **assunto** da mensagem em `what`
    /// (`EventThreadEntry(kind: .email)`). Não há id de mensagem no
    /// `EventDetail`, então o casamento é por assunto — e quando não casa, o
    /// item some do menu em vez de virar um caminho para lugar nenhum.
    ///
    /// Percorre as entradas na ordem em que o detalhe as escreve e devolve a
    /// primeira que encontra mensagem.
    public static func originMessageID(
        for detail: EventDetail,
        in messages: [Message]
    ) -> String? {
        for entry in detail.thread where entry.kind == .email {
            if let match = messages.first(where: { $0.subject == entry.what }) {
                return match.id
            }
        }
        return nil
    }
}
