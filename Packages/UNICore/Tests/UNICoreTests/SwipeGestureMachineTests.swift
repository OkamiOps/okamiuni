import Testing
import Foundation
import UNICore

/// O arraste dirigido por **sequência de eventos**, como um mouse de verdade o
/// produz: um `onChanged` por amostra, com a translação acumulada da origem
/// daquele gesto, e um `onEnded` no fim.
///
/// As três rodadas anteriores testaram `SwipeGesture.resolve` com **uma**
/// translação de cada vez, e por isso não podiam ver o defeito: ele só existe
/// entre um evento e o próximo, na conta que a view fazia — ou deixava de
/// fazer — entre a posição em que a linha estava e a translação que o gesto
/// reportava.
@Suite("Arraste — sequências de eventos")
struct SwipeGestureMachineTests {

    // MARK: - Cenário

    static func message(
        id: String = "m1",
        bucket: TriageBucket = .today,
        isRead: Bool = false
    ) -> Message {
        Message(
            id: id, accountID: "zoho",
            from: Contact(name: "Marina Duarte", address: "marina@clientepremium.com"),
            receivedAt: Date(timeIntervalSince1970: 0),
            subject: "Assunto", snippet: "Trecho", body: ["Corpo"],
            tags: [], bucket: bucket, isRead: isRead,
            summary: nil, detectedEvent: nil
        )
    }

    /// A lista de referência com o padrão de duas colunas de cada lado:
    /// painel de 168, abertura a 42, disparo a 277,5.
    static let context = SwipeContext(
        configuration: .default, rowWidth: 370, message: message()
    )

    /// O caderno de bordo de um gesto: tudo que a máquina mostrou em **cada**
    /// evento, mais o que ela mandou fazer.
    ///
    /// Existe porque as afirmações desta suíte quase nunca são sobre o estado
    /// final — são sobre o que aconteceu **no caminho**. "Nunca acendeu o outro
    /// lado" e "não executou duas ações" só se verificam sobre o rastro
    /// inteiro.
    struct Trace {
        var sides: [SwipeSide?] = []
        var offsets: [CGFloat] = []
        var flooded: [Bool] = []
        var fired: [SwipeAction] = []

        var distinctSides: Set<SwipeSide> { Set(sides.compactMap { $0 }) }
    }

    /// Dirige a máquina por uma sequência de amostras de um **único** gesto:
    /// mesma origem, translações acumuladas, e o `onEnded` na última.
    @discardableResult
    static func drive(
        _ machine: inout SwipeGestureMachine,
        from origin: CGPoint = CGPoint(x: 200, y: 60),
        samples: [CGSize],
        context: SwipeContext = Self.context,
        into trace: inout Trace,
        end: Bool = true
    ) -> SwipeOutcome {
        var last = SwipeOutcome.ignored
        for sample in samples {
            last = machine.dragChanged(
                translation: sample, startLocation: origin, context
            )
            record(machine, context, &trace, last)
        }
        if end, let final = samples.last {
            last = machine.dragEnded(
                translation: final, startLocation: origin, context
            )
            record(machine, context, &trace, last)
        }
        return last
    }

    static func record(
        _ machine: SwipeGestureMachine,
        _ context: SwipeContext,
        _ trace: inout Trace,
        _ outcome: SwipeOutcome
    ) {
        let resolution = machine.resolution(context)
        trace.sides.append(resolution.side)
        trace.offsets.append(resolution.offset)
        trace.flooded.append(resolution.willFire)
        if let action = outcome.fired { trace.fired.append(action) }
    }

    /// Uma passada de mão: da origem até `to`, em `steps` amostras, com o
    /// tremor vertical que um mouse real produz.
    static func sweep(
        to dx: CGFloat, steps: Int = 12, jitter: CGFloat = 0
    ) -> [CGSize] {
        (1...steps).map { i in
            let t = CGFloat(i) / CGFloat(steps)
            let dy = jitter == 0 ? 0 : (i % 2 == 0 ? jitter : -jitter)
            return CGSize(width: dx * t, height: dy)
        }
    }

    // MARK: - Abrir e ficar parado

