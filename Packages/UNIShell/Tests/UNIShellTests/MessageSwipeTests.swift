import AppKit
import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

/// O desenho do arraste, medido em pixel, e o efeito dele no `MailStore`.
///
/// Nada aqui lança o app nem sintetiza evento: o painel revelado entra pelo
/// `debugTranslation` do `SwipeRow`, que é o mesmo recurso de `debugFocused` em
/// `ChromeButton` — um parâmetro interno que põe a `View` no estado a medir.
///
/// A aritmética do gesto (engate, domínio da horizontal, limiares de abertura e
/// de disparo) é pura e tem teste próprio em `UNICore/SwipeActionTests`. Aqui
/// se mede o que só o desenho responde: onde o painel começa, onde ele termina,
/// e se os rótulos cabem inteiros nas colunas.
@Suite("Arraste da linha — desenho e efeito")
@MainActor
struct MessageSwipeTests {

    static let theme = Theme.tinta
    static let listWidth: CGFloat = MessageList.width  // 370
    static let stageHeight: CGFloat = 140

    /// O painel inteiro do padrão: duas colunas de 84.
    static let panel = SwipeMetrics.panelWidth(actions: 2)  // 168

    // MARK: - Palco

    private static func account() -> Account { Fixtures.accounts[0] }

    private static func sample(
        bucket: TriageBucket = .today, isRead: Bool? = nil
    ) -> Message {
        let base = Fixtures.messages[0]
        return Message(
            id: base.id, accountID: base.accountID, from: base.from,
            receivedAt: base.receivedAt, subject: base.subject, snippet: base.snippet,
            body: base.body, tags: base.tags, bucket: bucket, isRead: isRead ?? base.isRead,
            summary: base.summary, detectedEvent: base.detectedEvent,
            dayOffset: base.dayOffset, replyHints: base.replyHints
        )
    }

    /// A linha sozinha, encostada no topo do palco, com o painel forçado ao
    /// deslocamento pedido.
    ///
    /// `isSelected: false` de propósito: a linha selecionada pinta o fundo com
    /// a cor da conta a 10% sobre `surface`, o que em `tinta` cai a 3 níveis de
    /// `accentSoft` — o fundo da coluna de arquivar. Medir o painel contra um
    /// fundo que se confunde com ele daria uma medida que passa sempre.
    private static func stage(_ translation: CGSize, message: Message) -> some View {
        let account = account()
        let tint = TokenColor(css: account.tint(isDark: false))?.color ?? .gray
        return VStack(spacing: 0) {
            SwipeRow(
                message: message,
                configuration: .default,
                openRowID: .constant(nil),
                onFire: { _ in },
                debugTranslation: translation
            ) { _ in
                MessageRow(
                    message: message,
                    accountHost: account.host,
                    accountTint: tint,
                    isSelected: false
                )
            }
            Spacer(minLength: 0)
        }
        .frame(width: listWidth)
        // `paper` fica a 14 níveis de `surface3` e a 11 de `accentSoft`: o
        // sobrante do palco não pode ser confundido com painel.
        .background(theme.paper.color)
    }

    /// A altura que a linha de fato ocupa, para a varredura de tinta não sair
    /// dela e catar o fundo do palco.
    private static func rowHeight(_ message: Message) -> CGFloat {
        let account = account()
        let view = NSHostingView(
            rootView: MessageRow(
                message: message,
                accountHost: account.host,
                accountTint: .gray,
                isSelected: false
            )
            .frame(width: listWidth)
            .theme(theme)
            .environment(\.displayScale, 1)
        )
        return view.fittingSize.height
    }

    // MARK: - Leitura de pixel

    private static func color(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> TokenColor {
        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
            return TokenColor(red: -1, green: -1, blue: -1)
        }
        return TokenColor(
            red: Double(c.redComponent), green: Double(c.greenComponent),
            blue: Double(c.blueComponent), opacity: Double(c.alphaComponent)
        )
    }

    private static func levels(_ a: TokenColor, _ b: TokenColor) -> Double {
        max(abs(a.red - b.red), max(abs(a.green - b.green), abs(a.blue - b.blue))) * 255
    }

