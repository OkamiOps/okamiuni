import Foundation
import Observation
import UNICore

/// O último "o que acabou de acontecer, e como desfazer", partilhado pelas
/// superfícies que agem sobre a mesma mensagem.
///
/// ## Por que saiu do `@State` da lista
///
/// A faixa de retorno nasceu no arraste, e ali um `@State` na `MessageList`
/// bastava: o gesto começava e terminava dentro dela. A Task AR quebrou essa
/// suposição — apagar chega do menu da linha, do menu do **leitor** e da tecla
/// ⌫, e as três têm de produzir a mesma faixa com "Desfazer". Um `@State` por
/// superfície daria ao leitor uma ação destrutiva **sem** volta visível, que é
/// pior do que não ter a ação.
///
/// Quem **desenha** a faixa continua sendo a lista, e por um motivo que não
/// mudou: a linha some quando a mensagem sai da caixa, e um retorno preso a ela
/// morreria junto com o que precisava desfazer. A lista sobrevive a tudo.
///
/// Chega pelo ambiente, e é opcional lá — o harness de renderização e as
/// previews não precisam prover nada, e a lista cai num objeto próprio. É o
/// mesmo alcance que `SwipeSettingsStore` já tem.
@MainActor
@Observable
public final class ActionReceipts {
    public var current: SwipeReceipt?

    /// O retorno das ações **da agenda**, separado do das mensagens.
    ///
    /// Duas faixas porque são duas superfícies: a das mensagens vive no pé da
    /// lista, a da agenda vive no pé da trilha e da grade. Uma faixa só faria
    /// "Tirar da agenda" na aba Agenda desenhar o recibo num painel que não
    /// está na tela — a definição de retorno invisível.
    public var agenda: SwipeReceipt?

    /// A leva em curso, quando há uma. Ver `beginBatch`.
    private var batch: Batch?

    public init() {}

    // MARK: - A leva

    /// O que uma leva vai precisar para voltar atrás.
    private struct Batch {
        /// Os estados fotografados **antes**, um por mensagem e sem repetir:
        /// duas ações sobre a mesma mensagem na mesma leva têm um estado
        /// anterior só, e gravar o segundo (já mudado) faria o Desfazer
        /// devolver a mensagem para o meio do caminho.
        var states: [MessageState] = []
        var seen: Set<String> = []
        /// As regras aprendidas na leva, já normalizadas.
        var senders: [String] = []
        /// Houve ação sem volta (apagar de vez, esvaziar lixeira): a leva
        /// inteira deixa de ser desfazível, porque um Desfazer pela metade é
        /// pior do que nenhum.
        var blocked = false
        var count = 0
    }

    /// **Abre uma leva.** Enquanto ela está aberta, `intercept` não sela
    /// recibo nenhum: ele fotografa o estado, executa, e guarda a volta para
    /// o recibo único que `sealBatch` produz.
    ///
    /// É o mecanismo que "Arquivar e aprender" estreou (duas ações, um
    /// Desfazer) generalizado para a leva de um cartão da gaveta. Não há um
    /// segundo: executar um cartão é uma coisa só que a pessoa mandou fazer.
    public func beginBatch() {
        batch = Batch()
    }

    /// **Fecha a leva** e devolve o recibo dela, ou `nil` quando não há o que
    /// desfazer.
    ///
    /// Quando não há, `current` é **zerado**: um recibo de outra origem ainda
    /// de pé (a mensagem que a pessoa apagou um minuto atrás) faria o cartão
    /// escrever "Feito · Desfazer" e o Desfazer restaurar aquela outra coisa
    /// — o defeito C1 por inteiro.
    ///
    /// - Parameter undoable: `false` quando quem chama sabe que a leva tem
    ///   ação sem volta — uma escrita de agenda, por exemplo, que não é
    ///   comando e por isso não passa por aqui.
    @discardableResult
    public func sealBatch(
        note: String? = nil, undoable: Bool = true, stamp: String
    ) -> SwipeReceipt? {
        guard let leva = batch else { return nil }
        batch = nil
        guard undoable, !leva.blocked, !leva.states.isEmpty || !leva.senders.isEmpty else {
            current = nil
            return nil
        }
        let recibo = SwipeReceipt(
            messageID: leva.states.first?.messageID ?? "",
            note: note ?? Self.batchNote(count: leva.count, stamp: stamp),
            undo: .restoreBatch(states: leva.states, forgottenSenders: leva.senders)
        )
        current = recibo
        return recibo
    }

    /// "Feito — 3 emails · 14:32". A contagem é de **ações**, que é o que a
    /// pessoa acabou de mandar fazer.
    public static func batchNote(count: Int, stamp: String) -> String {
        let quantas = count == 1 ? "1 email" : "\(count) emails"
        return "Feito — \(quantas) · \(stamp)"
    }

    /// Uma ação **dentro** de uma leva: fotografa, executa e guarda a volta.
    ///
    /// Devolve `false` para o que não muda estado de mensagem (abrir o
    /// composer, revelar a linha): isso segue o caminho de sempre e não entra
    /// no Desfazer, porque não há o que desfazer numa janela que abriu.
    private func record(_ command: ContextCommand, on store: MailStore) -> Bool {
        switch command {
        case let .move(messageID, _), let .setRead(messageID, _),
             let .setFlagged(messageID, _):
            snapshot(messageID, on: store)
            guard StoreCommand.run(command, on: store) else { return false }
            batch?.count += 1
            return true

        case let .learnSender(address, neverPriority):
            let normalizado = SenderRule.normalize(address)
            guard StoreCommand.run(command, on: store) else { return false }
            if neverPriority, !normalizado.isEmpty, batch?.senders.contains(normalizado) == false {
                batch?.senders.append(normalizado)
            }
            return true

        // Sem volta: a leva inteira perde o Desfazer em vez de prometer um
        // que devolveria metade.
        case .deleteForever, .emptyTrash, .restoreDeleted:
            batch?.blocked = true
            return false

        default:
            return false
        }
    }

