import Testing
@testable import UNICore

/// O teclado do menu de contexto.
///
/// O painel custom da Task AN prometia ↑ ↓ ⏎ → ← Esc, e o ensaio no app real da
/// Task AQ (`--ensaiar-teclado`) mostrou o que a promessa escondia: `→` estava
/// no mesmo caminho de `⏎`. Apertar a seta direita sobre "Abrir em janela"
/// abria a janela e fechava o menu. Quem navegasse com as setas disparava a
/// primeira linha em que tropeçasse.
///
/// Estes testes travam a distinção. São sobre a **decisão**, que mora em
/// `UNICore` — o `ContextMenuPresenter` só executa o que sai daqui.
@Suite("Teclas do menu de contexto")
struct MenuKeyActionTests {

    /// Um menu com as cinco naturezas que importam: item, traço, item apagado,
    /// submenu e submenu vazio.
    private var entries: [ContextMenuEntry] {
        [
            .item(ContextMenuItem("Abrir em janela", .openMessageWindow(messageID: "m1"))),
            .separator,
            .item(ContextMenuItem("Copiar", .copy("x"), isEnabled: false)),
            .submenu(title: "Mover para", items: [
                ContextMenuItem("Depois", .move(messageID: "m1", to: .later)),
                ContextMenuItem("Arquivar", .move(messageID: "m1", to: .archived)),
            ]),
            .submenu(title: "Vazio", items: []),
        ]
    }

    // MARK: - A seta direita não é o Enter

    @Test("→ numa linha comum não faz nada — não executa e não fecha")
    func rightOnAPlainRowDoesNothing() {
        let action = MenuKeyNavigation.action(
            forKeyCode: MenuKeyNavigation.KeyCode.right,
            highlighted: 0, in: entries, depth: 0
        )
        #expect(action == .nothing)
    }

    @Test("→ sobre um submenu entra nele")
    func rightOnASubmenuEnters() {
        let action = MenuKeyNavigation.action(
            forKeyCode: MenuKeyNavigation.KeyCode.right,
            highlighted: 3, in: entries, depth: 0
        )
        #expect(action == .enterSubmenu(3))
    }

    @Test("→ sobre um submenu vazio não abre nada")
    func rightOnAnEmptySubmenuDoesNothing() {
        let action = MenuKeyNavigation.action(
            forKeyCode: MenuKeyNavigation.KeyCode.right,
            highlighted: 4, in: entries, depth: 0
        )
        #expect(action == .nothing)
    }

    @Test("→ sem realce nenhum não faz nada")
    func rightWithoutHighlightDoesNothing() {
        let action = MenuKeyNavigation.action(
            forKeyCode: MenuKeyNavigation.KeyCode.right,
            highlighted: nil, in: entries, depth: 0
        )
        #expect(action == .nothing)
    }

    // MARK: - ⏎

    @Test("⏎ num item executa esse item", arguments: [
        MenuKeyNavigation.KeyCode.ret, MenuKeyNavigation.KeyCode.enter,
    ])
    func returnActivatesTheItem(code: UInt16) {
        let action = MenuKeyNavigation.action(
            forKeyCode: code, highlighted: 0, in: entries, depth: 0
        )
        #expect(action == .activate(0))
    }

    /// Não há o que executar numa linha que só tem filhos — é o que o `NSMenu`
    /// faz, e cravar `.activate` aqui mandaria o presenter rodar um comando que
    /// a entrada não tem.
    @Test("⏎ sobre um submenu abre o submenu em vez de executar")
    func returnOnASubmenuEnters() {
        let action = MenuKeyNavigation.action(
            forKeyCode: MenuKeyNavigation.KeyCode.ret,
            highlighted: 3, in: entries, depth: 0
        )
        #expect(action == .enterSubmenu(3))
    }

