import Foundation
import Testing
@testable import UNICore

/// A conta que o `NSMenu` fazia por nós até a Task AN.
///
/// Todo caso mede o **ponto de virada**, não o meio do intervalo: um teste que
/// abre o menu no centro da tela passa com qualquer aritmética. O que separa o
/// código certo do errado é um ponto de folga, e é por um ponto que estes
/// testes perguntam.
///
/// Coordenadas de tela do AppKit: y cresce para cima, a origem do retângulo é o
/// canto inferior esquerdo. Ver `MenuPlacement`.
@Suite("Onde o painel de menu cabe")
struct MenuPlacementTests {

    /// Uma tela de 1000×800 com a área útil inteira, para as contas saírem
    /// redondas. `margin` é o padrão, 6.
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let size = CGSize(width: 200, height: 100)

    // MARK: - Primeiro nível

    @Test("no meio da tela o menu abre para baixo e para a direita, no ponto")
    func opensAtThePoint() {
        let placement = MenuPlacement.root(
            anchor: CGPoint(x: 400, y: 500), size: size, bounds: screen
        )
        #expect(placement.frame == CGRect(x: 400, y: 400, width: 200, height: 100))
        #expect(!placement.didFlipHorizontally)
        #expect(!placement.didFlipVertically)
    }

    /// O último ponto em que ele **cabe**: 794 + 200 = 994, que é `maxX` menos
    /// a folga. Um a mais e vira.
    @Test("cabe à direita pelo último ponto")
    func fitsRightByOnePoint() {
        let placement = MenuPlacement.root(
            anchor: CGPoint(x: 794, y: 500), size: size, bounds: screen
        )
        #expect(!placement.didFlipHorizontally)
        #expect(placement.frame.minX == 794)
    }

    @Test("um ponto a mais e ele vira para a esquerda do cursor")
    func flipsRightByOnePoint() {
        let placement = MenuPlacement.root(
            anchor: CGPoint(x: 795, y: 500), size: size, bounds: screen
        )
        #expect(placement.didFlipHorizontally)
        // Virado, é o canto **direito** que encosta no ponto.
        #expect(placement.frame.maxX == 795)
        #expect(placement.frame.minX == 595)
    }

    /// Em y-para-cima, "cabe embaixo" é `anchor.y - altura` não passar da
    /// borda de baixo mais a folga: 106 − 100 = 6.
    @Test("cabe embaixo pelo último ponto")
    func fitsBelowByOnePoint() {
        let placement = MenuPlacement.root(
            anchor: CGPoint(x: 400, y: 106), size: size, bounds: screen
        )
        #expect(!placement.didFlipVertically)
        #expect(placement.frame.minY == 6)
    }

    @Test("um ponto a menos e ele cresce para cima")
    func flipsBelowByOnePoint() {
        let placement = MenuPlacement.root(
            anchor: CGPoint(x: 400, y: 105), size: size, bounds: screen
        )
        #expect(placement.didFlipVertically)
        #expect(placement.frame.minY == 105)
        #expect(placement.frame.maxY == 205)
    }

    @Test("no canto de baixo à direita ele vira nos dois eixos e não sai da tela")
    func flipsInTheCorner() {
        let placement = MenuPlacement.root(
            anchor: CGPoint(x: 995, y: 4), size: size, bounds: screen
        )
        #expect(placement.didFlipHorizontally)
        #expect(placement.didFlipVertically)
        #expect(screen.insetBy(dx: 6, dy: 6).contains(placement.frame))
    }

    /// Uma tela que não comporta o painel não pode devolver um retângulo que
    /// começa fora dela: a primeira linha do menu tem de estar visível.
    @Test("painel maior que a tela começa visível em vez de começar fora")
    func clampsWhenTooBig() {
        let placement = MenuPlacement.root(
            anchor: CGPoint(x: 400, y: 400),
            size: CGSize(width: 2000, height: 2000),
            bounds: screen
        )
        #expect(placement.frame.minX == 6)
        #expect(placement.frame.maxY == 794)
    }

    /// A área útil não começa em zero quando há Dock e barra de menus. Cravar
    /// `0` em vez de ler `bounds.minY` passaria em todos os casos acima.
    @Test("a folga é medida contra a área útil, não contra a origem da tela")
    func respectsVisibleFrameOrigin() {
        let useful = CGRect(x: 100, y: 50, width: 800, height: 700)
        let placement = MenuPlacement.root(
            anchor: CGPoint(x: 400, y: 150), size: size, bounds: useful
        )
        // 150 − 100 = 50, que é menor que 50 + 6.
        #expect(placement.didFlipVertically)
        #expect(placement.frame.minY == 150)
    }

    // MARK: - Submenu

    /// Painel do pai de 200×200 com o topo em 600; a linha "Mover para" começa
    /// em 580.
    let parent = CGRect(x: 100, y: 400, width: 200, height: 200)

