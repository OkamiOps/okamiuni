import Foundation

/// Uma tecla de atalho **sem modificador**.
///
/// Existe porque ela tem um problema que ⌘E e ⇧⌘F não têm: o caminho normal de
/// um atalho no macOS é `performKeyEquivalent`, que a janela consulta **antes**
/// de entregar a tecla ao primeiro respondedor. Um ⌫ registrado por lá seria
/// roubado do campo de busca e do editor do composer — a pessoa apagaria uma
/// mensagem tentando apagar uma letra.
///
/// Então a decisão é em duas partes, e esta é a metade que dá para provar sem
/// app: **qual** tecla é, e **quando** ela vale. A outra metade — quem é o
/// primeiro respondedor agora — mora em `UNIShell.BareKeyMonitor` e se prova
/// por ensaio no app real (`--ensaiar-teclado`).
public enum BareKey: Sendable, Hashable, CaseIterable {
    case delete
    /// Sobe uma conversa na lista. `kVK_UpArrow` é 126.
    case up
    /// Desce uma conversa na lista. `kVK_DownArrow` é 125.
    case down
    /// Cancela a ação mais local. `kVK_Escape` é 53.
    case escape

    /// O código de tecla virtual do macOS. `kVK_Delete` é 51 — a tecla que o
    /// teclado brasileiro chama de "backspace".
    public var keyCode: UInt16 {
        switch self {
        case .delete: 51
        case .up: 126
        case .down: 125
        case .escape: 53
        }
    }

    /// O caractere que `MenuShortcut` carrega. `\u{8}` é o backspace de ASCII,
    /// que é o que o AppKit entrega em `NSEvent.charactersIgnoringModifiers`
    /// para esta tecla. As setas usam as function keys do AppKit (`NSUpArrow`
    /// / `NSDownArrow`); ninguém as escreve num atalho de menu.
    public var character: Character {
        switch self {
        case .delete: "\u{8}"
        case .up: "\u{F700}"
        case .down: "\u{F701}"
        case .escape: "\u{1B}"
        }
    }

    /// O símbolo que o menu desenha.
    public var symbol: String {
        switch self {
        case .delete: "⌫"
        case .up: "↑"
        case .down: "↓"
        case .escape: "Esc"
        }
    }

    public init?(character: Character) {
        guard let match = Self.allCases.first(where: { $0.character == character }) else {
            return nil
        }
        self = match
    }

    /// Esta tecla, sem modificador nenhum que mude o sentido dela.
    ///
    /// ⇧, ⌘, ⌥ e ⌃ desqualificam: ⌘⌫ é "mover para a lixeira" do Finder e ⌥⌫
    /// apaga a palavra num campo de texto. Só o ⌫ puro é nosso. Caps Lock e a
    /// função não contam — elas não mudam o sentido de tecla nenhuma aqui.
    public static func match(keyCode: UInt16, hasModifier: Bool) -> BareKey? {
        guard !hasModifier else { return nil }
        return allCases.first { $0.keyCode == keyCode }
    }
}

/// O Esc cancela **uma** camada por toque, de dentro para fora: o campo de
/// busca, um modal por cima da aba, o painel do assistente, o lote marcado,
/// o recorte que a busca ainda impõe na lista.
///
/// A ordem é a da ação que a pessoa está fazendo agora. Estar digitando na
/// busca vence o modal aberto atrás; o modal vence o assistente; o
/// assistente vence o lote; o lote vence o termo que ficou na caixa.
public enum EscapeCancel: Equatable, Sendable {
    case search
    case overlay
    case assistant
    case selection
    case searchQuery

    public static func next(
        searchFocused: Bool,
        query: String,
        assistantOpen: Bool,
        selecting: Bool,
        overlayOpen: Bool = false
    ) -> Self? {
        if searchFocused { return .search }
        if overlayOpen { return .overlay }
        if assistantOpen { return .assistant }
        if selecting { return .selection }
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .searchQuery
        }
        return nil
    }
}