    @Test("⏎ num item apagado não executa")
    func returnOnADisabledItemDoesNothing() {
        let action = MenuKeyNavigation.action(
            forKeyCode: MenuKeyNavigation.KeyCode.ret,
            highlighted: 2, in: entries, depth: 0
        )
        #expect(action == .nothing)
    }

    // MARK: - ← e Esc

    @Test("← fecha o nível quando há um nível acima")
    func leftLeavesTheSubmenu() {
        let action = MenuKeyNavigation.action(
            forKeyCode: MenuKeyNavigation.KeyCode.left,
            highlighted: 0, in: entries, depth: 1
        )
        #expect(action == .leaveSubmenu)
    }

    /// No nível de cima não há para onde voltar, e fechar o menu inteiro com ←
    /// seria uma saída que ninguém pediu.
    @Test("← no primeiro nível não faz nada")
    func leftAtTheRootDoesNothing() {
        let action = MenuKeyNavigation.action(
            forKeyCode: MenuKeyNavigation.KeyCode.left,
            highlighted: 0, in: entries, depth: 0
        )
        #expect(action == .nothing)
    }

    @Test("Esc fecha o menu de qualquer nível", arguments: [0, 1, 2])
    func escapeAlwaysCloses(depth: Int) {
        let action = MenuKeyNavigation.action(
            forKeyCode: MenuKeyNavigation.KeyCode.escape,
            highlighted: nil, in: entries, depth: depth
        )
        #expect(action == .close)
    }

    // MARK: - ↑ ↓

    @Test("↓ anda para a frente e ↑ para trás")
    func arrowsMoveTheHighlight() {
        #expect(MenuKeyNavigation.action(
            forKeyCode: MenuKeyNavigation.KeyCode.down,
            highlighted: 0, in: entries, depth: 0
        ) == .move(1))
        #expect(MenuKeyNavigation.action(
            forKeyCode: MenuKeyNavigation.KeyCode.up,
            highlighted: 0, in: entries, depth: 0
        ) == .move(-1))
    }

    /// Uma tecla que o menu não conhece não pode virar ação nenhuma — e
    /// continua engolida pelo presenter, para não vazar para a janela de baixo.
    @Test("uma tecla qualquer não faz nada")
    func unknownKeyDoesNothing() {
        #expect(MenuKeyNavigation.action(
            forKeyCode: 15, highlighted: 0, in: entries, depth: 0
        ) == .nothing)
    }
}

/// A metade da tecla sem modificador que dá para provar sem app: qual tecla é,
/// e quando ela vale. A outra metade — quem é o primeiro respondedor agora —
/// mora em `UNIShell.BareKeyMonitor` e se prova por ensaio no app real.
@Suite("Tecla de atalho sem modificador")
struct BareKeyTests {

    @Test("⌫ é a tecla 51, e ela sai no menu como símbolo, não como caractere de controle")
    func deleteIsTheBackspaceKey() {
        #expect(BareKey.delete.keyCode == 51)
        #expect(BareKey.delete.symbol == "⌫")
        #expect(MenuShortcut.delete.label == "⌫")
    }

    /// ⌘⌫ é "mover para a lixeira" do Finder e ⌥⌫ apaga a palavra num campo de
    /// texto. Só o ⌫ puro é nosso — reivindicar os outros roubaria teclas que
    /// já significam outra coisa.
    @Test("qualquer modificador desqualifica a tecla")
    func modifiersDisqualify() {
        #expect(BareKey.match(keyCode: 51, hasModifier: false) == .delete)
        #expect(BareKey.match(keyCode: 51, hasModifier: true) == nil)
    }

    @Test("outra tecla qualquer não vira ⌫ por engano")
    func otherKeysDoNotMatch() {
        #expect(BareKey.match(keyCode: 36, hasModifier: false) == nil)  // ⏎
        #expect(BareKey(character: "r") == nil)
        #expect(BareKey(character: BareKey.delete.character) == .delete)
    }
}
