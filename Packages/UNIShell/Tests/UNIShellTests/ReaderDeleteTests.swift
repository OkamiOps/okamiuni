import AppKit
import Foundation
import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

/// O "Apagar" da barra do leitor.
///
/// **O defeito.** A barra oferecia Hoje · Depois · Arquivar · Responder, e a
/// ação que o dono mais usa não estava lá: para apagar era preciso o botão
/// direito ou lembrar do ⌫. Agora ela está — e faz exatamente o que as outras
/// duas portas já faziam, porque é a mesma função por trás das três.
@Suite("Apagar, na barra do leitor")
@MainActor
struct ReaderDeleteTests {

    private static let conta = Account(
        id: "a", address: "eu@x.com", displayName: "Eu",
        provider: .imap, host: "host", tintLightHex: "#3E6FA8", tintDarkHex: "#7BA8D9"
    )

    private static func mensagem(
        id: String, bucket: TriageBucket = .today, threadKey: String? = nil
    ) -> Message {
        Message(
            id: id, accountID: "a",
            from: Contact(name: "Marina", address: "marina@x.com"),
            receivedAt: Date(timeIntervalSince1970: 1_800_000_000),
            subject: "Revisão do contrato", snippet: "Revisão", body: ["Oi"],
            tags: [], bucket: bucket, isRead: false, summary: nil,
            detectedEvent: nil, threadKey: threadKey
        )
    }

    private static func store(_ mensagens: [Message], seleciona: String) async -> MailStore {
        let store = MailStore(
            source: InMemoryMailSource(accounts: [conta], messages: mensagens, agenda: [])
        )
        await store.load()
        // Estes ensaios verificam a ação do leitor sobre conversas, não o
        // recorte temporal de Hoje. As datas sintéticas ficam visíveis em
        // Tudo para a pilha inteira participar da operação.
        store.select(bucket: .all)
        store.select(message: seleciona)
        return store
    }

    // MARK: O rótulo

    /// Na Lixeira, apagar não é mover para a Lixeira. O botão diz a verdade
    /// sobre o que vai fazer — a mesma decisão que o menu já tomava.
    @Test("O rótulo muda quando a mensagem já está na Lixeira")
    func rotulo() {
        #expect(ReaderPane.apagarLabel(Self.mensagem(id: "m")) == "Apagar")
        #expect(ReaderPane.apagarLabel(Self.mensagem(id: "m", bucket: .trash)) == "Apagar de vez")
    }

    // MARK: A ação

    @Test("Apagar move a mensagem para a Lixeira e deixa um Desfazer")
    func apagaComVolta() async throws {
        let store = await Self.store([Self.mensagem(id: "m1")], seleciona: "m1")
        let recibos = ActionReceipts()

        #expect(recibos.delete(try #require(store.selectedMessage), on: store))
        #expect(store.messages.first(where: { $0.id == "m1" })?.bucket == .trash)

        // **A volta.** Uma ação destrutiva sem retorno visível é pior do que não
        // ter a ação — é a regra que `ActionReceipts` existe para garantir.
        let recibo = try #require(recibos.current)
        #expect(recibo.note.contains("Marina"))
        StoreCommand.run(recibo.undo, on: store)
        #expect(store.messages.first(where: { $0.id == "m1" })?.bucket == .today)
    }

    @Test("Na Lixeira, Apagar tira de vez — e o Desfazer devolve")
    func apagaDeVezComVolta() async throws {
        let store = await Self.store(
            [Self.mensagem(id: "m1", bucket: .trash)], seleciona: "m1"
        )
        let recibos = ActionReceipts()

        #expect(recibos.delete(try #require(store.selectedMessage), on: store))
        #expect(!store.messages.contains { $0.id == "m1" })

        let recibo = try #require(recibos.current)
        StoreCommand.run(recibo.undo, on: store)
        #expect(store.messages.contains { $0.id == "m1" })
    }

    /// **A decisão da M3-9**: a barra do leitor age na pilha da caixa aberta,
    /// como o clique na linha agiria. Apagar a mensagem de cima de uma conversa
    /// de três e deixar as outras duas na caixa seria a linha continuar lá
    /// depois de a pessoa ter mandado a conversa embora.
    @Test("Na conversa, Apagar age na pilha inteira")
    func apagaAConversa() async throws {
        let store = await Self.store([
            Self.mensagem(id: "m1", threadKey: "t"),
            Self.mensagem(id: "m2", threadKey: "t"),
            Self.mensagem(id: "m3", threadKey: "t"),
        ], seleciona: "m3")
        let recibos = ActionReceipts()

        #expect(recibos.delete(try #require(store.selectedMessage), on: store))
        #expect(store.messages.filter { $0.bucket == .trash }.count == 3)

        // E a frase conta quantas foram: um "Desfazer" que devolvesse três
        // depois de uma faixa que falou de uma seria uma surpresa.
        let recibo = try #require(recibos.current)
        #expect(recibo.note.contains("3 mensagens"))
        StoreCommand.run(recibo.undo, on: store)
        #expect(store.messages.filter { $0.bucket == .today }.count == 3)
    }

    /// Uma mensagem que o store não conhece não é apagada, e a faixa não nasce:
    /// é o `false` que faz a tecla ⌫ seguir o caminho dela em vez de ser
    /// engolida por um atalho que não fez nada.
    @Test("Sem mensagem no store não há o que apagar, e não há faixa")
    func semMensagem() async throws {
        let store = await Self.store([Self.mensagem(id: "m1")], seleciona: "m1")
        let recibos = ActionReceipts()
        #expect(!recibos.delete(Self.mensagem(id: "fantasma"), on: store))
        #expect(recibos.current == nil)
    }

    // MARK: O botão está lá

    /// O desenho: **quatro** pastilhas contornadas na barra, e não três.
    ///
    /// A régua é o contorno (`btnLine`) e não o fundo: em `tinta`, `btn` e
    /// `surface` diferem 0,02, e contar fundo contaria o painel inteiro — 486
    /// mil pixels, um número que passa com o botão fora da tela. O contorno é a
    /// linha que existe uma vez por pastilha e some junto com ela.
    ///
    /// Medido neste desenho: 604 pixels de contorno com o "Apagar", 481 sem ele
    /// — a pastilha vale 123. O limite fica no meio dos dois.
    @Test("A barra do leitor desenha uma pastilha a mais do que antes")
    func aBarraTemOBotao() async throws {
        let store = await Self.store([Self.mensagem(id: "m1")], seleciona: "m1")
        let rep = try #require(Render.bitmap(
            ReaderPane(store: store).environment(ThemeStore()),
            size: CGSize(width: 760, height: 700), theme: .tinta
        ))
        #expect(rep.pixels(matching: Theme.tinta.btnLine, tolerance: 0.01) > 540)
    }

    @Test("Apagar é destacado em magenta suave, sem herdar a cor neutra da barra")
    func apagarTemTomPerigoso() async throws {
        let store = await Self.store([Self.mensagem(id: "m1")], seleciona: "m1")
        let rep = try #require(Render.bitmap(
            ReaderPane(store: store).environment(ThemeStore()),
            size: CGSize(width: 760, height: 700), theme: .tinta
        ))
        let danger = ReaderPane.apagarPalette(isDark: Theme.tinta.isDark)
        #expect(danger.fill != Theme.tinta.btn)
        #expect(danger.ink != Theme.tinta.ink)
        #expect(
            rep.pixels(matching: danger.fill, tolerance: 0.03) > 80,
            "Apagar voltou a ser uma pastilha neutra em vez de uma ação perigosa"
        )
    }
}
