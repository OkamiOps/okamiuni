import Foundation
import Observation

/// O gesto de **arrastar a linha da mensagem para o lado**, como dado e como
/// aritmética — sem uma `View` por perto.
///
/// Mora em `UNICore` pelo motivo de sempre nesta base: `View` é `@MainActor`
/// implícito no Swift 6 e um `static` lá dentro herda o isolamento, então um
/// teste nonisolated que o chamasse trapa em runtime. É a mesma razão de
/// `AgendaSummary`, `PaneLayout` e `RichBody` viverem aqui.
///
/// O que este arquivo decide:
///
/// - **quando** um arraste deixa de ser rolagem e vira arraste lateral
///   (`SwipeGesture.side`);
/// - **quanto** revelar para um deslocamento dado, já com a resistência do fim
///   do painel (`SwipeResolution.offset`);
/// - **qual ação está armada** e **se o limiar de disparo foi cruzado**
///   (`SwipeResolution.armed` / `.willFire`);
/// - o que soltar naquele ponto significa (`SwipeGesture.release`).
///
/// O que ele **não** decide: como desenhar, e o que a ação faz com a mensagem.
/// A segunda metade já existe — `ContextCommand` e quem o executa — e é por
/// isso que `SwipeAction` devolve comandos em vez de mexer no `MailStore`.

// MARK: - Lado

/// De que lado da linha o painel aparece.
///
/// O nome é o **lado do painel**, não a direção do dedo: arrastar da esquerda
/// para a direita revela o painel `leading` (o que estava escondido sob a borda
/// esquerda), e o contrário revela o `trailing`.
public enum SwipeSide: String, Sendable, Hashable, CaseIterable, Codable {
    case leading
    case trailing

    /// Como a tela de ajuste vai chamar cada lado. O usuário não pensa em
    /// "leading": ele pensa no gesto que faz.
    public var label: String {
        switch self {
        case .leading: "Arrastando para a direita"
        case .trailing: "Arrastando para a esquerda"
        }
    }
}

// MARK: - Tinta

/// O papel de cor de uma ação, em termos de **token**, nunca de cor literal.
/// Quem desenha traduz para `Theme`; aqui não há SwiftUI para resolver cor.
public enum SwipeTint: String, Sendable, Hashable, Codable {
    /// A ação forte do lado — fundo em `accent`, texto em `onAccent`.
    case strong
    /// As demais — fundo em `surface3`, texto em `ink2`.
    case quiet
}

// MARK: - Ação

/// Uma referência persistível a uma pasta do provedor.
///
/// `MailFolder` é um retrato que também carrega contador de não lidas. A
/// configuração do gesto precisa só da identidade e do vocabulário necessários
/// para montar a operação real depois de reiniciar; guardar o contador aqui
/// transformaria estado de tela em preferência.
public struct SwipeFolderReference: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let accountID: String
    public let serverName: String
    public let displayName: String
    public let role: FolderRole

    public init(folder: MailFolder) {
        id = folder.id
        accountID = folder.accountID
        serverName = folder.serverName
        displayName = folder.displayName
        role = folder.role
    }

    public init(
        id: String,
        accountID: String,
        serverName: String,
        displayName: String,
        role: FolderRole
    ) {
        self.id = id
        self.accountID = accountID
        self.serverName = serverName
        self.displayName = displayName
        self.role = role
    }

    public var folder: MailFolder {
        MailFolder(
            id: id, accountID: accountID, serverName: serverName,
            displayName: displayName, role: role
        )
    }
}

/// O destino concreto da ação de arraste "Mover para…".
///
/// A configuração é deliberadamente explícita sobre o transporte. IMAP move
/// entre pastas; Gmail aplica o marcador escolhido e remove `INBOX`. Não há
/// inferência por nome nem uma lista fechada de provedores: a tela que cria
/// este valor informa a pasta/marcador real que a conta descobriu.
public struct SwipeMoveDestination: Sendable, Hashable, Codable, Identifiable {
    public enum Transport: String, Sendable, Hashable, Codable {
        case imapFolder
        case gmailLabelFromInbox
    }

    public let transport: Transport
    public let target: SwipeFolderReference
    /// Obrigatória no Gmail para a operação remover exatamente `INBOX`, e
    /// ausente no IMAP, onde a origem vem da própria mensagem.
    public let source: SwipeFolderReference?
    /// O endereço (ou outro identificador apresentado pela conta) salvo junto
    /// do destino. Não participa da operação no servidor; serve somente para
    /// a pessoa diferenciar, por exemplo, dois marcadores chamados “Clientes”.
    /// Opcional para decodificar escolhas gravadas antes deste campo existir.
    public let accountLabel: String?

    public var id: String { "\(transport.rawValue):\(target.accountID):\(target.id)" }
    public var displayName: String { target.displayName }
    public var accountID: String { target.accountID }
    public var settingsLabel: String {
        "\(displayName) · \(accountLabel?.isEmpty == false ? accountLabel! : accountID)"
    }

    public init(imapFolder folder: MailFolder, accountLabel: String? = nil) {
        transport = .imapFolder
        target = SwipeFolderReference(folder: folder)
        source = nil
        self.accountLabel = accountLabel
    }

    /// Cria o gesto Gmail que esvazia a Caixa de entrada ao colocar a
    /// mensagem no marcador escolhido. Só `INBOX` é uma origem aceitável:
    /// retirar um marcador qualquer seria uma segunda semântica escondida no
    /// mesmo controle.
    public init?(
        gmailLabel folder: MailFolder,
        removing inbox: MailFolder,
        accountLabel: String? = nil
    ) {
        guard folder.accountID == inbox.accountID,
              folder.id != inbox.id,
              inbox.role == .inbox
        else { return nil }
        transport = .gmailLabelFromInbox
        target = SwipeFolderReference(folder: folder)
        source = SwipeFolderReference(folder: inbox)
        self.accountLabel = accountLabel
    }

    /// A ação só vale para a conta dona e, no Gmail, enquanto a mensagem ainda
    /// estiver em INBOX. Um gesto que não pode cumprir essa promessa fica
    /// desabilitado em vez de sumir com a mensagem e não alterar o servidor.
    public func isNoOp(for message: Message) -> Bool {
        guard message.accountID == target.accountID else { return true }
        switch transport {
        case .imapFolder:
            return message.folderIDs == [target.id]
        case .gmailLabelFromInbox:
            guard let source else { return true }
            return !message.folderIDs.contains(source.id)
        }
    }

