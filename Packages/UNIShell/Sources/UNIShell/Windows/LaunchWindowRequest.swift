import Foundation
import UNICore

/// Uma janela auxiliar pedida pela linha de comando do lançamento.
///
/// Existe por um motivo de método: verificar o quadro de uma janela auxiliar
/// exigia apertar ⌘N, e apertar ⌘N por evento sintético **toma o teclado da
/// máquina de quem está trabalhando**. `open -g --args --nova-mensagem` abre a
/// mesma janela pelo mesmo caminho (`openWindow`), sem trazer o app à frente e
/// sem tocar em mouse nem teclado.
///
/// Não é código de teste disfarçado: é uma porta de depuração, com o mesmo
/// gatilho que o menu usa. Ela só age quando o argumento está presente.
public struct LaunchWindowRequest: Sendable, Hashable {
    /// O identificador de cena a abrir — um dos de `UNIWindow`.
    public let windowID: String
    /// O valor que a cena carrega. `WindowGroup(id:for:)` exige um `String`.
    public let value: String

    public init(windowID: String, value: String) {
        self.windowID = windowID
        self.value = value
    }

    /// Os argumentos aceitos, e a cena de cada um.
    ///
    /// `--mensagem=m2` e `--mensagem m2` funcionam igual: o `open --args` do
    /// macOS entrega os dois formatos conforme quem escreve a linha.
    /// `prefix` é a intenção que a cena carrega junto do id — ver
    /// `ComposerRoute`. Só a janela 03 tem mais de uma; as outras usam `""`.
    public static let flags: [(flag: String, windowID: String, prefix: String)] = [
        ("--nova-mensagem", UNIWindow.newMessage, ""),
        ("--responder", UNIWindow.composer, ""),
        ("--responder-todos", UNIWindow.composer, ComposerRoute.replyAllPrefix),
        ("--encaminhar", UNIWindow.composer, ComposerRoute.forwardPrefix),
        ("--mensagem", UNIWindow.message, ""),
        ("--compromisso", UNIWindow.event, ""),
    ]

    /// Lê a linha de comando. Devolve `nil` quando nenhuma bandeira aparece —
    /// que é o caso de todo lançamento normal.
    ///
    /// Só a **primeira** bandeira reconhecida vale: abrir quatro janelas de uma
    /// vez esconderia justamente o defeito de quadro que ela serve para medir.
    public static func parse(_ arguments: [String]) -> LaunchWindowRequest? {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            let name = argument.prefix { $0 != "=" }
            guard let match = flags.first(where: { $0.flag == name }) else {
                index += 1
                continue
            }
            let inlineValue = argument.contains("=")
                ? String(argument.drop { $0 != "=" }.dropFirst())
                : nil
            let nextValue: String? = {
                guard inlineValue == nil, index + 1 < arguments.count else { return nil }
                let next = arguments[index + 1]
                return next.hasPrefix("--") ? nil : next
            }()
            return LaunchWindowRequest(
                windowID: match.windowID,
                value: match.prefix + (inlineValue ?? nextValue ?? "")
            )
        }
        return nil
    }

    /// O que o app lê no lançamento.
    public static var fromProcess: LaunchWindowRequest? {
        parse(Array(CommandLine.arguments.dropFirst()))
    }
}