    /// "ele tem que ficar parado". Soltar além de meia coluna deixa a linha
    /// **exatamente** no painel — 168 — e ela não se mexe mais sozinha.
    @Test("arrastar e soltar além de meia coluna deixa a linha parada no painel")
    func openRestsOnThePanel() {
        var machine = SwipeGestureMachine()
        var trace = Trace()
        Self.drive(&machine, samples: Self.sweep(to: 120), into: &trace)

        #expect(machine.restSide == .leading)
        #expect(machine.restMagnitude == 168)
        #expect(machine.resolution(Self.context).offset == 168)
        #expect(machine.isBlocked, "a linha aberta engole o clique — ele fecha, não seleciona")
        #expect(trace.fired.isEmpty)
    }

    /// O defeito literal do relato, medido: com a linha parada em 168, o
    /// primeiro evento do gesto seguinte não pode devolver a linha para perto
    /// de zero.
    ///
    /// A view antiga escrevia `translation = value.translation`, e a primeira
    /// amostra de um gesto novo vale 3pt. A linha ia de 168 para 3 num quadro.
    @Test("um segundo arraste não faz a linha aberta saltar para perto de zero")
    func openRowDoesNotJumpOnTheNextGesture() {
        var machine = SwipeGestureMachine()
        var open = Trace()
        Self.drive(&machine, samples: Self.sweep(to: 120), into: &open)
        #expect(machine.resolution(Self.context).offset == 168)

        var trace = Trace()
        Self.drive(
            &machine,
            from: CGPoint(x: 240, y: 61),
            samples: [CGSize(width: -3, height: 0), CGSize(width: -6, height: 1)],
            into: &trace, end: false
        )
        // 168 − 6 = 162, e não 6.
        #expect(trace.offsets == [165, 162])
    }

    /// Meia coluna de **volta** é o que fecha. Um tremor de 6pt não é meia
    /// coluna, e a linha continua onde estava.
    @Test("um tremor na linha aberta não a fecha")
    func jitterDoesNotCloseTheOpenRow() {
        var machine = SwipeGestureMachine()
        var trace = Trace()
        Self.drive(&machine, samples: Self.sweep(to: 120), into: &trace)

        Self.drive(
            &machine,
            from: CGPoint(x: 240, y: 61),
            samples: [CGSize(width: -3, height: 2), CGSize(width: -6, height: -3)],
            into: &trace
        )
        #expect(machine.restSide == .leading)
        #expect(machine.restMagnitude == 168)
    }

    // MARK: - Fechar nunca arma o lado oposto

