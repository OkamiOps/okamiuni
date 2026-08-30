import Foundation

/// A **máquina de estados inteira** do arraste da linha — a parte que até esta
/// tarefa morava em `@State` de `SwipeRow` e onde teste nenhum chegava.
///
/// ## Por que ela existe
///
/// Três rodadas seguidas (`db51586`, `e58b186`, `d0b09fa`) consertaram o
/// **modelo** — `SwipeGesture.resolve` ganhou fronteiras provadas, `SwipeLatch`
/// resolveu a reentrância do fechamento, os números foram recalibrados — e o
/// defeito sobreviveu, porque ele nunca esteve no modelo: estava no que a
/// `View` fazia com o modelo entre um evento e o próximo.
///
/// `DragGesture` reporta `translation` **acumulada a partir da origem daquele
/// gesto**, e a origem de cada gesto é onde o botão do mouse desceu. A view
/// escrevia `translation = value.translation` cru. Enquanto a linha descansa
/// fechada isso é inofensivo — a origem do gesto e a posição da linha
/// coincidem em zero. Assim que a linha descansa **aberta**, as duas deixam de
/// coincidir, e todo evento passa a mentir sobre onde a linha está.
///
/// Esta máquina separa as duas coisas que a view confundia:
///
/// - **`restMagnitude`** — onde a linha está parada, em unidades de mão
///   (0 fechada, `panelWidth` aberta);
/// - **`translation`** do gesto vivo — quanto a mão andou **desde que o botão
///   desceu**.
///
/// O deslocamento que vale é a **soma** dos dois, e é dela que saem o lado, o
/// painel revelado, a ação armada e o limiar de disparo. É o que o brief pede
/// com "medido A PARTIR DA POSIÇÃO REAL da linha, não da origem do gesto".
///
/// ## As duas regras que o defeito violava
///
/// 1. **O lado é decidido uma vez por gesto — e numa linha aberta ele já vem
///    decidido.** `side` só é escolhido quando a linha está fechada. Numa
///    linha aberta à direita, arrastar para a esquerda para fechá-la não pode
///    "descobrir" o lado `trailing`: o lado é o da linha, e o gesto só mexe na
///    magnitude. Era exatamente aqui que um gesto único acendia os dois lados.
/// 2. **A magnitude é presa em zero.** Puxar além do fechamento não atravessa
///    para o painel oposto; ele para fechado e fica fechado. O painel oposto só
///    existe num gesto que **comece** com a linha fechada.
///
/// ## O que ela não faz
///
/// Não desenha, não anima, não sabe o que a ação faz com a mensagem. Devolve
/// `SwipeResolution` (o que mostrar agora) e `SwipeOutcome` (o que a view deve
/// fazer em seguida). A view virou tradutora de eventos.

// MARK: - O contexto de um evento

/// O que a máquina precisa saber do mundo para resolver um evento, e que muda
/// de linha para linha e de janela para janela.
///
/// Entra em **cada chamada** em vez de ficar guardado dentro da máquina de
/// propósito: `configuration` muda quando a pessoa mexe nos ajustes, `rowWidth`
/// muda quando a janela é redimensionada e `message` muda quando a lista
/// reordena. Estado guardado ficaria velho exatamente nos três momentos em que
/// importa.
public struct SwipeContext: Sendable, Hashable {
    public var configuration: SwipeConfiguration
    /// A largura real da linha — dela sai o limiar do arraste longo.
    public var rowWidth: CGFloat
    public var message: Message

    public init(
        configuration: SwipeConfiguration = .default,
        rowWidth: CGFloat = SwipeMetrics.referenceRowWidth,
        message: Message
    ) {
        self.configuration = configuration
        self.rowWidth = rowWidth
        self.message = message
    }

    func actions(on side: SwipeSide) -> [SwipeAction] { configuration.actions(on: side) }

    func armed(on side: SwipeSide) -> SwipeAction? {
        let destination = configuration.destination(on: side, for: message.accountID)
        return actions(on: side).first {
            !$0.isNoOp(for: message, destination: destination)
        }
    }

    func panelWidth(on side: SwipeSide) -> CGFloat {
        SwipeMetrics.panelWidth(actions: actions(on: side).count)
    }

