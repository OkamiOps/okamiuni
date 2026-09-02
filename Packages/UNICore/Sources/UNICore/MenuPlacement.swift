import Foundation

/// Onde um painel de menu cabe na tela.
///
/// ## Por que isto mora em `UNICore`
///
/// O menu de contexto deixou de ser o `NSMenu` do sistema (Task AN). O que o
/// sistema dava de graça — abrir no ponto do clique, virar para o outro lado
/// perto da borda, ancorar o submenu ao lado do item — passa a ser conta
/// nossa. Conta que decide se uma coisa aparece cortada ou não é exatamente o
/// tipo de código que tem de ser verificável sem abrir janela: este arquivo
/// não importa SwiftUI nem AppKit, e os testes dele medem o ponto de virada
/// **por um ponto** de folga.
///
/// ## O sistema de coordenadas
///
/// Tudo aqui é o espaço de tela do AppKit: **y cresce para cima**, a origem de
/// um retângulo é o canto **inferior** esquerdo. É o espaço em que
/// `NSScreen.visibleFrame` e `NSWindow.setFrame` falam, e converter na
/// fronteira já custou defeito em outro projeto.
///
/// O menu, porém, se ancora pelo canto **superior** esquerdo — é ali que a
/// ponta do cursor encosta quando o menu abre para baixo e para a direita. Por
/// isso as funções recebem uma âncora (um ponto) e uma medida, e devolvem o
/// retângulo já resolvido.
public enum MenuPlacement {

    /// Folga mínima entre o painel e a beira da área útil da tela.
    ///
    /// O `NSMenu` do sistema também não encosta: um painel colado na borda lê
    /// como cortado mesmo quando não está.
    public static let margin: CGFloat = 6

    /// Quanto o submenu monta sobre o painel do pai, para o ponteiro atravessar
    /// a fronteira sem passar por um vão que fecharia o menu.
    public static let submenuOverlap: CGFloat = 4

    /// O resultado: o retângulo final e se ele precisou virar.
    ///
    /// As duas bandeiras não são enfeite — são o que um teste consegue afirmar
    /// sobre a **decisão**, e não só sobre o número que saiu dela.
    public struct Placement: Sendable, Hashable {
        public let frame: CGRect
        public let didFlipHorizontally: Bool
        public let didFlipVertically: Bool

        public init(frame: CGRect, didFlipHorizontally: Bool, didFlipVertically: Bool) {
            self.frame = frame
            self.didFlipHorizontally = didFlipHorizontally
            self.didFlipVertically = didFlipVertically
        }
    }

    // MARK: - O painel de primeiro nível

    /// O painel aberto no ponto do clique.
    ///
    /// Preferência: canto superior esquerdo **no** ponto do clique, crescendo
    /// para baixo e para a direita — é o que todo menu de contexto faz.
    ///
    /// - Não cabe à direita: vira, e o canto superior **direito** passa a
    ///   encostar no ponto. Continuar empurrando para dentro (só clampar)
    ///   deixaria o painel por cima do que a pessoa clicou.
    /// - Não cabe embaixo: vira, e o canto **inferior** esquerdo encosta no
    ///   ponto — o menu cresce para cima.
    /// - Se depois de virar ainda não couber (painel maior que a tela), o
    ///   retângulo é empurrado para dentro. Cortado é pior que deslocado.
    public static func root(
        anchor: CGPoint,
        size: CGSize,
        bounds: CGRect,
        margin: CGFloat = margin
    ) -> Placement {
        // Horizontal: origem é o próprio x da âncora.
        var x = anchor.x
        var flippedH = false
        if x + size.width > bounds.maxX - margin {
            x = anchor.x - size.width
            flippedH = true
        }

        // Vertical, em y-para-cima: crescer "para baixo" é ocupar de
        // `anchor.y - height` até `anchor.y`.
        var y = anchor.y - size.height
        var flippedV = false
        if y < bounds.minY + margin {
            y = anchor.y
            flippedV = true
        }

        return Placement(
            frame: clamp(CGRect(x: x, y: y, width: size.width, height: size.height),
                         into: bounds, margin: margin),
            didFlipHorizontally: flippedH,
            didFlipVertically: flippedV
        )
    }

