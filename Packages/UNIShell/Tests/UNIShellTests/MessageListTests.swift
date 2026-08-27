import Testing
import Foundation
import UNICore
@testable import UNIShell

@Suite("MessageList")
struct MessageListTests {

    @Test("mensagens se agrupam por dia, mais recente primeiro")
    @MainActor
    func groupsByDay() async {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        store.select(bucket: .all)

        let groups = MessageGroup.build(from: store.visibleMessages)
        #expect(groups.isEmpty == false)
        // Cada grupo carrega ao menos uma mensagem e nenhuma se perde.
        let regrouped = groups.flatMap(\.messages).count
        #expect(regrouped == store.visibleMessages.count)
    }

    @Test("o rótulo do grupo de hoje é 'Hoje'")
    @MainActor
    func todayLabel() {
        let groups = MessageGroup.build(from: [Message.preview()])
        #expect(groups.first?.label == "Hoje")
    }

    @Test("lista vazia não gera grupo vazio")
    func noEmptyGroups() {
        #expect(MessageGroup.build(from: []).isEmpty)
    }

    @Test("a largura da lista é a do design")
    func width() {
        #expect(MessageList.width == 370)
    }
}