    /// O estado de uma mensagem **antes** da leva, uma vez só.
    private func snapshot(_ messageID: String, on store: MailStore) {
        guard batch?.seen.contains(messageID) == false else { return }
        batch?.seen.insert(messageID)
        batch?.states.append(contentsOf: store.states(of: [messageID]))
    }

    /// Dá a "Tirar da agenda" o mesmo retorno com "Desfazer" que "Colocar na
    /// agenda" já tem no cartão de resumo do leitor.
    ///
    /// Como nos outros, o recibo nasce **antes** da mudança: fora da lista, o
    /// compromisso não sabe mais o título nem o horário dele.
    @discardableResult
    public func interceptAgenda(
        _ command: ContextCommand, on store: MailStore, stamp: String
    ) -> Bool {
        let itemID: String
        let note: String
        switch command {
        case .removeFromAgenda(let id):
            itemID = id
            note = "Tirada da agenda"
        case .cancelMeeting(let id):
            itemID = id
            note = "Reunião cancelada"
        default:
            return false
        }
        guard let item = store.agenda.first(where: { $0.id == itemID }) else { return false }

        agenda = SwipeReceipt(
            messageID: itemID,
            note: "\(note) — \(item.title) · \(stamp)",
            undo: .restoreToAgenda(itemID: itemID)
        )
        if case .cancelMeeting = command {
            store.cancelMeeting(itemID)
        } else {
            store.removeFromAgenda(itemID)
        }
        return true
    }

    /// Dá a "Apagar" e a "Apagar definitivamente" o retorno com "Desfazer" que
    /// o arraste já tem, venham eles do menu da linha, do menu do leitor ou da
    /// tecla ⌫.
    ///
    /// Devolver `true` quer dizer "já cuidei disto": `MenuCommandRunner` não
    /// repete a mutação. Todo comando que não é destrutivo passa direto e segue
    /// o caminho de sempre — nem toda ação ganha faixa, e encher a tela de
    /// confirmação de "marcada como lida" seria ruído.
    ///
    /// O recibo nasce **antes** da mudança, como o do arraste: depois de
    /// apagada, a mensagem não está mais no store para dizer quem era.
    @discardableResult
    public func intercept(_ command: ContextCommand, on store: MailStore, stamp: String) -> Bool {
        // Dentro de uma leva ninguém sela recibo sozinho: o recibo é um só, e
        // sai em `sealBatch`.
        if batch != nil { return record(command, on: store) }
        switch command {
        case .move(let messageID, .trash):
            guard let message = store.messages.first(where: { $0.id == messageID }) else {
                return false
            }
            let made = SwipeReceipt.of(.trash, message: message, stamp: stamp)
            StoreCommand.run(command, on: store)
            current = made
            return true

        case .deleteForever(let messageID):
            guard let message = store.messages.first(where: { $0.id == messageID }) else {
                return false
            }
            let made = SwipeReceipt.ofDeleteForever(message: message, stamp: stamp)
            store.deleteForever(messageID)
            current = made
            return true

        default:
            return false
        }
    }

    /// **Apagar, venha de onde vier** — a tecla ⌫, o menu, ou o botão da barra
    /// do leitor.
    ///
    /// Uma função só porque a decisão é uma só, e ela tem três partes que não
    /// podem divergir entre superfícies: *o quê* (Lixeira, ou de vez quando a
    /// mensagem já está lá — a mesma regra que `ContextMenus.deleteItem`
    /// escreve no rótulo), *sobre quem* (a conversa, quando a linha é uma
    /// conversa — a decisão da M3-9: a barra do leitor age na pilha da caixa
    /// aberta, como o clique na linha agiria), e *com que volta* (a faixa
    /// "Desfazer", sempre — uma ação destrutiva sem volta visível é pior do que
    /// não ter a ação).
    ///
    /// O recibo nasce **antes** da mudança, como todos os outros: depois de
    /// apagada, a mensagem não está mais no store para dizer quem era.
    ///
    /// - Returns: `false` quando não havia o que apagar — aí a tecla segue o
    ///   caminho dela em vez de ser engolida por um atalho que não fez nada.
    @discardableResult
    public func delete(_ message: Message, on store: MailStore) -> Bool {
        let comando = ContextMenus.deleteItem(message).command
        // Sem conversa aberta (a mensagem revelada de fora da visão), a
        // mensagem — que é o comportamento de sempre.
        guard let conversa = store.conversation(of: message.id), conversa.count > 1 else {
            return intercept(comando, on: store, stamp: Self.stamp)
        }
        switch comando {
        case .deleteForever:
            let feito = SwipeReceipt.ofConversationDeleteForever(
                conversation: conversa, stamp: Self.stamp
            )
            store.deleteForever(conversa)
            current = feito
        default:
            let feito = SwipeReceipt.ofConversation(
                .trash, conversation: conversa,
                states: store.states(of: conversa.messageIDs), stamp: Self.stamp
            )
            store.move(conversa, to: .trash)
            current = feito
        }
        return true
    }

    /// A hora do recibo. Entra pronta em `SwipeReceipt` justamente para a
    /// formatação ficar num lugar só — ver o comentário de `SwipeReceipt.of`.
    public static var stamp: String {
        Date.now.formatted(date: .omitted, time: .shortened)
    }
}
