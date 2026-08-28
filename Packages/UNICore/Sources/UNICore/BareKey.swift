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

    /// O código de tecla virtual do macOS. `kVK_Delete` é 51 — a tecla que o
    /// teclado brasileiro chama de "backspace".
    public var keyCode: UInt16 {
        switch self {
        case .delete: 51
        }
    }

    /// O caractere que `MenuShortcut` carrega. `\u{8}` é o backspace de ASCII,
    /// que é o que o AppKit entrega em `NSEvent.charactersIgnoringModifiers`
    /// para esta tecla.
    public var character: Character {
        switch self {
        case .delete: "\u{8}"
        }
    }

    /// O símbolo que o menu desenha.
    public var symbol: String {
        switch self {
        case .delete: "⌫"
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
