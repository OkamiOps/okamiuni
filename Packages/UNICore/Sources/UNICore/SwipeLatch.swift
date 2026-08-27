import Foundation

/// A trava que segura o clique de soltura depois do arraste.
///
/// ## Por que ela existe fora da `View`
///
/// Ela guarda o lado engatado (`side`) e um **selo** que diz qual fechamento
/// está em curso. Estado de `View` não se lê num teste, e o defeito que ela
/// conserta é de sequência, não de aparência: só uma máquina que se possa
/// dirigir passo a passo prova que o clique de soltura não seleciona.
///
/// ## O defeito
///
/// `snapShut()` zerava o `openRowID` compartilhado, e isso reentrava no
/// `onChange` da **própria linha**: a guarda de lá só perguntava
/// `opened != message.id`, e `nil` passa nessa pergunta. A linha que acabou de
/// fechar cancelava o próprio adiamento e se destravava no mesmo ciclo — a
/// proteção de 0,24s nunca valia para quem a pediu, e na caixa "Tudo" o clique
/// que solta o arraste selecionava a mensagem arrastada.
///
/// A guarda agora distingue as duas coisas: `nil` é o **eco do próprio
/// fechamento** e não destrava ninguém; só o `id` de **outra** linha destrava.
/// O selo cobre o resto — um settle atrasado que chegue depois de um novo
/// engate não tem mais o selo vigente e não destrava nada.
public struct SwipeLatch: Sendable, Hashable {

    public init() {}
    /// O lado em que o gesto nasceu, ou `nil` se a linha está livre.
    public private(set) var side: SwipeSide?
    /// Muda a cada transição. O settle adiado só age se o selo ainda for o dele.
    public private(set) var seal: Int = 0

    /// O arraste está em curso ou a linha está aberta — o clique fecha em vez
    /// de selecionar.
    public var isBlocked: Bool { side != nil }

    /// O gesto engatou de um lado.
    public mutating func engage(_ side: SwipeSide) {
        self.side = side
        seal &+= 1
    }

    /// Fechou por conta própria. **Continua travada** até o `settle` do selo
    /// devolvido — é essa a janela de 0,24s.
    public mutating func snapShut() -> Int {
        seal &+= 1
        return seal
    }

    /// A janela terminou. Só destrava se nada tiver acontecido no meio-tempo.
    public mutating func settle(_ seal: Int) {
        guard seal == self.seal else { return }
        side = nil
    }

    /// Destrava na hora — o clique deliberado numa linha aberta, ou outra linha
    /// tomando a vez.
    public mutating func release() {
        seal &+= 1
        side = nil
    }

    /// `openRowID` mudou. Devolve se a linha destravou, para quem chama
    /// cancelar o adiamento e animar o fechamento.
    ///
    /// `nil` é o eco do nosso próprio `snapShut()` e não pode destravar nada:
    /// era exatamente por aí que a janela de 0,24s se cancelava sozinha.
    public mutating func openRowChanged(to opened: String?, rowID: String) -> Bool {
        guard let opened, opened != rowID, isBlocked else { return false }
        release()
        return true
    }
}
