import SwiftUI
import Testing
import UNICore
@testable import UNIShell

/// O que a Lixeira acrescenta ao shell: o retorno com "Desfazer" que ela
/// partilha com o arraste, e a pergunta que substitui o "Desfazer" que
/// "Esvaziar lixeira" não tem.
@Suite("Lixeira no shell")
@MainActor
struct ShellTrashTests {

    private func store() async -> MailStore {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        return store
    }

    /// A faixa nasce com o caminho de volta dentro. Sem isso, apagar do menu
    /// seria destrutivo e mudo — o defeito número um deste projeto.
    @Test("apagar do menu deixa recibo com «Desfazer», e desfazer traz a mensagem de volta")
    func deleteLeavesAnUndo() async {
        let store = await store()
        let receipts = ActionReceipts()

        let agiu = receipts.intercept(
            .move(messageID: "m1", to: .trash), on: store, stamp: "14:32"
        )

        #expect(agiu)
        #expect(store.messages.first { $0.id == "m1" }?.bucket == .trash)
        #expect(receipts.current?.note == "Movida para a Lixeira — Marina Duarte · 14:32")
        #expect(receipts.current?.undo == .move(messageID: "m1", to: .today))

        StoreCommand.run(receipts.current!.undo, on: store)
        #expect(store.messages.first { $0.id == "m1" }?.bucket == .today)
    }

    @Test("apagar definitivamente também tem volta, e ela é `restoreDeleted`")
    func deleteForeverLeavesAnUndo() async {
        let store = await store()
        let receipts = ActionReceipts()
        store.move(store.messages.first { $0.id == "m1" }!, to: .trash)

        #expect(receipts.intercept(.deleteForever(messageID: "m1"), on: store, stamp: "14:32"))
        #expect(store.messages.first { $0.id == "m1" } == nil)
        #expect(receipts.current?.note == "Apagada de vez — Marina Duarte · 14:32")
        #expect(receipts.current?.undo == .restoreDeleted(messageID: "m1"))

        StoreCommand.run(receipts.current!.undo, on: store)
        #expect(store.messages.first { $0.id == "m1" }?.bucket == .trash)
    }

    /// Nem toda ação ganha faixa: uma confirmação a cada "marcada como lida"
    /// seria ruído, e o executor de comandos precisa continuar sendo o dono
    /// desses casos.
    @Test("o que não é destrutivo passa direto, sem faixa e sem ser executado aqui")
    func nonDestructiveCommandsPassThrough() async {
        let store = await store()
        let receipts = ActionReceipts()

        #expect(!receipts.intercept(
            .setRead(messageID: "m1", isRead: true), on: store, stamp: "14:32"
        ))
        #expect(receipts.current == nil)
        // Não foi executado aqui: quem executa é `MenuCommandRunner`.
        #expect(store.messages.first { $0.id == "m1" }?.isRead == false)
    }

    /// Id que não existe não pode virar uma faixa dizendo que algo aconteceu.
    @Test("apagar uma mensagem que não está lá não inventa recibo")
    func unknownMessageProducesNoReceipt() async {
        let store = await store()
        let receipts = ActionReceipts()
        #expect(!receipts.intercept(.deleteForever(messageID: "nao-existe"), on: store, stamp: "x"))
        #expect(receipts.current == nil)
    }

    // MARK: - A pergunta

    /// "Tem certeza?" sozinho não dá informação nenhuma a quem decide. O número
    /// e a falta de volta têm de estar na pergunta, antes do clique.
    @Test("a confirmação diz quantas mensagens e diz que não dá para desfazer")
    func confirmationSaysWhatItCosts() {
        #expect(EmptyTrashConfirmation.title(3)
            == "Esvaziar a Lixeira e apagar 3 mensagens de vez?")
        #expect(EmptyTrashConfirmation.title(1)
            == "Esvaziar a Lixeira e apagar 1 mensagem de vez?")
        #expect(EmptyTrashConfirmation.message == "Não dá para desfazer.")
    }

    // MARK: - A caixa na barra

    /// O símbolo não é enfeite: ele marca as caixas que **não** são o fluxo da
    /// triagem — a Lixeira, cujo conteúdo se perde, e Enviadas, que guarda o
    /// que saiu. As quatro do fluxo continuam só com o nome, e "arq", "lixo" e
    /// "env" não se distinguem no canto do olho numa trilha de 62pt.
    @Test("só a Lixeira e Enviadas têm símbolo, e a trilha as abrevia")
    func onlyTheTrashCarriesASymbol() {
        for bucket in TriageBucket.allCases
        where bucket != .trash && bucket != .sent && bucket != .drafts {
            #expect(FolderSidebar.symbol(for: bucket) == nil)
        }
        #expect(FolderSidebar.symbol(for: .trash) == "trash")
        #expect(FolderSidebar.symbol(for: .sent) == "paperplane")
        #expect(FolderSidebar.symbol(for: .drafts) == "square.and.pencil")
        #expect(SidebarRail.abbreviation(for: .trash) == "lixo")
        #expect(SidebarRail.abbreviation(for: .sent) == "env")
        #expect(SidebarRail.abbreviation(for: .drafts) == "rasc")
    }
}

/// O retorno com "Desfazer" de "Tirar da agenda", e a razão de ele ser um
/// segundo recibo e não o mesmo.
@Suite("Recibo da agenda")
@MainActor
struct AgendaReceiptTests {

    private func store() async -> MailStore {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        return store
    }

    @Test("tirar da agenda deixa recibo, e desfazer devolve o compromisso")
    func removingLeavesAnUndo() async {
        let store = await store()
        let receipts = ActionReceipts()
        let message = store.messages.first { $0.id == "m1" }!
        let criado = store.addToAgenda(message.detectedEvent!, from: message)!

        let agiu = receipts.interceptAgenda(
            .removeFromAgenda(itemID: criado.id), on: store, stamp: "14:32"
        )

        #expect(agiu)
        #expect(!store.agenda.contains { $0.id == criado.id })
        #expect(receipts.agenda?.note == "Tirada da agenda — \(criado.title) · 14:32")
        #expect(receipts.agenda?.undo == .restoreToAgenda(itemID: criado.id))

        StoreCommand.run(receipts.agenda!.undo, on: store)
        #expect(store.agenda.contains(criado))
    }

    /// Duas faixas porque são duas superfícies. Uma só faria "Tirar da agenda"
    /// na aba Agenda desenhar o recibo no pé de uma lista que não está na tela.
    @Test("o recibo da agenda não escreve no recibo das mensagens, e vice-versa")
    func theTwoReceiptsDoNotOverwriteEachOther() async {
        let store = await store()
        let receipts = ActionReceipts()
        let message = store.messages.first { $0.id == "m1" }!
        let criado = store.addToAgenda(message.detectedEvent!, from: message)!

        receipts.intercept(.move(messageID: "m4", to: .trash), on: store, stamp: "14:00")
        receipts.interceptAgenda(
            .removeFromAgenda(itemID: criado.id), on: store, stamp: "14:32"
        )

        #expect(receipts.current?.messageID == "m4")
        #expect(receipts.agenda?.messageID == criado.id)
    }

    /// Um compromisso que não está na agenda não pode virar uma faixa dizendo
    /// que algo aconteceu.
    @Test("tirar o que não está lá não produz recibo")
    func unknownItemProducesNoReceipt() async {
        let store = await store()
        let receipts = ActionReceipts()
        #expect(!receipts.interceptAgenda(
            .removeFromAgenda(itemID: "email-nao-existe"), on: store, stamp: "x"
        ))
        #expect(receipts.agenda == nil)
    }
}
