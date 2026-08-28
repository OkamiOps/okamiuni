import SwiftUI
import UNICore
import UNIDesign
import UNISync

/// A cena de Contas. Cena de verdade, como as quatro do Marco 1: ⌘W fecha,
/// entra no menu Janela, tem tamanho declarado.
public struct AccountsWindow: View {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    private let model: AccountsModel
    @State private var removendo: String?

    public init(model: AccountsModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            WindowTitleBar(title: "Contas")
            AccountsList(
                statuses: model.statuses,
                // Reconectar e tentar de novo caem na mesma carga — o que
                // muda é o que a pessoa vem consertar antes de clicar, e é o
                // rótulo que diz isso. Duas chamadas ao mesmo lugar é honesto;
                // dois rótulos para dois problemas é o que a `AccountsCopy`
                // decide.
                onReconnect: { id in Task { await model.loadInitial(id) } },
                onRetry: { id in Task { await model.loadInitial(id) } },
                onRemove: { id in removendo = id }
            )
            Rectangle()
                .fill(theme.line.color)
                .frame(height: Hairline.thickness(displayScale))
            AddAccountForm(model: model)
        }
        .background(theme.paper.color)
        .task { await model.start() }
        // Remover apaga banco **e** Keychain: é destrutivo, e destrutivo
        // pergunta antes — a mesma regra de `EmptyTrashConfirmation`.
        .confirmationDialog(
            "Remover esta conta?",
            isPresented: Binding(get: { removendo != nil }, set: { if !$0 { removendo = nil } })
        ) {
            Button("Remover", role: .destructive) {
                if let id = removendo { Task { await model.remove(id) } }
                removendo = nil
            }
            Button("Cancelar", role: .cancel) { removendo = nil }
        } message: {
            Text("As mensagens já baixadas e a senha guardada no Keychain serão apagadas. A conta no servidor não é tocada.")
        }
    }
}