    public func command(for message: Message) -> ContextCommand? {
        guard !isNoOp(for: message) else { return nil }
        switch transport {
        case .imapFolder:
            return .placeMessage(messageID: message.id, folder: target.folder, mode: .move)
        case .gmailLabelFromInbox:
            guard let source else { return nil }
            return .moveGmailMessage(
                messageID: message.id, from: source.folder, to: target.folder
            )
        }
    }

    public func receiptTitle() -> String { "Movida para \(displayName)" }
    public func help() -> String { "Mover esta mensagem para \(displayName)" }
}

/// As ações que uma linha pode oferecer sob o dedo.
///
/// Nenhuma é inventada: as três de triagem são `MailStore.move(_:to:)` e a de
/// leitura é `MailStore.setRead(_:for:)`. Ambas chegam por `ContextCommand`, o
/// mesmo valor que os menus de contexto carregam — assim o arraste e o botão
/// direito não podem divergir no primeiro conserto.
public enum SwipeAction: String, Sendable, Hashable, CaseIterable, Identifiable, Codable {
    case archive = "arquivar"
    case toggleRead = "leitura"
    case later = "depois"
    case today = "hoje"
    /// Apagar — mover para a Lixeira. **Não** é "apagar definitivamente": jogar
    /// fora de vez não pode ficar a um gesto de distância, e por isso essa
    /// ação existe só no menu, dentro da Lixeira.
    case trash = "lixeira"
    /// Sinalizar e tirar a sinalização. Como a de leitura, ela é **uma** ação
    /// com dois rótulos: o botão diz o contrário do estado corrente.
    case toggleFlag = "sinal"
    /// Destino persistido por lado em `SwipeConfiguration`. A ação não entra
    /// na configuração sem esse destino, portanto uma instalação antiga nunca
    /// ganha um botão sem operação por causa de uma atualização.
    case moveToDestination = "mover-destino"

    public var id: String { rawValue }

    /// A caixa de destino, quando a ação é de triagem. `nil` na de leitura, que
    /// não move nada.
    ///
    /// `.all` nunca aparece aqui: é uma **visão**, não um estado de triagem —
    /// a mesma razão pela qual ela fica fora do submenu "Mover para".
    public var target: TriageBucket? {
        switch self {
        case .archive: .archived
        case .later: .later
        case .today: .today
        case .trash: .trash
        case .toggleRead, .toggleFlag, .moveToDestination: nil
        }
    }

    /// O nome da ação na tela de ajuste, onde não há mensagem para consultar.
    /// A de leitura aparece pelos dois rótulos porque ela é uma só ação.
    public var settingsLabel: String {
        switch self {
        case .archive: "Arquivar"
        case .toggleRead: "Marcar como lida / não lida"
        case .later: "Depois"
        case .today: "Hoje"
        case .trash: "Apagar"
        case .toggleFlag: "Sinalizar / tirar a sinalização"
        case .moveToDestination: "Mover para pasta ou marcador"
        }
    }

    /// O rótulo no botão revelado. Curto de propósito: a coluna tem
    /// `SwipeMetrics.actionWidth` e o rótulo não pode ser cortado.
    ///
    /// A de leitura diz o **contrário** do estado corrente, como o item de
    /// menu equivalente (`ContextMenus.readToggle`): numa mensagem lida o
    /// botão oferece "Não lida".
    public func title(for message: Message) -> String {
        switch self {
        case .archive: "Arquivar"
        case .toggleRead: message.isRead ? "Não lida" : "Lida"
        case .later: "Depois"
        case .today: "Hoje"
        case .trash: "Apagar"
        case .toggleFlag: message.isFlagged ? "Tirar" : "Sinalizar"
        case .moveToDestination: "Mover"
        }
    }

    /// O símbolo do botão. Nome de SF Symbol, como o resto do app já usa
    /// (`paperclip`, `signature`).
    public func symbol(for message: Message) -> String {
        switch self {
        case .archive: "archivebox"
        case .toggleRead: message.isRead ? "envelope.badge" : "envelope.open"
        case .later: "clock"
        case .today: "tray.and.arrow.down"
        case .trash: "trash"
        case .toggleFlag: message.isFlagged ? "star.slash" : "star"
        case .moveToDestination: "folder"
        }
    }

    /// Arquivar e apagar tiram a mensagem da triagem inteira, e são as que o
    /// dedo alcança primeiro em cada lado. Elas pintam forte; o resto é
    /// discreto — adiar e trazer para hoje são movimentos entre caixas, e um
    /// painel todo forte não teria hierarquia nenhuma.
    public var tint: SwipeTint {
        switch self {
        case .archive, .trash: .strong
        case .toggleRead, .toggleFlag, .later, .today, .moveToDestination: .quiet
        }
    }

    /// Esta ação não faria nada com esta mensagem.
    ///
    /// Mover para a caixa em que ela já está é exatamente o que
    /// `MailStore.move(_:to:)` recusa logo na primeira guarda. O botão
    /// continua **visível** — é o que a fila de triagem do leitor já faz com a
    /// caixa corrente, e sumir com uma coluna mudaria a largura do painel de
    /// linha para linha — mas ele não dispara e não pode ser a ação armada.
    public func isNoOp(for message: Message) -> Bool {
        isNoOp(for: message, destination: nil)
    }

    /// A variante que conhece o destino persistido do gesto. As ações antigas
    /// mantêm exatamente a semântica anterior quando o destino é `nil`.
    public func isNoOp(for message: Message, destination: SwipeMoveDestination?) -> Bool {
        if self == .moveToDestination {
            return destination?.isNoOp(for: message) ?? true
        }
        guard let target else { return false }  // leitura e estrela sempre fazem algo
        return message.bucket == target
    }

    /// O que a ação manda fazer. `nil` quando não faria nada.
    public func command(for message: Message) -> ContextCommand? {
        command(for: message, destination: nil)
    }

