import AppKit
import Foundation
import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

@Suite("Faixa de resposta rápida — abertura e retorno")
struct QuickReplyBandStateTests {

    private static let sender = Contact(name: "Marina Duarte", address: "marina@clientepremium.com")

    @Test("sem rascunho, a faixa nasce aberta e já com o remetente no Para")
    func freshBandStartsOpen() {
        #expect(QuickReplyBand.opensExpanded(for: nil))
        #expect(
            QuickReplyBand.seededRecipients(draft: nil, sender: Self.sender)
                .map(\.address) == ["marina@clientepremium.com"]
        )
    }

    @Test("depois de 'Enviar' a faixa volta fechada, mostrando o que guardou")
    func afterSendItStaysClosed() {
        let sent = ReplyDraft(
            to: [Self.sender], body: AttributedString("Fecho quinta."),
            savedAt: Date(timeIntervalSince1970: 1_000),
            sentAt: Date(timeIntervalSince1970: 1_000)
        )
        #expect(QuickReplyBand.opensExpanded(for: sent) == false)
    }

    /// O defeito que este teste impede: "Salvar" e "Enviar" carimbavam o mesmo
    /// campo, então salvar e voltar à mensagem depois reabria a faixa fechada,
    /// dizendo que a resposta estava pronta para envio quando ninguém tinha
    /// apertado "Enviar".
    @Test("'Salvar' carimba mas não fecha: a faixa reabre aberta")
    func savedButNotSentReopensOpen() {
        let saved = ReplyDraft(
            to: [Self.sender], body: AttributedString("Fecho qui"),
            savedAt: Date(timeIntervalSince1970: 1_000)
        )
        #expect(saved.sentAt == nil)
        #expect(QuickReplyBand.opensExpanded(for: saved))
    }

    @Test("rascunho ainda não guardado reabre aberto, no ponto em que parou")
    func unsavedDraftReopensOpen() {
        let typing = ReplyDraft(to: [Self.sender], text: "Fecho qui", savedAt: nil)
        #expect(QuickReplyBand.opensExpanded(for: typing))
        #expect(
            QuickReplyBand.seededRecipients(draft: typing, sender: Self.sender)
                .map(\.address) == ["marina@clientepremium.com"]
        )
    }

    @Test("quem apagou o destinatário não o recebe de volta")
    func clearedRecipientStaysCleared() {
        let emptied = ReplyDraft(to: [], text: "para quem eu decidir depois", savedAt: nil)
        #expect(QuickReplyBand.seededRecipients(draft: emptied, sender: Self.sender).isEmpty)
    }

    @Test("o retorno do 'Enviar' diz o que o marco fez e o que não fez")
    func sentNoteIsExplicit() {
        #expect(
            QuickReplyBand.sentNote(words: "4 palavras", stamp: "14:32", archived: false)
                == "Pronta para envio — 4 palavras · 14:32 · sem rede neste marco"
        )
        #expect(
            QuickReplyBand.sentNote(words: "4 palavras", stamp: "14:32", archived: true)
                == "Pronta para envio, original arquivada — 4 palavras · 14:32 · sem rede neste marco"
        )
    }
}

/// As quatro ações do rodapé do protótipo (tela 01, linha 1319): 📎, "Enviar",
/// "Enviar e arquivar" e "Salvar".
///
/// Botão mudo é defeito — foi o que originou esta rodada. Aqui se prova, sem
/// clique e sem abrir o app, que cada um ou muda o estado de verdade ou fica
/// desabilitado por um motivo que dá para dizer em voz alta.
@Suite("Faixa de resposta rápida — as quatro ações do rodapé")
struct QuickReplyBandActionTests {

    private static let marina = Contact(name: "Marina Duarte", address: "marina@clientepremium.com")

    private static func written(_ text: String) -> ReplyDraft {
        ReplyDraft(to: [marina], body: AttributedString(text))
    }

    @Test("sem destinatário ou sem texto, os dois 'Enviar' ficam desabilitados")
    func sendNeedsRecipientAndText() {
        #expect(QuickReply.canSend(Self.written("Fecho quinta.")))
        #expect(QuickReply.canSend(ReplyDraft(to: [], body: AttributedString("Fecho quinta."))) == false)
        #expect(QuickReply.canSend(ReplyDraft(to: [Self.marina], body: AttributedString("   \n "))) == false)
        #expect(QuickReply.canSend(ReplyDraft()) == false)
    }

