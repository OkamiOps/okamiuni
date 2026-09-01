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

    public init() {}

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