    public func command(
        for message: Message,
        destination: SwipeMoveDestination?
    ) -> ContextCommand? {
        if self == .moveToDestination {
            return destination?.command(for: message)
        }
        guard !isNoOp(for: message, destination: destination) else { return nil }
        if let target { return .move(messageID: message.id, to: target) }
        if self == .toggleFlag {
            return .setFlagged(messageID: message.id, isFlagged: !message.isFlagged)
        }
        return .setRead(messageID: message.id, isRead: !message.isRead)
    }

    /// O caminho de volta.
    ///
    /// Sai da mensagem **antes** da mudança, e é por isso que não dá para
    /// derivá-lo depois: uma vez arquivada, a mensagem não sabe mais de que
    /// caixa veio. Quem dispara guarda o recibo no mesmo instante em que age.
    public func undo(for message: Message) -> ContextCommand? {
        guard !isNoOp(for: message) else { return nil }
        if target != nil { return .move(messageID: message.id, to: message.bucket) }
        if self == .toggleFlag {
            return .setFlagged(messageID: message.id, isFlagged: message.isFlagged)
        }
        return .setRead(messageID: message.id, isRead: message.isRead)
    }

    /// O que o retorno visível diz que aconteceu, no passado, contra o estado
    /// **anterior** da mensagem.
    public func receiptTitle(for message: Message) -> String {
        switch self {
        case .archive: "Arquivada"
        case .toggleRead: message.isRead ? "Marcada como não lida" : "Marcada como lida"
        case .later: "Adiada para depois"
        case .today: "Trazida para hoje"
        case .trash: "Movida para a Lixeira"
        case .toggleFlag: message.isFlagged ? "Sinalização retirada" : "Sinalizada"
        case .moveToDestination: "Movida"
        }
    }

    /// O `help` do botão. Numa ação que não faria nada ele diz o porquê, em vez
    /// de deixar a pessoa clicando num botão calado.
    public func help(for message: Message) -> String {
        help(for: message, destination: nil)
    }

    public func help(for message: Message, destination: SwipeMoveDestination?) -> String {
        if self == .moveToDestination {
            if destination?.isNoOp(for: message) ?? true {
                return "Escolha uma pasta ou marcador para este gesto"
            }
            return destination?.help() ?? "Escolha uma pasta ou marcador para este gesto"
        }
        if isNoOp(for: message, destination: destination), let target {
            return "Esta mensagem já está em \(target.label)"
        }
        switch self {
        case .archive: return "Arquivar esta mensagem"
        case .toggleRead: return message.isRead ? "Marcar como não lida" : "Marcar como lida"
        case .later: return "Mover para Depois"
        case .today: return "Mover para Hoje"
        case .trash: return "Mover esta mensagem para a Lixeira"
        case .toggleFlag:
            return message.isFlagged ? "Tirar a sinalização" : "Sinalizar esta mensagem"
        case .moveToDestination:
            return destination?.help() ?? "Escolha uma pasta ou marcador para este gesto"
        }
    }
}

// MARK: - Configuração

/// Quais ações ficam de cada lado. É a parte **configurável** do pedido, e o
/// que `SwipeSettingsStore` persiste.
public struct SwipeConfiguration: Sendable, Hashable, Codable {
    /// Teto por lado. Com a lista a 320–420pt, quatro colunas de 84 não deixam
    /// linha para arrastar.
    public static let maxPerSide = 3

    public let leading: [SwipeAction]
    public let trailing: [SwipeAction]
    /// Os destinos são por conta e por lado; as ações em si continuam globais.
    /// Assim, “Mover” pode existir em ambos os gestos sem tentar aplicar uma
    /// pasta da conta A numa mensagem da conta B.
    public let leadingDestinations: [String: SwipeMoveDestination]
    public let trailingDestinations: [String: SwipeMoveDestination]

    /// Compatibilidade de fonte para consumidores da versão de um destino por
    /// lado. Só retorna valor quando há exatamente uma conta configurada —
    /// escolher uma arbitrária depois que há múltiplas contas seria tão ruim
    /// quanto o antigo cross-account silencioso.
    public var leadingDestination: SwipeMoveDestination? {
        Self.onlyDestination(in: leadingDestinations)
    }
    public var trailingDestination: SwipeMoveDestination? {
        Self.onlyDestination(in: trailingDestinations)
    }

    public init(
        leading: [SwipeAction],
        trailing: [SwipeAction],
        leadingDestination: SwipeMoveDestination? = nil,
        trailingDestination: SwipeMoveDestination? = nil,
        leadingDestinations: [String: SwipeMoveDestination] = [:],
        trailingDestinations: [String: SwipeMoveDestination] = [:]
    ) {
        let leadingDestinations = Self.destinations(
            leadingDestinations, addingLegacy: leadingDestination
        )
        let trailingDestinations = Self.destinations(
            trailingDestinations, addingLegacy: trailingDestination
        )
        let normalizedLeading = Self.normalize(leading, destinations: leadingDestinations)
        let normalizedTrailing = Self.normalize(trailing, destinations: trailingDestinations)
        self.leading = normalizedLeading
        self.trailing = normalizedTrailing
        self.leadingDestinations = normalizedLeading.contains(.moveToDestination)
            ? leadingDestinations : [:]
        self.trailingDestinations = normalizedTrailing.contains(.moveToDestination)
            ? trailingDestinations : [:]
    }

    /// Sem repetição e dentro do teto, preservando a ordem escolhida — a
    /// primeira é a que o arraste longo dispara.
    static func normalize(
        _ actions: [SwipeAction], destinations: [String: SwipeMoveDestination]
    ) -> [SwipeAction] {
        var seen: Set<SwipeAction> = []
        var out: [SwipeAction] = []
        for action in actions where seen.insert(action).inserted {
            // Não há destino, não há ação. Isso impede que um array de uma
            // versão futura, mas sem seu dado associado, crie um gesto mudo.
            guard action != .moveToDestination || !destinations.isEmpty else { continue }
            out.append(action)
            if out.count == maxPerSide { break }
        }
        return out
    }

    public func actions(on side: SwipeSide) -> [SwipeAction] {
        side == .leading ? leading : trailing
    }

    public func destination(on side: SwipeSide) -> SwipeMoveDestination? {
        Self.onlyDestination(in: destinations(on: side))
    }

