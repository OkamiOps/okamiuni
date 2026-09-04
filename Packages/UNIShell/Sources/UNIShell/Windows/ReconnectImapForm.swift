import SwiftUI
import UNICore
import UNIDesign
import UNISync

/// A reconexão de uma conta IMAP: a senha nova, com o resto já preenchido.
///
/// **Não é o `AddAccountForm` com outro título.** Aquele existe para descobrir
/// uma conta que o app ainda não conhece — rota, host, porta, TLS — e termina
/// gravando uma conta. Este existe para trocar **uma** coisa numa conta que já
/// está aqui, com id, banco, fila de saída e cor próprios, e é por isso que o
/// endereço e o servidor chegam prontos: quem só trocou a senha de app não
/// pediu para redigitar a identidade da conta, e redigitá-la errado é
/// exatamente como se acaba com duas contas onde havia uma.
///
/// O endereço continua editável — teclado erra, e travá-lo esconderia um erro
/// em vez de o corrigir —, mas ele é **conferido**: voltar com outro endereço é
/// recusa explicada (`SyncError.contaDiferente`), não uma conta nova.
struct ReconnectImapForm: View {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    private let model: AccountsModel
    private let status: AccountStatus
    private let onClose: () -> Void

    @State private var address: String
    @State private var password = ""
    @State private var host: String
    @State private var port: String
    @State private var security: ImapEndpoint.Security

    init(model: AccountsModel, status: AccountStatus, onClose: @escaping () -> Void) {
        self.model = model
        self.status = status
        self.onClose = onClose
        _address = State(initialValue: status.address)
        _host = State(initialValue: status.imap?.host ?? "")
        _port = State(initialValue: status.imap.map { "\($0.port)" } ?? "993")
        _security = State(initialValue: status.imap?.security ?? .tls)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.tr("RECONECTAR CONTA")).capsLabel()
            Text(L10n.tr("A conta, as mensagens já baixadas e a fila de saída continuam onde estão. O que muda é a senha guardada."))
                .font(theme.sans.font(size: 11.5))
                .foregroundStyle(theme.ink3.color)
                .fixedSize(horizontal: false, vertical: true)

            campo(texto: $address, dica: L10n.tr("endereço@qualquerdominio.com"))
            SecureField(L10n.tr("senha de app"), text: $password)
                .textFieldStyle(.plain)
                .font(theme.sans.font(size: 12.5))
                .foregroundStyle(theme.ink.color)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(theme.surface2.color, in: RoundedRectangle(cornerRadius: theme.radiusSmall))

            HStack(spacing: 8) {
                campo(texto: $host, dica: "imap.servidor.com")
                TextField("993", text: $port)
                    .textFieldStyle(.plain)
                    .font(theme.mono.font(size: 12))
                    .foregroundStyle(theme.ink.color)
                    .frame(width: 64, height: 32)
                    .padding(.horizontal, 8)
                    .background(theme.surface2.color, in: RoundedRectangle(cornerRadius: theme.radiusSmall))
                ComposerSelect(
                    title: L10n.tr("Forma de TLS"),
                    selected: security.rawValue,
                    width: 108,
                    groups: [.init(title: nil, options: [
                        .init(value: ImapEndpoint.Security.tls.rawValue, label: "TLS (993)"),
                        .init(value: ImapEndpoint.Security.startTLS.rawValue, label: "STARTTLS (143)"),
                    ])],
                    pick: { valor in
                        security = ImapEndpoint.Security(rawValue: valor) ?? .tls
                        port = security == .tls ? "993" : "143"
                    }
                )
            }

            if let erro = model.lastError {
                Text(erro.mensagem)
                    .font(theme.sans.font(size: 11.5))
                    .foregroundStyle(theme.danger.color)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button(L10n.tr("Reconectar")) {
                    guard let endpoint else { return }
                    Task {
                        let passou = await model.reconnectImap(
                            accountID: status.accountID, address: address,
                            password: password, endpoint: endpoint
                        )
                        if passou { onClose() }
                    }
                }
                .buttonStyle(.plain)
                .font(theme.sans.font(size: 12, weight: .semibold))
                .foregroundStyle(theme.onAccent.color)
                .padding(.horizontal, 13)
                .frame(height: 30)
                .background(theme.accent.color, in: RoundedRectangle(cornerRadius: 8))
                .disabled(model.isBusy || password.isEmpty || endpoint == nil)
                .help(ajuda)
                .focusRing(cornerRadius: 8)

                Button(L10n.tr("Cancelar")) { onClose() }
                    .buttonStyle(.plain)
                    .font(theme.sans.font(size: 12))
                    .foregroundStyle(theme.ink3.color)
                    .focusRing(cornerRadius: theme.radiusSmall)

                if model.isBusy { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
            }
        }
        .padding(20)
        .frame(width: 420, alignment: .leading)
        .background(theme.surface.color)
    }

    private func campo(texto: Binding<String>, dica: String) -> some View {
        TextField(dica, text: texto)
            .textFieldStyle(.plain)
            .font(theme.sans.font(size: 12.5))
            .foregroundStyle(theme.ink.color)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(theme.surface2.color, in: RoundedRectangle(cornerRadius: theme.radiusSmall))
    }

    /// Por que o botão está apagado — uma frase por motivo, como no formulário
    /// de adicionar. Controle que existe explica o que faz.
    private var ajuda: String {
        if model.isBusy { return L10n.tr("Há outra ação em curso; ela termina em instantes.") }
        if password.isEmpty { return L10n.tr("Falta a senha de app desta conta.") }
        if endpoint == nil { return L10n.tr("Falta o servidor IMAP ou a porta.") }
        return L10n.tr("Autenticar de novo e gravar a senha por cima — nada é apagado se falhar.")
    }

    private var endpoint: ImapEndpoint? {
        guard !host.isEmpty, let numero = Int(port), numero > 0 else { return nil }
        return ImapEndpoint(host: host, port: numero, security: security)
    }
}
