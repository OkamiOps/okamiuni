import AppKit
import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

/// As três variantes do indicador de não-lida, desenhadas na **mesma** lista,
/// para que a escolha seja feita olhando em vez de no escuro.
///
/// Duas rodadas foram decididas por quem escreve o código e mostradas prontas;
/// as duas voltaram. Esta gera `nao-lida-A.png`, `-B.png` e `-C.png` em 1× —
/// a densidade das telas do dono do projeto — com lidas e não lidas
/// intercaladas e o tema claro padrão.
///
/// Como gerar:
///
/// ```
/// UNI_RENDER_DIR=.superpowers/sdd/2026-08-26-okamiuni-shell \
///   swift test --package-path Packages/UNIShell --filter UnreadEmphasisRender
/// ```
@Suite("Não-lida — as três variantes")
@MainActor
struct UnreadEmphasisRenderTests {

    /// A caixa "Tudo": as sete mensagens do design, em dois grupos, com lidas
    /// e não lidas intercaladas — que é exatamente a comparação que interessa.
    /// As sete mensagens do design chegam **todas** não lidas, e uma lista sem
    /// linha lida não compara nada. Metade delas é marcada pelo caminho de
    /// verdade — o mesmo `ContextCommand` que o menu e o arraste emitem.
    private func mixedStore() async -> MailStore {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        store.select(bucket: .all)
        for (index, message) in store.visibleMessages.enumerated() where index % 2 == 0 {
            _ = StoreCommand.run(.setRead(messageID: message.id, isRead: true), on: store)
        }
        return store
    }

    /// A lista do desenho novo. O botão `unreadEmphasis` saiu com o shell
    /// clássico: a linha do protótipo (`GlassMessageRow`) tem **uma** marca de
    /// não-lida, o ponto antes do remetente, e é a mesma nos 28 temas.
    private func lista(store: MailStore) -> some View {
        MessageList(store: store, width: MessageList.width)
    }

    /// A escolha das três variantes foi feita e está no desenho; o que precisa
    /// continuar provado é o **motivo** de ela ter existido: não-lida tem de
    /// ser visível sem esforço, e as duas rodadas que o dono recusou falhavam
    /// exatamente aí. O caso agora mede isso de frente — a mesma lista com e
    /// sem mensagens lidas não pode sair igual.
    @Test("a lista marca a não-lida, e a marca some quando ela é lida")
    func unreadIsVisible() async throws {
        let misturada = await mixedStore()
        let unread = misturada.visibleMessages.filter { !$0.isRead }.count
        let read = misturada.visibleMessages.count - unread
        #expect(unread > 0 && read > 0, "a lista de comparação precisa das duas")

        let tamanho = CGSize(width: MessageList.width, height: 700)
        let comNaoLidas = try #require(
            Render.snapshot(
                lista(store: misturada), named: "nao-lida-mista",
                size: tamanho, theme: .tinta
            )
        )
        #expect(comNaoLidas.pixelsWide == Int(MessageList.width))

        // A mesma lista, tudo lido: a marca tem de sumir.
        let todasLidas = await mixedStore()
        for message in todasLidas.visibleMessages where !message.isRead {
            _ = StoreCommand.run(.setRead(messageID: message.id, isRead: true), on: todasLidas)
        }
        let semNaoLidas = try #require(
            Render.bitmap(lista(store: todasLidas), size: tamanho, theme: .tinta)
        )
        #expect(
            comNaoLidas.pixelsDiffering(from: semNaoLidas) > 500,
            "ler as mensagens não mudou nada na lista — a marca de não-lida sumiu do desenho"
        )
    }
}
