import SwiftUI
import UNICore
import UNIDesign
import UNISync

/// "Entrar com Zoho": o login por navegador, dentro do formulário de conta.
///
/// Arquivo próprio, e não mais um ramo no `AddAccountForm`, por dois motivos.
/// O primeiro é de desenho: ele é o segundo provedor com consentimento no
/// navegador, e o terceiro vai entrar aqui do lado em vez de engordar um
/// formulário que já carrega endereço, servidor, porta, TLS, senha e trilha de
/// teste. O segundo é prático: o formulário é mexido por várias mãos, e um
/// bloco que mora sozinho é um bloco que não briga.
///
/// **Botão de verdade, não link.** Ele tem o mesmo peso do "Autorizar no
/// Google" — fundo de acento, altura cheia, largura do bloco — porque é a
/// mesma ação: a pessoa sai para o navegador e volta com a caixa conectada.
/// Um texto sublinhado no meio de um formulário de senha é uma saída que
/// ninguém vê.
struct ZohoSignInButton: View {
    @Environment(\.theme) private var theme

    let model: AccountsModel
    /// O que está no campo de endereço. Vai como dica de login — quem decide
    /// qual conta entra é o navegador.
    let address: String
    /// O que está no campo de servidor. Entra na decisão de mostrar o botão:
    /// quem digitou um domínio próprio hospedado no Zoho tem `imap.zoho.com`
    /// ali (o preset da tabela, ou o fallback `imappro`), e é exatamente essa
    /// pessoa que mais ganha com o login sem senha de app.
    let host: String
    /// Chamado quando o login terminou sem erro. A folha fecha: a conta já
    /// está na lista, e deixar o formulário aberto no passo do IMAP parece
    /// que o login não avançou.
    var onSignedIn: () -> Void = {}

    /// Esta tela deve oferecer o Zoho?
    ///
    /// Estático e puro porque é regra, não desenho: o teste a afirma sem
    /// montar `View` nenhuma — a mesma disciplina de `AddAccountForm.route`.
    ///
    /// Duas portas de entrada, e as duas importam:
    ///
    /// - o **endereço** num domínio do Zoho (`zoho.com`, `zohomail.com`) é a
    ///   caixa pessoal, que cai no preset "Zoho" da tabela;
    /// - o **host** falando em Zoho cobre o domínio próprio
    ///   (`marina@aempresa.com` com `imap.zoho.com` no campo), que é o caso em
    ///   que a tabela de presets não tem nada a dizer e a pessoa — ou a
    ///   descoberta por MX — pôs o servidor ali.
    static func applies(address: String, host: String) -> Bool {
        if let preset = ProviderDetector.domain(of: address)
            .flatMap(ImapPresets.preset(forDomain:)),
           preset.hostMark == "zoho" {
            return true
        }
        return host.lowercased().contains("zoho")
    }

    var body: some View {
        // A disponibilidade é do **build**, não da pessoa: sem as credenciais
        // do Zoho no bundle o botão some em vez de aparecer apagado. Um botão
        // desabilitado promete uma saída que não existe neste aplicativo.
        if Self.applies(address: address, host: host), model.canAddZoho {
            VStack(spacing: 10) {
                Button {
                    Task {
                        await model.addZoho(address: address)
                        if model.lastError == nil { onSignedIn() }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Text(L10n.tr("Entrar com Zoho"))
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 11, weight: .semibold))
                            .accessibilityHidden(true)
                    }
                    .font(theme.sans.font(size: 14.5, weight: .semibold))
                    .foregroundStyle(theme.onAccent.color)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(
                        theme.accent.color,
                        in: RoundedRectangle(
                            cornerRadius: theme.modalFieldRadius, style: .continuous
                        )
                    )
                    .shadow(theme.modalAccentGlow)
                    .contentShape(RoundedRectangle(cornerRadius: theme.modalFieldRadius))
                }
                .buttonStyle(.plain)
                .disabled(model.isBusy)
                .accessibilityIdentifier("add-account-zoho")
                .focusRing(cornerRadius: theme.modalFieldRadius, tint: \.onAccent)
                .help(model.isBusy
                    ? L10n.tr("Há outra ação em curso; ela termina em instantes.")
                    : L10n.tr("Abrir o login do Zoho no navegador"))

                Text(L10n.tr("O login abre no navegador e você volta sozinho para cá. Sem senha de app."))
                    .font(theme.sans.font(size: 13))
                    .lineSpacing(0.5 * 13)
                    .foregroundStyle(theme.ink3.color)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
