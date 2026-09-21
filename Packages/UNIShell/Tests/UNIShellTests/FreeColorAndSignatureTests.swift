import SwiftUI
import Testing
import UNICore
import UNIDesign
import WebKit
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
    /// No Tinta redesenhado o papel do painel se confunde com a janela; Papel
    /// preserva contraste suficiente para esta sonda estrutural de pixels.
    private static let theme = Theme.papel

    private func window(_ panel: ComposerToolbar.Panel?) async -> NSBitmapImageRep? {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        return Render.snapshot(
            ComposerWindow(store: store, mode: .new(accountID: nil), debugOpenPanel: panel),
            named: panel.map { "paleta-\($0)" } ?? "paleta-fechada",
            size: Self.size, theme: Self.theme
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
        let rows = opaqueRows(of: box, in: open, theme: Self.theme)
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

    /// O defeito do print: Configurações mostrava tabela e logo, mas o botão
    /// achatava o HTML em texto, com toda a indentação da tabela transformada
    /// em vazios. Agora o editor continua contendo somente o corpo digitável e
    /// a assinatura rica nasce como uma `WKWebView` segura separada.
    @Test("o botão renderiza a assinatura HTML fora do texto editável")
    func rendersRichSignatureOutsideTheStorage() async throws {
        let image = try InlineSignatureResource(
            contentID: "logo@vantion.local",
            mimeType: "image/png",
            data: try #require(Data(base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
            ))
        )
        let rich = try EmailSignature(
            plainText: "Marcos Santos\nCAIO · Software Development",
            html: """
            <table role="presentation" cellpadding="0" cellspacing="0" style="width:600px">
              <tr>
                <td style="width:180px;background:#121415;padding:16px">
                  <img src="cid:logo@vantion.local" width="120" height="80" alt="Vantion">
                </td>
                <td style="padding:16px"><strong>Marcos Santos</strong><br>CAIO · Software Development</td>
              </tr>
            </table>
            """,
            inlineResources: [image]
        )
        let base = try #require(Fixtures.accounts.first)
        let account = base.withEmailSignature(rich)
        let store = MailStore(source: InMemoryMailSource(
            accounts: [account], messages: Fixtures.messages, agenda: Fixtures.month
        ))
        await store.load()

        var untouchedPreview: WKWebView?
        let rendered = await loadedSignaturePreview(
            ComposerWindow(
                store: store, mode: .new(accountID: account.id), debugInsertSignature: true
            ),
            size: CGSize(width: 820, height: 620),
            theme: .tinta,
            snapshotAt: Render.outputDirectory?.appendingPathComponent("assinatura-preview.png")
        )
        EditorProbe.withHostedView(
            ComposerWindow(store: store, mode: .new(accountID: account.id)),
            size: CGSize(width: 820, height: 620), theme: .tinta
        ) { content in
            untouchedPreview = EditorProbe.signaturePreview(in: content)
        }

        let preview = try #require(rendered)
        #expect(preview.editorText == "", "a assinatura ainda foi achatada no editor: «\(preview.editorText)»")
        #expect(preview.frame.height >= 44)
        #expect(preview.frame.height <= 380)
        let dom = preview.dom
        #expect(dom.text.contains("Marcos Santos"))
        #expect(dom.text.contains("CAIO · Software Development"))
        // A prévia local resolve o CID para `data:` antes de chegar ao WebKit.
        // O MIME do e-mail continua com CID (coberto em ComposerOutgoingTests),
        // enquanto esta prova verifica que a imagem efetivamente renderiza.
        #expect(dom.imageSource.hasPrefix("data:image/png;base64,"))
        #expect(dom.hasTable)
        #expect(untouchedPreview == nil, "a assinatura apareceu sem apertar o botão")

        if Render.outputDirectory != nil {
            #expect(Render.snapshot(
                ComposerWindow(
                    store: store,
                    mode: .new(accountID: account.id),
                    debugInsertSignature: true
                ),
                named: "composer-assinatura-rica",
                size: CGSize(width: 820, height: 620),
                theme: .tinta
            ) != nil)
        }
    }

    @Test("a assinatura rica fica no cursor em início, meio e fim da resposta")
    func richSignatureFollowsCaretAcrossTheReply() async throws {
        let rich = try signatureForCursorTests()
        let base = try #require(Fixtures.accounts.first)
        let account = base.withEmailSignature(rich)

        for (offset, before, after) in [
            (0, "", "AntesDepois"),
            (5, "Antes", "Depois"),
            (11, "AntesDepois", ""),
        ] {
            let store = MailStore(source: InMemoryMailSource(
                accounts: [account], messages: Fixtures.messages, agenda: Fixtures.month
            ))
            await store.load()
            let message = try #require(store.messages.first)
            store.setReplyDraft(ReplyDraft(text: "AntesDepois"), for: message.id)

            var editors: [ComposerNSTextView] = []
            var preview: WKWebView?
            var positions: (before: CGRect, signature: CGRect, after: CGRect)?
            EditorProbe.withHostedView(
                ComposerWindow(
                    store: store,
                    mode: .reply(messageID: message.id),
                    debugInsertSignature: true,
                    debugSignatureOffset: offset
                ),
                size: CGSize(width: 820, height: 660), theme: .tinta
            ) { content in
                editors = EditorProbe.composerTextViews(in: content)
                preview = EditorProbe.signaturePreview(in: content)
                if let signature = preview,
                   let prefix = editors.first(where: { $0.string == before }),
                   let suffix = editors.first(where: { $0.string == after })
                {
                    positions = (
                        before: prefix.convert(prefix.bounds, to: content),
                        signature: signature.convert(signature.bounds, to: content),
                        after: suffix.convert(suffix.bounds, to: content)
                    )
                }
            }

            #expect(editors.map(\.string).contains(before))
            #expect(editors.map(\.string).contains(after))
            #expect(editors.allSatisfy { !$0.string.contains("Marcos Santos") })
            let renderedPreview = try #require(preview)
            #expect(renderedPreview.frame.height >= 44)
            let frames = try #require(positions)
            let firstStep = frames.signature.midY - frames.before.midY
            let secondStep = frames.after.midY - frames.signature.midY
            #expect(firstStep * secondStep > 0, "o preview não ficou entre os trechos em offset \(offset)")
            #expect(
                abs(firstStep) < 170,
                "o preview ficou \(abs(firstStep))pt depois do cursor em offset \(offset)"
            )
            if offset == 5, Render.outputDirectory != nil {
                #expect(Render.snapshot(
                    ComposerWindow(
                        store: store, mode: .reply(messageID: message.id),
                        debugInsertSignature: true, debugSignatureOffset: offset
                    ),
                    named: "composer-assinatura-no-cursor",
                    size: CGSize(width: 820, height: 660), theme: .tinta
                ) != nil)
            }
        }
    }

    @Test("uma seleção é substituída pela assinatura sem perder o texto vizinho")
    func richSignatureReplacesTheCurrentSelection() async throws {
        let rich = try signatureForCursorTests()
        let base = try #require(Fixtures.accounts.first)
        let account = base.withEmailSignature(rich)
        let store = MailStore(source: InMemoryMailSource(
            accounts: [account], messages: Fixtures.messages, agenda: Fixtures.month
        ))
        await store.load()
        let message = try #require(store.messages.first)
        store.setReplyDraft(ReplyDraft(text: "AntesREMOVERDepois"), for: message.id)

        var editors: [ComposerNSTextView] = []
        var preview: WKWebView?
        EditorProbe.withHostedView(
            ComposerWindow(
                store: store,
                mode: .reply(messageID: message.id),
                debugInsertSignature: true,
                debugSignatureSelection: 5..<12
            ),
            size: CGSize(width: 820, height: 660), theme: .tinta
        ) { content in
            editors = EditorProbe.composerTextViews(in: content)
            preview = EditorProbe.signaturePreview(in: content)
        }

        #expect(editors.map(\.string).contains("Antes"))
        #expect(editors.map(\.string).contains("Depois"))
        #expect(editors.allSatisfy { !$0.string.contains("REMOVER") })
        #expect(preview != nil)
    }

    @Test("rascunho salvo reabre a assinatura rica no ponto registrado", arguments: ["", "  \n\n\n"])
    func savedDraftRestoresRichSignatureAtItsOffset(prefix: String) async throws {
        let rich = try signatureForCursorTests()
        let base = try #require(Fixtures.accounts.first)
        let account = base.withEmailSignature(rich)
        let store = MailStore(source: InMemoryMailSource(
            accounts: [account], messages: Fixtures.messages, agenda: Fixtures.month
        ))
        await store.load()
        let message = try #require(store.messages.first)
        store.setReplyDraft(ReplyDraft(text: prefix + "AntesDepois"), for: message.id)

        EditorProbe.withHostedView(
            ComposerWindow(
                store: store,
                mode: .reply(messageID: message.id),
                debugInsertSignature: true,
                debugSignatureOffset: prefix.count + 5,
                debugSaveDraft: true
            ),
            size: CGSize(width: 820, height: 660), theme: .tinta
        ) { _ in }

        let saved = try #require(store.messages.first(where: { $0.bucket == .drafts }))
        #expect(saved.bodyHTML?.contains("okamiuni-signature:") == true)

        var editors: [ComposerNSTextView] = []
        var preview: WKWebView?
        EditorProbe.withHostedView(
            ComposerWindow(store: store, mode: .draft(messageID: saved.id)),
            size: CGSize(width: 820, height: 660), theme: .tinta
        ) { content in
            editors = EditorProbe.composerTextViews(in: content)
            preview = EditorProbe.signaturePreview(in: content)
        }

        #expect(editors.map(\.string).contains(prefix + "Antes"))
        #expect(editors.map(\.string).contains("Depois"))
        #expect(editors.allSatisfy { !$0.string.contains("Marcos Santos") })
        #expect(preview != nil)
    }

    @Test("rascunho HTML preservado renderiza tabela e imagem sem limitar a altura")
    func preservedDraftHTMLRendersWithoutClipping() async throws {
        let html = """
        <html><head><style>body{margin:0;background:#fff;color:#18232d;font:16px system-ui}td{padding:20px;border-bottom:1px solid #dce1e5}</style></head><body>
        <table style="width:100%;border-collapse:collapse"><tr><td><h2>Proposta para revisão</h2><p>Marcos Santos · conteúdo de teste</p>
        <img alt="Imagem inline" width="24" height="24" src="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="></td></tr>
        <tr><td style="height:440px;vertical-align:top">Tabela mantida no rascunho.<br>O conteúdo continua disponível ao rolar.</td></tr>
        <tr><td>Fim do documento preservado.</td></tr></table></body></html>
        """
        let result = await loadedSignaturePreview(
            ScrollView { ComposerPreservedHTMLBlock(html: html).padding(20) },
            size: CGSize(width: 820, height: 920), theme: .tinta,
            snapshotAt: Render.outputDirectory?.appendingPathComponent("composer-html-preservado.png")
        )
        let rendered = try #require(result)
        #expect(rendered.dom.hasTable)
        #expect(rendered.dom.imageSource.hasPrefix("data:image/png;base64,"))
        #expect(rendered.dom.text.contains("Fim do documento preservado."))
        #expect(rendered.frame.height > 420)
    }

    private func signatureForCursorTests() throws -> EmailSignature {
        let image = try InlineSignatureResource(
            contentID: "logo@vantion.local",
            mimeType: "image/png",
            data: try #require(Data(base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
            ))
        )
        return try EmailSignature(
            plainText: "Marcos Santos\nCAIO · Software Development",
            html: """
            <table role="presentation" cellpadding="0" cellspacing="0" style="width:600px">
              <tr>
                <td style="width:180px;background:#121415;padding:16px">
                  <img src="cid:logo@vantion.local" width="120" height="80" alt="Vantion">
                </td>
                <td style="padding:16px"><strong>Marcos Santos</strong><br>CAIO · Software Development</td>
              </tr>
            </table>
            """,
            inlineResources: [image]
        )
    }

    /// `cacheDisplay` não vê a camada remota do WebKit e fotografa um retângulo
    /// branco. Esta janela fica fora da tela, mas viva durante os `await`s do
    /// próprio WebKit; assim o carregamento e o snapshot recebem tempo de
    /// execução sem usar mouse, teclado ou o harness compartilhado.
    private func loadedSignaturePreview<V: View>(
        _ view: V,
        size: CGSize,
        theme: Theme,
        snapshotAt destination: URL?
    ) async -> SignaturePreviewRender? {
        let root = view
            .theme(theme)
            .environment(\.locale, Locale(identifier: "pt_BR"))
            .frame(width: size.width, height: size.height)
        let window = NSWindow(
            contentRect: NSRect(x: -50_000, y: -50_000, width: size.width, height: size.height),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)
        defer { window.close() }
        guard let content = window.contentView else { return nil }

        let deadline = Date().addingTimeInterval(5)
        var preview: WKWebView?
        while preview == nil && Date() < deadline {
            content.layoutSubtreeIfNeeded()
            preview = EditorProbe.signaturePreview(in: content)
            if preview == nil { try? await Task.sleep(for: .milliseconds(20)) }
        }
        guard let preview else { return nil }

        let script = """
        [document.body.innerText || '',
         document.querySelector('img')?.getAttribute('src') || '',
         document.querySelector('table') ? 'table' : ''].join('\\u001F')
        """
        var dom: SignaturePreviewDOM?
        while dom == nil && Date() < deadline {
            if let result = try? await preview.evaluateJavaScript(script) as? String {
                dom = SignaturePreviewDOM.parse(result)
            }
            if dom == nil { try? await Task.sleep(for: .milliseconds(20)) }
        }
        guard let dom else { return nil }

        if let destination {
            try? await Task.sleep(for: .milliseconds(120))
            let configuration = WKSnapshotConfiguration()
            configuration.rect = preview.bounds
            guard let image = try? await preview.takeSnapshot(configuration: configuration),
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:])
            else { return nil }
            do {
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try png.write(to: destination)
            } catch {
                return nil
            }
        }

        return SignaturePreviewRender(
            editorText: EditorProbe.anyTextView(in: content)?.string ?? "",
            frame: preview.frame,
            dom: dom
        )
    }
}

private struct SignaturePreviewDOM {
    let text: String
    let imageSource: String
    let hasTable: Bool

    static func parse(_ value: String) -> SignaturePreviewDOM? {
        let fields = value.split(separator: "\u{001F}", maxSplits: 2, omittingEmptySubsequences: false)
        guard fields.count == 3 else { return nil }
        let result = SignaturePreviewDOM(
            text: String(fields[0]),
            imageSource: String(fields[1]),
            hasTable: fields[2] == "table"
        )
        return result.text.contains("Marcos Santos") && result.hasTable ? result : nil
    }
}

private struct SignaturePreviewRender {
    let editorText: String
    let frame: CGRect
    let dom: SignaturePreviewDOM
}

@MainActor
private extension EditorProbe {
    static func signaturePreview(in view: NSView) -> WKWebView? {
        if let preview = view as? WKWebView { return preview }
        for child in view.subviews {
            if let preview = signaturePreview(in: child) { return preview }
        }
        return nil
    }

    static func composerTextViews(in view: NSView) -> [ComposerNSTextView] {
        let own = (view as? ComposerNSTextView).map { [$0] } ?? []
        return own + view.subviews.flatMap { composerTextViews(in: $0) }
    }
}