    @Test("'Salvar' exige algo novo para salvar")
    func saveNeedsSomethingNew() {
        #expect(QuickReply.canSave(Self.written("Fecho quinta.")))
        // Só um anexo, sem uma palavra escrita, ainda é algo a guardar.
        var onlyFile = ReplyDraft(to: [Self.marina])
        onlyFile.attachments = ["contrato-v4.pdf"]
        #expect(QuickReply.canSave(onlyFile))
        // Nada escrito e nada anexado: não há o que salvar.
        #expect(QuickReply.canSave(ReplyDraft(to: [Self.marina])) == false)
        // Já carimbado: o botão apaga em vez de recarimbar o mesmo texto.
        let stamped = QuickReply.saved(Self.written("Fecho quinta."), at: Date(timeIntervalSince1970: 10))
        #expect(QuickReply.canSave(stamped) == false)
    }

    @Test("'Salvar' carimba o rascunho e não finge que ele saiu")
    func saveStampsWithoutSending() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let saved = QuickReply.saved(Self.written("Fecho quinta."), at: now)
        #expect(saved.savedAt == now)
        #expect(saved.sentAt == nil)
        #expect(saved.archivedOriginal == false)
        // E o rótulo da linha de baixo deixa de dizer "não salvo".
        #expect(DraftMeta.savedLabel("14:32") == "rascunho salvo 14:32")
    }

    @Test("editar o corpo apaga os dois carimbos — eles deixaram de ser verdade")
    func editingClearsBothStamps() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let sent = QuickReply.sent(Self.written("Fecho quinta."), archiving: true, at: now)
        let edited = QuickReply.edited(sent)
        #expect(edited.savedAt == nil)
        #expect(edited.sentAt == nil)
        // Arquivar não se desfaz digitando: a mensagem já saiu da caixa.
        #expect(edited.archivedOriginal)
    }

    @Test("o 📎 anexa o próximo da lista e para quando ela acaba")
    func attachWalksTheCatalog() {
        let catalog = ["contrato-v4.pdf", "planilha.xlsx"]
        let one = QuickReply.attaching(Self.written("Segue."), from: catalog)
        #expect(one.attachments == ["contrato-v4.pdf"])
        let two = QuickReply.attaching(one, from: catalog)
        #expect(two.attachments == ["contrato-v4.pdf", "planilha.xlsx"])
        // Sem nada sobrando, devolve o rascunho intacto — e a faixa desabilita.
        let three = QuickReply.attaching(two, from: catalog)
        #expect(three.attachments == ["contrato-v4.pdf", "planilha.xlsx"])
    }
}

@Suite("Faixa de resposta rápida — 'Enviar e arquivar' arquiva de verdade")
@MainActor
struct QuickReplyBandSendTests {

    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func loaded() async -> MailStore {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        store.select(message: "m1")
        return store
    }

    private func draft(to message: Message) -> ReplyDraft {
        ReplyDraft(to: [message.from], body: AttributedString("Quinta às 15h está de pé."))
    }

    /// A metade real do botão. Não é simulação: a mensagem muda de caixa no
    /// `MailStore`, sai da visão "Hoje" e a seleção passa para outra.
    @Test("'Enviar e arquivar' move a original para Arquivado")
    func sendAndArchiveMovesTheMessage() async throws {
        let store = await loaded()
        let message = try #require(store.messages.first { $0.id == "m1" })
        #expect(message.bucket != .archived)

        let updated = QuickReplyBand.send(
            draft(to: message), for: message, in: store, archiving: true, at: Self.now
        )

        #expect(updated.sentAt == Self.now)
        #expect(updated.archivedOriginal)
        let after = try #require(store.messages.first { $0.id == "m1" })
        #expect(after.bucket == .archived)
        // E o leitor não fica apontando para uma mensagem que saiu da caixa.
        #expect(store.selectedMessageID != "m1")
    }