    func commitThreshold(on side: SwipeSide) -> CGFloat {
        SwipeMetrics.commitThreshold(actions: actions(on: side).count, rowWidth: rowWidth)
    }
}

// MARK: - O que a view faz depois

/// A ordem de serviço que um evento deixa para quem desenha.
///
/// Nada aqui é opinião sobre aparência: é o que a máquina **não pode** fazer
/// sozinha porque mora fora dela — a ação que dispara, o `openRowID`
/// compartilhado, e o adiamento de 0,24s que segura o clique de soltura.
public struct SwipeOutcome: Sendable, Hashable {
    /// A ação que o arraste longo disparou. `nil` na esmagadora maioria dos
    /// eventos — e **nunca** mais de uma por gesto.
    public var fired: SwipeAction?
    /// O lado é necessário quando a mesma ação configurável existe nos dois
    /// lados com destinos diferentes. `SwipeAction` continua sendo a unidade
    /// do gesto; este campo só identifica qual configuração a resolveu.
    public var firedSide: SwipeSide?
    /// A linha passou a ser a aberta: escreva o id dela em `openRowID`.
    public var claimsOpenRow: Bool
    /// A linha deixou de ser a aberta: limpe `openRowID` se ele for dela.
    public var releasesOpenRow: Bool
    /// Agende `settle(_:)` com este selo depois da janela de 0,24s.
    public var settleSeal: Int?
    /// Agende `settleGrace(_:)` com este selo depois da mesma janela — é a
    /// carência que impede o clique fantasma do mouse-up de fechar a linha
    /// que o próprio arrasto acabou de deixar aberta.
    public var graceSeal: Int?
    /// A mudança de posição merece animação (soltura, fechamento, toque) — ao
    /// contrário do acompanhamento sob a mão, que tem de ser instantâneo.
    public var animates: Bool

    public init(
        fired: SwipeAction? = nil,
        firedSide: SwipeSide? = nil,
        claimsOpenRow: Bool = false,
        releasesOpenRow: Bool = false,
        settleSeal: Int? = nil,
        graceSeal: Int? = nil,
        animates: Bool = false
    ) {
        self.fired = fired
        self.firedSide = firedSide
        self.claimsOpenRow = claimsOpenRow
        self.releasesOpenRow = releasesOpenRow
        self.settleSeal = settleSeal
        self.graceSeal = graceSeal
        self.animates = animates
    }

    public static let ignored = SwipeOutcome()
}

// MARK: - A máquina

public struct SwipeGestureMachine: Sendable, Hashable {

    // MARK: Repouso

    /// O lado em que a linha está **parada**, ou `nil` se ela está fechada.
    public private(set) var restSide: SwipeSide?
    /// Onde a linha está parada, em unidades de mão. `0` fechada,
    /// `panelWidth` aberta.
    public private(set) var restMagnitude: CGFloat = 0

    // MARK: Gesto vivo

    /// O lado que vale agora — o do repouso quando a linha já estava aberta, o
    /// engatado quando ela estava fechada. `nil` enquanto o gesto ainda é
    /// rolagem ou clique.
    public private(set) var side: SwipeSide?
    /// O deslocamento efetivo: repouso mais o que a mão andou neste gesto,
    /// preso em zero.
    public private(set) var magnitude: CGFloat = 0
    public private(set) var isDragging = false

    /// A origem do gesto vivo, para reconhecer um **re-engate**.
    ///
    /// O `DragGesture` roda `simultaneousGesture` com a `ScrollView`, e quando
    /// a rolagem toma a vez o `onEnded` pode simplesmente não chegar. Sem esta
    /// marca, o primeiro evento do gesto seguinte seria lido como continuação
    /// do anterior — a origem trocou de lugar e a magnitude daria um salto. Uma
    /// `startLocation` diferente é gesto novo, tenha o anterior terminado
    /// direito ou não.
    private var origin: CGPoint?

    /// A carência contra o clique fantasma do mouse-up — ver `dismiss(force:)`.
    private var dismissGraceArmed = false
    private var dismissGraceSeal = 0

    // MARK: Trava

    /// A trava do clique de soltura, intacta desde `e58b186` — ela já tinha
    /// teste próprio e o defeito desta tarefa não é o dela.
    public private(set) var latch = SwipeLatch()

    public init() {}

    /// O clique fecha a linha em vez de selecionar.
    public var isBlocked: Bool { latch.isBlocked }

