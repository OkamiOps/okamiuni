import Foundation
import Observation
import UNICore

/// O último "o que acabou de acontecer, e como desfazer", partilhado pelas
/// superfícies que agem sobre a mesma mensagem.
///
/// ## Por que saiu do `@State` da lista
///
/// A faixa de retorno nasceu no arraste, e ali um `@State` na `MessageList`
/// bastava: o gesto começava e terminava dentro dela. A Task AR quebrou essa
/// suposição — apagar chega do menu da linha, do menu do **leitor** e da tecla
/// ⌫, e as três têm de produzir a mesma faixa com "Desfazer". Um `@State` por
/// superfície daria ao leitor uma ação destrutiva **sem** volta visível, que é
/// pior do que não ter a ação.
///
/// Quem **desenha** a faixa continua sendo a lista, e por um motivo que não
/// mudou: a linha some quando a mensagem sai da caixa, e um retorno preso a ela
/// morreria junto com o que precisava desfazer. A lista sobrevive a tudo.
///
/// Chega pelo ambiente, e é opcional lá — o harness de renderização e as
/// previews não precisam prover nada, e a lista cai num objeto próprio. É o
/// mesmo alcance que `SwipeSettingsStore` já tem.
@MainActor
@Observable
public final class ActionReceipts {
    public var current: SwipeReceipt?

    public init() {}

    /// Dá a "Apagar" e a "Apagar definitivamente" o retorno com "Desfazer" que
    /// o arraste já tem, venham eles do menu da linha, do menu do leitor ou da
    /// tecla ⌫.
    ///
    /// Devolver `true` quer dizer "já cuidei disto": `MenuCommandRunner` não
    /// repete a mutação. Todo comando que não é destrutivo passa direto e segue
    /// o caminho de sempre — nem toda ação ganha faixa, e encher a tela de
    /// confirmação de "marcada como lida" seria ruído.
    ///
    /// O recibo nasce **antes** da mudança, como o do arraste: depois de
    /// apagada, a mensagem não está mais no store para dizer quem era.
    @discardableResult
    public func intercept(_ command: ContextCommand, on store: MailStore, stamp: String) -> Bool {
        switch command {
        case .move(let messageID, .trash):
            guard let message = store.messages.first(where: { $0.id == messageID }) else {
                return false
            }
            let made = SwipeReceipt.of(.trash, message: message, stamp: stamp)
            StoreCommand.run(command, on: store)
            current = made
            return true

        case .deleteForever(let messageID):
            guard let message = store.messages.first(where: { $0.id == messageID }) else {
                return false
            }
            let made = SwipeReceipt.ofDeleteForever(message: message, stamp: stamp)
            store.deleteForever(messageID)
            current = made
            return true

        default:
            return false
        }
    }

    /// A hora do recibo. Entra pronta em `SwipeReceipt` justamente para a
    /// formatação ficar num lugar só — ver o comentário de `SwipeReceipt.of`.
    public static var stamp: String {
        Date.now.formatted(date: .omitted, time: .shortened)
    }
}
