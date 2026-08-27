import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

/// A caixa que envolve todos os pixels em que dois desenhos diferem.
///
/// O cartão da paleta é uma sobreposição: ele não muda o tamanho de nada, então
/// a pergunta certa não é "quantos pixels mudaram" e sim "que retângulo mudou".
/// É a altura desse retângulo que diz se o item de cor livre está no cartão.
@MainActor
struct DifferenceBox {
    var x: ClosedRange<Int>
    var y: ClosedRange<Int>
    var count: Int

    var height: Int { y.upperBound - y.lowerBound + 1 }
    var width: Int { x.upperBound - x.lowerBound + 1 }

    init?(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) {
        var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min, total = 0
        for row in 0..<min(a.pixelsHigh, b.pixelsHigh) {
            for column in 0..<min(a.pixelsWide, b.pixelsWide)
            where a.colorAt(x: column, y: row) != b.colorAt(x: column, y: row) {
                minX = min(minX, column); maxX = max(maxX, column)
                minY = min(minY, row); maxY = max(maxY, row)
                total += 1
            }
        }
        guard total > 0 else { return nil }
        self.x = minX...maxX
        self.y = minY...maxY
        self.count = total
    }
}

/// A paleta deixou de ser uma escolha entre seis.
///
/// **Nenhum teste daqui abre o `NSColorPanel`.** Ele é uma janela do sistema, e
/// abri-la numa suíte a poria na cara de quem está usando a máquina — que é a
/// mesma razão de este projeto nunca dirigir a interface com evento sintético.
/// O que se verifica é o que o painel **de cor da barra** desenha, e a
/// aritmética da cor livre, que é pura e mora em `ColorHexTests`.
@Suite("Paleta com caminho livre")
@MainActor
struct FreeColorPanelTests {

    private static let size = CGSize(width: 820, height: 620)

    private func window(_ panel: ComposerToolbar.Panel?) async -> NSBitmapImageRep? {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        return Render.snapshot(
            ComposerWindow(store: store, mode: .new(accountID: nil), debugOpenPanel: panel),
            named: panel.map { "paleta-\($0)" } ?? "paleta-fechada",
            size: Self.size, theme: .tinta
        )
    }

    /// A caixa que envolve o que mudou entre o painel fechado e o aberto.
    private func openedPanelBox(
        _ panel: ComposerToolbar.Panel
    ) async throws -> DifferenceBox {
        let closed = try #require(await window(nil))
        let open = try #require(await window(panel))
        return try #require(DifferenceBox(open, closed), "o painel não desenhou nada")
    }

    /// Quantas linhas do cartão, numa coluna que o atravessa, estão no token
    /// `surface`.
    ///
    /// **Não é a altura da caixa de diferença**, e a diferença entre as duas
    /// medidas foi o que fez a primeira versão deste teste passar com o item
    /// de cor livre arrancado: o cartão tem `box-shadow: 0 10px 12px`, e a
    /// sombra sozinha estica a caixa em ~30pt. Medido, com o item removido de
    /// propósito: caixa de **80pt** contra os 117 do cartão inteiro — e o corte
    /// que eu tinha posto era 55.
    ///
    /// O papel do cartão é opaco e a sombra não é. Contar as linhas opacas
    /// mede o cartão e ignora a sombra: **38** sem o item, **66 a 69** com ele.
    private func opaqueRows(
        of box: DifferenceBox, in image: NSBitmapImageRep, theme: Theme
    ) -> Int {
        guard let surface = theme.surface.nsColor.usingColorSpace(.deviceRGB) else { return 0 }
        let column = box.x.lowerBound + box.width / 2
        var rows = 0
        for y in box.y {
            guard let pixel = image.colorAt(x: column, y: y)?.usingColorSpace(.deviceRGB) else {
                continue
            }
            // Tolerância apertada: em `tinta`, `surface` e `btn` diferem 0,02.
            if abs(pixel.redComponent - surface.redComponent) < 0.008,
               abs(pixel.greenComponent - surface.greenComponent) < 0.008,
               abs(pixel.blueComponent - surface.blueComponent) < 0.008 {
                rows += 1
            }
        }
        return rows
    }

