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

    private func stagedList(_ emphasis: UnreadEmphasis, store: MailStore) -> some View {
        var list = MessageList(store: store, width: MessageList.width)
        list.unreadEmphasis = emphasis
        return list
    }

    @Test("as três variantes desenham a mesma lista, com lidas e não lidas")
    func renderTheThreeVariants() async throws {
        let store = await mixedStore()

        let unread = store.visibleMessages.filter { !$0.isRead }.count
        let read = store.visibleMessages.count - unread
        #expect(unread > 0 && read > 0, "a lista de comparação precisa das duas")

        var counts: [UnreadEmphasis: Int] = [:]
        for emphasis in UnreadEmphasis.allCases {
            let rep = try #require(
                Render.snapshot(
                    stagedList(emphasis, store: store),
                    named: "nao-lida-\(emphasis.fileTag)",
                    size: CGSize(width: MessageList.width, height: 700),
                    theme: .tinta
                )
            )
            #expect(rep.pixelsWide == Int(MessageList.width))
            counts[emphasis] = rep.pixels(matching: Theme.tinta.accent)
        }

        // As três são de fato diferentes: a do ponto pinta `accent` e a do
        // campo não, e a combinada pinta como a do ponto. Sem esta conta o
        // teste seria "renderizou sem trapar" — verdadeiro por construção.
        let dotOnly = try #require(counts[.dot])
        let fieldOnly = try #require(counts[.field])
        let both = try #require(counts[.both])
        #expect(dotOnly > 0, "a variante A não pintou ponto nenhum")
        #expect(fieldOnly == 0, "a variante B pintou accent — ela não tem ponto")
        #expect(both == dotOnly, "a variante C perdeu os pontos da A")
    }

    /// A variante do campo muda a lista **inteira**, não uma coluna dela: é o
    /// que a distingue de A aos olhos, e o que um teste de ponto não veria.
    @Test("a variante do campo pinta fundo onde a do ponto não pinta nada")
    func fieldVariantPaintsTheRows() async throws {
        let store = await mixedStore()

        func softPixels(_ emphasis: UnreadEmphasis) throws -> Int {
            let rep = try #require(
                Render.bitmap(
                    stagedList(emphasis, store: store),
                    size: CGSize(width: MessageList.width, height: 700),
                    theme: .tinta
                )
            )
            return rep.pixels(matching: Theme.tinta.surface2, tolerance: 0.008)
        }

        let dot = try softPixels(.dot)
        let field = try softPixels(.field)
        let both = try softPixels(.both)
        // A conta é a **diferença**, não o número absoluto: a lista já tem
        // pixels nessa vizinhança de cor sem nenhuma variante de campo — o
        // cabeçalho e outras superfícies neutras já usam `surface2`.
        #expect(
            field - dot > 50_000,
            "a variante B acrescentou só \(field - dot)px de fundo sobre a base de \(dot)"
        )
        #expect(
            both - dot > 50_000,
            "a variante C acrescentou só \(both - dot)px de fundo sobre a base de \(dot)"
        )
        // C e B pintam o mesmo campo; a diferença é só a área que os pontos
        // cobrem — quatro pontos de 9pt, ~250px.
        #expect(
            field - both > 0 && field - both < 1_000,
            "C e B divergem em \(field - both)px de campo — não é só o ponto"
        )
    }
}