    /// Escolhe somente o destino da conta da mensagem. O segundo `guard` é
    /// defesa de dados corrompidos: nem uma chave de dicionário alterada à mão
    /// pode fazer o gesto mandar um id de uma conta para outro provedor.
    public func destination(on side: SwipeSide, for accountID: String) -> SwipeMoveDestination? {
        guard let destination = destinations(on: side)[accountID],
              destination.accountID == accountID
        else { return nil }
        return destination
    }

    /// Destinos efetivos do lado, indexados pelo `Account.id` real.
    public func destinations(on side: SwipeSide) -> [String: SwipeMoveDestination] {
        side == .leading ? leadingDestinations : trailingDestinations
    }

    private static func destinations(
        _ destinations: [String: SwipeMoveDestination],
        addingLegacy legacy: SwipeMoveDestination?
    ) -> [String: SwipeMoveDestination] {
        var valid = destinations.filter { accountID, destination in
            accountID == destination.accountID
        }
        if let legacy { valid[legacy.accountID] = legacy }
        return valid
    }

    private static func onlyDestination(
        in destinations: [String: SwipeMoveDestination]
    ) -> SwipeMoveDestination? {
        guard destinations.count == 1 else { return nil }
        return destinations.values.first
    }

    private enum CodingKeys: String, CodingKey {
        case leading
        case trailing
        case leadingDestination
        case trailingDestination
        case leadingDestinations
        case trailingDestinations
    }

    /// O decodificador aceita o formato anterior de um destino por lado. A
    /// leitura normaliza esse valor em uma entrada cujo id é a conta contida
    /// nele; nunca o replica para as demais contas do perfil.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            leading: try container.decodeIfPresent([SwipeAction].self, forKey: .leading) ?? [],
            trailing: try container.decodeIfPresent([SwipeAction].self, forKey: .trailing) ?? [],
            leadingDestination: try container.decodeIfPresent(
                SwipeMoveDestination.self, forKey: .leadingDestination
            ),
            trailingDestination: try container.decodeIfPresent(
                SwipeMoveDestination.self, forKey: .trailingDestination
            ),
            leadingDestinations: try container.decodeIfPresent(
                [String: SwipeMoveDestination].self, forKey: .leadingDestinations
            ) ?? [:],
            trailingDestinations: try container.decodeIfPresent(
                [String: SwipeMoveDestination].self, forKey: .trailingDestinations
            ) ?? [:]
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(leading, forKey: .leading)
        try container.encode(trailing, forKey: .trailing)
        try container.encode(leadingDestinations, forKey: .leadingDestinations)
        try container.encode(trailingDestinations, forKey: .trailingDestinations)
    }

    /// O padrão do marco: duas de cada lado, todas com caminho real no
    /// `MailStore`.
    public static let `default` = SwipeConfiguration(
        leading: [.archive, .toggleRead],
        trailing: [.later, .today]
    )
}

// MARK: - Medidas e limiares

/// Os números do gesto. Ficam juntos porque os testes de fronteira precisam
/// citá-los, e porque cada um responde a uma pergunta diferente do brief.
public enum SwipeMetrics {
    /// Deslocamento horizontal mínimo para o gesto deixar de ser clique.
    ///
    /// Abaixo disto nada acontece: clicar seleciona e duplo clique abre a
    /// janela, e nenhum dos dois anda 12pt.
    public static let engage: CGFloat = 12

    /// Quanto a horizontal precisa dominar a vertical para o gesto ser nosso.
    ///
    /// `|dx| >= 1.5 × |dy|`. Um gesto que começa vertical é da rolagem — e
    /// como o `DragGesture` roda em paralelo com a `ScrollView`, é esta razão,
    /// e não o `minimumDistance`, que decide.
    public static let dominance: CGFloat = 1.5

    /// A largura de uma coluna revelada.
    public static let actionWidth: CGFloat = 84

    /// Soltar além disto deixa a linha aberta; aquém, ela volta ao lugar.
    /// Meia coluna: passou da metade do primeiro botão, abre.
    public static let openThreshold: CGFloat = actionWidth / 2

    /// A largura de linha que vale quando quem resolve o gesto não sabe a
    /// largura de verdade — previews, harness, e as chamadas de teste que só
    /// querem a aritmética.
    ///
    /// É a largura que `PaneLayout` concede à lista na janela de fidelidade
    /// (`MessageList.width`, 370). A faixa real vai de 320 a 420, e é por isso
    /// que o limiar de disparo recebe a largura em vez de assumir esta.
    public static let referenceRowWidth: CGFloat = 370

    /// A fração da largura da linha além da qual o arraste longo dispara.
    ///
    /// **Por que era baixo demais.** O limiar era absoluto — painel (168) mais
    /// 60 — e dava 228pt numa lista de 370: 62% do caminho, com o painel
    /// descansando em 168 (45%). Sobravam 60pt entre "aberto" e "disparou", e
    /// num **mouse**, que não tem o atrito do dedo, um puxão natural atravessa
    /// os 60 sem que a mão perceba. Era o que o dono do projeto via: a linha
    /// nunca parava no meio, ela sempre chegava ao fim e arquivava.
    ///
    /// Agora o disparo é **três quartos da linha**. A 370 são 277,5pt: bem
    /// além do painel de 168, e longe o bastante para que parar em cima dele
    /// seja o resultado normal do gesto, não uma pontaria. `0,75` é exato em
    /// binário — as fronteiras deste arquivo só valem cravadas, e um `0,7`
    /// daria 258,99999… numa comparação de igualdade.
    public static let commitFraction: CGFloat = 0.75

    /// O piso: quanto além do painel inteiro o arraste tem de ir, quando a
    /// fração da largura ficaria perto demais do painel.
    ///
    /// Duas situações onde só a fração não bastaria:
    ///
    /// - **lista estreita** (320, o mínimo de `PaneLayout`): 75% dão 240, e o
    ///   painel de duas colunas termina em 168 — 72pt de folga, o mesmo aperto
    ///   de antes. O piso leva a 258.
    /// - **três colunas** (252 de painel): 75% de 370 dão 277,5, a 25pt do fim
    ///   do painel. O piso leva a 342.
    ///
    /// Nas larguras de trabalho com o padrão de duas colunas (370 e acima)
    /// quem manda é a fração; o piso é a rede.
    public static let commitMargin: CGFloat = 90