    /// Só as seis amostras medem 22pt de altura mais 6 de folga em cima e
    /// embaixo. Com a divisória e o item "Outra cor…" o cartão quase dobra. É
    /// essa diferença que prova que o caminho livre está no painel — e é ela
    /// que some se alguém tirar o item de volta.
    @Test("o painel de cor tem as seis do design e o caminho livre embaixo", arguments: [
        ComposerToolbar.Panel.color, .highlight,
    ])
    func panelCarriesFreeRow(panel: ComposerToolbar.Panel) async throws {
        let open = try #require(await window(panel))
        let box = try await openedPanelBox(panel)
        let rows = opaqueRows(of: box, in: open, theme: .tinta)
        let complaint = "o cartão tem \(rows) linhas de papel: cabe a fileira de amostras "
            + "e mais nada, o item de cor livre sumiu"
        #expect(rows > 50, "\(complaint)")
        // E a largura continua a da fileira de seis (6×22 + 5×4 + 12 = 164),
        // com folga para a sombra: o item novo entrou **embaixo**, sem alargar
        // o cartão nem empurrar as amostras.
        #expect(box.width > 150 && box.width < 220, "o cartão mede \(box.width)pt de largura")
    }

    /// A paleta em si não mudou — as seis do protótipo continuam as seis do
    /// protótipo, na ordem dele. Somar não é trocar.
    @Test("as seis cores e os seis realces do protótipo continuam intactos")
    func prototypePaletteUnchanged() {
        #expect(ComposerFormatting.textColors.map(\.hex) == [
            "#241F18", "#B4562A", "#8E2020", "#2F4B7C", "#4C6B45", "#6C6D80",
        ])
        #expect(ComposerFormatting.highlights.map(\.hex) == [
            "transparent", "#FBEFA6", "#CFEBD6", "#FBD9CF", "#D6E3F7", "#EBDDF7",
        ])
    }
}

/// O botão de assinatura, que o protótipo não tem.
///
/// A regra de inserção é pura e está em `SignatureTests`, no `UNICore`. O que
/// mora aqui é o que só a `View` responde: o botão coube no rodapé sem quebrar
/// a linha, e a legenda da linha "De" passou a dizer de qual conta é a
/// assinatura.
@Suite("Botão de assinatura")
@MainActor
struct SignatureButtonTests {

    private func footerFits(width: CGFloat, mode: ComposerWindow.Mode) async -> CGFloat {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let host = NSHostingView(
            rootView: ComposerWindow(store: store, mode: mode)
                .theme(.tinta)
                .frame(width: width, height: 620)
        )
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.width
    }

    /// O rodapé da 03 é o apertado: 📎, assinatura, Enviar, Enviar e arquivar,
    /// Salvar, carimbo e Voltar ao painel. Se o botão novo não coubesse, a
    /// hierarquia pediria mais largura do que os 820 do protótipo.
    @Test("o botão cabe no rodapé das duas janelas, na largura do protótipo", arguments: [
        ComposerWindow.Mode.new(accountID: nil), .reply(messageID: "m1"),
    ])
    func fitsInFooter(mode: ComposerWindow.Mode) async {
        let asked = await footerFits(width: 820, mode: mode)
        #expect(asked <= 820, "a janela pede \(asked)pt de largura: o rodapé não cabe em 820")
    }

    /// A legenda do protótipo era uma frase fixa — "a assinatura muda com a
    /// conta" — e nada mudava com a conta. Agora ela nomeia a assinatura da
    /// conta escolhida, que é o que o botão vai inserir.
    @Test("a legenda da linha De muda junto com a conta")
    func noteFollowsTheAccount() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let first = try #require(store.accounts.first)
        let other = try #require(store.accounts.dropFirst().first)

        func note(_ account: Account) -> String {
            let line = account.signature.split(separator: "\n", maxSplits: 1).first.map(String.init)
            return "assinatura: \(line ?? "")"
        }
        #expect(note(first) != note(other))

