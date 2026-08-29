import SwiftUI
import UNICore
import UNIDesign
import UNISync

/// A cena de **Configurações** — "Contas" até o primeiro teste com contas
/// reais, quando o dono do projeto pediu o nome que o macOS já reserva para
/// ⌘,. Cena de verdade, como as quatro do Marco 1: ⌘W fecha, entra no menu
/// Janela, tem tamanho declarado. `UNIWindow.accounts` continua sendo o id —
/// só o que a pessoa lê mudou, não o que o código chama as coisas.
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
            WindowTitleBar(title: "Configurações")
            // "Contas" é a primeira seção de Configurações, e por ora a
            // única — nomeá-la (`accountsSection`, abaixo) é o que separa
            // "seção" de "corpo da janela" neste `VStack`, para a próxima
            // seção entrar como outro membro dele, ao lado desta, sem
            // reformar o que já existe. Nenhuma seção nova nasce aqui: é
            // estrutura, não conteúdo.
            accountsSection
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

    /// A seção "Contas": a lista (rolável, cresce) mais o formulário de
    /// adicionar (fixo, embaixo do divisor). `@ViewBuilder`, e não um
    /// `VStack` em volta — um `VStack` daria à seção um recuo e um
    /// espaçamento próprios, que não é o que este corpo tem hoje; o
    /// `@ViewBuilder` deixa `AccountsList`, o divisor e `AddAccountForm`
    /// exatamente como membros diretos do `VStack` de `body`, do jeito que
    /// já eram antes desta seção ganhar nome.
    @ViewBuilder
    private var accountsSection: some View {
        AccountsList(
            statuses: model.statuses,
            // Reconectar e tentar de novo caem na mesma carga — o que
            // muda é o que a pessoa vem consertar antes de clicar, e é o
            // rótulo que diz isso. Duas chamadas ao mesmo lugar é honesto;
            // dois rótulos para dois problemas é o que a `AccountsCopy`
            // decide.
            onReconnect: { id in Task { await model.loadInitial(id) } },
            onRetry: { id in Task { await model.loadInitial(id) } },
            // A fila parada **não** cai na carga: a trava dela mora no
            // executor, e nenhuma quantidade de mensagens baixadas a tira de
            // lá. Ver `AccountsModel.retryQueue`.
            onRetryQueue: { id in Task { await model.retryQueue(id) } },
            onRemove: { id in removendo = id }
        )
        Rectangle()
            .fill(theme.line.color)
            .frame(height: Hairline.thickness(displayScale))
        AddAccountForm(model: model)
    }
}