    @Test("'Enviar' sozinho não mexe na caixa da mensagem")
    func plainSendLeavesTheBucketAlone() async throws {
        let store = await loaded()
        let message = try #require(store.messages.first { $0.id == "m1" })
        let bucketBefore = message.bucket

        let updated = QuickReplyBand.send(
            draft(to: message), for: message, in: store, archiving: false, at: Self.now
        )

        #expect(updated.sentAt == Self.now)
        #expect(updated.archivedOriginal == false)
        let after = try #require(store.messages.first { $0.id == "m1" })
        #expect(after.bucket == bucketBefore)
        #expect(after.bucket != .archived)
        #expect(store.selectedMessageID == "m1")
    }

    @Test("o que foi enviado fica no store, para a faixa fechada e o ⤢ acharem")
    func sendPersistsTheDraft() async throws {
        let store = await loaded()
        let message = try #require(store.messages.first { $0.id == "m1" })

        QuickReplyBand.send(
            draft(to: message), for: message, in: store, archiving: false, at: Self.now
        )

        let stored = try #require(store.replyDraft(for: "m1"))
        #expect(stored.sentAt == Self.now)
        #expect(stored.text == "Quinta às 15h está de pé.")
        #expect(QuickReplyBand.opensExpanded(for: stored) == false)
    }

    /// O botão desabilitado não é decorativo: mesmo que alguém o alcance por
    /// atalho, a ação recusa e nada muda.
    @Test("sem destinatário, o envio não carimba nem arquiva")
    func sendWithoutRecipientDoesNothing() async throws {
        let store = await loaded()
        let message = try #require(store.messages.first { $0.id == "m1" })
        let empty = ReplyDraft(to: [], body: AttributedString("Quinta às 15h está de pé."))

        let updated = QuickReplyBand.send(
            empty, for: message, in: store, archiving: true, at: Self.now
        )

        #expect(updated.sentAt == nil)
        #expect(updated.archivedOriginal == false)
        let after = try #require(store.messages.first { $0.id == "m1" })
        #expect(after.bucket != .archived)
        #expect(store.replyDraft(for: "m1") == nil)
    }
}

/// O corpo da faixa é `AttributedString` desde esta tarefa. Estes testes travam
/// as duas coisas que isso tinha de comprar: a barra age sobre a **seleção**, e
/// o que foi formatado sobrevive à travessia até a janela.
@Suite("Faixa de resposta rápida — o corpo é texto rico")
@MainActor
struct QuickReplyBandRichBodyTests {

    private static let marina = Contact(name: "Marina Duarte", address: "marina@clientepremium.com")

    private static func message() -> Message {
        Message(
            id: "m1", accountID: "a1", from: marina,
            receivedAt: Date(timeIntervalSince1970: 1_700_000_000),
            subject: "Contrato", snippet: "", body: ["corpo"], tags: [],
            bucket: .today, isRead: true, summary: nil, detectedEvent: nil
        )
    }

    /// A barra da faixa é a mesma da janela: emite `ComposerCommand`, e quem
    /// aplica é `ComposerEditor`, sobre o intervalo selecionado.
    @Test("negritar só o trecho selecionado deixa o resto do corpo em texto normal")
    func boldHitsOnlyTheSelection() throws {
        var body = AttributedString("Fecho quinta às 15h")
        ComposerEditor.decorate(&body, theme: .tinta)

        let characters = body.characters
        let start = characters.index(characters.startIndex, offsetBy: 6)
        let end = characters.index(characters.startIndex, offsetBy: 12)
        var selection = AttributedTextSelection(range: start..<end)

        ComposerEditor.perform(.bold, on: &body, selection: &selection, theme: .tinta)

        let bolded = body.runs
            .filter { ($0.attributes[BodyStyleAttribute.self] ?? .default).bold }
            .map { String(body[$0.range].characters) }
            .joined()
        #expect(bolded == "quinta")
        // E o corpo inteiro não virou negrito de tabela — o defeito da Task W.
        #expect(String(body.characters) == "Fecho quinta às 15h")
        let plainRuns = body.runs
            .filter { !(($0.attributes[BodyStyleAttribute.self] ?? .default).bold) }
            .map { String(body[$0.range].characters) }
            .joined()
        #expect(plainRuns == "Fecho  às 15h")
    }

