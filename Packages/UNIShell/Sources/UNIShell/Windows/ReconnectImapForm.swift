import SwiftUI
import UNICore
import UNIDesign
import UNISync

/// A reconexão de uma conta IMAP: **um campo**, com o resto já no lugar.
///
/// **Não é o `AddAccountForm` com outro título.** Aquele existe para descobrir
/// uma conta que o app ainda não conhece — rota, host, porta, TLS — e termina
/// gravando uma conta. Este existe para trocar **uma** coisa numa conta que já
/// está aqui, com id, banco, fila de saída e cor próprios, e é por isso que o
/// endereço e o servidor chegam prontos: quem só trocou a senha não
/// pediu para redigitar a identidade da conta, e redigitá-la errado é
/// exatamente como se acaba com duas contas onde havia uma.
///
/// ## O desenho
///
/// Protótipo: `ModalContas.dc.html`, bloco "RECONECTAR CONTA". Folha de 460,
/// cabeçalho com o avatar de 44 na cor da conta, "Reconectar" em 20 e o
/// endereço em mono logo abaixo; o recado de que nada se perde num bloco
/// `soft`; **um** campo, em foco; e o servidor atual numa linha mono com
/// "mudar" ao lado.
///
/// O protótipo punha "O que é isso?" dentro do campo, apontando para o guia
/// de senha de app. Saiu: o campo pede a senha da conta, que não tem o que
/// explicar, e o link mandava quem não tem senha de app procurar uma.
///
/// O endereço deixou de ser campo. Ele é a identidade desta folha — é o que o
/// avatar e a linha mono do cabeçalho dizem —, e um campo editável ali
/// convidava justamente ao erro que `SyncError.contaDiferente` tem de recusar.
/// Quem precisa mudar endereço está adicionando outra conta, não reconectando
/// esta. "mudar" abre host, porta e TLS, que é o que a reconexão de fato às
/// vezes precisa.
struct ReconnectImapForm: View {
    @Environment(\.theme) private var theme

    private let model: AccountsModel
    private let status: AccountStatus
    private let onClose: () -> Void

    @State private var password = ""
    @State private var host: String
    @State private var port: String
    @State private var security: ImapEndpoint.Security
    @State private var mudandoServidor = false

