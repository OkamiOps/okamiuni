import SwiftUI
import UNICore
import UNIDesign

/// A pergunta antes de esvaziar a Lixeira.
///
/// **A razão de ela existir é estreita**: esvaziar a Lixeira é a única ação de
/// mensagem sem "Desfazer". Arquivar, apagar e mover têm recibo com volta (ver
/// `SwipeUndoBand`), e para essas o desenho não pergunta nada — avisa, com a
/// faixa de desfazer. Esta não tem volta, e a pergunta é o que fica no lugar.
///
/// ## O que mudou
///
/// Era `confirmationDialog`, o diálogo do macOS. Trocou por `UNIConfirmation`,
/// a peça do desenho, por três motivos medidos e não estéticos:
///
/// 1. O diálogo do sistema não vira com o tema. Nos 28 temas do app ele saía
///    sempre no cinza do macOS, e o vermelho do destrutivo não era o `remove`
///    do tema — foi a mesma queixa que tirou o `confirmationDialog` da janela
///    do compromisso, onde o magenta do Remover sumia.
/// 2. Ele não aceita a frase que o desenho pede. "A mais antiga é de março"
///    cabe no corpo; o rótulo "Apagar as 23" **com o número** não cabe num
///    botão de diálogo sem virar título.
/// 3. Com ele, o app tinha dois idiomas de pergunta — o do macOS aqui e o
///    nosso na janela do compromisso. Agora é um.
///
/// O que não mudou: o número está na pergunta, antes do clique. "Tem certeza?"
/// sozinho não dá informação nenhuma a quem decide.
struct EmptyTrashConfirmation: ViewModifier {
    let store: MailStore
    @Binding var isPresented: Bool

    private var count: Int { store.trashCount(accountID: store.selectedAccountID) }

    private var oldest: String? {
        store.oldestTrashDate(accountID: store.selectedAccountID).map { Self.monthLabel($0) }
    }

    /// "março" — mês por extenso, sem dia e sem ano quando é deste ano.
    ///
    /// O dia exato não ajuda a decidir ("a mais antiga é de 3 de março" não é
    /// mais decidível que "de março"), e o mês é o que dá a escala do que se
    /// perde.
    static func monthLabel(_ date: Date, now: Date = Date(), locale: Locale = L10n.locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        let calendar = Calendar.current
        let mesmoAno = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        formatter.setLocalizedDateFormatFromTemplate(mesmoAno ? "MMMM" : "MMMM y")
        return formatter.string(from: date)
    }

    /// "3 mensagens" — o número é o que faz a pergunta ser respondível.
    static func title(_ count: Int) -> String {
        count == 1
            ? L10n.tr("Apagar de vez a mensagem da Lixeira?")
            : L10n.tr("Apagar de vez as \(count) mensagens da Lixeira?")
    }

    static var message: String { L10n.tr("Isso não dá para desfazer — por isso a pergunta.") }

    /// O texto inteiro da confirmação. Puro e estático: é o que o retrato
    /// desenha e o que o teste afirma, sem precisar de uma `MailStore`.
    static func text(count: Int, oldest: String?) -> UNIConfirmationText {
        let detalhe = oldest.map { L10n.tr("A mais antiga é de \($0). \(message)") } ?? message
        return UNIConfirmationText(
            title: title(count),
            detail: detalhe,
            confirm: count == 1 ? L10n.tr("Apagar a mensagem") : L10n.tr("Apagar as \(count)"),
            icon: "trash"
        )
    }

    func body(content: Content) -> some View {
        content.uniConfirmation(
            isPresented ? Self.text(count: count, oldest: oldest) : nil,
            onConfirm: {
                isPresented = false
                store.emptyTrash(accountID: store.selectedAccountID)
            },
            onCancel: { isPresented = false }
        )
    }
}