    @Test("a barra da faixa lê a seleção: um trecho já em negrito acende o B")
    func toolbarReadsTheSelection() throws {
        var body = AttributedString("Fecho quinta")
        ComposerEditor.decorate(&body, theme: .tinta)
        let characters = body.characters
        let start = characters.index(characters.startIndex, offsetBy: 6)
        var selection = AttributedTextSelection(range: start..<characters.endIndex)

        #expect(ComposerEditor.reading(of: body, selection: selection).bold == false)
        ComposerEditor.perform(.bold, on: &body, selection: &selection, theme: .tinta)
        #expect(ComposerEditor.reading(of: body, selection: selection).bold)
    }

    /// O `ReplyDraft` guarda o corpo rico, e é ele que o "⤢" entrega.
    /// `ComposerSeed.rich` chega com os atributos; `ComposerSeed.body`, que é a
    /// projeção em `String` que a janela ainda lê, chega **sem** — é a perda
    /// registrada no relatório da Task Z.
    @Test("o rascunho atravessa a fronteira com a formatação em ComposerSeed.rich")
    func draftCarriesFormattingToTheSeed() throws {
        var body = AttributedString("Fecho quinta")
        body[BodyStyleAttribute.self] = BodyStyle(bold: true, colorHex: "#8E2020")

        let draft = ReplyDraft(to: [Self.marina], body: body)
        let seed = ComposerSeed.reply(to: Self.message(), draft: draft)

        let style = try #require(seed.rich.runs.first?.attributes[BodyStyleAttribute.self])
        #expect(style.bold)
        #expect(style.colorHex == "#8E2020")
        #expect(seed.to.map(\.address) == ["marina@clientepremium.com"])
        #expect(seed.subject == "Re: Contrato")

        // A projeção em texto puro é a que perde — e é a que a janela lê hoje.
        #expect(seed.body == "Fecho quinta")
        #expect(AttributedString(seed.body).runs.first?.attributes[BodyStyleAttribute.self] == nil)
    }

    /// `Message.replyHints` é o `sel.replyHints` do protótipo, e este é o
    /// primeiro leitor dele. As fixtures trazem as dicas do design; o menu tem
    /// de mostrar **essas**, não uma lista nossa.
    @Test("o menu de rascunho sugerido lê replyHints da mensagem")
    func suggestedDraftsReadReplyHints() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let message = try #require(store.messages.first { !$0.replyHints.isEmpty })

        let drafts = QuickReply.suggestedDrafts(for: message)
        #expect(drafts.map(\.label) == message.replyHints)
        // E o que a dica escreve no corpo começa pelo tratamento e continua
        // pela dica — não é o rótulo repetido.
        let first = String(message.from.name.split(separator: " ")[0])
        #expect(drafts.allSatisfy { $0.text.hasPrefix("\(first), ") })
        #expect(drafts.allSatisfy { $0.text.count > $0.label.count })
    }

    @Test("mensagem sem replyHints não fica com um menu vazio")
    func suggestedDraftsComeFromTheMessage() {
        // `Self.message()` nasce com `replyHints: []`.
        let plain = QuickReply.suggestedDrafts(for: Self.message())
        #expect(plain.count == 2)
        #expect(plain.allSatisfy { $0.text.hasPrefix("Marina,") })

        let withEvent = Message(
            id: "m2", accountID: "a1", from: Self.marina,
            receivedAt: Date(timeIntervalSince1970: 1_700_000_000),
            subject: "Contrato", snippet: "", body: ["corpo"], tags: [],
            bucket: .today, isRead: true, summary: nil,
            detectedEvent: DetectedEvent(
                label: "Call de contrato · qui 27, 15:00",
                start: Date(timeIntervalSince1970: 1_700_000_000), duration: 3_600
            )
        )
        let drafts = QuickReply.suggestedDrafts(for: withEvent)
        #expect(drafts.map(\.label) == ["Confirmar", "Remarcar", "Peço um prazo"])
        #expect(drafts[0].text.contains("Call de contrato · qui 27, 15:00"))
    }
}

@Suite("Faixa de resposta rápida — o corpo continua legível")
@MainActor
struct QuickReplyBandRenderTests {

    private static let size = CGSize(width: 760, height: 780)