    /// O quanto o painel resiste depois de aberto por inteiro.
    ///
    /// Era 0,35 — um freio. Agora é **um oitavo**: oito pontos de mão para um
    /// ponto de painel. É a parede do Mail, e é ela que faz o ponto de
    /// descanso aberto ser um lugar onde o gesto **para** em vez de um ponto
    /// por onde ele passa. Um oitavo é exato em binário, pela mesma razão de
    /// `commitFraction`.
    public static let resistance: CGFloat = 0.125

    public static func panelWidth(actions: Int) -> CGFloat {
        actionWidth * CGFloat(max(0, actions))
    }

    /// O limiar do arraste longo, em **deslocamento da mão** (não no painel
    /// revelado, que a resistência encolhe).
    ///
    /// O maior entre a fração da largura da linha e o painel mais a margem.
    /// Nenhum dos dois sozinho serve: a fração ignora quantas colunas há, e o
    /// piso ignora o tamanho da lista — que é justamente o que decide se 228pt
    /// é "metade do caminho" ou "quase tudo".
    public static func commitThreshold(
        actions: Int,
        rowWidth: CGFloat = referenceRowWidth
    ) -> CGFloat {
        max(commitFraction * rowWidth, panelWidth(actions: actions) + commitMargin)
    }

    /// Quanto revelar para um deslocamento, com a resistência já aplicada.
    /// Sempre positivo; o sinal é de quem chama.
    public static func reveal(magnitude: CGFloat, actions: Int) -> CGFloat {
        let panel = panelWidth(actions: actions)
        guard magnitude > panel else { return max(0, magnitude) }
        return panel + (magnitude - panel) * resistance
    }
}

// MARK: - Resolução

/// O estado do gesto num instante: onde está, o que está armado, e o que
/// aconteceria se a pessoa soltasse agora.
public struct SwipeResolution: Sendable, Hashable {
    /// `nil` enquanto o gesto ainda é rolagem ou clique.
    public let side: SwipeSide?
    /// Positivo revela o painel `leading`, negativo o `trailing`.
    public let offset: CGFloat
    /// A primeira ação do lado que **faz** alguma coisa com esta mensagem.
    /// `nil` quando o lado inteiro seria mudo.
    public let armed: SwipeAction?
    /// Soltar agora deixa a linha aberta.
    public let isOpen: Bool
    /// Soltar agora dispara `armed`.
    public let willFire: Bool

    public init(
        side: SwipeSide?,
        offset: CGFloat,
        armed: SwipeAction?,
        isOpen: Bool,
        willFire: Bool
    ) {
        self.side = side
        self.offset = offset
        self.armed = armed
        self.isOpen = isOpen
        self.willFire = willFire
    }

    public static let idle = SwipeResolution(
        side: nil, offset: 0, armed: nil, isOpen: false, willFire: false
    )
}

/// O que soltar significa.
public enum SwipeRelease: Sendable, Hashable {
    /// A linha volta ao lugar.
    case closed
    /// A linha fica aberta com o painel à mostra.
    case open(SwipeSide)
    /// A ação dispara sem a pessoa precisar acertar o botão.
    case fire(SwipeAction, SwipeSide)
}

public enum SwipeGesture {

    /// De que lado o gesto é — ou `nil` se ele ainda não é nosso.
    ///
    /// `locked` é o lado em que o gesto **nasceu**. Uma vez que o arraste
    /// lateral começou, ele continua lateral até a pessoa soltar: sem isso,
    /// baixar a mão 20pt no meio do caminho devolveria a linha para a rolagem
    /// com o painel meio aberto na tela.
    public static func side(
        translation: CGSize,
        locked: SwipeSide? = nil,
        configuration: SwipeConfiguration = .default
    ) -> SwipeSide? {
        if let locked {
            return configuration.actions(on: locked).isEmpty ? nil : locked
        }
        let dx = translation.width
        let dy = translation.height
        guard abs(dx) >= SwipeMetrics.engage else { return nil }
        guard abs(dx) >= SwipeMetrics.dominance * abs(dy) else { return nil }
        let candidate: SwipeSide = dx > 0 ? .leading : .trailing
        guard !configuration.actions(on: candidate).isEmpty else { return nil }
        return candidate
    }

    /// `rowWidth` é a largura da linha em pontos — a lista varia de 320 a 420 e
    /// o limiar de disparo acompanha (ver `SwipeMetrics.commitThreshold`). Quem
    /// não sabe a largura cai na de referência.
    public static func resolve(
        translation: CGSize,
        locked: SwipeSide? = nil,
        configuration: SwipeConfiguration = .default,
        message: Message,
        rowWidth: CGFloat = SwipeMetrics.referenceRowWidth
    ) -> SwipeResolution {
        guard let side = side(
            translation: translation, locked: locked, configuration: configuration
        ) else {
            return .idle
        }

        let actions = configuration.actions(on: side)
        // Voltar atrás — ou atravessar o zero para o outro lado — **fecha**,
        // não abre o painel oposto no meio do gesto. Trocar de painel sob o
        // dedo é como se perde a noção do que vai disparar.
        let magnitude = max(0, side == .leading ? translation.width : -translation.width)

        let revealed = SwipeMetrics.reveal(magnitude: magnitude, actions: actions.count)
        let destination = configuration.destination(on: side, for: message.accountID)
        let armed = actions.first {
            !$0.isNoOp(for: message, destination: destination)
        }

        return SwipeResolution(
            side: side,
            offset: side == .leading ? revealed : -revealed,
            armed: armed,
            isOpen: magnitude >= SwipeMetrics.openThreshold,
            // Um lado inteiramente mudo não dispara por arraste longo: puxar
            // até o fim e a mensagem não mudar de estado é pior do que nada
            // acontecer.
            willFire: armed != nil
                && magnitude >= SwipeMetrics.commitThreshold(
                    actions: actions.count, rowWidth: rowWidth
                )
        )
    }