    // MARK: - O que mostrar agora

    public func resolution(_ context: SwipeContext) -> SwipeResolution {
        guard let side, !context.actions(on: side).isEmpty else { return .idle }
        let count = context.actions(on: side).count
        let revealed = SwipeMetrics.reveal(magnitude: magnitude, actions: count)
        let armed = context.armed(on: side)
        return SwipeResolution(
            side: side,
            offset: side == .leading ? revealed : -revealed,
            armed: armed,
            isOpen: magnitude >= SwipeMetrics.openThreshold,
            willFire: armed != nil && magnitude >= context.commitThreshold(on: side)
        )
    }

    // MARK: - Eventos do arraste

    /// Um `onChanged`. `translation` é acumulada da origem **deste** gesto, e
    /// `startLocation` é essa origem — é ela que distingue um gesto novo de uma
    /// continuação.
    public mutating func dragChanged(
        translation: CGSize,
        startLocation: CGPoint,
        _ context: SwipeContext
    ) -> SwipeOutcome {
        beginIfNeeded(startLocation)

        guard let projected = project(translation: translation, context) else {
            // Ainda é rolagem ou clique: a linha não se mexe.
            return .ignored
        }

        var outcome = SwipeOutcome()
        if side == nil {
            side = projected.side
            latch.engage(projected.side)
            outcome.claimsOpenRow = true
        }
        magnitude = projected.magnitude
        return outcome
    }

    /// Um `onEnded`. É o **único** ponto em que uma ação dispara — e dispara no
    /// máximo uma vez, porque o gesto morre no mesmo passo.
    public mutating func dragEnded(
        translation: CGSize,
        startLocation: CGPoint,
        _ context: SwipeContext
    ) -> SwipeOutcome {
        beginIfNeeded(startLocation)
        defer {
            origin = nil
            isDragging = false
        }

        guard let projected = project(translation: translation, context) else {
            return settleToRest()
        }

        let side = projected.side
        let magnitude = projected.magnitude
        self.side = side
        self.magnitude = magnitude

        // Disparo por arraste longo, medido a partir da posição real da linha.
        if let armed = context.armed(on: side), magnitude >= context.commitThreshold(on: side) {
            var outcome = shut()
            outcome.fired = armed
            outcome.firedSide = side
            return outcome
        }

        if magnitude >= openBar {
            return rest(open: side, context)
        }
        return shut()
    }

    /// O gesto morreu sem `onEnded` — a `ScrollView` levou. Nada dispara e a
    /// linha volta para onde estava parada.
    public mutating func dragCancelled() -> SwipeOutcome {
        origin = nil
        isDragging = false
        return settleToRest()
    }

    // MARK: - Os outros caminhos

    /// O clique deliberado numa linha aberta, ou o toque numa coluna revelada.
    /// Fecha na hora e destrava.
    ///
    /// **A carência é o coração do defeito "não fica parada".** No macOS um
    /// `Button` dispara no mouse-up mesmo depois de a mão andar 200pt, desde
    /// que solte dentro dos limites — e a linha inteira é um `Button`. Todo
    /// arrasto terminava com um clique fantasma, e este método fechava a linha
    /// que o `dragEnded` tinha acabado de deixar aberta: o descanso era
    /// **inalcançável por construção**. Visto no ensaio dentro do app
    /// (`--ensaiar-arraste`): painel aberto no quadro do mouse-up, linha
    /// fechada 60ms depois.
    ///
    /// Então: com um arraste vivo, ou dentro da carência que `rest(open:)`
    /// arma, o pedido é o eco do próprio gesto e não fecha nada. `force`
    /// atravessa — é o toque numa coluna (que precisa fechar para disparar) e
    /// a troca de mensagem na mesma posição da lista.
    public mutating func dismiss(force: Bool = false) -> SwipeOutcome {
        guard force || (!isDragging && !dismissGraceArmed) else { return .ignored }
        origin = nil
        isDragging = false
        restSide = nil
        restMagnitude = 0
        side = nil
        magnitude = 0
        latch.release()
        dismissGraceArmed = false
        return SwipeOutcome(releasesOpenRow: true, animates: true)
    }

    /// A janela de 0,24s terminou.
    public mutating func settle(_ seal: Int) {
        latch.settle(seal)
    }