    /// **A regra que o relato cobra.** Linha aberta à esquerda, arraste para a
    /// esquerda para fechar: em nenhum evento do caminho o lado `trailing`
    /// aparece, nenhuma ação é armada do outro lado, e nada dispara.
    @Test("fechar uma linha aberta nunca arma o lado oposto, nem dispara")
    func closingNeverArmsTheOppositeSide() {
        var machine = SwipeGestureMachine()
        var open = Trace()
        Self.drive(&machine, samples: Self.sweep(to: 120), into: &open)

        var trace = Trace()
        Self.drive(
            &machine,
            from: CGPoint(x: 240, y: 61),
            samples: Self.sweep(to: -400, steps: 20, jitter: 3),
            into: &trace
        )

        #expect(
            !trace.distinctSides.contains(.trailing),
            "o painel direito apareceu ao fechar uma linha aberta à esquerda: \(trace.sides)"
        )
        #expect(trace.fired.isEmpty, "fechar disparou \(trace.fired)")
        #expect(trace.flooded.allSatisfy { !$0 }, "fechar chegou a inundar o painel")
        #expect(machine.restSide == nil)
        #expect(machine.resolution(Self.context).offset == 0)
    }

    /// A mesma regra pelo outro lado, e no gesto de ida: atravessar o zero
    /// para trás numa linha fechada **para** em zero, não abre o painel
    /// contrário debaixo da mão.
    @Test("atravessar o zero no meio do gesto para em zero, não troca de painel")
    func crossingZeroClampsInsteadOfSwitching() {
        var machine = SwipeGestureMachine()
        var trace = Trace()
        Self.drive(
            &machine,
            samples: Self.sweep(to: 100) + Self.sweep(to: -260, steps: 20),
            into: &trace
        )
        #expect(!trace.distinctSides.contains(.trailing))
        #expect(trace.fired.isEmpty)
        #expect(machine.restSide == nil)
    }

    // MARK: - Um gesto, no máximo uma ação

    /// Contado sobre o rastro inteiro de uma passada rápida e longa, ida e
    /// volta, com tremor: uma ação, nunca duas.
    @Test("nenhuma sequência única executa duas ações")
    func oneGestureFiresAtMostOnce() {
        for samples in [
            Self.sweep(to: 400, steps: 30, jitter: 3),
            Self.sweep(to: -400, steps: 30, jitter: 3),
            [CGSize(width: 400, height: 0)],
            Self.sweep(to: 400, steps: 20) + Self.sweep(to: 60, steps: 10),
            Self.sweep(to: -400, steps: 20) + Self.sweep(to: 400, steps: 20),
        ] {
            var machine = SwipeGestureMachine()
            var trace = Trace()
            Self.drive(&machine, samples: samples, into: &trace)
            #expect(trace.fired.count <= 1, "uma sequência disparou \(trace.fired)")
        }
    }

    /// A passada rápida — um mouse veloz entrega poucas amostras enormes — não
    /// pode se comportar diferente da lenta.
    @Test("a passada rápida dispara a mesma ação que a lenta")
    func fastSweepMatchesSlow() {
        var fast = SwipeGestureMachine()
        var fastTrace = Trace()
        Self.drive(&fast, samples: [CGSize(width: 300, height: 0)], into: &fastTrace)

        var slow = SwipeGestureMachine()
        var slowTrace = Trace()
        Self.drive(&slow, samples: Self.sweep(to: 300, steps: 40), into: &slowTrace)

        #expect(fastTrace.fired == [.archive])
        #expect(slowTrace.fired == [.archive])
    }

    // MARK: - O disparo mede a posição real da linha

    /// O brief: "medido A PARTIR DA POSIÇÃO REAL da linha, não da origem do
    /// gesto". Com a linha parada em 168, faltam 109,5pt para os 277,5 — e não
    /// 277,5 outra vez.
    @Test("na linha aberta, o disparo conta a partir de onde ela está")
    func commitCountsFromTheRestingPosition() {
        func fires(afterExtra dx: CGFloat) -> [SwipeAction] {
            var machine = SwipeGestureMachine()
            var trace = Trace()
            Self.drive(&machine, samples: Self.sweep(to: 120), into: &trace)
            var second = Trace()
            Self.drive(
                &machine,
                from: CGPoint(x: 240, y: 61),
                samples: Self.sweep(to: dx, steps: 10),
                into: &second
            )
            return second.fired
        }

        // 168 + 109 = 277 — um ponto aquém.
        #expect(fires(afterExtra: 109).isEmpty)
        // 168 + 109,5 = 277,5 — exatamente o limiar.
        #expect(fires(afterExtra: 109.5) == [.archive])
    }

    /// E o contrário: da linha fechada, o mesmo 109,5 não chega nem perto.
    @Test("da linha fechada, o mesmo arraste curto não dispara nada")
    func closedRowNeedsTheWholeThreshold() {
        var machine = SwipeGestureMachine()
        var trace = Trace()
        Self.drive(&machine, samples: Self.sweep(to: 109.5, steps: 10), into: &trace)
        #expect(trace.fired.isEmpty)
        #expect(machine.restSide == .leading, "109,5 passa de meia coluna: abre")
    }

    // MARK: - Rolagem e re-engate

    /// Um gesto que começa vertical é da rolagem, e continua sendo dela mesmo
    /// que a mão escorregue para o lado depois de já ter descido bastante.
    @Test("o gesto que começa vertical não vira arraste lateral")
    func verticalGestureStaysScroll() {
        var machine = SwipeGestureMachine()
        var trace = Trace()
        Self.drive(
            &machine,
            samples: [
                CGSize(width: 2, height: 30),
                CGSize(width: 8, height: 60),
                CGSize(width: 14, height: 90),
            ],
            into: &trace
        )
        #expect(trace.sides.allSatisfy { $0 == nil })
        #expect(machine.restSide == nil)
    }

    /// Oscilação vertical de ±3pt no meio de um arraste lateral: o lado não se
    /// perde e o painel não pisca.
    @Test("a oscilação vertical no meio do arraste não desengata o lado")
    func verticalJitterKeepsTheSide() {
        var machine = SwipeGestureMachine()
        var trace = Trace()
        Self.drive(&machine, samples: Self.sweep(to: 150, steps: 24, jitter: 3), into: &trace)
        let seen = trace.sides.compactMap { $0 }
        #expect(seen.allSatisfy { $0 == .leading })
        #expect(seen.count >= 20, "o lado se perdeu no meio: \(trace.sides)")
    }

    /// **O re-engate.** A `ScrollView` pode levar o gesto sem que `onEnded`
    /// chegue. O gesto seguinte tem outra origem, e é por ela que a máquina
    /// sabe que é outro gesto — sem isso a translação nova seria lida como
    /// continuação e a linha daria um salto.
    @Test("um gesto novo com outra origem não é lido como continuação do anterior")
    func newOriginStartsANewGesture() {
        var machine = SwipeGestureMachine()
        var trace = Trace()
        // Abre e some, sem `onEnded` — a rolagem levou.
        Self.drive(&machine, samples: Self.sweep(to: 150), into: &trace, end: false)
        #expect(machine.resolution(Self.context).offset == 150)

        // Gesto novo, origem nova, mão andando 10pt: a linha continua onde
        // estava parada — em zero, porque o gesto anterior nunca foi solto.
        var second = Trace()
        Self.drive(
            &machine,
            from: CGPoint(x: 500, y: 200),
            samples: [CGSize(width: 20, height: 0)],
            into: &second, end: false
        )
        #expect(second.offsets == [20], "a origem nova não reiniciou o gesto: \(second.offsets)")
    }

    /// O cancelamento explícito devolve a linha ao repouso e não dispara nada.
    @Test("o gesto cancelado pela rolagem não executa ação nenhuma")
    func cancelFiresNothing() {
        var machine = SwipeGestureMachine()
        var trace = Trace()
        Self.drive(&machine, samples: Self.sweep(to: 300), into: &trace, end: false)
        #expect(machine.resolution(Self.context).willFire)
        let outcome = machine.dragCancelled()
        #expect(outcome.fired == nil)
        #expect(machine.resolution(Self.context).offset == 0)
    }

    // MARK: - Lado mudo

    /// Um lado sem ação nenhuma configurada não engata — e um lado cujas ações
    /// todas seriam mudas nesta mensagem abre, mas não dispara.
    @Test("o lado sem ações não engata; o lado todo mudo abre mas não dispara")
    func silentSides() {
        let empty = SwipeContext(
            configuration: SwipeConfiguration(leading: [], trailing: [.later]),
            rowWidth: 370, message: Self.message()
        )
        var machine = SwipeGestureMachine()
        var trace = Trace()
        Self.drive(&machine, samples: Self.sweep(to: 300), context: empty, into: &trace)
        #expect(trace.sides.allSatisfy { $0 == nil })

        // "Hoje" numa mensagem que já está em Hoje não faz nada.
        let mute = SwipeContext(
            configuration: SwipeConfiguration(leading: [.today], trailing: [.later]),
            rowWidth: 370, message: Self.message(bucket: .today)
        )
        var second = SwipeGestureMachine()
        var muteTrace = Trace()
        Self.drive(&second, samples: Self.sweep(to: 340), context: mute, into: &muteTrace)
        #expect(muteTrace.fired.isEmpty, "um lado mudo disparou \(muteTrace.fired)")
        #expect(second.restSide == .leading)
    }

    // MARK: - A trava do clique de soltura

    /// Disparar por arraste longo fecha e **segura** o bloqueio até o `settle`
    /// do selo devolvido — é a janela de 0,24s, agora dirigida por evento.
    @Test("o disparo fecha, devolve selo e só destrava no settle daquele selo")
    func firingHoldsTheLatchUntilSettle() throws {
        var machine = SwipeGestureMachine()
        var trace = Trace()
        let outcome = Self.drive(&machine, samples: Self.sweep(to: 300), into: &trace)

        #expect(outcome.fired == .archive)
        #expect(outcome.releasesOpenRow)
        let seal = try #require(outcome.settleSeal)
        #expect(machine.isBlocked, "destravou antes da janela: o clique de soltura selecionaria")

        machine.settle(seal - 1)
        #expect(machine.isBlocked, "um selo velho destravou a linha")
        machine.settle(seal)
        #expect(!machine.isBlocked)
    }

    /// O clique deliberado numa linha aberta fecha e destrava na hora.
    @Test("o clique numa linha aberta fecha e destrava")
    func dismissClosesAndReleases() {
        var machine = SwipeGestureMachine()
        var trace = Trace()
        Self.drive(&machine, samples: Self.sweep(to: 120), into: &trace)
        #expect(machine.isBlocked)

        let outcome = machine.dismiss()
        #expect(outcome.releasesOpenRow)
        #expect(!machine.isBlocked)
        #expect(machine.resolution(Self.context).offset == 0)
    }

    /// Outra linha abrindo fecha esta na hora, sem disparar nada.
    @Test("outra linha abrindo fecha esta")
    func anotherRowClosesThisOne() {
        var machine = SwipeGestureMachine()
        var trace = Trace()
        Self.drive(&machine, samples: Self.sweep(to: 120), into: &trace)

        let closed = machine.openRowChanged(to: "outra", rowID: "m1")
        #expect(closed)
        #expect(machine.restSide == nil)
        #expect(machine.resolution(Self.context).offset == 0)
        // O eco do próprio fechamento não destrava ninguém.
        let echo = machine.openRowChanged(to: nil, rowID: "m1")
        #expect(!echo)
    }
}

