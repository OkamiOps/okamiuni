import AppKit
import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

/// A lacuna que a auditoria nomeou: `MessageRow` não tinha medida nenhuma.
/// `.fixedSize`, `.lineLimit(2)` e `accountBarWidth` podiam mudar de valor, ou
/// sumir, sem que suíte nenhuma reclamasse — nada aqui olhava para o que a
/// linha de fato desenha, só para os dados que ela recebe.
///
/// Sem harness de texto (não há OCR), a técnica é a mesma da suíte de
/// hairline: ler pixel do bitmap renderizado e comparar contra o que o token
/// e a constante preveem. A barra colorida da conta (`accountBarWidth`) é o
/// instrumento — ela cobre a altura inteira da linha (`.overlay(alignment:
/// .leading)` sem `.frame(height:)` próprio, então herda o da `VStack`), e por
/// isso serve tanto para medir a própria largura quanto, por extensão, a
/// altura da linha inteira.
@Suite("MessageRow")
@MainActor
struct MessageRowTests {
    private static let width: CGFloat = MessageList.width
    private static let canvasHeight: CGFloat = 300

    private func message(
        subject: String = "Assunto", snippet: String, isRead: Bool = true
    ) -> Message {
        Message(
            id: "m", accountID: "a",
            from: Contact(name: "Quem Escreveu", address: "quem@exemplo.com"),
            receivedAt: .now, subject: subject, snippet: snippet, body: [],
            tags: [], bucket: .today, isRead: isRead, summary: nil, detectedEvent: nil
        )
    }

    /// Vermelho puro como cor da conta: satura os três canais ao extremo, o
    /// que sobrevive tanto à opacidade cheia da barra (linha selecionada)
    /// quanto aos 45% da linha comum e aos 10% do fundo de seleção — nos três
    /// casos o canal vermelho fica bem acima do verde e do azul.
    private func renderRow(
        subject: String = "Assunto",
        snippet: String,
        isSelected: Bool = false,
        isRead: Bool = true,
        emphasis: UnreadEmphasis = .standard
    ) -> NSBitmapImageRep? {
        renderRow(
            message(subject: subject, snippet: snippet, isRead: isRead),
            isSelected: isSelected, emphasis: emphasis
        )
    }

    private func renderRow(
        _ message: Message,
        isSelected: Bool = false,
        emphasis: UnreadEmphasis = .standard
    ) -> NSBitmapImageRep? {
        let row = MessageRow(
            message: message,
            accountHost: "host", accountTint: .red, isSelected: isSelected,
            emphasis: emphasis
        )
        let staged = row
            .frame(width: Self.width, alignment: .topLeading)
            .frame(height: Self.canvasHeight, alignment: .top)
            .background(Theme.tinta.surface.color)
        return Render.bitmap(staged, size: CGSize(width: Self.width, height: Self.canvasHeight), theme: .tinta)
    }