    /// Quantos pixels de tinta há na faixa horizontal entre `top` e `bottom`.
    ///
    /// É a pergunta "o corpo da mensagem continua aparecendo?" em forma de
    /// número: se a faixa de resposta tivesse comido o leitor, ou se o corpo
    /// tivesse ficado atrás dela, esta região seria fundo liso.
    private static func inkPixels(
        _ rep: NSBitmapImageRep, top: CGFloat, bottom: CGFloat,
        left: Int = 40, right: Int? = nil
    ) -> Int {
        let first = Int(CGFloat(rep.pixelsHigh) * top)
        let last = Int(CGFloat(rep.pixelsHigh) * bottom)
        var count = 0
        for y in stride(from: first, to: last, by: 2) {
            for x in stride(from: left, to: right ?? (rep.pixelsWide - 40), by: 2) {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                // Tema claro: a tinta do texto é escura sobre papel claro.
                if color.brightnessComponent < 0.55 { count += 1 }
            }
        }
        return count
    }

    /// Quantos pixels diferem entre dois desenhos, dentro de um retângulo.
    private static func differingPixels(
        _ a: NSBitmapImageRep, _ b: NSBitmapImageRep,
        x: ClosedRange<Int>, y: ClosedRange<Int>
    ) -> Int {
        var count = 0
        for row in y where row < min(a.pixelsHigh, b.pixelsHigh) {
            for column in x where column < min(a.pixelsWide, b.pixelsWide) {
                guard let left = a.colorAt(x: column, y: row),
                      let right = b.colorAt(x: column, y: row) else { continue }
                if abs(left.brightnessComponent - right.brightnessComponent) > 0.02 {
                    count += 1
                }
            }
        }
        return count
    }

    /// Quantos pixels de altura o cartão da faixa ocupa dentro do leitor.
    ///
    /// Medir a altura que a faixa **pede** (`fittingSize`) não responde à
    /// pergunta desta tarefa: um editor com `maxHeight` pede pouco e ocupa
    /// muito, e foi exatamente assim que a faixa comeu o corpo da mensagem.
    /// Aqui se mede o que ela **ocupa**, no desenho.
    ///
    /// Como: numa coluna à direita do texto do corpo (que é limitado a 500pt),
    /// o cartão pinta `surface2` e a página pinta `surface`. Sobe-se do rodapé
    /// até a cor voltar a ser a da página.
    private static func bandCardHeight(_ rep: NSBitmapImageRep) -> Int {
        let column = rep.pixelsWide - 36
        // Uma linha que é página nos dois estados: abaixo do cabeçalho e acima
        // do cartão de resumo.
        guard let page = rep.colorAt(x: column, y: 140) else { return 0 }
        // 16pt de `padding` embaixo do cartão são página; começa acima deles.
        let bottom = rep.pixelsHigh - 20
        var y = bottom
        while y > 0,
              let color = rep.colorAt(x: column, y: y),
              abs(color.brightnessComponent - page.brightnessComponent) > 0.004 {
            y -= 1
        }
        return bottom - y
    }

    private func reader(_ store: MailStore) -> some View {
        ReaderPane(store: store, onAddEvent: { _ in }, onReply: { _ in })
            .environment(ThemeStore())
    }