// MARK: - O defeito, reproduzido

/// A view **anterior** a esta tarefa, reduzida ao que ela fazia com os eventos
/// — para que a sequência que o dono do projeto descreveu possa ser
/// reproduzida em vez de suposta.
///
/// Só duas linhas importam, e são as duas que a máquina nova mudou:
///
/// - `translation = value.translation` — a translação crua, medida da origem
///   **do gesto**, escrita por cima de onde a linha estava parada;
/// - `locked: latch.side` — a trava, que sobrevivia ao gesto e podia cair no
///   meio do seguinte, pelo `settle` de 0,24s.
struct LegacySwipeRow {
    var latch = SwipeLatch()
    var translation: CGSize = .zero

    mutating func changed(_ t: CGSize, _ configuration: SwipeConfiguration = .default) {
        guard let side = SwipeGesture.side(
            translation: t, locked: latch.side, configuration: configuration
        ) else { return }
        if latch.side == nil { latch.engage(side) }
        translation = t
    }

    mutating func ended(
        _ t: CGSize, _ message: Message, _ configuration: SwipeConfiguration = .default,
        rowWidth: CGFloat = 370
    ) -> SwipeRelease {
        guard latch.side != nil else {
            translation = .zero
            return .closed
        }
        let release = SwipeGesture.release(
            translation: t, locked: latch.side, configuration: configuration,
            message: message, rowWidth: rowWidth
        )
        switch release {
        case .closed, .fire:
            translation = .zero
            _ = latch.snapShut()
        case .open(let side):
            let width = SwipeMetrics.panelWidth(
                actions: configuration.actions(on: side).count
            )
            translation = CGSize(width: side == .leading ? width : -width, height: 0)
        }
        return release
    }

