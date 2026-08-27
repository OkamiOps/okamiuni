import SwiftUI
import UNIDesign
import UNICore

/// O gesto que Mail.app, Gmail e Outlook têm: **arrastar a linha para o lado
/// revela ações**.
///
/// Aqui não se decide nada sobre o gesto. Quando ele começa, quanto revelar,
/// qual ação está armada e o que soltar significa são perguntas de
/// `UNICore.SwipeGesture`, que tem teste de fronteira. Este arquivo é só o
/// desenho e a ligação com os gestos que já existiam na linha.
///
/// ## Como ele convive com o que já funcionava
///
/// - **Clique** continua sendo do `Button` da lista, e ele só some enquanto o
///   arraste está em curso ou a linha está aberta — nesses dois estados o
///   clique **fecha** a linha em vez de selecionar. É o que `SwipeRowContext`
///   carrega para dentro do rótulo.
/// - **Duplo clique** continua abrindo a janela, pelo mesmo
///   `simultaneousGesture` de antes. Um duplo clique não anda 12pt, então ele
///   nunca engata o arraste.
/// - **Botão direito** é do `contextMenu`, que o `DragGesture` não vê: o
///   arraste só acompanha o botão esquerdo.
/// - **Rolagem** ganha por construção. O `DragGesture` entra como
///   `simultaneousGesture`, então a `ScrollView` continua recebendo o mesmo
///   evento, e o gesto lateral só engata quando a horizontal **domina** a
///   vertical (`SwipeMetrics.dominance`). Um gesto que começa vertical nunca é
///   nosso; um que começa horizontal fica nosso até soltar (`locked`).

/// O que o rótulo da linha precisa saber sobre o arraste.
///
/// Existe porque o clique é do `Button` que a lista monta, e ele precisa se
/// calar enquanto a linha está aberta. Passar um `Bool` só resolveria metade:
/// o clique numa linha aberta não deve ser engolido em silêncio, ele deve
/// **fechar** a linha, que é o que qualquer pessoa espera.
///
/// Mora **fora** de `SwipeRow`. Aninhado num tipo genérico, o parâmetro do
/// fechamento (`SwipeRow<Content>.Context`) depende do próprio `Content` que a
/// chamada está tentando inferir, e o compilador desiste com "generic parameter
/// 'Content' could not be inferred".
struct SwipeRowContext {
    /// O arraste está em curso ou a linha está aberta.
    let isBlocked: Bool
    /// Fecha a linha. Chame no lugar da ação normal quando `isBlocked`.
    let dismiss: () -> Void
}

/// A duração das animações do arraste — a mesma do resto do app
/// (`InboxScreen.paneTransition`). Fora do genérico para quem só quer a
/// animação não precisar nomear um `Content`.
enum SwipeMotion {
    static let transition: Animation = .easeInOut(duration: 0.18)
}

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
struct SwipeLatch: Equatable {
    /// O lado em que o gesto nasceu, ou `nil` se a linha está livre.
    private(set) var side: SwipeSide?
    /// Muda a cada transição. O settle adiado só age se o selo ainda for o dele.
    private(set) var seal: Int = 0

    /// O arraste está em curso ou a linha está aberta — o clique fecha em vez
    /// de selecionar.
    var isBlocked: Bool { side != nil }

    /// O gesto engatou de um lado.
    mutating func engage(_ side: SwipeSide) {
        self.side = side
        seal &+= 1
    }

    /// Fechou por conta própria. **Continua travada** até o `settle` do selo
    /// devolvido — é essa a janela de 0,24s.
    mutating func snapShut() -> Int {
        seal &+= 1
        return seal
    }

    /// A janela terminou. Só destrava se nada tiver acontecido no meio-tempo.
    mutating func settle(_ seal: Int) {
        guard seal == self.seal else { return }
        side = nil
    }

    /// Destrava na hora — o clique deliberado numa linha aberta, ou outra linha
    /// tomando a vez.
    mutating func release() {
        seal &+= 1
        side = nil
    }