        // E o desenho muda de verdade quando a conta muda: duas janelas
        // semeadas em contas diferentes não desenham a mesma linha "De".
        func draw(_ id: String) -> NSBitmapImageRep? {
            Render.snapshot(
                ComposerWindow(store: store, mode: .new(accountID: id)),
                named: "de-\(id)", size: CGSize(width: 820, height: 620), theme: .tinta
            )
        }
        let a = try #require(draw(first.id))
        let b = try #require(draw(other.id))
        var changed = 0
        for y in 45..<80 {
            for x in 0..<820 where a.colorAt(x: x, y: y) != b.colorAt(x: x, y: y) { changed += 1 }
        }
        #expect(changed > 200, "só \(changed) pixels mudaram na linha De ao trocar de conta")
    }

    /// Controle mudo é defeito. Sem assinatura na conta e com a assinatura já
    /// inserida, o botão apaga — e as duas recusas são a mesma regra pura que
    /// o `UNICore` já trava. O que se verifica aqui é que a janela pergunta.
    @Test("o botão apaga quando não há o que inserir")
    func disabledWhenNothingToInsert() throws {
        let account = try #require(Fixtures.accounts.first)
        #expect(Signature.canInsert(account.signature, into: ""))
        #expect(!Signature.canInsert("", into: "texto"))

        var body = AttributedString("texto")
        Signature.insert(account.signature, into: &body)
        #expect(!Signature.canInsert(account.signature, into: String(body.characters)))
    }

    /// **O botão insere.** Era o que faltava: a revisão gutou
    /// `insertSignature()` para `return` e a suíte inteira continuou verde,
    /// porque os dois testes que diziam cobrir o botão só chamavam a regra pura
    /// de `UNICore` (já travada em `SignatureTests`) e comparavam pixels de uma
    /// faixa que muda de conta para conta por outros motivos.
    ///
    /// Aqui corre a ação do botão dentro da janela de verdade, e o que se afirma
    /// é o **texto que sai no `NSTextStorage`** — o que o editor desenha.
    @Test("o botão insere a assinatura da conta no fim do corpo")
    func insertsIntoTheStorage() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let account = try #require(store.accounts.first { !$0.signature.isEmpty })
        let expected = account.signature.trimmingCharacters(in: .whitespacesAndNewlines)
        try #require(!expected.isEmpty)

        var inserted: String?
        var untouched: String?
        EditorProbe.withHostedView(
            ComposerWindow(
                store: store, mode: .new(accountID: account.id), debugInsertSignature: true
            ),
            size: CGSize(width: 820, height: 620), theme: .tinta
        ) { content in
            inserted = EditorProbe.anyTextView(in: content)?.string
        }
        // A mesma janela sem apertar o botão: a assinatura não aparece sozinha.
        EditorProbe.withHostedView(
            ComposerWindow(store: store, mode: .new(accountID: account.id)),
            size: CGSize(width: 820, height: 620), theme: .tinta
        ) { content in
            untouched = EditorProbe.anyTextView(in: content)?.string
        }

        let text = try #require(inserted)
        #expect(text.hasSuffix(expected), "o corpo terminou em «\(text)»")
        #expect(untouched?.contains(expected) == false, "a assinatura apareceu sem o botão")
    }

    /// E ela entra **com atributo**, não como texto cru: o estilo do fim do
    /// corpo, sem herdar o realce. `Signature.style(endingIn:)` decide isso, e
    /// a janela tem de passar por lá — inserir sem estilo sai em Newsreader 15
    /// no meio de um corpo escrito em outro corpo.
    @Test("a assinatura inserida carrega o estilo do fim do corpo, sem o realce")
    func insertedSignatureCarriesTheStyle() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let account = try #require(store.accounts.first { !$0.signature.isEmpty })
        let expected = account.signature.trimmingCharacters(in: .whitespacesAndNewlines)

        var style: BodyStyle?
        var face: NSFont?
        EditorProbe.withHostedView(
            ComposerWindow(
                store: store, mode: .new(accountID: account.id), debugInsertSignature: true
            ),
            size: CGSize(width: 820, height: 620), theme: .tinta
        ) { content in
            guard let view = EditorProbe.anyTextView(in: content),
                  let storage = view.textStorage,
                  storage.length >= expected.count else { return }
            let at = storage.length - expected.count
            style = ComposerTextKit.model(storage).runs.last
                .map { RichBody.style(of: $0.attributes) }
            face = storage.attribute(.font, at: at, effectiveRange: nil) as? NSFont
        }

        let written = try #require(style)
        #expect(written.highlightHex == BodyStyle.noHighlight)
        #expect(written.size == BodyStyle.defaultSize)
        // E o trecho tem fonte de verdade no storage, não o atributo ausente que
        // um `append` de texto cru deixaria.
        #expect(face != nil)
    }
}
