import SwiftUI
import UNICore

/// A pergunta antes de esvaziar a Lixeira.
///
/// **É o único diálogo do app**, e a razão é estreita: esvaziar a Lixeira é a
/// única ação sem "Desfazer". Arquivar, apagar e apagar definitivamente têm
/// recibo com volta; esta não tem, e a pergunta é o que fica no lugar dela.
///
/// `confirmationDialog` e não uma folha desenhada por nós: aqui o sistema é o
/// idioma certo. Um diálogo destrutivo tem comportamento que a pessoa reconhece
/// pelo corpo — Esc cancela, ⏎ não confirma um botão destrutivo, o botão
/// vermelho fica onde o macOS o põe. Redesenhá-lo custaria essas garantias sem
/// ganhar nada: ele não é uma superfície do produto, é uma parada. É a mesma
/// exceção deliberada do menu de texto do composer, registrada em
/// `docs/decisoes-de-engenharia.md`.
///
/// A frase diz **quantas** e diz que não dá para desfazer, antes do clique.
struct EmptyTrashConfirmation: ViewModifier {
    let store: MailStore
    @Binding var isPresented: Bool

    private var count: Int { store.trashCount(accountID: store.selectedAccountID) }

    /// "3 mensagens" — o número é o que faz a pergunta ser respondível. "Tem
    /// certeza?" sozinho não dá informação nenhuma a quem decide.
    static func title(_ count: Int) -> String {
        count == 1
            ? "Esvaziar a Lixeira e apagar 1 mensagem de vez?"
            : "Esvaziar a Lixeira e apagar \(count) mensagens de vez?"
    }

    static let message = "Não dá para desfazer."

    func body(content: Content) -> some View {
        content.confirmationDialog(
            Self.title(count),
            isPresented: $isPresented,
            titleVisibility: .visible
        ) {
            Button("Esvaziar lixeira", role: .destructive) {
                store.emptyTrash(accountID: store.selectedAccountID)
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text(Self.message)
        }
    }
}