    // MARK: - O submenu

    /// O painel de um submenu, ancorado na linha que o abriu.
    ///
    /// - `parent` é o retângulo do painel de cima, já colocado.
    /// - `rowTop` é a coordenada **y** da borda de cima da linha, no mesmo
    ///   espaço de tela. O submenu alinha o topo dele com o topo da linha, que
    ///   é o que o `NSMenu` faz — e é o que faz o primeiro item do submenu
    ///   cair debaixo do ponteiro.
    ///
    /// Preferência: à direita, montando `overlap` sobre o pai. Não cabendo,
    /// abre à esquerda, com a mesma monta. Sem espaço dos dois lados, fica à
    /// direita empurrado para dentro.
    public static func submenu(
        parent: CGRect,
        rowTop: CGFloat,
        size: CGSize,
        bounds: CGRect,
        margin: CGFloat = margin,
        overlap: CGFloat = submenuOverlap
    ) -> Placement {
        var x = parent.maxX - overlap
        var flippedH = false
        if x + size.width > bounds.maxX - margin {
            x = parent.minX + overlap - size.width
            flippedH = true
        }

        var y = rowTop - size.height
        var flippedV = false
        if y < bounds.minY + margin {
            // Vira pelo mesmo princípio do painel de primeiro nível: o submenu
            // passa a crescer para cima a partir da linha, e o **fim** dele é
            // que alinha com a base da linha.
            y = rowTop
            flippedV = true
        }

        return Placement(
            frame: clamp(CGRect(x: x, y: y, width: size.width, height: size.height),
                         into: bounds, margin: margin),
            didFlipHorizontally: flippedH,
            didFlipVertically: flippedV
        )
    }

    // MARK: - Empurrar para dentro

    /// Põe o retângulo dentro da área útil, sem mudar o tamanho dele.
    ///
    /// Quando o painel é **maior** que a área (tela minúscula, menu enorme) a
    /// borda de início ganha: o menu começa visível e sobra embaixo, em vez de
    /// começar fora e a primeira linha nunca aparecer.
    static func clamp(_ rect: CGRect, into bounds: CGRect, margin: CGFloat) -> CGRect {
        var out = rect
        if out.maxX > bounds.maxX - margin { out.origin.x = bounds.maxX - margin - out.width }
        if out.minX < bounds.minX + margin { out.origin.x = bounds.minX + margin }
        if out.minY < bounds.minY + margin { out.origin.y = bounds.minY + margin }
        // A ordem decide quem ganha quando o painel é maior que a área: a
        // borda de **início da leitura** — esquerda e topo — é a última a ser
        // aplicada em cada eixo, e é a que fica visível.
        if out.maxY > bounds.maxY - margin { out.origin.y = bounds.maxY - margin - out.height }
        return out
    }
}

// MARK: - Navegação por teclado

/// O cursor do menu: qual linha está realçada e para onde ↑ e ↓ o levam.
///
/// Mora aqui pelo mesmo motivo do posicionamento — é aritmética sobre a lista
/// de entradas, e separador e item desabilitado **não recebem** o realce. Um
/// menu que para num traço é o defeito que o `NSMenu` não tinha, e prová-lo
/// abrindo janela seria impossível.
public enum MenuKeyNavigation {

    /// A entrada pode receber o realce?
    ///
    /// Submenu vazio não pode: ele não abre nada. `ContextMenus` já não monta
    /// nenhum, e isto é a segunda tranca.
    public static func isSelectable(_ entry: ContextMenuEntry) -> Bool {
        switch entry {
        case .item(let item): item.isEnabled
        case .submenu(_, let children): !children.isEmpty
        // Legenda é texto de cabeçalho: as setas passam por cima dela como
        // passam por cima de um traço.
        case .separator, .legenda, .aviso: false
        }
    }