    /// `openRowID` mudou. Devolve se a linha destravou, para quem chama
    /// cancelar o adiamento e animar o fechamento.
    ///
    /// `nil` é o eco do nosso próprio `snapShut()` e não pode destravar nada:
    /// era exatamente por aí que a janela de 0,24s se cancelava sozinha.
    mutating func openRowChanged(to opened: String?, rowID: String) -> Bool {
        guard let opened, opened != rowID, isBlocked else { return false }
        release()
        return true
    }
}

struct SwipeRow<Content: View>: View {

    @Environment(\.theme) private var theme

    let message: Message
    let configuration: SwipeConfiguration
    /// Só uma linha aberta por vez: abrir uma fecha a outra.
    @Binding var openRowID: String?
    let onFire: (SwipeAction) -> Void

    /// Força o deslocamento, **só para verificação fora da tela**.
    ///
    /// O painel revelado depende de um `@State` que só um arraste de verdade
    /// escreve, e este projeto não sintetiza evento nenhum — dirigir a interface
    /// com `CGEvent` toma o computador do dono (ver
    /// `docs/decisoes-de-engenharia.md`). É o mesmo recurso de `debugFocused`
    /// em `ChromeButton` e de `debugOpenPanel`: um parâmetro interno que põe a
    /// `View` no estado a medir. Zero — o padrão — deixa o gesto no comando.
    var debugTranslation: CGSize = .zero

    @ViewBuilder let content: (SwipeRowContext) -> Content

    /// O lado em que o gesto **nasceu** e a trava que sobrevive ao fechamento.
    /// Uma vez lateral, sempre lateral até soltar — ver
    /// `SwipeGesture.side(translation:locked:configuration:)` e `SwipeLatch`.
    @State private var latch = SwipeLatch()
    @State private var translation: CGSize = .zero
    /// Segura a trava até a animação de fechamento terminar. Sem isso o
    /// clique que solta o arraste chegaria ao `Button` com a linha já
    /// desbloqueada e selecionaria a mensagem que a pessoa acabou de arrastar.
    @State private var settleTask: Task<Void, Never>?

    /// O lado engatado, para quem só quer perguntar isso.
    private var locked: SwipeSide? { latch.side }

    /// O deslocamento que vale para o desenho. Ver `debugTranslation`.
    private var effectiveTranslation: CGSize {
        debugTranslation == .zero ? translation : debugTranslation
    }

    private var resolution: SwipeResolution {
        SwipeGesture.resolve(
            translation: effectiveTranslation, locked: locked,
            configuration: configuration, message: message
        )
    }

    private var isBlocked: Bool { latch.isBlocked }

    var body: some View {
        content(SwipeRowContext(isBlocked: isBlocked, dismiss: close))
            // O painel fica atrás; sem fundo opaco ele apareceria através da
            // linha, que só pinta fundo quando está selecionada.
            .background(theme.surface.color)
            .offset(x: resolution.offset)
            // **`background`, não `ZStack`.** Num `ZStack` o painel é irmão do
            // conteúdo, e `maxHeight: .infinity` faz dele um irmão guloso: ele
            // toma toda a altura oferecida e a linha cresce no instante em que
            // o arraste começa. Medido, com o palco a 140pt: a linha de 106
            // passava a ocupar os 140, com o conteúdo centrado e 17pt de
            // painel sobrando em cima e embaixo. É a mesma família da
            // `Rectangle` irmã de `docs/decisoes-de-engenharia.md` — e é
            // exatamente "a lista não pode pular".
            //
            // Como fundo, o painel é medido **pelo conteúdo**: ele preenche a
            // linha e não opina sobre o tamanho dela. O `offset` não mexe no
            // quadro de layout, então o fundo fica parado enquanto a linha
            // desliza por cima — que é o efeito desejado.
            .background {
                if let side = resolution.side {
                    panel(side)
                }
            }
            .clipped()
        // O arraste roda **junto** com a rolagem, não no lugar dela.
        .simultaneousGesture(drag)
        // Quem decide se este `onChange` destrava é `SwipeLatch`: `nil` aqui é o
        // eco do nosso próprio fechamento, não outra linha tomando a vez.
        .onChange(of: openRowID) { _, opened in
            guard latch.openRowChanged(to: opened, rowID: message.id) else { return }
            settleTask?.cancel()
            withAnimation(SwipeMotion.transition) { translation = .zero }
        }
        // A linha aberta não pode sobreviver a uma troca de mensagem na mesma
        // posição da lista — arquivar a de cima faz a de baixo herdar a linha.
        .onChange(of: message.id) { _, _ in close() }
    }