    @Test("o submenu abre à direita, montado no pai, alinhado pelo topo da linha")
    func submenuOpensRight() {
        let placement = MenuPlacement.submenu(
            parent: parent, rowTop: 580,
            size: CGSize(width: 180, height: 120), bounds: screen
        )
        #expect(!placement.didFlipHorizontally)
        #expect(placement.frame.minX == parent.maxX - MenuPlacement.submenuOverlap)
        #expect(placement.frame.maxY == 580)
    }

    /// O ponto de virada horizontal do submenu: `maxX − 4 + 180 = 994`.
    @Test("o submenu cabe à direita pelo último ponto")
    func submenuFitsRightByOnePoint() {
        let tight = CGRect(x: 618, y: 400, width: 200, height: 200)
        let placement = MenuPlacement.submenu(
            parent: tight, rowTop: 580,
            size: CGSize(width: 180, height: 120), bounds: screen
        )
        #expect(!placement.didFlipHorizontally)
        #expect(placement.frame.maxX == 994)
    }

    @Test("um ponto a mais e o submenu abre para o outro lado")
    func submenuFlipsLeftByOnePoint() {
        let tight = CGRect(x: 619, y: 400, width: 200, height: 200)
        let placement = MenuPlacement.submenu(
            parent: tight, rowTop: 580,
            size: CGSize(width: 180, height: 120), bounds: screen
        )
        #expect(placement.didFlipHorizontally)
        // Do outro lado ele monta sobre a borda **esquerda** do pai.
        #expect(placement.frame.maxX == tight.minX + MenuPlacement.submenuOverlap)
    }

    @Test("submenu que não cabe embaixo da linha cresce para cima a partir dela")
    func submenuFlipsUp() {
        let low = CGRect(x: 100, y: 20, width: 200, height: 100)
        let placement = MenuPlacement.submenu(
            parent: low, rowTop: 100,
            size: CGSize(width: 180, height: 200), bounds: screen
        )
        #expect(placement.didFlipVertically)
        #expect(placement.frame.minY >= 6)
        #expect(screen.insetBy(dx: 6, dy: 6).contains(placement.frame))
    }
}

/// O cursor do menu no teclado. O `NSMenu` pulava traço e item apagado sozinho;
/// perder isso na troca seria perder acessibilidade.
@Suite("Setas do menu")
struct MenuKeyNavigationTests {

    let menu: [ContextMenuEntry] = [
        .item(ContextMenuItem("Abrir", .openMessageWindow(messageID: "m1"))),
        .separator,
        .item(ContextMenuItem("Apagado", .copy("x"), isEnabled: false)),
        .submenu(title: "Mover para", items: [
            ContextMenuItem("Depois", .move(messageID: "m1", to: .later))
        ]),
    ]

    @Test("a primeira seta para baixo entra no primeiro item realçável")
    func entersAtTheTop() {
        #expect(MenuKeyNavigation.next(after: nil, step: 1, in: menu) == 0)
    }

    @Test("a primeira seta para cima entra pelo fim")
    func entersAtTheBottom() {
        #expect(MenuKeyNavigation.next(after: nil, step: -1, in: menu) == 3)
    }

    @Test("o traço e o item apagado são pulados")
    func skipsSeparatorAndDisabled() {
        #expect(MenuKeyNavigation.next(after: 0, step: 1, in: menu) == 3)
        #expect(MenuKeyNavigation.next(after: 3, step: -1, in: menu) == 0)
    }

    @Test("no fim, dá a volta")
    func wraps() {
        #expect(MenuKeyNavigation.next(after: 3, step: 1, in: menu) == 0)
        #expect(MenuKeyNavigation.next(after: 0, step: -1, in: menu) == 3)
    }

    @Test("submenu vazio não recebe realce — ele não abre nada")
    func emptySubmenuIsNotSelectable() {
        let entries: [ContextMenuEntry] = [.submenu(title: "Vazio", items: [])]
        #expect(!MenuKeyNavigation.isSelectable(entries[0]))
        #expect(MenuKeyNavigation.next(after: nil, step: 1, in: entries) == nil)
    }

    @Test("um menu só de traços não realça nada, em vez de parar num deles")
    func allSeparators() {
        #expect(MenuKeyNavigation.first(in: [.separator, .separator]) == nil)
    }

    /// O menu de verdade da linha de mensagem: a navegação tem de pular os dois
    /// traços dele e chegar em todos os itens, na ordem em que se lê.
    @Test("o menu da linha de mensagem percorre item por item, sem parar no traço")
    func walksTheRealMenu() {
        let entries = ContextMenus.messageRow(Fixtures.messages[0])
        var seen: [Int] = []
        var cursor: Int? = nil
        for _ in 0..<entries.count {
            cursor = MenuKeyNavigation.next(after: cursor, step: 1, in: entries)
            guard let cursor else { break }
            if seen.contains(cursor) { break }
            seen.append(cursor)
        }
        #expect(seen.count == entries.filter { !$0.isSeparator }.count)
        #expect(seen.allSatisfy { !entries[$0].isSeparator })
    }
}
