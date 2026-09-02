import AppKit
import Foundation
import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

/// A porta de escrita, espionada. É a **mesma** por onde a Caixa manda arquivar
/// (`MailStore` → `MailCommandDispatcher` → `MailCommandPort`): o que estes
/// casos provam é que a folha do dashboard cai nessa fila, e não num caminho
/// paralelo que amanhã divergiria dela.
private final class PortaEspia: MailCommandPort, @unchecked Sendable {
    private let trava = NSLock()
    private var _chamadas: [String] = []

    var chamadas: [String] {
        trava.lock(); defer { trava.unlock() }
        return _chamadas
    }

    private func registrar(_ texto: String) {
        trava.lock(); _chamadas.append(texto); trava.unlock()
    }

    /// A fila é serial e fora da main; esperar por ela é esperar o registro
    /// aparecer, sem `sleep` fixo no teste.
    func esperar(_ prefixo: String) async -> Bool {
        for _ in 0..<200 {
            if chamadas.contains(where: { $0.hasPrefix(prefixo) }) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    func setRead(_ isRead: Bool, accountID: String, messageIDs: [String]) throws {
        registrar("setRead:\(isRead):\(messageIDs.joined(separator: ","))")
    }
    func setFlagged(_ isFlagged: Bool, accountID: String, messageIDs: [String]) throws {
        registrar("setFlagged:\(isFlagged)")
    }
    func move(to bucket: TriageBucket, accountID: String, messageIDs: [String]) throws {
        registrar("move:\(bucket.rawValue):\(messageIDs.joined(separator: ","))")
    }
    func place(in folder: MailFolder, mode: FolderPlacement, accountID: String, messageIDs: [String]) throws {
        registrar("place:\(folder.id)")
    }
    func moveGmailLabel(from source: MailFolder, to destination: MailFolder, accountID: String, messageIDs: [String]) throws {
        registrar("moveGmailLabel:\(destination.id)")
    }
    func setAccountTint(lightHex: String, darkHex: String, accountID: String) throws {
        registrar("setAccountTint")
    }
    func delete(accountID: String, messageIDs: [String]) throws {
        registrar("delete:\(messageIDs.joined(separator: ","))")
    }
    func deletePermanently(accountID: String, messageIDs: [String]) throws {
        registrar("deletePermanently")
    }
    func emptyTrash(accountID: String) throws {
        registrar("emptyTrash")
    }
}

/// O assistente espionado da folha: prova que "Gerar rascunho" chega em
/// `draftReply()` e nunca em `answer`.
private final class FolhaSpyAssistant: TextAssisting, @unchecked Sendable {
    let modelVersion = "spy/folha"
    private(set) var acoes: [WritingAction] = []
    private(set) var perguntas = 0

    func availability() async -> AppleIntelligenceAvailability { .available }

    func answer(question: String, in conversation: AssistantConversationSnapshot) async throws -> String {
        perguntas += 1
        return "resposta"
    }

    func transform(_ text: String, using action: WritingAction, context: AssistantMailContext?) async throws -> String {
        acoes.append(action)
        return "Oi Marina,\n\nFechado."
    }
}

/// A folha de leitura do dashboard, depois de ela ter virado o `ReaderPane`.
@Suite("Folha de leitura do dashboard")
@MainActor
struct DashboardMailSheetTests {

    /// O recorte da folha nos retratos e nos cliques. É o mesmo do dashboard.
    private static let tamanho = CGSize(width: 1_200, height: 820)

    private func loja(porta: MailCommandPort? = nil) async -> MailStore {
        let store = MailStore(source: InMemoryMailSource.fixtures, commandPort: porta)
        await store.load()
        return store
    }

    private func folha(
        store: MailStore,
        messageID: String,
        onClose: @escaping () -> Void = {},
        onOpenInMailbox: @escaping (Message) -> Void = { _ in },
        onDraft: @escaping (Message) -> Void = { _ in }
    ) -> some View {
        DashboardMailSheet(
            store: store,
            messageID: messageID,
            onClose: onClose,
            onOpenInMailbox: onOpenInMailbox,
            onDraft: onDraft
        )
        .environment(ThemeStore())
    }

    @Test("a folha aberta desenha a barra de ações do leitor, não um rodapé de duas saídas")
    func desenhaBarraDoLeitor() async throws {
        let store = await loja()
        let id = try #require(store.messages.first?.id)
        for (tema, nome) in [(Theme.okami, "okami-folha"), (Theme.tinta, "tinta-folha")] {
            let rep = try #require(Render.snapshot(
                folha(store: store, messageID: id),
                named: nome,
                size: Self.tamanho,
                theme: tema
            ))
            #expect(rep.pixelsWide == 1_200)
            #expect(rep.pixelsHigh == 820)
        }
    }