    init(model: AccountsModel, status: AccountStatus, onClose: @escaping () -> Void) {
        self.model = model
        self.status = status
        self.onClose = onClose
        _host = State(initialValue: status.imap?.host ?? "")
        _port = State(initialValue: status.imap.map { "\($0.port)" } ?? "993")
        _security = State(initialValue: status.imap?.security ?? .tls)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            fields
            footer
        }
        .frame(width: Theme.ModalWidth.smallSheet)
        .modalSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("Reconectar \(status.address)"))
    }

    /// `padding: 26px 28px 0`, avatar de 44 e o par título/endereço.
    private var header: some View {
        HStack(spacing: 14) {
            Text(initial)
                .font(theme.sans.font(size: 16, weight: .semibold))
                .foregroundStyle(theme.onAccent.color)
                .frame(width: 44, height: 44)
                .background(accountTint.color, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.tr("Reconectar"))
                    .font(theme.sans.font(size: 20, weight: .bold))
                    .tracking(theme.modalTitleTracking(at: 20) * 0.75)   // -0.015em
                    .foregroundStyle(theme.ink.color)
                Text(status.address)
                    .font(theme.mono.font(size: 13))
                    .foregroundStyle(theme.ink3.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, Theme.modalHeaderTop)
        .padding(.horizontal, Theme.modalSide)
    }

    private var initial: String {
        status.address.first.map { String($0).uppercased() } ?? "?"
    }

    /// O azul do avatar no protótipo (`#0ea5e9`), que é o `liveMeeting` do
    /// tema.
    ///
    /// **Não é a cor da conta**, e é de propósito: `AccountStatus` não carrega
    /// a tinta escolhida para ela (`AccountTint` mora na `Account`, e a lista
    /// de Contas pinta o chip em `ink4`). Derivar uma aqui — por hash do id,
    /// por posição na lista — daria um avatar de cor diferente da que **esta**
    /// conta mostra na barra lateral, que é pior do que uma cor neutra. Quando
    /// o status passar a trazer a tinta, esta linha troca por ela.
    private var accountTint: TokenColor { theme.liveMeeting }

    /// `padding: 16px 28px 0; gap: 14px`.
    private var fields: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.tr("A conta, as mensagens e a fila de saída continuam como estão. Só a senha muda."))
                .font(theme.sans.font(size: 13.5))
                .lineSpacing(0.5 * 13.5)
                .foregroundStyle(theme.ink2.color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 11)
                .padding(.horizontal, 14)
                .background(
                    theme.modalSoft.color,
                    in: RoundedRectangle(cornerRadius: theme.modalFieldRadius, style: .continuous)
                )

            // Uma senha, sem adjetivo. Esta folha abre quando o servidor
            // recusou a credencial que estava guardada, e o que a pessoa tem
            // em mãos nessa hora é a senha com que ela entra no webmail. O
            // rótulo antigo dizia "senha de app" e mandava quem não tem uma
            // atrás de uma tela que a conta dela não oferece.
            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.tr("Nova senha"))
                    .font(theme.sans.font(size: 12, weight: .semibold))
                    .foregroundStyle(theme.ink3.color)
                SecureField(L10n.tr("senha da conta"), text: $password)
                    .textFieldStyle(.plain)
                    .font(theme.mono.font(size: 13.5))
                    .foregroundStyle(theme.ink.color)
                    .accessibilityLabel(L10n.tr("Nova senha"))
                    .modalFieldBox(focused: true, verticalPadding: 11, horizontalPadding: 12)
            }

            serverLine
            if let erro = model.lastError {
                Text(erro.mensagem)
                    .font(theme.sans.font(size: 12.5))
                    .foregroundStyle(theme.danger.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 16)
        .padding(.horizontal, Theme.modalSide)
    }

    /// `imap.empresa.com.br · 993 · TLS` numa linha mono, com "mudar" ao lado.
    /// Endereço se confere letra a letra, e é por isso que ele é mono.
    @ViewBuilder
    private var serverLine: some View {
        if mudandoServidor {
            HStack(alignment: .bottom, spacing: 10) {
                TextField("imap.servidor.com", text: $host)
                    .textFieldStyle(.plain)
                    .font(theme.mono.font(size: 13))
                    .foregroundStyle(theme.ink.color)
                    .modalFieldBox(verticalPadding: 9, horizontalPadding: 12)
                    .accessibilityLabel(L10n.tr("Servidor IMAP"))
                TextField("993", text: $port)
                    .textFieldStyle(.plain)
                    .font(theme.mono.font(size: 13))
                    .foregroundStyle(theme.ink.color)
                    .modalFieldBox(verticalPadding: 9, horizontalPadding: 12)
                    .frame(width: 72)
                    .accessibilityLabel(L10n.tr("Porta"))
                ComposerSelect(
                    title: L10n.tr("Forma de TLS"),
                    selected: security.rawValue,
                    width: 128,
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
        } else {
            HStack(spacing: 8) {
                Text("\(host) · \(port) · \(security == .tls ? "TLS" : "STARTTLS")")
                    .font(theme.mono.font(size: 12))
                    .foregroundStyle(theme.ink3.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button { mudandoServidor = true } label: {
                    Text(L10n.tr("mudar"))
                        .font(theme.sans.font(size: 12.5, weight: .medium))
                        .foregroundStyle(theme.accentInk.color)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusRing(cornerRadius: theme.modalButtonRadius)
                Spacer(minLength: 0)
            }
        }
    }

    private var footer: some View {
        ModalFooter(context: L10n.tr("Testa antes de salvar."), onCancel: onClose) {
            ModalPrimaryButton(
                title: L10n.tr("Testar e reconectar"),
                enabled: !model.isBusy && !password.isEmpty && endpoint != nil,
                horizontalPadding: 18,
                action: reconnect
            )
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("reconnect-primary")
            .help(ajuda)
        }
        .padding(.top, 18)
    }

    private func reconnect() {
        guard let endpoint else { return }
        Task {
            let passou = await model.reconnectImap(
                accountID: status.accountID, address: status.address,
                password: password, endpoint: endpoint
            )
            if passou { onClose() }
        }
    }

    /// Por que o botão está apagado — uma frase por motivo, como no formulário
    /// de adicionar. Controle que existe explica o que faz.
    private var ajuda: String {
        if model.isBusy { return L10n.tr("Há outra ação em curso; ela termina em instantes.") }
        if password.isEmpty { return L10n.tr("Falta a senha desta conta.") }
        if endpoint == nil { return L10n.tr("Falta o servidor IMAP ou a porta.") }
        return L10n.tr("Autenticar de novo e gravar a senha por cima — nada é apagado se falhar.")
    }

    private var endpoint: ImapEndpoint? {
        guard !host.isEmpty, let numero = Int(port), numero > 0 else { return nil }
        return ImapEndpoint(host: host, port: numero, security: security)
    }
}