    /// A carência do clique fantasma terminou. Só desarma se nenhum gesto novo
    /// a rearmou no meio-tempo — o mesmo idioma de selo do `SwipeLatch`.
    public mutating func settleGrace(_ seal: Int) {
        guard seal == dismissGraceSeal else { return }
        dismissGraceArmed = false
    }

    /// `openRowID` mudou. `nil` é o eco do nosso próprio fechamento e não
    /// destrava nada; o id de **outra** linha fecha esta na hora.
    public mutating func openRowChanged(to opened: String?, rowID: String) -> Bool {
        guard latch.openRowChanged(to: opened, rowID: rowID) else { return false }
        origin = nil
        isDragging = false
        restSide = nil
        restMagnitude = 0
        side = nil
        magnitude = 0
        dismissGraceArmed = false
        return true
    }

    // MARK: - Aritmética interna

    /// Começa um gesto se `startLocation` não for a do gesto em curso.
    ///
    /// O lado já vem decidido quando a linha está aberta: é **isto** que
    /// impede um gesto de acender os dois painéis.
    private mutating func beginIfNeeded(_ startLocation: CGPoint) {
        guard origin != startLocation || !isDragging else { return }
        origin = startLocation
        isDragging = true
        side = restSide
        magnitude = restMagnitude
    }

    /// Onde o gesto põe a linha, dado o que a mão andou.
    ///
    /// Numa linha **aberta** o lado é o dela e só a magnitude anda — presa em
    /// zero, de modo que puxar demais para o lado contrário para fechando, não
    /// abrindo o painel oposto.
    ///
    /// Numa linha **fechada** o lado ainda precisa ser conquistado: engate de
    /// 12pt e domínio da horizontal sobre a vertical, como sempre.
    private func project(
        translation: CGSize,
        _ context: SwipeContext
    ) -> (side: SwipeSide, magnitude: CGFloat)? {
        if let side {
            guard !context.actions(on: side).isEmpty else { return nil }
            let signed = side == .leading ? translation.width : -translation.width
            return (side, max(0, restMagnitude + signed))
        }
        guard let candidate = SwipeGesture.side(
            translation: translation, locked: nil, configuration: context.configuration
        ) else { return nil }
        let signed = candidate == .leading ? translation.width : -translation.width
        return (candidate, max(0, signed))
    }

    /// O limiar de soltura, com histerese.
    ///
    /// Fechada, meia coluna abre. Aberta, meia coluna de **volta** fecha — e
    /// não meia coluna de ida, que deixaria a linha aberta fechar ao primeiro
    /// tremor. É o que faz a linha aberta *ficar parada*: soltar de novo em
    /// cima dela é o resultado normal, não pontaria.
    private var openBar: CGFloat {
        guard restSide != nil else { return SwipeMetrics.openThreshold }
        return max(0, restMagnitude - SwipeMetrics.openThreshold)
    }

    private mutating func rest(open side: SwipeSide, _ context: SwipeContext) -> SwipeOutcome {
        restSide = side
        restMagnitude = context.panelWidth(on: side)
        self.side = side
        magnitude = restMagnitude
        // Arma a carência contra o clique fantasma do mouse-up — ver
        // `dismiss(force:)`. O selo vai na ordem de serviço para a `View`
        // agendar `settleGrace` depois da mesma janela de 0,24s.
        dismissGraceArmed = true
        dismissGraceSeal &+= 1
        return SwipeOutcome(claimsOpenRow: true, graceSeal: dismissGraceSeal, animates: true)
    }

    /// Fecha e **segura o bloqueio** até o `settle` do selo devolvido.
    private mutating func shut() -> SwipeOutcome {
        restSide = nil
        restMagnitude = 0
        side = nil
        magnitude = 0
        return SwipeOutcome(
            releasesOpenRow: true, settleSeal: latch.snapShut(), animates: true
        )
    }

    /// Volta para o repouso sem decidir nada — o gesto que nunca engatou, e o
    /// cancelado pela rolagem.
    private mutating func settleToRest() -> SwipeOutcome {
        guard let restSide else {
            guard latch.isBlocked else {
                side = nil
                magnitude = 0
                return .ignored
            }
            return shut()
        }
        side = restSide
        magnitude = restMagnitude
        return SwipeOutcome(animates: true)
    }
}
