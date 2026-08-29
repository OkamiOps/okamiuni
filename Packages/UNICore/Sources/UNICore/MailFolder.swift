import Foundation

/// O papel de uma pasta, do ponto de vista do app.
///
/// Nome do servidor não serve: "Archive", "Arquivo", "[Gmail]/Todos os e-mails"
/// e "Alle Nachrichten" são a mesma coisa. O papel é o que a projeção de
/// triagem lê, e é por isso que ele é gravado — descobri-lo de novo a cada
/// abertura significaria refazer a heurística de nome sobre dados que já
/// resolvemos uma vez.
///
/// `other` é legítimo e comum: pasta que o usuário criou não tem papel nosso.
///
/// **Mora aqui, e não em `UNISync`, desde a M3-17.** Ele nasceu no pacote de
/// rede porque só a rede o produzia; agora a barra lateral desenha as pastas do
/// provedor, e ela precisa saber que uma delas é a lixeira para lhe dar o
/// ícone. `UNIShell` não pode perguntar isso a `UNISync` sem que `MailStore` —
/// que é de `UNICore` — passe a falar o tipo de outro pacote. Quem usa o papel
/// para decidir **destino no servidor** continua em `UNISync`; o que desceu foi
/// só o vocabulário.
public enum FolderRole: String, Sendable, Hashable, CaseIterable {
    case inbox
    case archive
    case trash
    case sent
    /// A pasta `OkamiUNI/Depois`, quando existe.
    case later = "depois"
    /// Rascunhos do provedor (`\Drafts`, `DRAFT` no Gmail).
    ///
    /// Ele e `junk` entraram na M3-17 e **não mudam projeção nenhuma**: as duas
    /// pastas caíam em `.other` e iam para Arquivado com o nome delas como
    /// etiqueta, e continuam indo (ver `TriageProjection`). O que os dois casos
    /// compram é o ícone da linha na barra lateral — dizer "isto é a lixeira" e
    /// "isto são os rascunhos" pelo desenho, e não só pelo nome que o servidor
    /// escolheu.
    case drafts = "rascunhos"
    /// Spam/lixo eletrônico (`\Junk`, `SPAM` no Gmail).
    case junk = "spam"
    case other = "outra"
}

/// Uma pasta do provedor, como a barra lateral a mostra.
///
/// **É o mapa do servidor, e não o Fluxo.** O Fluxo (Hoje/Depois/Tudo/
/// Arquivado/Lixeira/Enviadas) é triagem: ele responde "o que eu ainda preciso
/// decidir". A pasta responde "onde isto está guardado lá". As duas dimensões
/// são paralelas de propósito — abrir "Faturas" não muda a caixa aberta, e
/// mudar de caixa não fecha a pasta.
public struct MailFolder: Sendable, Hashable, Identifiable {
    /// Conta + nome no servidor, o mesmo id determinístico que o banco guarda.
    public let id: String
    public let accountID: String
    /// O nome **do provedor**, inteiro. Numa hierarquia ele vem composto
    /// ("Clientes/Faturas"), e é assim que ele é mostrado.
    ///
    /// **O mínimo honesto sobre hierarquia**, dito em voz alta: o app não
    /// indenta subpastas. O delimitador de hierarquia não é o mesmo em todo
    /// servidor (`/`, `.`, `\`), o `LIST` o informa por linha, e a nossa camada
    /// de resposta ainda não o carrega. Mostrar o caminho composto é a resposta
    /// que **nunca mente**; indentar por um separador chutado desenharia uma
    /// árvore errada num servidor que use outro. Quando o delimitador subir
    /// pelo fio, a indentação é uma linha de desenho.
    public let serverName: String
    /// O que a linha escreve. Hoje é sempre o `serverName`; existe separado
    /// porque o Gmail dá nome de rótulo ("Faturas") e id opaco ("Label_17"), e
    /// a linha mostra o nome.
    public let displayName: String
    public let role: FolderRole
    /// Quantas mensagens desta pasta ainda não foram lidas. Calculado pelo
    /// `MailStore` a partir das mensagens que ele já tem — a barra lateral não
    /// faz consulta nenhuma.
    public let unreadCount: Int

    public init(
        id: String, accountID: String, serverName: String,
        displayName: String, role: FolderRole, unreadCount: Int = 0
    ) {
        self.id = id
        self.accountID = accountID
        self.serverName = serverName
        self.displayName = displayName
        self.role = role
        self.unreadCount = unreadCount
    }

    /// A mesma pasta com o contador preenchido.
    public func withUnreadCount(_ count: Int) -> MailFolder {
        MailFolder(
            id: id, accountID: accountID, serverName: serverName,
            displayName: displayName, role: role, unreadCount: count
        )
    }

    /// A ordem em que as pastas de uma conta aparecem.
    ///
    /// As de papel conhecido primeiro, na ordem em que se pensa numa caixa
    /// (entrada, enviados, rascunhos, arquivo, spam, lixeira), e as do usuário
    /// depois, em ordem alfabética. Sem isto a ordem seria a do `LIST`, que é a
    /// do servidor e muda de provedor para provedor — a mesma conta abriria com
    /// a lixeira no topo num servidor e no fim noutro.
    public static func ordered(_ folders: [MailFolder]) -> [MailFolder] {
        folders.sorted { esquerda, direita in
            let a = rank(esquerda.role)
            let b = rank(direita.role)
            if a != b { return a < b }
            return esquerda.displayName.localizedCaseInsensitiveCompare(direita.displayName)
                == .orderedAscending
        }
    }

    private static func rank(_ role: FolderRole) -> Int {
        switch role {
        case .inbox: 0
        case .sent: 1
        case .drafts: 2
        case .later: 3
        case .archive: 4
        case .junk: 5
        case .trash: 6
        case .other: 7
        }
    }

    /// O símbolo da linha, quando o papel é conhecido.
    ///
    /// `nil` para a pasta que a pessoa criou: ela não é nenhuma das nossas, e
    /// um ícone genérico ao lado de todas roubaria o sinal das que têm um.
    public var symbol: String? {
        switch role {
        case .inbox: "tray"
        case .sent: "paperplane"
        case .drafts: "square.and.pencil"
        case .archive: "archivebox"
        case .junk: "exclamationmark.octagon"
        case .trash: "trash"
        case .later, .other: nil
        }
    }
}