    /// Aperto de propósito: os fundos que este teste separa estão a 11 níveis
    /// no pior caso (`paper` contra `accentSoft`), então 6 os distingue e não
    /// engole nenhum dos dois.
    static let tolerance = 6.0

    /// Este pixel é fundo de painel? As duas colunas do padrão pintam
    /// `accentSoft` (arquivar, a forte) e `surface3` (a discreta).
    private static func isPanel(_ c: TokenColor) -> Bool {
        levels(c, theme.accentSoft) <= tolerance || levels(c, theme.surface3) <= tolerance
    }

    /// As colunas de pixel que são painel, numa faixa de varredura.
    ///
    /// A faixa fica **perto do topo da linha**: ali a coluna mostra só o fundo,
    /// porque ícone e rótulo ficam centrados na altura. Varrer no meio pegaria
    /// os glifos e a contagem mediria outra coisa.
    private static func panelColumns(_ rep: NSBitmapImageRep, y: Int) -> [Int] {
        (0..<rep.pixelsWide).filter { isPanel(color(rep, $0, y)) }
    }

    /// A tinta do **texto da linha**: bem mais escura que qualquer fundo desta
    /// paleta. `ink` soma 85/765 e `ink2`, 227/765; `surface3` soma 687 e
    /// `surface`, 755. O corte em 1,6 (de 3,0) separa com folga — e deixa de
    /// fora a barra da conta a 45%, `rgb(167,186,209)`, que soma 2,17 e não é
    /// texto.
    private static func isTextInk(_ c: TokenColor) -> Bool {
        c.opacity > 0.5 && c.red >= 0 && (c.red + c.green + c.blue) < 1.6
    }

    /// O pixel mais escuro de uma janela, em soma de canais (0 a 3).
    ///
    /// Serve para comparar uma coluna viva com uma desabilitada sem depender de
    /// um corte fixo: a desabilitada desenha, e desenha **mais claro**.
    private static func darkest(_ rep: NSBitmapImageRep, x: Range<Int>, y: Range<Int>) -> Double {
        var best = 3.0
        for column in x where column < rep.pixelsWide {
            for row in y where row < rep.pixelsHigh {
                let c = color(rep, column, row)
                guard c.opacity > 0.5, c.red >= 0 else { continue }
                best = Swift.min(best, c.red + c.green + c.blue)
            }
        }
        return best
    }

    /// A extensão horizontal da tinta dentro de uma faixa, em pixel.
    private static func inkSpan(
        _ rep: NSBitmapImageRep,
        x: Range<Int>,
        y: Range<Int>,
        where isInk: (TokenColor) -> Bool
    ) -> (min: Int, max: Int)? {
        var lo = Int.max
        var hi = Int.min
        for column in x where column < rep.pixelsWide {
            for row in y where row < rep.pixelsHigh {
                guard isInk(color(rep, column, row)) else { continue }
                lo = Swift.min(lo, column)
                hi = Swift.max(hi, column)
                break
            }
        }
        return lo <= hi ? (lo, hi) : nil
    }

    /// As colunas em que um token aparece chapado. Usada para achar o botão
    /// "Desfazer" dentro da faixa: ele é a única coisa ali pintada em `btn`.
    private static func columns(of token: TokenColor, in rep: NSBitmapImageRep, y: Range<Int>)
        -> (min: Int, max: Int)?
    {
        var lo = Int.max
        var hi = Int.min
        for column in 0..<rep.pixelsWide {
            for row in y where row < rep.pixelsHigh {
                guard levels(color(rep, column, row), token) <= 3 else { continue }
                lo = Swift.min(lo, column)
                hi = Swift.max(hi, column)
                break
            }
        }
        return lo <= hi ? (lo, hi) : nil
    }