    /// Vermelho domina claramente verde e azul, em qualquer das opacidades que
    /// a linha usa (10%, 45%, 100% sobre o fundo do tema `tinta`) — a conta
    /// entre parênteses na descrição de cada teste mostra a folga real.
    private func isReddish(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> Bool {
        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.99
        else { return false }
        let r = Double(c.redComponent), g = Double(c.greenComponent), b = Double(c.blueComponent)
        return r - max(g, b) > 0.04
    }

    /// Quantas linhas, a partir do topo, a barra da conta pinta na coluna
    /// `x`. A barra não tem `.frame(height:)` — herda o da `VStack` via
    /// `.overlay(alignment: .leading)` — então esta contagem É a altura da
    /// linha inteira, em pontos (escala 1×, como todo o harness).
    private func barRunLength(_ rep: NSBitmapImageRep, x: Int) -> Int {
        var count = 0
        for y in 0..<rep.pixelsHigh {
            guard isReddish(rep, x, y) else { break }
            count += 1
        }
        return count
    }

    // MARK: - Quem a primeira linha nomeia

    /// Em Enviadas a linha mostra **o destinatário**, e é o desenho que tem de
    /// mostrar — não só a regra pura do `UNICore`.
    ///
    /// O instrumento é a diferença: duas linhas iguais em tudo, menos no
    /// destinatário. Se a `View` continuasse escrevendo `message.from.name`
    /// (que é o mesmo nas duas), os bitmaps sairiam pixel a pixel idênticos —
    /// que é exatamente a mutação que isto mata.
    @Test("a linha de uma mensagem enviada nomeia o destinatário, não o remetente")
    func enviadaMostraODestinatario() throws {
        func enviada(para nome: String) -> Message {
            Message(
                id: "e1", accountID: "a",
                from: Contact(name: "Eu Mesmo", address: "eu@meudominio.com.br"),
                receivedAt: .now, subject: "Contrato", snippet: "Segue a versão final.",
                body: [], tags: [], bucket: .sent, isRead: true,
                summary: nil, detectedEvent: nil,
                to: [Contact(name: nome, address: "quem@exemplo.com")]
            )
        }
        let paraMarina = try #require(renderRow(enviada(para: "Marina Duarte")))
        let paraRicardo = try #require(renderRow(enviada(para: "Ricardo Alves")))
        #expect(
            paraMarina.pixelsDiffering(from: paraRicardo) > 0,
            "trocar o destinatário não mudou nada na linha — ela ainda desenha o remetente"
        )

        // E na caixa de entrada nada mudou: lá quem interessa é quem escreveu.
        func recebida(de nome: String) -> Message {
            Message(
                id: "r1", accountID: "a",
                from: Contact(name: nome, address: "quem@exemplo.com"),
                receivedAt: .now, subject: "Contrato", snippet: "Segue a versão final.",
                body: [], tags: [], bucket: .today, isRead: true,
                summary: nil, detectedEvent: nil,
                to: [Contact(name: "Eu Mesmo", address: "eu@meudominio.com.br")]
            )
        }
        let deMarina = try #require(renderRow(recebida(de: "Marina Duarte")))
        let deRicardo = try #require(renderRow(recebida(de: "Ricardo Alves")))
        #expect(
            deMarina.pixelsDiffering(from: deRicardo) > 0,
            "trocar o remetente não mudou nada na linha de uma mensagem recebida"
        )
    }

    // MARK: - Altura compacta da linha

    /// O redesenho mantém remetente, assunto, trecho e chips em uma linha cada;
    /// quebras no trecho não podem fazer uma conversa ocupar duas alturas.
    @Test("o trecho permanece compacto em uma linha")
    func snippetHeightStaysCompact() throws {
        let oneLine = try #require(renderRow(snippet: "Uma linha só, sem quebra nenhuma."))
        let twoLines = try #require(
            renderRow(snippet: "Primeira linha do trecho.\nSegunda linha do trecho.")
        )
        let threeLinesForced = try #require(
            renderRow(snippet: "Primeira linha do trecho.\nSegunda linha do trecho.\nTerceira linha, que o limite deve esconder.")
        )

        let h1 = barRunLength(oneLine, x: 1)
        let h2 = barRunLength(twoLines, x: 1)
        let h3 = barRunLength(threeLinesForced, x: 1)

        #expect(h1 > 0, "a barra da conta não pintou nada — a sonda não está medindo a linha")
        #expect(h2 == h1, "uma quebra no trecho alterou a altura compacta: \(h1) → \(h2)")
        #expect(h3 == h1, "três linhas lógicas alteraram a altura compacta: \(h1) → \(h3)")
    }

    // MARK: - Largura da barra da conta

    /// `accountBarWidth` é `3`. Medir a largura de fato pintada, não repetir
    /// a constante: uma `.frame(width:)` trocada no `overlay` continuaria
    /// compilando e a constante continuaria dizendo 3 sem que o desenho
    /// concordasse.
    @Test("o avatar marcado pinta diferente do das iniciais")
    func checkedAvatarDiffersFromInitials() throws {
        let plain = try #require(renderRow(snippet: "Um trecho comum, de uma linha."))
        let checked = try #require(
            Render.bitmap(
                MessageRow(
                    message: message(snippet: "Um trecho comum, de uma linha."),
                    accountHost: "host", accountTint: .red, isSelected: false,
                    isChecked: true
                )
                .frame(width: Self.width, alignment: .topLeading)
                .frame(height: Self.canvasHeight, alignment: .top)
                .background(Theme.tinta.surface.color),
                size: CGSize(width: Self.width, height: Self.canvasHeight),
                theme: .tinta
            )
        )
        #expect(
            checked.pixelsDiffering(from: plain) > 0,
            "marcar a conversa não mudou o círculo do avatar"
        )
    }

    @Test("a barra da conta pinta exatamente accountBarWidth pontos de largura")
    func accountBarWidthMatchesDrawing() throws {
        let rep = try #require(renderRow(snippet: "Um trecho comum, de uma linha."))
        // Meio da primeira linha (cabeçalho), longe de qualquer borda inferior.
        let y = 10
        var measuredWidth = 0
        for x in 0..<rep.pixelsWide {
            guard isReddish(rep, x, y) else { break }
            measuredWidth += 1
        }
        #expect(measuredWidth == Int(MessageRow.accountBarWidth))
    }

    // MARK: - Seleção pinta a linha inteira

    /// Requisito explícito do dono do projeto: a linha inteira pinta na
    /// seleção, não só embaixo do texto ou do chip. Medido bem à direita da
    /// linha, onde nem texto nem chip chegam — só o fundo.
    @Test("selecionar a linha pinta até a borda direita, não só o texto")
    func selectionPaintsTheFullRow() throws {
        let snippet = "Um trecho comum, de uma linha."
        let selected = try #require(renderRow(snippet: snippet, isSelected: true))
        let notSelected = try #require(renderRow(snippet: snippet, isSelected: false))

        let rowHeight = barRunLength(selected, x: 1)
        #expect(rowHeight > 20, "a sonda de altura não achou uma linha de verdade para escolher um y no meio dela")
        let y = rowHeight / 2
        let x = Int(Self.width) - 10

        let selectedColor = try #require(selected.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
        let plainColor = try #require(notSelected.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
        let selectedToken = try #require(Theme.tinta.surface3.nsColor.usingColorSpace(.sRGB))
        let plainToken = try #require(Theme.tinta.surface.nsColor.usingColorSpace(.sRGB))
        #expect(abs(selectedColor.redComponent - selectedToken.redComponent) < 0.02)
        #expect(abs(plainColor.redComponent - plainToken.redComponent) < 0.02)
        #expect(selectedColor != plainColor, "a seleção não cobre a largura inteira da linha")
    }

    // MARK: - O ponto de não-lida

    /// Os pixels que são o `accent` do tema, dentro de uma janela.
    ///
    /// A cor da conta neste harness é vermelho puro e a barra dela mora nos
    /// 3pt da esquerda; `accent` em `tinta` é `rgb(47,75,124)`, azul, e não
    /// existe em lugar nenhum da linha fora do ponto. Contar em vez de olhar
    /// um pixel: um ponto de 7pt tem uns 38px de área, e um único pixel
    /// certeiro passaria mesmo com o ponto reduzido a um respingo.
    private func accentPixels(
        _ rep: NSBitmapImageRep, x: Range<Int>, y: Range<Int>
    ) -> [(x: Int, y: Int)] {
        guard let wanted = Theme.tinta.accent.nsColor.usingColorSpace(.sRGB) else { return [] }
        var found: [(x: Int, y: Int)] = []
        for column in x where column < rep.pixelsWide {
            for row in y where row < rep.pixelsHigh {
                guard let c = rep.colorAt(x: column, y: row)?.usingColorSpace(.sRGB),
                      c.alphaComponent > 0.9 else { continue }
                if abs(c.redComponent - wanted.redComponent) < 0.02,
                   abs(c.greenComponent - wanted.greenComponent) < 0.02,
                   abs(c.blueComponent - wanted.blueComponent) < 0.02 {
                    found.append((column, row))
                }
            }
        }
        return found
    }

    /// A coluna do ponto: da borda direita da barra grossa até o fim da
    /// coluna. Fora dela o ponto estaria por cima da barra ou invadindo o
    /// conteúdo.
    ///
    /// **Mudou nesta tarefa, de propósito.** Antes era a goteira de 3–16pt,
    /// dividida com o recuo do texto; a variante escolhida (C) dá ao ponto uma
    /// coluna de 20pt, com a barra da conta engrossada para 6 embaixo dela.
    private static let dotColumn =
        Int(UnreadMetrics.loudBarWidth)..<Int(UnreadMetrics.dotColumnWidth)

    /// O defeito relatado: "ta muito dificil de saber se a mensagem já foi
    /// lida ou nào (…) eu demorei muito tempo pra perceber o sutil negrito no
    /// titulo". O negrito continua; o ponto é a marca que se vê sem procurar.
    ///
    /// Mutação que derruba: apagar o `overlay` do ponto em `MessageRow` — a
    /// contagem da linha não lida cai a zero e o primeiro `#expect` falha.
    @Test("a linha não lida marca um ponto de accent na goteira da esquerda")
    func unreadRowShowsTheDot() throws {
        let unread = try #require(renderRow(snippet: "Um trecho comum.", isRead: false))
        let marks = accentPixels(unread, x: 0..<Int(Self.width), y: 0..<60)

        // Área de um círculo de 9pt: ~63px. Metade disso já é um ponto, e um
        // respingo de 3px não passa. O piso subiu junto com o diâmetro: com 20
        // o ponto de 7pt de antes ainda passaria neste teste.
        #expect(marks.count >= 40, "o ponto pintou só \(marks.count)px — não é um ponto")
        let xs = marks.map(\.x)
        let ys = marks.map(\.y)
        let minX = try #require(xs.min()), maxX = try #require(xs.max())
        let minY = try #require(ys.min()), maxY = try #require(ys.max())

        // Na goteira: depois da barra da conta e antes do recuo do texto.
        #expect(Self.dotColumn.contains(minX), "o ponto começa em \(minX), fora da coluna")
        #expect(Self.dotColumn.contains(maxX), "o ponto termina em \(maxX), fora da coluna")
        // E do tamanho anunciado, com um pixel de folga para a antisserrilha.
        #expect(maxX - minX + 1 <= Int(UnreadMetrics.dotDiameter))
        #expect(maxY - minY + 1 <= Int(UnreadMetrics.dotDiameter))
        // Alinhado com a linha do remetente, não perdido no pé da linha.
        #expect(abs((minY + maxY) / 2 - Int(UnreadMetrics.dotCenterY)) <= 1)
    }

    /// A outra metade da sonda: sem ela, um ponto pintado em **toda** linha
    /// passaria no teste de cima.
    @Test("a linha lida não tem nada na goteira")
    func readRowHasNoDot() throws {
        let read = try #require(renderRow(snippet: "Um trecho comum.", isRead: true))
        let marks = accentPixels(read, x: 0..<Int(Self.width), y: 0..<60)
        #expect(marks.isEmpty, "a linha lida pintou \(marks.count)px de accent")
    }

    /// O ponto tem de sumir **na hora**, por qualquer caminho que marque lida.
    /// Aqui o caminho é o de verdade: o mesmo `ContextCommand` que o menu de
    /// contexto e o arraste emitem, executado pelo `StoreCommand` sobre o
    /// `MailStore`. A linha relê `message.isRead` e o ponto vai embora.
    @Test("marcar como lida pelo comando do app apaga o ponto")
    func markingReadClearsTheDot() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let unread = try #require(store.messages.first { !$0.isRead })

        let before = try #require(renderRow(unread))
        #expect(accentPixels(before, x: 0..<Int(Self.width), y: 0..<60).count >= 20)

        #expect(StoreCommand.run(.setRead(messageID: unread.id, isRead: true), on: store))
        let marked = try #require(store.messages.first { $0.id == unread.id })
        #expect(marked.isRead)

        let after = try #require(renderRow(marked))
        #expect(
            accentPixels(after, x: 0..<Int(Self.width), y: 0..<60).isEmpty,
            "o ponto sobreviveu à marcação de lida"
        )
    }

    /// O negrito continua sendo parte da distinção — o ponto é **adição**, não
    /// troca. Medido pela tinta que o nome do remetente deposita: em
    /// `.semibold` ela é mais grossa que em `.regular`.
    @Test("o ponto não substituiu o negrito do remetente")
    func boldSenderSurvivesTheDot() throws {
        let unread = try #require(renderRow(snippet: "Um trecho comum.", isRead: false))
        let read = try #require(renderRow(snippet: "Um trecho comum.", isRead: true))
        // Só a faixa do nome, e só à direita da coluna do ponto — que agora
        // ocupa layout. `accent` soma 0,96 nos três canais e passaria por
        // "tinta escura" se a janela o incluísse.
        let x = Int(UnreadMetrics.dotColumnWidth)..<Int(Self.width)
        #expect(inkCount(unread, x: x, y: 10..<26) > inkCount(read, x: x, y: 10..<26),
                "o nome não lido não deposita mais tinta que o lido — o negrito sumiu")
    }

    // MARK: - O campo: barra grossa e fundo próprio (a outra metade da C)

    /// A variante escolhida marca por **dois** sinais, e cada um cai sozinho.
    /// Este é o segundo: a barra da conta engrossa de 3 para 6 na linha não
    /// lida — e continua com 3 na lida, senão o sinal não separa nada.
    ///
    /// Mutação que derruba: `barWidth` devolvendo `Self.accountBarWidth`
    /// sempre. A medida da não lida cai para 3 e o primeiro `#expect` falha.
    @Test("a barra da conta engrossa na linha não lida, e só nela")
    func unreadRowThickensTheAccountBar() throws {
        func barWidth(isRead: Bool) throws -> Int {
            let rep = try #require(renderRow(snippet: "Um trecho comum.", isRead: isRead))
            var measured = 0
            for x in 0..<rep.pixelsWide {
                guard isReddish(rep, x, 10) else { break }
                measured += 1
            }
            return measured
        }
        #expect(try barWidth(isRead: false) == Int(UnreadMetrics.loudBarWidth))
        #expect(try barWidth(isRead: true) == Int(UnreadMetrics.quietBarWidth))
    }

    /// O terceiro sinal da variante C: o **fundo**. A linha não lida pinta
    /// `surface2` de ponta a ponta; a lida não pinta nada e mostra o
    /// `surface` do palco.
    ///
    /// Medido bem à direita (x = largura − 10), onde nem texto nem chip chegam
    /// — a mesma sonda que prova a seleção cobrir a linha inteira.
    ///
    /// Mutação que derruba: `rowBackground` devolvendo `.clear` para a não
    /// lida. A contagem cai a zero e o primeiro `#expect` falha, **sem** o
    /// teste do ponto se mexer — que é o ponto de separar os dois sinais.
    @Test("a linha não lida pinta o fundo próprio até a borda direita")
    func unreadRowPaintsItsField() throws {
        let unread = try #require(renderRow(snippet: "Um trecho comum.", isRead: false))
        let read = try #require(renderRow(snippet: "Um trecho comum.", isRead: true))
        let x = Int(Self.width) - 10
        let y = 0..<barRunLength(unread, x: 1)

        func softPixels(_ rep: NSBitmapImageRep) -> Int {
            var count = 0
            guard let wanted = Theme.tinta.surface2.nsColor.usingColorSpace(.sRGB)
            else { return 0 }
            for row in y {
                guard let c = rep.colorAt(x: x, y: row)?.usingColorSpace(.sRGB) else { continue }
                if abs(c.redComponent - wanted.redComponent) < 0.008,
                   abs(c.greenComponent - wanted.greenComponent) < 0.008,
                   abs(c.blueComponent - wanted.blueComponent) < 0.008 {
                    count += 1
                }
            }
            return count
        }

        #expect(softPixels(unread) > 60, "o fundo da não lida pintou \(softPixels(unread))px")
        #expect(softPixels(read) == 0, "a linha lida pintou fundo de não lida")
    }

    // MARK: - As três variantes, para a escolha ser feita olhando

    /// Cada variante acende exatamente os sinais que promete — é o que impede
    /// que "trocar `UnreadEmphasis.standard`" mude menos do que anuncia.
    @Test("cada variante acende só os sinais que promete", arguments: UnreadEmphasis.allCases)
    func eachVariantShowsWhatItPromises(emphasis: UnreadEmphasis) throws {
        let rep = try #require(
            renderRow(snippet: "Um trecho comum.", isRead: false, emphasis: emphasis)
        )
        let dot = accentPixels(rep, x: 0..<Int(Self.width), y: 0..<60).count
        var bar = 0
        for x in 0..<rep.pixelsWide {
            guard isReddish(rep, x, 10) else { break }
            bar += 1
        }
        #expect((dot >= 40) == emphasis.showsDot, "o ponto de \(emphasis) pintou \(dot)px")
        #expect(bar == Int(emphasis.barWidth), "a barra de \(emphasis) mede \(bar)")
    }

    /// O carimbo da direita **é** a data, e não o `dayOffset`.
    ///
    /// As três mensagens deste teste têm `dayOffset` 0 — o valor que toda
    /// mensagem vinda de servidor tem, porque ninguém preenche esse campo fora
    /// das fixtures. Era por isso que a caixa do dono mostrava julho inteiro
    /// com horário. Aqui elas só diferem no `receivedAt`, e o canto direito da
    /// linha tem de sair diferente nos três casos: hora, "21 de jul." e a data
    /// com o ano.
    @Test("O carimbo segue a data recebida, e não o dayOffset")
    func carimboSegueAData() throws {
        func linha(_ receivedAt: Date) throws -> NSBitmapImageRep {
            let mensagem = Message(
                id: "m", accountID: "a",
                from: Contact(name: "Quem Escreveu", address: "quem@exemplo.com"),
                receivedAt: receivedAt, subject: "Assunto", snippet: "trecho", body: [],
                tags: [], bucket: .today, isRead: true, summary: nil, detectedEvent: nil,
                dayOffset: 0
            )
            let row = MessageRow(
                message: mensagem, accountHost: "host", accountTint: .red,
                isSelected: false, today: Fixtures.today
            )
            return try #require(
                Render.bitmap(
                    row.frame(width: Self.width, alignment: .topLeading)
                        .frame(height: Self.canvasHeight, alignment: .top)
                        .background(Theme.tinta.surface.color),
                    size: CGSize(width: Self.width, height: Self.canvasHeight), theme: .tinta
                )
            )
        }
        let calendario = Calendar.current
        let deJulho = try #require(
            calendario.date(from: DateComponents(year: 2026, month: 7, day: 21, hour: 16, minute: 55))
        )
        let doAnoPassado = try #require(
            calendario.date(from: DateComponents(year: 2025, month: 7, day: 21, hour: 16, minute: 55))
        )
        // Mesma hora de parede, dias diferentes: enquanto a linha carimbava
        // pelo `dayOffset`, estas duas saíam idênticas — "16:55" e "16:55".
        let hojeNaMesmaHora = try #require(
            calendario.date(from: DateComponents(year: 2026, month: 8, day: 25, hour: 16, minute: 55))
        )
        #expect(try linha(deJulho).pixelsDiffering(from: linha(hojeNaMesmaHora)) > 0,
                "a mensagem de julho carimbou igual à de hoje na mesma hora")
        #expect(try linha(doAnoPassado).pixelsDiffering(from: linha(deJulho)) > 0,
                "a mensagem do ano passado carimbou igual à deste ano")
    }

    /// Pixels escuros (tinta de texto) numa janela.
    private func inkCount(_ rep: NSBitmapImageRep, x: Range<Int>, y: Range<Int>) -> Int {
        var count = 0
        for column in x where column < rep.pixelsWide {
            for row in y where row < rep.pixelsHigh {
                guard let c = rep.colorAt(x: column, y: row)?.usingColorSpace(.sRGB),
                      c.alphaComponent > 0.5 else { continue }
                if c.redComponent + c.greenComponent + c.blueComponent < 1.6 { count += 1 }
            }
        }
        return count
    }
}
