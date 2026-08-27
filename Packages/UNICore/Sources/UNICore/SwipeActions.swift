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
        case .toggleRead: nil
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
        }
    }

    /// Arquivar é a única que tira a mensagem da triagem inteira, e é a que o
    /// dedo alcança primeiro no lado esquerdo. Ela pinta forte; o resto é
    /// discreto.
    public var tint: SwipeTint {
        self == .archive ? .strong : .quiet
    }

    /// Esta ação não faria nada com esta mensagem.
    ///
    /// Mover para a caixa em que ela já está é exatamente o que
    /// `MailStore.move(_:to:)` recusa logo na primeira guarda. O botão
    /// continua **visível** — é o que a fila de triagem do leitor já faz com a
    /// caixa corrente, e sumir com uma coluna mudaria a largura do painel de
    /// linha para linha — mas ele não dispara e não pode ser a ação armada.
    public func isNoOp(for message: Message) -> Bool {
        guard let target else { return false }  // a de leitura sempre faz algo
        return message.bucket == target
    }

    /// O que a ação manda fazer. `nil` quando não faria nada.
    public func command(for message: Message) -> ContextCommand? {
        guard !isNoOp(for: message) else { return nil }
        if let target { return .move(messageID: message.id, to: target) }
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
        }
    }

    /// O `help` do botão. Numa ação que não faria nada ele diz o porquê, em vez
    /// de deixar a pessoa clicando num botão calado.
    public func help(for message: Message) -> String {
        if isNoOp(for: message), let target {
            return "Esta mensagem já está em \(target.label)"
        }
        switch self {
        case .archive: return "Arquivar esta mensagem"
        case .toggleRead: return message.isRead ? "Marcar como não lida" : "Marcar como lida"
        case .later: return "Mover para Depois"
        case .today: return "Mover para Hoje"
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

    public init(leading: [SwipeAction], trailing: [SwipeAction]) {
        self.leading = Self.normalize(leading)
        self.trailing = Self.normalize(trailing)
    }

    /// Sem repetição e dentro do teto, preservando a ordem escolhida — a
    /// primeira é a que o arraste longo dispara.
    static func normalize(_ actions: [SwipeAction]) -> [SwipeAction] {
        var seen: Set<SwipeAction> = []
        var out: [SwipeAction] = []
        for action in actions where seen.insert(action).inserted {
            out.append(action)
            if out.count == maxPerSide { break }
        }
        return out
    }

    public func actions(on side: SwipeSide) -> [SwipeAction] {
        side == .leading ? leading : trailing
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
        let armed = actions.first { !$0.isNoOp(for: message) }

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
    public let action: SwipeAction
    public let messageID: String
    public let note: String
    public let undo: ContextCommand

    public init(
        id: UUID = UUID(),
        action: SwipeAction,
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
    public static func note(
        _ action: SwipeAction,
        message: Message,
        stamp: String
    ) -> String {
        let who = message.from.name.isEmpty ? message.from.address : message.from.name
        let head = action.receiptTitle(for: message)
        guard !who.isEmpty else { return "\(head) · \(stamp)" }
        return "\(head) — \(who) · \(stamp)"
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

    public private(set) var configuration: SwipeConfiguration

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.configuration = SwipeConfiguration(
            leading: Self.read(defaults, Self.leadingKey) ?? SwipeConfiguration.default.leading,
            trailing: Self.read(defaults, Self.trailingKey) ?? SwipeConfiguration.default.trailing
        )
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

    public func select(_ configuration: SwipeConfiguration) {
        self.configuration = configuration
        defaults.set(configuration.leading.map(\.rawValue), forKey: Self.leadingKey)
        defaults.set(configuration.trailing.map(\.rawValue), forKey: Self.trailingKey)
    }

    public func setActions(_ actions: [SwipeAction], on side: SwipeSide) {
        select(
            side == .leading
                ? SwipeConfiguration(leading: actions, trailing: configuration.trailing)
                : SwipeConfiguration(leading: configuration.leading, trailing: actions)
        )
    }

    /// Volta ao padrão **apagando** as chaves, para o estado voltar a ser "nunca
    /// escolhido". Gravar o padrão por cima faria um lado vazio de propósito
    /// ficar indistinguível de um lado nunca configurado no próximo marco.
    public func resetToDefault() {
        defaults.removeObject(forKey: Self.leadingKey)
        defaults.removeObject(forKey: Self.trailingKey)
        configuration = .default
    }
}
