import AppKit
import Foundation
import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

@Suite("ReaderPane")
struct ReaderTests {

    @Test("o cabeçalho junta remetente e assunto numa linha")
    func identityCaptionIsOneLine() {
        #expect(ReaderPane.identityCaption(name: "Marina Duarte", subject: "Contrato") == "Marina Duarte · Contrato")
        #expect(ReaderPane.identityCaption(name: "", subject: "Contrato") == "Contrato")
        #expect(ReaderPane.identityCaption(name: "Marina", subject: "") == "Marina")
    }

    @Test("o TL;DR recolhido expande pela linha, não só pelo chevron")
    func tldrRowToggles() {
        #expect(ReaderPane.mostrarResumo == "Mostrar resumo")
        #expect(ReaderPane.recolherResumo == "Recolher resumo")
        #expect(!ReaderPane.resumoComecaAberto)
    }

    @Test("o clique na linha revela o email do remetente")
    func identityExpandsOnClick() {
        #expect(ReaderPane.expandirCabecalho == "Mostra o email do remetente e o assunto completo")
        #expect(ReaderPane.recolherCabecalho == "Recolhe remetente e assunto")
        let para = Message(
            id: "m", accountID: "a",
            from: Contact(name: "Meta", address: "noreply@meta.com"),
            receivedAt: .now, subject: "Muse", snippet: "", body: [],
            tags: [], bucket: .today, isRead: true,
            summary: nil, detectedEvent: nil,
            to: [Contact(name: "Marcos", address: "eu@okami.example")],
            cc: [Contact(name: "Time", address: "time@okami.example")]
        )
        #expect(ReaderPane.destinatarios(para) == "Para Marcos · Cc Time")
        let soPara = Message(
            id: "m2", accountID: "a",
            from: Contact(name: "A", address: "a@x.com"),
            receivedAt: .now, subject: "Oi", snippet: "", body: [],
            tags: [], bucket: .today, isRead: true,
            summary: nil, detectedEvent: nil,
            to: [Contact(name: "Eu", address: "eu@x.com")]
        )
        #expect(ReaderPane.destinatarios(soPara) == "Para Eu")
    }

    @Test("abrir uma mensagem pede prioridade para o TL;DR")
    @MainActor
    func openingMessagePrioritizesTLDR() async {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        var presentedIDs: [String] = []
        let reader = ReaderPane(
            store: store,
            onMessagePresented: { presentedIDs.append($0) }
        )

        reader.messageDidAppear("m1")

        #expect(presentedIDs == ["m1"])
    }

    /// O estado vazio do leitor ("Nada aqui. Bom sinal.") é para uma caixa
    /// vazia, não para a abertura do app: o protótipo abre em `selected: 'm1'`.
    /// Este teste trocou de sentido na Task P junto com esse defeito.
    @Test("o leitor só fica vazio quando a caixa está vazia")
    @MainActor
    func emptyOnlyWhenBoxIsEmpty() async {
        let full = MailStore(source: InMemoryMailSource.fixtures)
        await full.load()
        #expect(full.selectedMessage != nil)

        let empty = MailStore(source: InMemoryMailSource(accounts: [], messages: [], agenda: []))
        await empty.load()
        #expect(empty.selectedMessage == nil)
    }

    @Test("a mensagem m1 traz resumo e compromisso detectado")
    @MainActor
    func summaryAndEvent() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        store.select(bucket: .all)
        store.select(message: "m1")