    // MARK: - O painel

    /// As colunas reveladas.
    ///
    /// No lado `trailing` a ordem se inverte no desenho: a **primeira** ação da
    /// configuração é a que o dedo revela primeiro, e num arraste para a
    /// esquerda a primeira a aparecer é a mais à direita. É a mesma ordem que a
    /// primeira ser a que o arraste longo dispara.
    private func panel(_ side: SwipeSide) -> some View {
        let actions = side == .leading
            ? configuration.leading
            : configuration.trailing.reversed().map { $0 }

        return HStack(spacing: 0) {
            ForEach(actions) { action in
                SwipeActionColumn(
                    action: action,
                    message: message,
                    isArmed: action == resolution.armed,
                    willFire: resolution.willFire && action == resolution.armed,
                    onTap: { fire($0) }
                )
            }
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: side == .leading ? .leading : .trailing
        )
        .background(theme.surface3.color)
    }

    // MARK: - O gesto

    /// `minimumDistance: 1` é de propósito baixo: quem decide se o gesto é
    /// nosso é `SwipeGesture.side`, com o engate e a razão de domínio que os
    /// testes travam. Deixar o `DragGesture` decidir por distância total
    /// engataria numa rolagem vertical de 12pt.
    private var drag: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard let side = SwipeGesture.side(
                    translation: value.translation,
                    locked: locked,
                    configuration: configuration
                ) else { return }

                if latch.side == nil {
                    settleTask?.cancel()
                    latch.engage(side)
                    openRowID = message.id
                }
                translation = value.translation
            }
            .onEnded { value in
                guard locked != nil else {
                    translation = .zero
                    return
                }
                switch SwipeGesture.release(
                    translation: value.translation, locked: locked,
                    configuration: configuration, message: message
                ) {
                case .closed:
                    snapShut()

                case .open(let side):
                    let width = SwipeMetrics.panelWidth(
                        actions: configuration.actions(on: side).count
                    )
                    withAnimation(SwipeMotion.transition) {
                        translation = CGSize(
                            width: side == .leading ? width : -width, height: 0
                        )
                    }

                case .fire(let action, _):
                    snapShut()
                    onFire(action)
                }
            }
    }

    /// Tocar numa coluna revelada. O mesmo caminho do arraste longo, com o
    /// mesmo retorno visível.
    private func fire(_ action: SwipeAction) {
        snapShut()
        onFire(action)
    }

    /// Fecha e **segura o bloqueio** até a animação terminar, para o clique que
    /// solta o arraste não virar seleção.
    private func snapShut() {
        withAnimation(SwipeMotion.transition) { translation = .zero }
        settleTask?.cancel()
        let seal = latch.snapShut()
        // Zerar o `openRowID` reentra no `onChange` desta mesma linha. É por
        // isso que o selo sai **antes**: quando o eco chega, a trava já sabe
        // que o fechamento é dela e o ignora.
        if openRowID == message.id { openRowID = nil }
        settleTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.24))
            guard !Task.isCancelled else { return }
            latch.settle(seal)
        }
    }

    /// Fecha na hora — é o clique deliberado numa linha aberta, e ali não há
    /// arraste em curso para proteger.
    private func close() {
        settleTask?.cancel()
        withAnimation(SwipeMotion.transition) { translation = .zero }
        latch.release()
        if openRowID == message.id { openRowID = nil }
    }
}

// MARK: - Uma coluna