    public static func release(
        translation: CGSize,
        locked: SwipeSide? = nil,
        configuration: SwipeConfiguration = .default,
        message: Message,
        rowWidth: CGFloat = SwipeMetrics.referenceRowWidth
    ) -> SwipeRelease {
        let resolution = resolve(
            translation: translation, locked: locked,
            configuration: configuration, message: message, rowWidth: rowWidth
        )
        guard let side = resolution.side else { return .closed }
        if resolution.willFire, let armed = resolution.armed { return .fire(armed, side) }
        return resolution.isOpen ? .open(side) : .closed
    }
}

// MARK: - Recibo

/// O retorno visível de uma ação disparada, com o caminho de volta dentro.
///
/// Copia o idioma da faixa de resposta rápida — "✓ Resposta guardada — 7
/// palavras · 14:32", com um botão que reabre o que foi feito. Aqui a frase é
/// "Arquivada — Marina Duarte · 14:32" e o botão diz "Desfazer".
///
/// O `undo` vem calculado contra a mensagem **antes** da mudança. Depois de
/// arquivada ela não sabe mais de que caixa veio, e um "Desfazer" que
/// adivinhasse a caixa seria a versão silenciosa do botão mudo.
public struct SwipeReceipt: Sendable, Hashable, Identifiable {
    public let id: UUID
    /// Qual ação de arraste gerou o recibo. **Opcional** desde a Task AR: o
    /// mesmo retorno visível passou a servir a "Apagar definitivamente", que
    /// não é uma coluna do arraste e nunca vai ser — jogar fora de vez não
    /// pode ficar a um gesto de distância.
    public let action: SwipeAction?
    public let messageID: String
    public let note: String
    public let undo: ContextCommand

    public init(
        id: UUID = UUID(),
        action: SwipeAction? = nil,
        messageID: String,
        note: String,
        undo: ContextCommand
    ) {
        self.id = id
        self.action = action
        self.messageID = messageID
        self.note = note
        self.undo = undo
    }

    /// O recibo de uma ação sobre uma mensagem, ou `nil` quando não houve o que
    /// fazer — ação muda não ganha faixa dizendo que algo aconteceu.
    ///
    /// `stamp` entra pronto porque formatar hora aqui reintroduziria a
    /// conversão de fuso que este projeto já pagou uma vez (ver
    /// `docs/decisoes-de-engenharia.md`).
    public static func of(
        _ action: SwipeAction,
        message: Message,
        stamp: String,
        id: UUID = UUID()
    ) -> SwipeReceipt? {
        guard let undo = action.undo(for: message) else { return nil }
        return SwipeReceipt(
            id: id,
            action: action,
            messageID: message.id,
            note: note(action, message: message, stamp: stamp),
            undo: undo
        )
    }

    /// "Arquivada — Marina Duarte · 14:32".
    ///
    /// Quem é a mensagem vem do nome do remetente e, na falta dele, do
    /// endereço. Assunto não serve: ele já é longo demais na primeira linha da
    /// própria lista.
    /// O recibo de "Apagar definitivamente", que não vem de coluna nenhuma.
    ///
    /// O caminho de volta é `restoreDeleted`, e ele só funciona porque o
    /// `MailStore` guardou a mensagem inteira ao apagá-la — pela mesma razão
    /// que este recibo nasce **antes** da mudança nos outros casos.
    public static func ofDeleteForever(
        message: Message,
        stamp: String,
        id: UUID = UUID()
    ) -> SwipeReceipt {
        SwipeReceipt(
            id: id,
            messageID: message.id,
            note: note("Apagada de vez", message: message, count: 1, stamp: stamp),
            undo: .restoreDeleted(messageID: message.id)
        )
    }

    /// O recibo de uma ação sobre a **conversa inteira**.
    ///
    /// A frase é a mesma da mensagem, com a contagem no meio — "Arquivada —
    /// Marina Duarte · 3 mensagens · 14:32". Sem a contagem, "Desfazer"
    /// devolveria três linhas depois de uma faixa que só falou de uma.
    ///
    /// O caminho de volta é `restoreConversation`, com o estado de **cada**
    /// mensagem fotografado antes da ação: as três podiam estar em caixas
    /// diferentes, e desfazer não pode empilhá-las todas na caixa da mais
    /// recente.
    public static func ofConversation(
        _ action: SwipeAction,
        conversation: Conversation,
        states: [MessageState],
        stamp: String,
        id: UUID = UUID()
    ) -> SwipeReceipt? {
        guard action.undo(for: conversation.latest) != nil else { return nil }
        return SwipeReceipt(
            id: id,
            action: action,
            messageID: conversation.latest.id,
            note: note(
                action.receiptTitle(for: conversation.latest),
                message: conversation.latest,
                count: conversation.count, stamp: stamp
            ),
            undo: .restoreConversation(states: states)
        )
    }

    /// O "Apagar definitivamente" de uma conversa inteira.
    ///
    /// O caminho de volta é uma cadeia de `restoreDeleted`, um por mensagem —
    /// e não `restoreConversation`: fora do store, a mensagem não existe mais
    /// para ter estado nenhum restaurado. É o cofre de `deleteForever` que a
    /// devolve, exatamente como no caso de uma mensagem só.
    public static func ofConversationDeleteForever(
        conversation: Conversation,
        stamp: String,
        id: UUID = UUID()
    ) -> SwipeReceipt {
        SwipeReceipt(
            id: id,
            messageID: conversation.latest.id,
            note: note(
                "Apagada de vez", message: conversation.latest,
                count: conversation.count, stamp: stamp
            ),
            undo: .restoreDeletedConversation(messageIDs: conversation.messageIDs)
        )
    }

    /// O recibo de uma ação sobre **várias** conversas, o lote da lista.
    ///
    /// Uma conversa só cai no caminho de `ofConversation`, e a frase continua
    /// falando do remetente. Duas ou mais falam da contagem — "Arquivada —
    /// 3 conversas · 14:32" — para o Desfazer não devolver um lote depois de
    /// uma faixa que só nomeou uma pessoa.
    public static func ofBatch(
        _ action: SwipeAction,
        conversations: [Conversation],
        states: [MessageState],
        stamp: String,
        id: UUID = UUID()
    ) -> SwipeReceipt? {
        guard let first = conversations.first else { return nil }
        if conversations.count == 1 {
            return ofConversation(
                action, conversation: first, states: states, stamp: stamp, id: id
            )
        }
        return SwipeReceipt(
            id: id,
            action: action,
            messageID: first.latest.id,
            note: batchNote(
                action.receiptTitle(for: first.latest),
                conversations: conversations,
                stamp: stamp
            ),
            undo: .restoreConversation(states: states)
        )
    }