    /// A janela de 0,24s expirando. Na view era um `Task` com `sleep`; aqui é
    /// um evento, que é o que permite pô-la no meio de uma sequência.
    mutating func settleWindowElapsed() {
        latch.settle(latch.seal)
    }

    func resolution(_ message: Message, _ configuration: SwipeConfiguration = .default)
        -> SwipeResolution {
        SwipeGesture.resolve(
            translation: translation, locked: latch.side,
            configuration: configuration, message: message, rowWidth: 370
        )
    }
}

@Suite("Arraste — o defeito de d0b09fa, reproduzido")
struct LegacySwipeDefectTests {

    private let message = SwipeGestureMachineTests.message()
    private let context = SwipeGestureMachineTests.context

    /// **O salto.** A linha descansa aberta em 168 e o primeiro evento do
    /// gesto seguinte a joga para 3.
    ///
    /// "ele tem que ficar parado": ele não ficava. Bastava encostar.
    @Test("a linha aberta saltava de 168 para 3 no primeiro evento do gesto seguinte")
    func openRowJumpedShut() {
        var legacy = LegacySwipeRow()
        legacy.changed(CGSize(width: 120, height: 0))
        #expect(legacy.ended(CGSize(width: 120, height: 0), message) == .open(.leading))
        #expect(legacy.resolution(message).offset == 168)

        // Gesto novo: 3pt de mão. A translação é da origem do gesto, e a view
        // a escrevia crua.
        legacy.changed(CGSize(width: 3, height: 0))
        #expect(legacy.resolution(message).offset == 3, "o salto não estava aqui")

        // A máquina nova não salta: 168 + 3.
        var fixed = SwipeGestureMachine()
        var trace = SwipeGestureMachineTests.Trace()
        SwipeGestureMachineTests.drive(
            &fixed, samples: SwipeGestureMachineTests.sweep(to: 120), into: &trace
        )
        _ = fixed.dragChanged(
            translation: CGSize(width: 3, height: 0),
            startLocation: CGPoint(x: 240, y: 61), context
        )
        // 168 + 3, com a resistência de um oitavo além do painel: 168,375.
        // O que importa é o sinal da conta — a linha **avança** 3pt de onde
        // estava, em vez de recuar 165.
        #expect(fixed.resolution(context).offset == 168.375)
    }

