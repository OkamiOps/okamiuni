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
/// - **Botão direito** abre o painel de menu do app (`RightClickCatcher`), que
///   o `DragGesture` não vê: o arraste só acompanha o botão esquerdo, e a
///   `NSView` que pega o clique direito devolve `nil` no teste de acerto para
///   qualquer outro evento — clique, duplo clique e arraste passam por ela sem
///   saber que ela existe.
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


/// A linha arrastável — e **só** a linha arrastável.
///
/// Desde esta tarefa ela não decide mais nada sobre o gesto. Onde a linha
/// está, de que lado, o que está armado, o que soltar significa e quando a
/// trava cai são perguntas de `UNICore.SwipeGestureMachine`, que se dirige por
/// sequência de eventos num teste. Aqui só se traduz `DragGesture` em chamadas
/// e `SwipeOutcome` em animação.
///
/// O defeito que motivou a mudança está documentado na máquina: a view
/// escrevia `translation = value.translation` cru, e `translation` é medida da
/// origem **do gesto**, não da posição da linha. Numa linha aberta as duas
/// deixam de coincidir e todo evento passa a mentir.
struct SwipeRow<Content: View>: View {

    @Environment(\.theme) private var theme

    let message: Message
    let configuration: SwipeConfiguration
    /// A largura da linha, que é a da lista — e ela varia de 320 a 420.
    ///
    /// Entra porque o limiar do arraste longo depende dela: disparar a três
    /// quartos da linha é uma promessa que só se pode cumprir sabendo o
    /// tamanho da linha (ver `SwipeMetrics.commitThreshold`). O padrão é a
    /// largura de referência, para previews e harness desenharem.
    var rowWidth: CGFloat = SwipeMetrics.referenceRowWidth
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
    ///
    /// Ele entra pela **mesma porta** que o mouse: uma máquina zerada recebe um
    /// `onChanged` com esta translação. Não há mais um caminho de desenho que o
    /// gesto de verdade não percorra.
    var debugTranslation: CGSize = .zero

    @ViewBuilder let content: (SwipeRowContext) -> Content

    /// Toda a máquina de estados do gesto, num só lugar e testável fora daqui.
    @State private var machine = SwipeGestureMachine()
    /// Segura a trava até a animação de fechamento terminar. Sem isso o
    /// clique que solta o arraste chegaria ao `Button` com a linha já
    /// desbloqueada e selecionaria a mensagem que a pessoa acabou de arrastar.
    @State private var settleTask: Task<Void, Never>?

    private var context: SwipeContext {
        SwipeContext(configuration: configuration, rowWidth: rowWidth, message: message)
    }

    /// O que desenhar agora. Com `debugTranslation` a resolução sai de uma
    /// máquina descartável dirigida por aquele único evento.
    private var resolution: SwipeResolution {
        guard debugTranslation != .zero else { return machine.resolution(context) }
        var probe = SwipeGestureMachine()
        _ = probe.dragChanged(
            translation: debugTranslation, startLocation: .zero, context
        )
        return probe.resolution(context)
    }

    private var isBlocked: Bool { machine.isBlocked }

    var body: some View {
        content(SwipeRowContext(isBlocked: isBlocked, dismiss: dismiss))
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
        // Quem decide se este `onChange` destrava é a máquina, por
        // `SwipeLatch`: `nil` aqui é o eco do nosso próprio fechamento, não
        // outra linha tomando a vez.
        .onChange(of: openRowID) { _, opened in
            guard machine.openRowChanged(to: opened, rowID: message.id) else { return }
            settleTask?.cancel()
        }
        // A linha aberta não pode sobreviver a uma troca de mensagem na mesma
        // posição da lista — arquivar a de cima faz a de baixo herdar a linha.
        .onChange(of: message.id) { _, _ in dismiss() }
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

        // **O estado de armado.** Enquanto o arraste está aquém do limiar, o
        // painel é o de sempre. Cruzado o limiar, ele **inunda**: as colunas
        // inteiras passam a `accent` com tinta `onAccent`, e a armada empurra
        // ícone e rótulo para a ponta de fora. Antes desta tarefa o único
        // sinal era a coluna armada mudando de fundo — 84pt de um painel de
        // 168, atrás da linha que desliza — e o dono do projeto não via nada.
        //
        // Inundar o painel inteiro é o que torna o sinal inequívoco: a metade
        // da lista que está debaixo da mão muda de cor de uma vez.
        let flooded = resolution.willFire

        return HStack(spacing: 0) {
            ForEach(actions) { action in
                SwipeActionColumn(
                    action: action,
                    message: message,
                    side: side,
                    isArmed: action == resolution.armed,
                    isFlooded: flooded,
                    onTap: { fire($0) }
                )
            }
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: side == .leading ? .leading : .trailing
        )
        // O sobrante do painel — o pedaço além das colunas, que aparece quando
        // a resistência ainda deixa a linha andar — acompanha a inundação.
        .background(flooded ? theme.accent.color : theme.surface3.color)
    }