    /// O primeiro índice realçável, na direção dada. `step` é +1 ou -1.
    public static func first(in entries: [ContextMenuEntry], step: Int = 1) -> Int? {
        guard !entries.isEmpty else { return nil }
        let start = step > 0 ? 0 : entries.count - 1
        return scan(from: start, step: step, in: entries, includeStart: true)
    }

    /// O próximo índice realçável a partir de `current`, dando a volta.
    ///
    /// `nil` em `current` significa "nada realçado ainda" — a primeira seta
    /// entra pela ponta correspondente à direção.
    public static func next(
        after current: Int?,
        step: Int,
        in entries: [ContextMenuEntry]
    ) -> Int? {
        guard !entries.isEmpty else { return nil }
        guard let current else { return first(in: entries, step: step) }
        return scan(from: current + step, step: step, in: entries, includeStart: true)
    }

    private static func scan(
        from start: Int,
        step: Int,
        in entries: [ContextMenuEntry],
        includeStart: Bool
    ) -> Int? {
        let count = entries.count
        var index = ((start % count) + count) % count
        for _ in 0..<count {
            if isSelectable(entries[index]) { return index }
            index = (((index + step) % count) + count) % count
        }
        _ = includeStart
        return nil
    }

    // MARK: - O que cada tecla faz

    /// Os códigos de tecla virtuais que o menu escuta. São os do
    /// `Carbon.HIToolbox.Events`, escritos aqui para `UNICore` continuar sem
    /// AppKit — é o que deixa a decisão inteira testável sem abrir janela.
    public enum KeyCode {
        public static let escape: UInt16 = 53
        public static let left: UInt16 = 123
        public static let right: UInt16 = 124
        public static let down: UInt16 = 125
        public static let up: UInt16 = 126
        public static let ret: UInt16 = 36
        public static let enter: UInt16 = 76
    }

    /// A decisão de uma tecla num menu aberto.
    public enum KeyAction: Equatable, Sendable {
        case close
        /// Anda o realce em `step` (+1 para ↓, -1 para ↑).
        case move(Int)
        /// Executa o item realçado e fecha o menu.
        case activate(Int)
        /// Abre o submenu da linha realçada e leva o realce para dentro dele.
        case enterSubmenu(Int)
        /// Fecha o nível corrente e volta o realce ao pai.
        case leaveSubmenu
        case nothing
    }

    /// Traduz uma tecla na decisão do menu.
    ///
    /// ## A distinção que o ensaio cobrou
    ///
    /// `→` **não é** `⏎`. Numa linha comum a seta direita não faz nada — no
    /// `NSMenu` ela nunca executou item nenhum. O painel custom da Task AN
    /// mandava as duas para o mesmo lugar, e o ensaio no app real mostrou o
    /// resultado: apertar `→` sobre "Abrir em janela" abria a janela e fechava
    /// o menu. Quem navegasse com as setas disparava a primeira linha em que
    /// tropeçasse.
    ///
    /// `⏎` sobre um submenu **abre** o submenu em vez de executar: é o que o
    /// `NSMenu` faz, e não há o que executar numa linha que só tem filhos.
    public static func action(
        forKeyCode code: UInt16,
        highlighted: Int?,
        in entries: [ContextMenuEntry],
        depth: Int
    ) -> KeyAction {
        switch code {
        case KeyCode.escape:
            return .close

        case KeyCode.down:
            return .move(1)

        case KeyCode.up:
            return .move(-1)

        case KeyCode.ret, KeyCode.enter:
            guard let row = highlighted, entries.indices.contains(row) else { return .nothing }
            if case .submenu = entries[row] {
                return isSelectable(entries[row]) ? .enterSubmenu(row) : .nothing
            }
            return isSelectable(entries[row]) ? .activate(row) : .nothing

        case KeyCode.right:
            guard let row = highlighted, entries.indices.contains(row),
                  case .submenu = entries[row], isSelectable(entries[row])
            else { return .nothing }
            return .enterSubmenu(row)

        case KeyCode.left:
            return depth > 0 ? .leaveSubmenu : .nothing

        default:
            return .nothing
        }
    }
}