    private static func render(_ name: String, _ translation: CGSize, _ message: Message) throws
        -> NSBitmapImageRep
    {
        try #require(
            Render.snapshot(
                stage(translation, message: message),
                named: name,
                size: CGSize(width: listWidth, height: stageHeight),
                theme: theme
            )
        )
    }

    // MARK: - Os três estados

    /// Em repouso a linha é exatamente a de antes desta tarefa: nenhum pixel de
    /// painel em lugar nenhum dela.
    ///
    /// É a metade que prova que o gesto não canibalizou nada. Se o `SwipeRow`
    /// passar a desenhar o painel sempre — ou a deslocar a linha por engano —
    /// a contagem deixa de ser zero.
    @Test("em repouso, a linha não mostra painel nenhum")
    func atRestNoPanel() throws {
        let message = Self.sample()
        let rep = try Self.render("arraste-repouso-tinta", .zero, message)
        let found = Self.panelColumns(rep, y: 6)
        #expect(found.isEmpty, "painel visível em repouso nas colunas \(found.prefix(12))")
    }

    /// Arrastando para a direita, o painel esquerdo ocupa exatamente as duas
    /// colunas e a linha sai de baixo dele.
    @Test("revelada à esquerda, o painel mede as duas colunas e começa na borda")
    func revealedLeading() throws {
        let message = Self.sample()
        let rep = try Self.render(
            "arraste-esquerda-tinta", CGSize(width: Self.panel, height: 0), message
        )
        let found = Self.panelColumns(rep, y: 6)
        #expect(found.first == 0)
        #expect(found.last == Int(Self.panel) - 1)
        #expect(found.count == Int(Self.panel), "painel com \(found.count)px, esperados 168")
    }

    /// Arrastando para a esquerda, o painel encosta na borda direita.
    ///
    /// O número que se mede aqui é o **começo** dele: 370 − 168 = 202. Medir só
    /// a largura passaria com o painel desenhado do lado errado.
    @Test("revelada à direita, o painel encosta na borda oposta")
    func revealedTrailing() throws {
        // Arquivada: as duas colunas da direita ("Depois" e "Hoje") fazem algo,
        // então as duas pintam `surface3`. Numa mensagem que já está em Hoje, a
        // coluna "Hoje" sai desabilitada e o `.disabled()` do SwiftUI escurece o
        // fundo dela para `rgb(237,235,229)` — que passa raspando pela mesma
        // tolerância. A medida ficaria certa por acidente.
        let message = Self.sample(bucket: .archived)
        let rep = try Self.render(
            "arraste-direita-tinta", CGSize(width: -Self.panel, height: 0), message
        )
        let found = Self.panelColumns(rep, y: 6)
        #expect(found.first == Int(Self.listWidth - Self.panel))
        #expect(found.last == Int(Self.listWidth) - 1)
        #expect(found.count == Int(Self.panel), "painel com \(found.count)px, esperados 168")
    }

    // MARK: - Os rótulos cabem inteiros

    /// Cada coluna tem tinta, e a tinta não encosta na borda da coluna.
    ///
    /// Rótulo cortado é o defeito clássico deste componente, e ele não aparece
    /// olhando o PNG: "Arquivar" com a perna do "r" comida continua parecendo
    /// "Arquivar". A medida é a folga entre o glifo mais externo e a divisória
    /// da coluna.
    @Test("os rótulos do painel esquerdo cabem inteiros nas colunas")
    func leadingLabelsFit() throws {
        let message = Self.sample()
        let rep = try Self.render(
            "arraste-esquerda-rotulos-tinta", CGSize(width: Self.panel, height: 0), message
        )
        let height = Int(Self.rowHeight(message))
        let width = Int(SwipeMetrics.actionWidth)

        for (index, action) in SwipeConfiguration.default.leading.enumerated() {
            let start = index * width
            let span = try #require(
                Self.inkSpan(rep, x: start..<(start + width), y: 0..<height, where: Self.isTextInk),
                "a coluna de \(action.title(for: message)) não desenhou nada"
            )
            #expect(span.min - start >= Self.clearance,
                    "\(action.title(for: message)) encosta na borda esquerda da coluna")
            #expect((start + width - 1) - span.max >= Self.clearance,
                    "\(action.title(for: message)) encosta na borda direita da coluna")
        }
    }

    @Test("os rótulos do painel direito cabem inteiros nas colunas")
    func trailingLabelsFit() throws {
        let message = Self.sample(bucket: .archived)
        let rep = try Self.render(
            "arraste-direita-rotulos-tinta", CGSize(width: -Self.panel, height: 0), message
        )
        let height = Int(Self.rowHeight(message))
        let width = Int(SwipeMetrics.actionWidth)
        let origin = Int(Self.listWidth - Self.panel)

        for index in 0..<SwipeConfiguration.default.trailing.count {
            let start = origin + index * width
            let span = try #require(
                Self.inkSpan(rep, x: start..<(start + width), y: 0..<height, where: Self.isTextInk),
                "a coluna \(index) do painel direito não desenhou nada"
            )
            #expect(span.min - start >= Self.clearance)
            #expect((start + width - 1) - span.max >= Self.clearance)
        }
    }

    /// Nenhum rótulo pede mais largura do que a coluna tem.
    ///
    /// A folga medida em pixel só enxerga os rótulos que **aquela linha**
    /// desenha, e a linha de exemplo nunca mostra todos: "Não lida" só aparece
    /// em mensagem lida, e o painel direito de uma mensagem arquivada nunca
    /// mostra "Arquivar". Este mede todos.
    ///
    /// Provado quebrando, com o corpo do rótulo em 22pt: "Arquivar" passou a
    /// pedir 85pt e "Não lida" 81, numa coluna de 84 — e o teste de folga do
    /// painel **direito** continuou passando, porque nem "Depois" (70) nem
    /// "Hoje" (46) estouram ali.
    ///
    /// Mede a largura que o rótulo pede solto, sem quadro, contra a literal da
    /// coluna.
    @Test("nenhum rótulo do painel pede mais largura do que a coluna tem")
    func everyLabelFitsItsColumn() {
        let room = SwipeMetrics.actionWidth - CGFloat(2 * Self.clearance)
        for action in SwipeAction.allCases {
            for isRead in [false, true] {
                let message = Self.sample(isRead: isRead)
                let title = action.title(for: message)
                let view = NSHostingView(
                    rootView: Text(title)
                        .font(Self.theme.sans.font(
                            size: SwipeActionColumn.labelSize, weight: .semibold
                        ))
                        .fixedSize()
                        .theme(Self.theme)
                        .environment(\.displayScale, 1)
                )
                let asked = view.fittingSize.width
                #expect(asked <= room,
                        "\"\(title)\" pede \(Int(asked.rounded()))pt e a coluna dá \(Int(room))")
            }
        }
    }

    /// A coluna que não faria nada continua **desenhada**, e continua legível
    /// como desabilitada.
    ///
    /// Ela fica visível de propósito: sumir com uma coluna mudaria a largura do
    /// painel de linha para linha, e a fila de triagem do leitor já mostra a
    /// caixa corrente em vez de escondê-la. O que muda é a tinta — `ink4` em
    /// lugar de `ink2`, e o `.disabled()` por cima.
    ///
    /// A medida é comparativa, não um corte cravado: a coluna morta desenha
    /// alguma coisa (senão o rótulo teria sumido) e desenha mais claro que a
    /// viva ao lado.
    @Test("a coluna que não faria nada aparece, e aparece apagada")
    func deadColumnLooksDead() throws {
        // Em "Hoje": a coluna "Hoje" é muda, a coluna "Depois" é viva.
        let message = Self.sample(bucket: .today)
        let rep = try Self.render(
            "arraste-direita-coluna-morta-tinta",
            CGSize(width: -Self.panel, height: 0), message
        )
        let height = Int(Self.rowHeight(message))
        let width = Int(SwipeMetrics.actionWidth)
        let origin = Int(Self.listWidth - Self.panel)

        // O painel da direita desenha [Hoje][Depois]: a primeira da
        // configuração é a que o dedo revela primeiro, e portanto a mais à
        // direita.
        let dead = Self.darkest(rep, x: origin..<(origin + width), y: 0..<height)
        let live = Self.darkest(
            rep, x: (origin + width)..<(origin + 2 * width), y: 0..<height
        )
        // Desenhou: o pixel mais escuro dela está bem abaixo do fundo da
        // coluna (`surface3` soma 2,69).
        #expect(dead < 2.5, "a coluna muda não desenhou rótulo nenhum")
        // E desenhou apagado: a viva é claramente mais escura.
        #expect(live < dead - 0.5,
                "morta em \(dead) e viva em \(live) — não dá para distinguir")
    }

    /// Folga mínima entre o glifo mais externo e a borda da coluna, em pixel.
    /// Um rótulo cortado tem folga **zero** de um dos lados; três pixels é
    /// pouco para um desenho folgado e muito para um cortado.
    static let clearance = 3

    /// A linha não corta o conteúdo dela ao ser deslocada: o que estava na
    /// linha continua desenhando, só que 168pt adiante.
    ///
    /// Medido pela **tinta do assunto**, na faixa de altura onde ela está: em
    /// repouso ela começa perto do recuo da linha (16pt), revelada ela começa
    /// 168pt depois. Sem isso, um `.clipped()` no lugar errado passaria
    /// despercebido — o painel mediria certo e a linha estaria vazia.
    @Test("a linha desliza inteira, sem perder conteúdo")
    func contentSlidesWhole() throws {
        let message = Self.sample()
        let height = Int(Self.rowHeight(message))

        let rest = try Self.render("arraste-conteudo-repouso-tinta", .zero, message)
        let moved = try Self.render(
            "arraste-conteudo-esquerda-tinta", CGSize(width: Self.panel, height: 0), message
        )

        let atRest = try #require(Self.inkSpan(rest, x: 0..<Int(Self.listWidth), y: 0..<height, where: Self.isTextInk))
        let shifted = try #require(
            Self.inkSpan(moved, x: Int(Self.panel)..<Int(Self.listWidth), y: 0..<height, where: Self.isTextInk)
        )
        // A primeira tinta da linha em repouso está no recuo do protótipo.
        #expect(atRest.min >= Int(Self.theme.rowPadding.leading) - 2)
        #expect(atRest.min <= Int(Self.theme.rowPadding.leading) + 8)
        // E, deslocada, ela reaparece exatamente 168pt adiante.
        #expect(shifted.min == atRest.min + Int(Self.panel))
    }

    // MARK: - A faixa de retorno

    /// Espremida na lista mais estreita, quem cede é a **frase**, nunca o botão.
    ///
    /// A faixa pede 329pt para escrever tudo numa linha só, e a lista mais
    /// estreita que `PaneLayout` concede dá 320 — 300 depois do recuo. Alguém
    /// tem de ceder, e num `HStack` o SwiftUI comprime o que for flexível: se o
    /// botão entrar nessa conta, o controle mais importante da faixa vira
    /// "Desfaz…".
    ///
    /// A medida é a largura do botão, achada pelo fundo dele — ele é a única
    /// coisa da faixa pintada em `btn`. Ela tem de ser a mesma numa faixa
    /// larga e numa apertada.
    @Test("espremida, a faixa aperta a frase e não o botão")
    func undoBandKeepsTheButtonWhole() throws {
        let message = Self.sample()
        let receipt = try #require(
            SwipeReceipt.of(.archive, message: message, stamp: "14:32")
        )

        let roomy = try Self.renderBand("desfazer-larga-tinta", receipt: receipt, width: 420)
        let tight = try Self.renderBand("desfazer-estreita-tinta", receipt: receipt, width: 300)

        let wide = try #require(
            Self.columns(of: Self.theme.btn, in: roomy, y: 0..<70),
            "não achei o botão na faixa larga"
        )
        let narrow = try #require(
            Self.columns(of: Self.theme.btn, in: tight, y: 0..<70),
            "não achei o botão na faixa estreita"
        )
        let wideWidth = wide.max - wide.min
        let narrowWidth = narrow.max - narrow.min
        #expect(wideWidth == narrowWidth,
                "o botão mede \(wideWidth)px solto e \(narrowWidth)px apertado")
        // E ele continua encostado na borda direita, não empurrado para fora.
        #expect(narrow.max <= 300 - 8)
        #expect(narrow.max >= 300 - 20)
    }

    /// A faixa sozinha, encostada no topo, sobre `paper` — que não se confunde
    /// com `btn` nem com `accentSoft`.
    private static func renderBand(
        _ name: String, receipt: SwipeReceipt, width: CGFloat
    ) throws -> NSBitmapImageRep {
        try #require(
            Render.snapshot(
                VStack(spacing: 0) {
                    SwipeUndoBand(receipt: receipt, onUndo: {})
                    Spacer(minLength: 0)
                }
                .frame(width: width)
                .background(theme.paper.color),
                named: name,
                size: CGSize(width: width, height: 80),
                theme: theme
            )
        )
    }

    /// Espremida na largura da lista mais estreita, ela cresce em altura em vez
    /// de cortar a frase — `lineLimit(2)` com `fixedSize` vertical.
    @Test("espremida, a faixa cresce em vez de cortar")
    func undoBandWrapsInsteadOfTruncating() throws {
        let message = Self.sample()
        let receipt = try #require(
            SwipeReceipt.of(.archive, message: message, stamp: "14:32")
        )
        let view = NSHostingView(
            rootView: SwipeUndoBand(receipt: receipt, onUndo: {})
                .frame(width: 220)
                .theme(Self.theme)
                .environment(\.displayScale, 1)
        )
        // Duas linhas de 12pt mais os recuos verticais: acima de uma linha só,
        // e longe de estourar.
        #expect(view.fittingSize.height >= 30)
        #expect(view.fittingSize.height <= 70)
    }

    // MARK: - O efeito no modelo

    /// O caminho inteiro de uma ação disparada: comando, recibo, e o desfazer
    /// devolvendo a mensagem à caixa de onde veio.
    ///
    /// A seleção andar para a próxima é trabalho de `MailStore.move`, que já
    /// tem teste em `UNICore` — aqui só se confere que ela **não** ficou
    /// apontando para fora da visão, que é o sintoma se alguém duplicar a
    /// lógica errado.
    @Test("arquivar pelo arraste move de verdade, e desfazer devolve")
    func archiveAndUndo() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()

        let message = try #require(store.visibleMessages.first)
        #expect(message.bucket == .today)

        let receipt = try #require(
            SwipeReceipt.of(.archive, message: message, stamp: "14:32")
        )
        let command = try #require(SwipeAction.archive.command(for: message))
        #expect(StoreCommand.run(command, on: store))

        let archived = try #require(store.messages.first { $0.id == message.id })
        #expect(archived.bucket == .archived)
        #expect(store.visibleMessages.contains { $0.id == message.id } == false)
        if let selected = store.selectedMessageID {
            #expect(store.visibleMessages.contains { $0.id == selected })
        }

        #expect(StoreCommand.run(receipt.undo, on: store))
        let restored = try #require(store.messages.first { $0.id == message.id })
        #expect(restored.bucket == .today)
    }

    @Test("marcar como lida pelo arraste, e desfazer, passam pelo mesmo comando")
    func readToggleAndUndo() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()

        let unread = try #require(store.messages.first { !$0.isRead })
        let receipt = try #require(
            SwipeReceipt.of(.toggleRead, message: unread, stamp: "14:32")
        )
        #expect(receipt.note.hasPrefix("Marcada como lida"))

        let command = try #require(SwipeAction.toggleRead.command(for: unread))
        #expect(StoreCommand.run(command, on: store))
        #expect(store.messages.first { $0.id == unread.id }?.isRead == true)

        #expect(StoreCommand.run(receipt.undo, on: store))
        #expect(store.messages.first { $0.id == unread.id }?.isRead == false)
    }

    /// `StoreCommand` é o executor **só do modelo**. Um comando que precisa de
    /// janela não pode ser engolido em silêncio ali — se ele passar a devolver
    /// `true`, o desfazer do arraste ganharia um caminho que não faz nada.
    @Test("o executor do modelo recusa o que precisa de janela")
    func storeCommandRefusesWindowWork() async {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        #expect(StoreCommand.run(.openMessageWindow(messageID: "m1"), on: store) == false)
        #expect(StoreCommand.run(.reply(messageID: "m1"), on: store) == false)
        #expect(StoreCommand.run(.copy("x"), on: store) == false)
    }

    /// A lista lê a configuração do ambiente e cai no padrão quando ninguém a
    /// proveu — é o que deixa o harness e as previews desenharem.
    @Test("sem ninguém no ambiente, a lista usa o padrão")
    func listFallsBackToTheDefaultConfiguration() async {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        #expect(MessageList(store: store).swipeConfiguration == .default)
    }
}