    // MARK: - O gesto

    /// `minimumDistance: 1` é de propósito baixo: quem decide se o gesto é
    /// nosso é a máquina, com o engate e a razão de domínio que os testes
    /// travam. Deixar o `DragGesture` decidir por distância total engataria
    /// numa rolagem vertical de 12pt.
    ///
    /// `startLocation` vai junto porque é ela que distingue um gesto novo de
    /// uma continuação — a `ScrollView` pode levar o gesto sem que `onEnded`
    /// chegue, e sem essa marca o primeiro evento do gesto seguinte seria lido
    /// como continuação do anterior.
    private var drag: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                // Sem animação: o painel tem de andar colado na mão.
                apply(machine.dragChanged(
                    translation: value.translation,
                    startLocation: value.startLocation,
                    context
                ))
            }
            // Soltar, sim: o repouso — aberto ou fechado — é um destino, e ele
            // se alcança animado.
            .onEnded { value in
                apply(withAnimation(SwipeMotion.transition) {
                    machine.dragEnded(
                        translation: value.translation,
                        startLocation: value.startLocation,
                        context
                    )
                })
            }
    }

    /// Executa a ordem de serviço que a máquina deixou.
    ///
    /// A mutação da máquina já aconteceu quando isto roda; o que sobra é o que
    /// mora fora dela — a animação, o `openRowID` compartilhado, o adiamento
    /// de 0,24s e a ação disparada. Ordem importa: o selo já saiu da máquina
    /// **antes** de mexermos em `openRowID`, e é por isso que o eco do nosso
    /// próprio fechamento não destrava ninguém.
    private func apply(_ outcome: SwipeOutcome) {
        if outcome.claimsOpenRow {
            settleTask?.cancel()
            if openRowID != message.id { openRowID = message.id }
        }
        if outcome.releasesOpenRow, openRowID == message.id {
            openRowID = nil
        }
        if let seal = outcome.settleSeal {
            settleTask?.cancel()
            settleTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.24))
                guard !Task.isCancelled else { return }
                machine.settle(seal)
            }
        }
        if let action = outcome.fired {
            onFire(action)
        }
    }

    /// Tocar numa coluna revelada. O mesmo caminho do arraste longo, com o
    /// mesmo retorno visível.
    private func fire(_ action: SwipeAction) {
        apply(withAnimation(SwipeMotion.transition) { machine.dismiss() })
        onFire(action)
    }

    /// Fecha na hora — é o clique deliberado numa linha aberta, e ali não há
    /// arraste em curso para proteger.
    private func dismiss() {
        settleTask?.cancel()
        apply(withAnimation(SwipeMotion.transition) { machine.dismiss() })
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
    /// De que lado o painel está. Só serve para saber para onde é "a ponta de
    /// fora" quando a coluna armada salta.
    let side: SwipeSide
    /// É esta que o arraste longo dispara.
    let isArmed: Bool
    /// O arraste passou do limiar: o painel inteiro está inundado e soltar
    /// dispara a armada.
    let isFlooded: Bool
    let onTap: (SwipeAction) -> Void

    /// Quanto a coluna armada empurra ícone e rótulo para a ponta de fora
    /// quando o painel inunda. O Mail faz o mesmo: o ícone salta para a borda
    /// no instante em que soltar passa a disparar.
    static let armNudge: CGFloat = 5

    private var isNoOp: Bool { action.isNoOp(for: message) }

    /// A ponta de fora é a borda da lista: à esquerda no painel `leading`, à
    /// direita no `trailing`.
    private var nudge: CGFloat {
        guard isFlooded, isArmed else { return 0 }
        return side == .leading ? -Self.armNudge : Self.armNudge
    }

    var body: some View {
        Button { onTap(action) } label: {
            VStack(spacing: 5) {
                Image(systemName: action.symbol(for: message))
                    .font(.system(size: Self.symbolSize, weight: .medium))
                Text(action.title(for: message))
                    .font(theme.sans.font(size: Self.labelSize, weight: .semibold))
                    .lineLimit(1)
            }
            .offset(x: nudge)
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

    /// Inundado, tudo escreve em `onAccent`; a coluna muda escreve na mesma
    /// tinta a meio tom, para continuar legível como desabilitada sem sair do
    /// idioma da inundação.
    private var foreground: Color {
        if isFlooded {
            return isNoOp ? theme.onAccent.color.opacity(0.45) : theme.onAccent.color
        }
        if isNoOp { return theme.ink4.color }
        return action.tint == .strong ? theme.accentInk.color : theme.ink2.color
    }

    private var background: Color {
        if isFlooded { return theme.accent.color }
        if isNoOp { return theme.surface2.color }
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