    /// O "Apagar definitivamente" de um lote.
    public static func ofBatchDeleteForever(
        conversations: [Conversation],
        stamp: String,
        id: UUID = UUID()
    ) -> SwipeReceipt? {
        guard let first = conversations.first else { return nil }
        if conversations.count == 1 {
            return ofConversationDeleteForever(
                conversation: first, stamp: stamp, id: id
            )
        }
        return SwipeReceipt(
            id: id,
            messageID: first.latest.id,
            note: batchNote("Apagada de vez", conversations: conversations, stamp: stamp),
            undo: .restoreDeletedConversation(
                messageIDs: conversations.flatMap(\.messageIDs)
            )
        )
    }

    /// "Arquivada — 3 conversas · 14:32".
    public static func batchNote(
        _ head: String,
        conversations: [Conversation],
        stamp: String
    ) -> String {
        let n = conversations.count
        guard n > 1 else {
            guard let first = conversations.first else { return "\(head) · \(stamp)" }
            return note(head, message: first.latest, count: first.count, stamp: stamp)
        }
        return "\(head) — \(n) conversas · \(stamp)"
    }

    /// "Arquivada — Marina Duarte · 3 mensagens · 14:32".
    ///
    /// Uma função para os dois casos: com `count == 1` ela devolve exatamente a
    /// frase de antes desta tarefa, sem a contagem — a linha de uma mensagem só
    /// não ganha um "· 1 mensagens".
    public static func note(
        _ head: String,
        message: Message,
        count: Int,
        stamp: String
    ) -> String {
        let who = message.from.name.isEmpty ? message.from.address : message.from.name
        let quantas = count > 1 ? "\(count) mensagens · " : ""
        guard !who.isEmpty else { return "\(head) · \(quantas)\(stamp)" }
        return "\(head) — \(who) · \(quantas)\(stamp)"
    }

    public static func note(
        _ action: SwipeAction,
        message: Message,
        stamp: String
    ) -> String {
        note(action.receiptTitle(for: message), message: message, count: 1, stamp: stamp)
    }
}

// MARK: - Persistência

/// A escolha do usuário, guardada como o tema já é: `@MainActor @Observable`
/// sobre `UserDefaults`, com o prefixo `okamiuni.` (ver `ThemeStore`).
///
/// **Onde entraria a tela de ajuste.** Não neste marco. Quando entrar, ela é
/// uma cena `Settings` no `App/`, lendo este mesmo objeto do ambiente e
/// oferecendo `SwipeAction.allCases` em duas listas ordenáveis — uma por
/// `SwipeSide`, com `settingsLabel` no rótulo e `SwipeSide.label` no cabeçalho.
/// Nada mais precisa mudar: quem desenha a linha já lê `configuration`, e
/// `select(_:)` grava e notifica.
@MainActor
@Observable
public final class SwipeSettingsStore {
    private static let leadingKey = "okamiuni.swipe.leading"
    private static let trailingKey = "okamiuni.swipe.trailing"
    /// Formato anterior: uma escolha global por lado. É lido somente para
    /// migrar a conta que está dentro do próprio destino.
    private static let leadingDestinationKey = "okamiuni.swipe.leading.destination"
    private static let trailingDestinationKey = "okamiuni.swipe.trailing.destination"
    private static let leadingDestinationsKey = "okamiuni.swipe.leading.destinations"
    private static let trailingDestinationsKey = "okamiuni.swipe.trailing.destinations"