        let selected = try #require(store.selectedMessage)
        #expect(selected.summary?.isEmpty == false)
        let event = try #require(selected.detectedEvent)
        #expect(event.label.contains("15:00"))
        #expect(event.end > event.start)
    }

    /// Antes apontava para `m2` pelo id. No design, `m2` é a cobrança da
    /// Hostinger e **tem** compromisso detectado ("Renovar domínio · 04 set");
    /// quem não tinha era a `m2` das fixtures antigas, que nem existe mais com
    /// esse conteúdo. O que o teste quer dizer não é "m2": é "uma mensagem sem
    /// compromisso", e agora ele pede exatamente isso.
    /// Selecionar por `detectedEvent == nil` e depois afirmar
    /// `detectedEvent == nil` prova só que `MailStore` guardou o que recebeu —
    /// nunca chega a perguntar o que o `ReaderPane` desenhou. Com o cartão
    /// "Compromisso detectado" apagado do `ReaderPane` inteiro, essa versão
    /// continuava passando.
    ///
    /// Prova de verdade: duas mensagens idênticas — mesmo resumo, mesmo corpo,
    /// mesma conta — divergindo só em `detectedEvent` (uma tem, outra não).
    /// Se o cartão de fato depende do campo, os dois desenhos do `ReaderPane`
    /// saem diferentes; se o cartão foi removido (ou nunca olha
    /// `detectedEvent`), os dois saem pixel a pixel iguais.
    private func readerMessage(
        id: String,
        event: DetectedEvent?,
        attachments: [MailAttachment] = [],
        subject: String = "Assunto"
    ) -> Message {
        Message(
            id: id, accountID: "a",
            from: Contact(name: "Quem", address: "quem@exemplo.com"),
            receivedAt: .now, subject: subject, snippet: "Trecho",
            body: ["Corpo do email, para o leitor ter o que mostrar."],
            tags: [], bucket: .today, isRead: false,
            summary: "Resumo qualquer, para o cartão existir.",
            detectedEvent: event, attachments: attachments
        )
    }

    @MainActor
    private func renderReader(
        event: DetectedEvent?,
        attachments: [MailAttachment] = [],
        subject: String = "Assunto",
        snapshotName: String? = nil,
        width: CGFloat = 760
    ) async -> NSBitmapImageRep? {
        let account = Account(
            id: "a", address: "conta@dominio.com", displayName: "Conta",
            provider: .imap, host: "host", tintLightHex: "#3E6FA8", tintDarkHex: "#7BA8D9"
        )
        let message = readerMessage(
            id: "m", event: event, attachments: attachments, subject: subject
        )
        let source = InMemoryMailSource(accounts: [account], messages: [message], agenda: [])
        let store = MailStore(source: source)
        await store.load()
        store.select(message: "m")
        let reader = ReaderPane(
            store: store,
            debugEmailAssistantOpen: false,
            debugResumoAberto: true
        )
        let size = CGSize(width: width, height: 700)
        if let snapshotName {
            return Render.snapshot(
                reader, named: snapshotName, size: size, theme: .tinta
            )
        }
        return Render.bitmap(reader, size: size, theme: .tinta)
    }

    /// A fila de triagem mora **acima** do assunto. Assunto curto e assunto
    /// de várias linhas não podem empurrá-la: é o defeito da tela do dono, os
    /// botões subindo e descendo conforme o título.
    ///
    /// A régua é o magenta do "Apagar": ele mora na mesma fileira e não
    /// depende do assunto. `btn` no tema Tinta é branco, o mesmo do papel.
    @Test("assunto longo não move a fila de triagem")
    @MainActor
    func assuntoNaoMoveAFila() async throws {
        let curto = try #require(await renderReader(event: nil, subject: "Oi"))
        let longo = try #require(await renderReader(
            event: nil,
            subject: """
            Re: [aitherion-labs/contion-app] Contion — workflow contábil
            agêntico (fiscal real, certificado, agentes, WhatsApp)
            (PR #2) e mais uma linha para o título ocupar altura de verdade
            """
        ))

        #expect(curto.pixelsDiffering(from: longo) > 0)

        let recorte = 0..<260
        let apagar = ReaderPane.apagarPalette(isDark: Theme.tinta.isDark)
        let filaCurta = try #require(
            curto.rows(matching: apagar.fill, inRows: recorte)
        )
        let filaLonga = try #require(
            longo.rows(matching: apagar.fill, inRows: recorte)
        )
        #expect(
            filaCurta == filaLonga,
            "a fila de triagem andou quando o assunto quebrou linha: curto \(filaCurta) vs longo \(filaLonga)"
        )
    }

    /// No ponto de fidelidade o leitor tem 516pt. Uma fileira só com ícone +
    /// rótulo espreme o trilho e o "Hoje" vira "Hoj e". A régua é a altura do
    /// preenchimento `accentSoft` da caixa ativa: uma linha tem 28pt. O recorte
    /// é só a barra — o cabeçalho ficou mais baixo, e o TL;DR aberto logo
    /// abaixo pintava `accentSoft` no recorte antigo de 140pt.
    @Test("no leitor estreito os rótulos da fila cabem numa linha")
    @MainActor
    func filaNaoQuebraRotulo() async throws {
        let bitmap = try #require(await renderReader(event: nil, width: 516))
        let barra = 0..<90
        let ativo = try #require(
            bitmap.rows(matching: Theme.tinta.accentSoft, inRows: barra)
        )
        #expect(
            ativo.upperBound - ativo.lowerBound <= 36,
            "Hoje quebrou linha no trilho: \(ativo)"
        )
        let apagar = ReaderPane.apagarPalette(isDark: Theme.tinta.isDark)
        let responder = try #require(
            bitmap.rows(matching: apagar.fill, inRows: barra)
        )
        #expect(
            responder.upperBound - responder.lowerBound <= 36,
            "a fila de ações quebrou linha: \(responder)"
        )
    }

    @Test("a barra traz responder, responder a todos e encaminhar em ícone")
    @MainActor
    func composeTrioIsOnTheBar() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        store.select(bucket: .all)
        store.select(message: "m1")
        let rep = try #require(
            Render.bitmap(
                ReaderPane(store: store).environment(ThemeStore()),
                size: CGSize(width: 760, height: 700),
                theme: .tinta
            )
        )
        // Três ícones 28×28 + pasta + lixeira: o contorno `btnLine` cresce.
        #expect(rep.pixels(matching: Theme.tinta.btnLine, tolerance: 0.02) > 700)
    }

    @Test("o botão da IA fica à direita do Responder, com folga")
    @MainActor
    func iaADireitaDoResponder() async throws {
        let bitmap = try #require(await renderReader(event: nil))
        let cabeca = 0..<130
        let ia = try #require(bitmap.columns(matching: Theme.tinta.info, tolerance: 0.08, inRows: cabeca))
        let apagar = ReaderPane.apagarPalette(isDark: Theme.tinta.isDark)
        let lixeira = try #require(
            bitmap.columns(matching: apagar.ink, tolerance: 0.08, inRows: cabeca)
        )
        #expect(
            ia.lowerBound > lixeira.upperBound,
            "a IA ficou à esquerda ou por cima do Apagar: IA \(ia) vs Apagar \(lixeira)"
        )
        #expect(
            ia.lowerBound - lixeira.upperBound >= 12,
            "a IA colou no Apagar: folga \(ia.lowerBound - lixeira.upperBound)pt"
        )
        #expect(
            ia.lowerBound > 600,
            "a IA saiu do canto direito da barra: \(ia)"
        )
    }

    @Test("o cartão \"Compromisso detectado\" só aparece quando a mensagem tem evento")
    @MainActor
    func noEvent() async throws {
        let event = DetectedEvent(label: "Reunião · qui 27, 15:00", start: .now, duration: 1800)
        let withEvent = try #require(await renderReader(event: event))
        let withoutEvent = try #require(await renderReader(event: nil))

        #expect(withEvent.pixelsWide == withoutEvent.pixelsWide)
        #expect(withEvent.pixelsHigh == withoutEvent.pixelsHigh)
        #expect(
            withEvent.pixelsDiffering(from: withoutEvent) > 0,
            "duas mensagens que só diferem em detectedEvent renderizaram igual — o cartão não está reagindo ao evento"
        )
    }

    /// A foto é opcional na suíte normal e vai para `UNI_RENDER_DIR` quando o
    /// harness é chamado para inspeção. A diferença de pixels mata a mutação
    /// que deixaria `Message.attachments` chegar ao leitor sem superfície.
    @Test("anexos recebidos aparecem no leitor fora da tela")
    @MainActor
    func receivedAttachmentsRender() async throws {
        let attachment = MailAttachment(
            id: "contrato", filename: "contrato-final.pdf",
            mimeType: "application/pdf", byteCount: 1_572_864
        )
        let withAttachment = try #require(await renderReader(
            event: nil, attachments: [attachment], snapshotName: "m4-anexos-recebidos"
        ))
        let withoutAttachment = try #require(await renderReader(event: nil))
        #expect(withAttachment.pixelsDiffering(from: withoutAttachment) > 0)
    }

    /// A outra metade: as fixtures continuam tendo dos dois tipos. Sem isto, o
    /// teste acima passaria numa lista onde nenhuma mensagem tem compromisso.
    @Test("as fixtures têm mensagens com e sem compromisso detectado")
    @MainActor
    func bothKindsExist() async {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        #expect(store.messages.contains { $0.detectedEvent != nil })
        #expect(store.messages.contains { $0.detectedEvent == nil })
    }
}
