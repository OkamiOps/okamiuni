import SwiftUI
import UNICore

/// A faixa de "Desfazer" das ações da agenda, flutuando no pé da superfície.
///
/// Ela é a mesma peça que a lista usa (`SwipeUndoBand`) — a frase, o botão, a
/// vida útil e a reinicialização por `id` são as mesmas, e é assim que "Tirar
/// da agenda" se parece com apagar uma mensagem, porque as duas são a mesma
/// promessa: aconteceu, e dá para voltar.
///
/// O que ela acrescenta é **onde**: as quatro superfícies que desenham cartão
/// de compromisso vivem em dois contêineres — a trilha do email e a coluna da
/// aba Agenda —, e o recibo tem de aparecer no que está na tela. Uma faixa só,
/// no pé da lista de mensagens, ficaria invisível na aba Agenda.
///
/// Flutua, e não empurra, pela mesma razão de sempre: a grade não pode pular
/// porque uma ação aconteceu.
struct AgendaUndoBand: ViewModifier {
    let store: MailStore
    @Environment(ActionReceipts.self) private var receipts: ActionReceipts?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) { band }
            .task(id: receipts?.agenda?.id) {
                guard receipts?.agenda != nil else { return }
                try? await Task.sleep(for: MessageList.receiptLifetime)
                guard !Task.isCancelled else { return }
                withAnimation(SwipeMotion.transition) { receipts?.agenda = nil }
            }
    }

    @ViewBuilder
    private var band: some View {
        if let receipts, let receipt = receipts.agenda {
            SwipeUndoBand(receipt: receipt) {
                StoreCommand.run(receipt.undo, on: store)
                withAnimation(SwipeMotion.transition) { receipts.agenda = nil }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

extension View {
    /// Pendura a faixa de retorno da agenda, e o intercetador que a alimenta.
    func agendaUndoBand(store: MailStore) -> some View {
        modifier(AgendaUndoBand(store: store))
    }
}