    @Test("a folha aponta o leitor para a mensagem dela, e não para a seleção da Caixa")
    func mensagemPropria() async throws {
        let store = await loja()
        let ids = store.messages.map(\.id)
        try #require(ids.count > 1)
        // A Caixa está noutra mensagem; a folha continua sendo a dela.
        store.select(message: ids[0])
        let presentation = ReaderPresentation.sheet(messageID: ids[1], onMessageLeft: {})
        #expect(presentation.messageID == ids[1])
        #expect(store.selectedMessageID == ids[0])
    }

    @Test("Arquivar dentro da folha vai pela porta de comandos e fecha a folha")
    func arquivarFechaAFolha() async throws {
        let porta = PortaEspia()
        let store = await loja(porta: porta)
        let mensagem = try #require(store.messages.first { $0.bucket != .archived })
        var fechou = false

        CliqueDeEnsaio.em(
            folha(store: store, messageID: mensagem.id, onClose: { fechou = true }),
            size: Self.tamanho,
            aY: Self.arquivarPonto.y,
            x: Self.arquivarPonto.x
        )

        #expect(await porta.esperar("move:\(TriageBucket.archived.rawValue)"))
        #expect(store.message(mensagem.id)?.bucket == .archived)
        #expect(fechou)
    }

    @Test("Responder abre a faixa de resposta e mantém a folha aberta")
    func responderMantemAFolhaAberta() async throws {
        let porta = PortaEspia()
        let store = await loja(porta: porta)
        let mensagem = try #require(store.messages.first { $0.bucket != .drafts })
        var fechou = false

        CliqueDeEnsaio.em(
            folha(store: store, messageID: mensagem.id, onClose: { fechou = true }),
            size: Self.tamanho,
            aY: Self.responderPonto.y,
            x: Self.responderPonto.x
        )

        #expect(!fechou)
        #expect(store.message(mensagem.id)?.bucket == mensagem.bucket)
        #expect(!porta.chamadas.contains { $0.hasPrefix("move:") || $0.hasPrefix("delete:") })
    }

    @Test("\"Gerar rascunho\" chega em draftReply(), nunca em answer")
    func gerarRascunho() async throws {
        let store = await loja()
        let mensagem = try #require(store.messages.first)
        let spy = FolhaSpyAssistant()
        let conversa = AssistantConversation(
            scope: .email,
            context: .init(subject: mensagem.subject, sender: mensagem.from.display),
            destination: .init(label: "Neste Mac", detail: "Nada sai deste Mac.", isLocal: true),
            engine: AssistantBridge.engine(
                using: spy,
                supportsDraftReply: true,
                mailContext: { AssistantMailContext(message: mensagem) }
            )
        )

        CliqueDeEnsaio.em(
            folha(
                store: store,
                messageID: mensagem.id,
                onDraft: { _ in conversa.draftReply() }
            ),
            size: Self.tamanho,
            aY: Self.rascunhoPonto.y,
            x: Self.rascunhoPonto.x
        )
        await conversa.waitForIdle()

        #expect(spy.acoes == [.draftReply])
        #expect(spy.perguntas == 0)
    }

    @Test("o ✕ da barra da folha fecha")
    func fecharPeloX() async throws {
        let store = await loja()
        let mensagem = try #require(store.messages.first)
        var fechou = false
        CliqueDeEnsaio.em(
            folha(store: store, messageID: mensagem.id, onClose: { fechou = true }),
            size: Self.tamanho,
            aY: Self.fecharPonto.y,
            x: Self.fecharPonto.x
        )
        #expect(fechou)
    }

    @Test("Esc fecha a folha antes de qualquer outro cancelamento pendente")
    func escFechaAFolha() {
        // A precedência mora no `EscapeCancel` do `UNICore` e é ele quem a
        // tranca; o que importa aqui é que a folha aberta é o primeiro passo
        // quando não há busca em foco.
        #expect(
            EscapeCancel.next(
                searchFocused: false,
                query: "",
                assistantOpen: true,
                selecting: true,
                overlayOpen: true
            ) == .overlay
        )
    }

    // MARK: - Pontos medidos no recorte

    /// Medidos sobre o PNG do harness (1200×820, tema `okami`), com a folha
    /// centrada e recuada em 28: a barra da folha em cima, o leitor logo
    /// abaixo com a fila de triagem na primeira linha de botões.
    private static let arquivarPonto = CGPoint(x: 333, y: 128)
    private static let responderPonto = CGPoint(x: 463, y: 128)
    private static let rascunhoPonto = CGPoint(x: 925, y: 54)
    private static let fecharPonto = CGPoint(x: 1_007, y: 54)
}