    /// A altura que a faixa **pede** com a largura dada. Mede o layout de
    /// verdade, sem janela e sem foco: é `NSHostingView` fora de qualquer tela.
    private static func fittingHeight<V: View>(_ view: V, width: CGFloat) -> CGFloat {
        let host = NSHostingView(
            rootView: view.theme(.tinta).environment(ThemeStore()).frame(width: width)
        )
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    private static func sentDraft() -> ReplyDraft {
        ReplyDraft(
            to: [Contact(name: "Marina Duarte", address: "marina@clientepremium.com")],
            body: AttributedString("Quinta às 15h está de pé aqui."),
            savedAt: Date(timeIntervalSince1970: 1_000),
            sentAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    @Test("com a faixa aberta, o corpo da mensagem ainda ocupa o meio do leitor")
    func bodyStaysReadableWithBandOpen() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        store.select(message: "m1")

        let rep = try #require(
            Render.snapshot(
                reader(store), named: "leitor-faixa-aberta",
                size: Self.size, theme: .tinta
            )
        )
        #expect(rep.pixelsWide == 760)
        #expect(rep.pixelsHigh == 780)
        // A faixa aberta ocupa o terço de baixo; o corpo tem de continuar
        // desenhando texto entre o cabeçalho e ela.
        #expect(Self.inkPixels(rep, top: 0.28, bottom: 0.50) > 500)

        // Com a barra de formatação dentro dela, a faixa aberta ocupa 271 dos
        // 780pt do leitor — pouco mais de um terço.
        let card = Self.bandCardHeight(rep)
        #expect(card > 200, "a faixa aberta mediu só \(card)pt: ela não desenhou inteira")
        #expect(card < 300, "a faixa aberta ocupou \(card)pt dos 780 do leitor")
    }

    /// O defeito desta tarefa, em forma de invariante: **leitor maior dá o
    /// espaço ao corpo, não à faixa**.
    ///
    /// Medir a altura pedida não pega isso. Um editor com `maxHeight: 300` —
    /// que é o que o protótipo escreve, e o que a rodada anterior tentou —
    /// **pede** 110 e **ocupa** o que sobrar: 271pt num leitor de 560 e 292 num
    /// de 780, roubando do corpo justamente onde havia espaço para ele. Com a
    /// altura fixa do editor, os três desenhos dão o mesmo número.
    @Test("a faixa tem a mesma altura em qualquer leitor: o espaço extra é do corpo")
    func bandHeightDoesNotFollowTheReader() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        store.select(message: "m1")

        let heights = try [560.0, 700.0, 780.0].map { height -> Int in
            let rep = try #require(
                Render.bitmap(
                    reader(store), size: CGSize(width: 760, height: height), theme: .tinta
                )
            )
            return Self.bandCardHeight(rep)
        }