/// Um botão do painel. Ícone em cima, rótulo embaixo, largura fixa —
/// `SwipeMetrics.actionWidth`, o mesmo número de que sai o limiar de disparo.
///
/// Cor e ícone saem dos tokens: `SwipeAction.tint` diz o **papel** (`strong` /
/// `quiet`) e esta `View` traduz para `Theme`. Nenhuma cor literal atravessa a
/// fronteira do `UNICore`, que nem SwiftUI importa.
struct SwipeActionColumn: View {
    /// O corpo do rótulo e o do ícone.
    ///
    /// Estão expostos porque o rótulo **tem de caber inteiro** na coluna, e a
    /// folga medida em pixel não basta para garantir isso: ela só enxerga os
    /// rótulos que aquela linha desenha. Medido a 10,5: "Arquivar" pede 45pt,
    /// "Não lida" 43, "Depois" 37 — numa coluna de 84. Provado quebrando, com o
    /// corpo em 22: "Arquivar" passa a pedir 85 e "Não lida" 81, e o teste de
    /// folga do painel **direito** continuou passando, porque nem "Depois" (70)
    /// nem "Hoje" (46) estouram a coluna.
    static let labelSize: CGFloat = 10.5
    static let symbolSize: CGFloat = 14

    @Environment(\.theme) private var theme

    let action: SwipeAction
    let message: Message
    /// É esta que o arraste longo dispara.
    let isArmed: Bool
    /// O arraste já passou do limiar: soltar agora dispara.
    let willFire: Bool
    let onTap: (SwipeAction) -> Void

    private var isNoOp: Bool { action.isNoOp(for: message) }

    var body: some View {
        Button { onTap(action) } label: {
            VStack(spacing: 5) {
                Image(systemName: action.symbol(for: message))
                    .font(.system(size: Self.symbolSize, weight: .medium))
                Text(action.title(for: message))
                    .font(theme.sans.font(size: Self.labelSize, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(foreground)
            .frame(width: SwipeMetrics.actionWidth)
            .frame(maxHeight: .infinity)
            .background(background)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // `MailStore.move` já recusa mover para a caixa em que a mensagem está.
        // Desabilitar aqui é a segunda tranca, e o `help` diz o porquê em vez
        // de deixar a pessoa clicando num botão calado.
        .disabled(isNoOp)
        .help(action.help(for: message))
        .hairline(theme.line2, edges: .trailing)
    }

    private var foreground: Color {
        if isNoOp { return theme.ink4.color }
        if willFire { return theme.onAccent.color }
        return action.tint == .strong ? theme.accentInk.color : theme.ink2.color
    }

    private var background: Color {
        if isNoOp { return theme.surface2.color }
        if willFire { return theme.accent.color }
        return action.tint == .strong ? theme.accentSoft.color : theme.surface3.color
    }
}

// MARK: - O retorno com desfazer

/// O que aparece depois que uma ação dispara.
///
/// Copia o idioma da faixa de resposta rápida — lá é
/// "✓ Pronta para envio — 7 palavras · 14:32" com um botão "Retomar"; aqui é
/// "✓ Arquivada — Marina Duarte · 14:32" com um botão "Desfazer". Mesmo ✓ em
/// `accentInk`, mesmo fundo `accentSoft` com borda `accentLine`, mesmo raio.
///
/// Arquivar por engano com um gesto rápido é fácil demais para não ter volta.
struct SwipeUndoBand: View {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    let receipt: SwipeReceipt
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("✓")
                .font(theme.sans.font(size: 12, weight: .semibold))
                .foregroundStyle(theme.accentInk.color)

            Text(receipt.note)
                .font(theme.sans.font(size: 12))
                .foregroundStyle(theme.ink2.color)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 6)

            ChromeButton(
                "Desfazer", appearance: .outlined,
                size: 12, height: 26, horizontalPadding: 10,
                action: onUndo
            )
            // Não leva `fixedSize`. Tentei pôr, e o teste passou sem ele: o
            // `ChromeButton` já tem `lineLimit(1)` e recuo fixo, e quem cede
            // sob aperto é a frase, que quebra em duas linhas. Medido, o botão
            // sai com 67pt de largura a 200, 240, 300 e 420 — e a lista mais
            // estreita que `PaneLayout` concede é 320. Guarda que não muda
            // medida nenhuma é decoração.
            .help("Desfazer: \(receipt.note)")
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(
            theme.accentSoft.color,
            in: RoundedRectangle(cornerRadius: theme.radiusLarge)
        )
        .overlay {
            RoundedRectangle(cornerRadius: theme.radiusLarge)
                .strokeBorder(
                    theme.accentLine.color,
                    lineWidth: Hairline.thickness(displayScale)
                )
        }
        .shadow(theme.shadow)
    }
}