    public private(set) var configuration: SwipeConfiguration

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let legacyLeading = Self.readDestination(defaults, Self.leadingDestinationKey)
        let legacyTrailing = Self.readDestination(defaults, Self.trailingDestinationKey)
        let persistedLeading = Self.readDestinations(defaults, Self.leadingDestinationsKey)
        let persistedTrailing = Self.readDestinations(defaults, Self.trailingDestinationsKey)
        let leadingDestinations = persistedLeading ?? Self.destinations(from: legacyLeading)
        let trailingDestinations = persistedTrailing ?? Self.destinations(from: legacyTrailing)
        self.configuration = SwipeConfiguration(
            leading: Self.read(defaults, Self.leadingKey) ?? SwipeConfiguration.default.leading,
            trailing: Self.read(defaults, Self.trailingKey) ?? SwipeConfiguration.default.trailing,
            leadingDestinations: leadingDestinations,
            trailingDestinations: trailingDestinations
        )
        // Migração de preferência, não de conta: o destino global antigo vira
        // uma única entrada pelo `accountID` que ele já carregava. Não há
        // fallback para as outras contas e a chave antiga some em seguida.
        if persistedLeading == nil, legacyLeading != nil {
            Self.write(leadingDestinations, to: Self.leadingDestinationsKey, defaults: defaults)
            defaults.removeObject(forKey: Self.leadingDestinationKey)
        }
        if persistedTrailing == nil, legacyTrailing != nil {
            Self.write(trailingDestinations, to: Self.trailingDestinationsKey, defaults: defaults)
            defaults.removeObject(forKey: Self.trailingDestinationKey)
        }
    }

    /// `nil` quer dizer "não há escolha gravada, vale o padrão".
    ///
    /// Uma lista **vazia** gravada é diferente: é a pessoa desligando o arraste
    /// daquele lado, e tem de sobreviver ao relançamento. Por isso a distinção
    /// passa pela existência da chave, não pelo tamanho da lista.
    ///
    /// Chave presente com conteúdo que não decodifica em nada — versão antiga,
    /// arquivo mexido à mão — cai no padrão em vez de deixar o lado mudo sem
    /// ninguém ter pedido.
    private static func read(_ defaults: UserDefaults, _ key: String) -> [SwipeAction]? {
        guard let raw = defaults.array(forKey: key) as? [String] else { return nil }
        let decoded = raw.compactMap(SwipeAction.init(rawValue:))
        if decoded.isEmpty && !raw.isEmpty { return nil }
        return decoded
    }

    /// Destino inválido é tratado como ausência. A lista de ações é então
    /// normalizada e o gesto especial some, sem afetar as ações antigas da
    /// pessoa nem abrir uma rota para um comando que não se sabe executar.
    private static func readDestination(
        _ defaults: UserDefaults, _ key: String
    ) -> SwipeMoveDestination? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(SwipeMoveDestination.self, from: data)
    }

    private static func readDestinations(
        _ defaults: UserDefaults, _ key: String
    ) -> [String: SwipeMoveDestination]? {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: SwipeMoveDestination].self, from: data)
        else { return nil }
        return decoded.filter { accountID, destination in accountID == destination.accountID }
    }

    private static func destinations(
        from destination: SwipeMoveDestination?
    ) -> [String: SwipeMoveDestination] {
        guard let destination else { return [:] }
        return [destination.accountID: destination]
    }

    public func select(_ configuration: SwipeConfiguration) {
        self.configuration = configuration
        defaults.set(configuration.leading.map(\.rawValue), forKey: Self.leadingKey)
        defaults.set(configuration.trailing.map(\.rawValue), forKey: Self.trailingKey)
        Self.write(configuration.leadingDestinations, to: Self.leadingDestinationsKey, defaults: defaults)
        Self.write(configuration.trailingDestinations, to: Self.trailingDestinationsKey, defaults: defaults)
        defaults.removeObject(forKey: Self.leadingDestinationKey)
        defaults.removeObject(forKey: Self.trailingDestinationKey)
    }

    public func setActions(_ actions: [SwipeAction], on side: SwipeSide) {
        select(
            side == .leading
                ? SwipeConfiguration(
                    leading: actions, trailing: configuration.trailing,
                    // Tirar "Mover" da lista também tira seu dado associado;
                    // deixar um destino órfão faria ele reaparecer depois de
                    // uma escolha futura sem a pessoa tê-lo selecionado.
                    leadingDestinations: actions.contains(.moveToDestination)
                        ? configuration.leadingDestinations : [:],
                    trailingDestinations: configuration.trailingDestinations
                )
                : SwipeConfiguration(
                    leading: configuration.leading, trailing: actions,
                    leadingDestinations: configuration.leadingDestinations,
                    trailingDestinations: actions.contains(.moveToDestination)
                        ? configuration.trailingDestinations : [:]
                )
        )
    }

    /// Configura ou remove o gesto "Mover para…" de um lado. A escolha
    /// guarda a ação e o destino como uma unidade: remover o destino remove a
    /// ação, e escolher um destino garante que ela está na lista sem apagar a
    /// ordem das demais colunas.
    /// - Returns: `false` quando o lado já alcançou o teto de colunas e ainda
    ///   não tem a ação Mover. Assim a tela pode pedir que a pessoa libere uma
    ///   vaga, sem salvar um destino que nunca apareceria no gesto.
    @discardableResult
    public func setMoveDestination(_ destination: SwipeMoveDestination?, on side: SwipeSide) -> Bool {
        if let destination {
            return setMoveDestination(destination, on: side, for: destination.accountID)
        }
        // A API anterior não tinha como expressar de qual conta remover. Para
        // não apagar decisões de várias contas pelo controle legado, ela só
        // remove quando há uma única escolha naquele lado.
        guard let existing = configuration.destination(on: side) else { return false }
        return setMoveDestination(nil, on: side, for: existing.accountID)
    }

    /// Configura ou remove o destino de uma conta num dos lados. A lista de
    /// ações segue global: só o dado associado a Mover é por conta.
    @discardableResult
    public func setMoveDestination(
        _ destination: SwipeMoveDestination?,
        on side: SwipeSide,
        for accountID: String
    ) -> Bool {
        guard destination?.accountID == nil || destination?.accountID == accountID else { return false }
        var leading = configuration.leading
        var trailing = configuration.trailing
        var leadingDestinations = configuration.leadingDestinations
        var trailingDestinations = configuration.trailingDestinations

        switch side {
        case .leading:
            guard destination == nil
                || leading.contains(.moveToDestination)
                || leading.count < SwipeConfiguration.maxPerSide
            else { return false }
            if let destination { leadingDestinations[accountID] = destination }
            else { leadingDestinations.removeValue(forKey: accountID) }
            leading = Self.actions(leading, hasMoveDestinations: !leadingDestinations.isEmpty)
        case .trailing:
            guard destination == nil
                || trailing.contains(.moveToDestination)
                || trailing.count < SwipeConfiguration.maxPerSide
            else { return false }
            if let destination { trailingDestinations[accountID] = destination }
            else { trailingDestinations.removeValue(forKey: accountID) }
            trailing = Self.actions(trailing, hasMoveDestinations: !trailingDestinations.isEmpty)
        }
        select(SwipeConfiguration(
            leading: leading, trailing: trailing,
            leadingDestinations: leadingDestinations, trailingDestinations: trailingDestinations
        ))
        return true
    }

    private static func actions(
        _ actions: [SwipeAction], hasMoveDestinations: Bool
    ) -> [SwipeAction] {
        guard hasMoveDestinations else { return actions.filter { $0 != .moveToDestination } }
        return actions.contains(.moveToDestination) ? actions : actions + [.moveToDestination]
    }

    private static func write(
        _ destinations: [String: SwipeMoveDestination], to key: String, defaults: UserDefaults
    ) {
        guard !destinations.isEmpty else {
            defaults.removeObject(forKey: key)
            return
        }
        guard let data = try? JSONEncoder().encode(destinations) else { return }
        defaults.set(data, forKey: key)
    }

    /// Volta ao padrão **apagando** as chaves, para o estado voltar a ser "nunca
    /// escolhido". Gravar o padrão por cima faria um lado vazio de propósito
    /// ficar indistinguível de um lado nunca configurado no próximo marco.
    public func resetToDefault() {
        defaults.removeObject(forKey: Self.leadingKey)
        defaults.removeObject(forKey: Self.trailingKey)
        defaults.removeObject(forKey: Self.leadingDestinationKey)
        defaults.removeObject(forKey: Self.trailingDestinationKey)
        defaults.removeObject(forKey: Self.leadingDestinationsKey)
        defaults.removeObject(forKey: Self.trailingDestinationsKey)
        configuration = .default
    }
}