    /// **"eu arrasto ele ativa os dois".** A sequência inteira, uma passada de
    /// mão contínua para a esquerda sobre uma linha aberta à direita:
    ///
    /// 1. a linha descansa aberta à esquerda, em 168;
    /// 2. a mão vai para a esquerda para fechá-la — a trava ainda diz
    ///    `leading`, a translação crua dá magnitude zero, e a linha bate no
    ///    fundo sem fechar de verdade;
    /// 3. o botão sobe: `.closed`, `snapShut`, a janela de 0,24s começa;
    /// 4. a mão continua para a esquerda e desce de novo — **a janela expira no
    ///    meio**, a trava cai, e agora `side` é decidido do zero: `dx < 0` dá
    ///    `trailing`. O painel **direito** acende;
    /// 5. a mão já andou 300pt para a esquerda: passa dos 277,5 e "Depois"
    ///    dispara.
    ///
    /// Dois painéis e uma ação que ninguém pediu, numa mão que só queria
    /// fechar a linha.
    @Test("fechar uma linha aberta acendia o painel oposto e adiava a mensagem")
    func closingArmedTheOppositeSideAndFired() {
        var legacy = LegacySwipeRow()
        legacy.changed(CGSize(width: 120, height: 0))
        #expect(legacy.ended(CGSize(width: 120, height: 0), message) == .open(.leading))

        var seen: [SwipeSide?] = []
        for dx in stride(from: CGFloat(-10), through: -150, by: -20) {
            legacy.changed(CGSize(width: dx, height: 0))
            seen.append(legacy.resolution(message).side)
        }
        #expect(legacy.ended(CGSize(width: -150, height: 0), message) == .closed)
        legacy.settleWindowElapsed()

        var fired: SwipeRelease?
        for dx in stride(from: CGFloat(-170), through: -300, by: -20) {
            legacy.changed(CGSize(width: dx, height: 0))
            seen.append(legacy.resolution(message).side)
        }
        fired = legacy.ended(CGSize(width: -300, height: 0), message)

        #expect(seen.contains(.leading), "o painel esquerdo não apareceu na ida")
        #expect(seen.contains(.trailing), "o painel direito não apareceu — o defeito não reproduziu")
        #expect(fired == .fire(.later, .trailing), "a mão que só fechava adiou a mensagem")
    }

    /// A mesma sequência na máquina nova: um painel só, nenhuma ação.
    @Test("a máquina nova fecha a mesma sequência sem acender o outro lado")
    func machineClosesWithoutTheOppositeSide() {
        var machine = SwipeGestureMachine()
        var trace = SwipeGestureMachineTests.Trace()
        SwipeGestureMachineTests.drive(
            &machine, samples: SwipeGestureMachineTests.sweep(to: 120), into: &trace
        )

        var closing = SwipeGestureMachineTests.Trace()
        SwipeGestureMachineTests.drive(
            &machine, from: CGPoint(x: 240, y: 61),
            samples: SwipeGestureMachineTests.sweep(to: -150, steps: 8),
            into: &closing
        )
        var again = SwipeGestureMachineTests.Trace()
        SwipeGestureMachineTests.drive(
            &machine, from: CGPoint(x: 90, y: 61),
            samples: SwipeGestureMachineTests.sweep(to: -150, steps: 8),
            into: &again
        )

        #expect(!closing.distinctSides.contains(.trailing))
        #expect(closing.fired.isEmpty)
        // O segundo gesto começa com a linha **fechada**, então o painel
        // direito pode aparecer — é um gesto novo, e é o que a pessoa está
        // pedindo. O que ele não pode é disparar sem chegar aos 277,5.
        #expect(again.fired.isEmpty, "150pt do zero dispararam \(again.fired)")
    }
}
