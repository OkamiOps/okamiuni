import AppKit
import Foundation
import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

@Suite("ReaderPane")
struct ReaderTests {

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
        id: String, event: DetectedEvent?, attachments: [MailAttachment] = []
    ) -> Message {
        Message(
            id: id, accountID: "a",
            from: Contact(name: "Quem", address: "quem@exemplo.com"),
            receivedAt: .now, subject: "Assunto", snippet: "Trecho",
            body: ["Corpo do email, para o leitor ter o que mostrar."],
            tags: [], bucket: .today, isRead: false,
            summary: "Resumo qualquer, para o cartão existir.",
            detectedEvent: event, attachments: attachments
        )
    }

    @MainActor
    private func renderReader(
        event: DetectedEvent?, attachments: [MailAttachment] = [], snapshotName: String? = nil
    ) async -> NSBitmapImageRep? {
        let account = Account(
            id: "a", address: "conta@dominio.com", displayName: "Conta",
            provider: .imap, host: "host", tintLightHex: "#3E6FA8", tintDarkHex: "#7BA8D9"
        )
        let message = readerMessage(id: "m", event: event, attachments: attachments)
        let source = InMemoryMailSource(accounts: [account], messages: [message], agenda: [])
        let store = MailStore(source: source)
        await store.load()
        store.select(message: "m")
        let reader = ReaderPane(store: store)
        if let snapshotName {
            return Render.snapshot(
                reader, named: snapshotName, size: CGSize(width: 760, height: 700), theme: .tinta
            )
        }
        return Render.bitmap(reader, size: CGSize(width: 760, height: 700), theme: .tinta)
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