        #expect(heights[0] > 200, "a faixa nem desenhou: \(heights)")
        #expect(heights[1] == heights[0], "a faixa cresceu com o leitor: \(heights)")
        #expect(heights[2] == heights[0], "a faixa cresceu com o leitor: \(heights)")
    }

    @Test("com a faixa fechada, o corpo ganha o espaço de volta")
    func bodyGrowsWithBandClosed() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        store.select(message: "m1")
        store.setReplyDraft(Self.sentDraft(), for: "m1")

        let rep = try #require(
            Render.snapshot(
                reader(store), named: "leitor-faixa-fechada",
                size: Self.size, theme: .tinta
            )
        )
        #expect(rep.pixelsWide == 760)
        #expect(rep.pixelsHigh == 780)
        // O corpo continua desenhando texto no mesmo lugar de antes…
        #expect(Self.inkPixels(rep, top: 0.28, bottom: 0.50) > 500)
        // …e o parágrafo que a faixa aberta empurrava para fora agora aparece.
        #expect(Self.inkPixels(rep, top: 0.57, bottom: 0.67) > 200)
    }

    @Test("a faixa vive no rodapé: abrir e fechar não mexe no corpo da mensagem")
    func bandLivesInTheFooter() async throws {
        func render(sent: Bool, named: String) async throws -> NSBitmapImageRep {
            let store = MailStore(source: InMemoryMailSource.fixtures)
            await store.load()
            store.select(message: "m1")
            if sent { store.setReplyDraft(Self.sentDraft(), for: "m1") }
            return try #require(
                Render.snapshot(reader(store), named: named, size: Self.size, theme: .tinta)
            )
        }

        let open = try await render(sent: false, named: "leitor-faixa-aberta")
        let closed = try await render(sent: true, named: "leitor-faixa-fechada")

        // Do fim do cabeçalho até 380pt é corpo de mensagem nos dois estados, e
        // tem de ser o **mesmo** desenho: a faixa mora embaixo. Se ela subisse
        // para cima do corpo — ou o cobrisse — estes pixels divergiriam.
        #expect(Self.differingPixels(open, closed, x: 40...720, y: 150...380) == 0)

        // E o rodapé é justamente onde os dois têm de divergir: aberta ali há
        // campo, barra de formatação, editor e botões; fechada, uma linha.
        #expect(Self.differingPixels(open, closed, x: 40...720, y: 560...740) > 5_000)
    }

    @Test("a faixa fechada devolve mais de 200pt de altura ao corpo")
    func closedBandIsMuchShorter() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let message = try #require(store.messages.first { $0.id == "m1" })

        let openHeight = Self.fittingHeight(
            QuickReplyBand(store: store, message: message, onPromote: { _ in }),
            width: 700
        )

        store.setReplyDraft(Self.sentDraft(), for: message.id)
        let closedHeight = Self.fittingHeight(
            QuickReplyBand(store: store, message: message, onPromote: { _ in }),
            width: 700
        )

        // Medido: 285pt. Somando o protótipo — 26 da faixa "Para" + 38 da barra
        // de formatação + 110 do editor + 48 do rodapé + 41 da linha do
        // carimbo, dentro do `padding: 10px 28px 16px`. O teto existe porque a
        // faixa **não pode** crescer sem limite: era isso que comia o corpo.
        #expect(openHeight > 275)
        #expect(openHeight < 320)
        // A confirmação fechada é uma linha só.
        #expect(closedHeight < 90)
        #expect(openHeight - closedHeight > 200)
    }

    /// O que o dono do projeto disse que faltava: a barra de formatação inteira
    /// dentro da faixa, com o `⋯` que abre o resto.
    @Test("a barra de formatação está na faixa, e o ⋯ abre a segunda linha")
    func formattingBarIsInsideTheBand() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let message = try #require(store.messages.first { $0.id == "m1" })
        let size = CGSize(width: 700, height: 420)

        func band(more: Bool) -> some View {
            QuickReplyBand(
                store: store, message: message, onPromote: { _ in },
                debugMoreFormatting: more
            )
            .environment(ThemeStore())
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Theme.tinta.surface.color)
        }

        let oneRow = try #require(
            Render.snapshot(band(more: false), named: "faixa-barra", size: size, theme: .tinta)
        )
        let twoRows = try #require(
            Render.snapshot(band(more: true), named: "faixa-barra-mais", size: size, theme: .tinta)
        )

        // As duas asserções abaixo só podem ser diferentes de zero se a barra
        // **estiver** dentro da faixa: `debugMoreFormatting` é uma porta da
        // própria `ComposerToolbar`. Sem a barra ali, ligar o ⋯ não mudaria
        // altura nenhuma nem um pixel sequer.
        //
        // O ⋯ acrescenta uma segunda linha de ~38pt, e tudo abaixo dela desce.
        let grew = Self.fittingHeight(
            QuickReplyBand(
                store: store, message: message, onPromote: { _ in }, debugMoreFormatting: true
            ),
            width: 700
        )
        let base = Self.fittingHeight(
            QuickReplyBand(store: store, message: message, onPromote: { _ in }),
            width: 700
        )
        #expect(grew - base > 30)
        #expect(grew - base < 60)
        #expect(Self.differingPixels(oneRow, twoRows, x: 45...640, y: 60...200) > 3_000)
    }

    /// Os painéis de cor e realce da barra descem por cima do editor. Dentro da
    /// faixa isso é mais apertado que na janela: se o `zIndex` da barra não
    /// estivesse certo, o editor decepava o painel e não dava para escolher cor.
    @Test("o painel de cor abre inteiro dentro da faixa")
    func colorPanelIsNotClippedInsideTheBand() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let message = try #require(store.messages.first { $0.id == "m1" })
        let size = CGSize(width: 700, height: 420)

        func band(_ panel: ComposerToolbar.Panel?) -> some View {
            QuickReplyBand(
                store: store, message: message, onPromote: { _ in }, debugOpenPanel: panel
            )
            .environment(ThemeStore())
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Theme.tinta.surface.color)
        }

        let closed = try #require(
            Render.snapshot(band(nil), named: "faixa-sem-painel", size: size, theme: .tinta)
        )
        let open = try #require(
            Render.snapshot(band(.color), named: "faixa-painel-cor", size: size, theme: .tinta)
        )

        // As seis amostras medem ~160×34pt. Decepadas, sobrariam poucas
        // dezenas de pixels na borda da barra.
        let changed = Self.differingPixels(closed, open, x: 45...400, y: 60...220)
        #expect(changed > 3_000, "só \(changed) pixels mudaram: o painel está sendo decepado")
    }

    @Test("o menu de sugestões desenha as linhas do catálogo")
    func suggestionMenuRenders() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let message = try #require(store.messages.first { $0.id == "m1" })
        let size = CGSize(width: 700, height: 460)

        // O papel por baixo é explícito: sem ele a área que a faixa não ocupa
        // sai preta no bitmap, e "preto" conta como tinta na contagem abaixo.
        func band(query: String?) -> some View {
            QuickReplyBand(
                store: store, message: message, onPromote: { _ in }, seededQuery: query
            )
            .environment(ThemeStore())
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Theme.tinta.surface.color)
        }

        let closed = try #require(
            Render.snapshot(band(query: nil), named: "faixa-sem-menu", size: size, theme: .tinta)
        )
        let open = try #require(
            Render.snapshot(band(query: "a"), named: "faixa-sugestoes", size: size, theme: .tinta)
        )
        #expect(open.pixelsWide == 700)

        // O menu é uma sobreposição: ele não muda o tamanho de nada, então a
        // pergunta certa é "o retângulo dele mudou de conteúdo?". Sem menu esse
        // pedaço é a barra de formatação e a área de escrita; com menu são
        // cinco linhas de contato desenhadas por cima delas.
        let insideMenu = Self.differingPixels(
            closed, open, x: 90...370, y: 50...265
        )
        #expect(insideMenu > 2_000)

        // E a mudança fica onde deve: fora do menu, os dois desenhos são iguais.
        let outsideMenu = Self.differingPixels(
            closed, open, x: 420...680, y: 330...440
        )
        #expect(outsideMenu == 0)
    }

    /// Com destinatário e texto, os três botões do rodapé **acendem**. É o par
    /// do estado vazio, em que ficam apagados — a diferença entre os dois
    /// desenhos é a prova de que "desabilitado" ali é estado, não decoração.
    @Test("com a resposta escrita, os botões do rodapé saem do estado apagado")
    func footerButtonsLightUpWhenTheDraftIsUsable() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let message = try #require(store.messages.first { $0.id == "m1" })
        let size = CGSize(width: 700, height: 420)

        func band(named: String) throws -> NSBitmapImageRep {
            try #require(
                Render.snapshot(
                    QuickReplyBand(store: store, message: message, onPromote: { _ in })
                        .environment(ThemeStore())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .background(Theme.tinta.surface.color),
                    named: named, size: size, theme: .tinta
                )
            )
        }

        let empty = try band(named: "faixa-vazia")

        var body = AttributedString("Quinta às 15h ")
        var strong = AttributedString("está de pé")
        strong[BodyStyleAttribute.self] = BodyStyle(bold: true, colorHex: "#8E2020")
        body.append(strong)
        store.setReplyDraft(ReplyDraft(to: [message.from], body: body), for: message.id)
        let written = try band(named: "faixa-escrita")

        // O rodapé fica na faixa 200…240 destes 420pt. Apagado e aceso são
        // desenhos diferentes ali.
        let footer = Self.differingPixels(empty, written, x: 40...400, y: 200...240)
        #expect(footer > 1_500, "só \(footer) pixels mudaram: o rodapé não acendeu")
    }

    @Test("as linhas Cc e Cco entram sem empurrar nada para fora")
    func copyRowsRender() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let message = try #require(store.messages.first { $0.id == "m1" })

        let base = Self.fittingHeight(
            QuickReplyBand(store: store, message: message, onPromote: { _ in }),
            width: 700
        )
        let withCopies = Self.fittingHeight(
            QuickReplyBand(
                store: store, message: message, onPromote: { _ in }, debugCopiesOpen: true
            ),
            width: 700
        )
        // Duas linhas de 22 + 14 de folga cada.
        #expect(withCopies - base > 60)
        #expect(withCopies - base < 100)
    }

    @Test("a faixa escura desenha com os mesmos tokens")
    func darkThemeRenders() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        store.select(message: "m1")
        let dark = try #require(Theme.all.first { $0.isDark })

        let rep = try #require(
            Render.snapshot(
                reader(store), named: "leitor-faixa-aberta-escuro",
                size: Self.size, theme: dark
            )
        )
        #expect(rep.pixelsHigh == 780)
    }
}
