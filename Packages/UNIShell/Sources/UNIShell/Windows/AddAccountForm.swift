import AppKit
import SwiftUI
import UNICore
import UNIDesign
import UNISync

/// Os roteiros que a janela de Contas abre, embarcados no aplicativo.
///
/// **Arquivo, não URL.** Um link para o GitHub depende de rede, de branch e de
/// o arquivo não ter sido renomeado — três maneiras de o botão virar um 404, e
/// botão que abre um 404 é botão mudo com um passo a mais. Os dois `.md` entram
/// como recurso do alvo do app (ver `project.yml`) e abrem no aplicativo que o
/// usuário usa para Markdown.
public enum AccountsDocs {
    /// O roteiro do OAuth do Google — o que fazer quando falta o Client ID.
    public static let oauthGoogle = "oauth-google"
    /// O que é uma senha de app, e onde gerar uma em cada provedor.
    public static let senhaDeApp = "senha-de-app"

    /// Os guias nos dois idiomas, para quem verifica o empacotamento.
    public static let all = [oauthGoogle, senhaDeApp, "oauth-google.en", "senha-de-app.en"]

    /// O arquivo dentro do bundle. Nulo quando o app não foi empacotado com ele
    /// — o que acontece num alvo de teste, e é por isso que o botão que o abre
    /// pergunta antes de se acender.
    public static func url(
        _ name: String,
        in bundle: Bundle = .main,
        language: AppLanguage = L10n.language
    ) -> URL? {
        if language.resolved != .portugueseBrazil,
           let english = bundle.url(forResource: "\(name).en", withExtension: "md") {
            return english
        }
        return bundle.url(forResource: name, withExtension: "md")
    }

    /// Abre o roteiro. Devolve `false` quando não havia o que abrir — quem
    /// chama já desabilitou o botão nesse caso; isto é a segunda tranca.
    @discardableResult
    public static func open(_ name: String) -> Bool {
        guard let url = url(name) else { return false }
        return NSWorkspace.shared.open(url)
    }
}

/// Endereço → rota → OAuth ou formulário IMAP, na anatomia dos modais.
///
/// ## O desenho
///
/// Protótipo: `ModalContas.dc.html`, bloco "ADICIONAR CONTA". Folha de 500,
/// cabeçalho "Adicionar conta" com **uma** linha de apoio que muda com a rota,
/// o endereço num campo de 15 com o provedor detectado à direita, e logo
/// abaixo **os três passos do caminho**, à vista antes do primeiro clique.
///
/// A rota decide o resto: no Google, um botão só e a frase de que a senha
/// nunca passa pelo OkamiUNI; no IMAP, servidor/porta/senha e a trilha do
/// teste acontecendo dentro da folha, com "nada fica salvo se falhar" dito no
/// rodapé e não depois do erro.
///
/// O formulário antigo tinha os mesmos campos numa pilha rotulada em
/// versalete, sem caminho e sem trilha: ele dizia **o que** preencher e nunca
/// **onde a pessoa estava**.
public struct AddAccountForm: View {
    @Environment(\.theme) private var theme

    private let model: AccountsModel
    /// Quem fecha a folha. Nulo quando ela está embutida numa coluna que já
    /// tem a própria saída — é o caso da janela de Contas, que a desenha
    /// inteira no detalhe. Sem isto, "Cancelar" seria um botão sem resposta.
    private let onClose: (() -> Void)?

    @State private var address: String
    @State private var password = ""
    @State private var host: String
    @State private var port: String
    @State private var security: ImapEndpoint.Security
    @State private var testado: Bool?
    @State private var testando = false

    /// `initialAddress` existe para o formulário ser **dirigível**: o harness
    /// desenha fora da tela e não digita, e o ensaio do app (`--ensaiar-contas`)
    /// precisa chegar num estado sem sintetizar tecla. Vazio é o caso normal,
    /// e é o que a janela usa.
    ///
    /// `initialHost` é a mesma porta, pela mesma razão, para o único estado que
    /// o endereço não alcança: a nota do endereço numérico depende do que está
    /// no campo de **host**, e a rota nunca sugere um IP.
    public init(
        model: AccountsModel,
        initialAddress: String = "",
        initialHost: String? = nil,
        onClose: (() -> Void)? = nil
    ) {
        self.model = model
        self.onClose = onClose
        _address = State(initialValue: initialAddress)
        let palpite = Self.route(for: initialAddress)
        _host = State(initialValue: initialHost ?? Self.host(of: palpite))
        _port = State(initialValue: Self.port(of: palpite))
        _security = State(initialValue: Self.security(of: palpite))
    }

    /// A rota do endereço digitado. Estático e puro para o teste não precisar
    /// de `View` nenhuma — é a mesma regra de "lógica pura fora de View".
    public static func route(for address: String) -> ProviderRoute? {
        ProviderDetector.route(for: address)
    }

    /// A pessoa mandou: Gmail por IMAP com senha de app, sem OAuth. Vale só
    /// para o endereço em que foi pedido — trocar o endereço desfaz a escolha
    /// (`preenche` zera), senão o clique numa conta contaminaria a próxima.
    @State private var imapForcadoPara: String?

    private var route: ProviderRoute? {
        let rota = Self.route(for: address)
        if case .google = rota, imapForcadoPara == address {
            return .imap(Self.gmailPorImap)
        }
        return rota
    }

    /// O preset que a tabela não tem de propósito (o caminho padrão do Gmail é
    /// OAuth): só existe para quem escolhe a senha de app explicitamente.
    static let gmailPorImap = ImapPreset(
        name: "Gmail (IMAP)", hostMark: "gmail",
        endpoint: ImapEndpoint(host: "imap.gmail.com", port: 993, security: .tls),
        domains: []
    )

    private func forceImapForGoogle() {
        imapForcadoPara = address
        host = Self.gmailPorImap.endpoint.host
        port = "\(Self.gmailPorImap.endpoint.port)"
        security = .tls
    }

    private var isGoogle: Bool {
        if case .google = route { return true }
        return false
    }

    private var isImap: Bool {
        switch route {
        case .imap, .manual: true
        case .google, .none: false
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModalHeader(
                title: L10n.tr("Adicionar conta"),
                subtitle: subtitle
            )
            body(of: route)
            footer
        }
        .frame(width: Theme.ModalWidth.accountSheet)
        .modalSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("Adicionar conta"))
    }

    /// A frase de apoio do cabeçalho — uma só, e ela muda com a rota, que é o
    /// que o protótipo faz (`subtitulo`).
    private var subtitle: String {
        if isGoogle { return L10n.tr("Digite o endereço. O caminho aparece aqui embaixo.") }
        if isImap { return L10n.tr("Servidor próprio: três campos e um teste.") }
        return L10n.tr("Digite o endereço. O caminho aparece aqui embaixo.")
    }

    /// `padding: 18px 28px 0; gap: 16px`.
    @ViewBuilder
    private func body(of route: ProviderRoute?) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            addressField
            AccountPathSteps(steps: pathSteps)
            if isGoogle { googleRoute }
            if isImap { imapRoute }
            if let erro = model.lastError { errorLine(erro) }
            if mostraNotaDoEnderecoNumerico { notaDoEnderecoNumerico }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 18)
        .padding(.horizontal, Theme.modalSide)
    }

    /// O endereço, com o provedor detectado à direita: ponto de 7 e o nome em
    /// 12. Em foco (a rota Google, que é onde o desenho o mostra) com a borda
    /// de 1,5 e o anel de 4.
    private var addressField: some View {
        HStack(spacing: 10) {
            TextField(L10n.tr("endereço@qualquerdominio.com"), text: $address)
                .textFieldStyle(.plain)
                .font(theme.sans.font(size: 15))
                .foregroundStyle(theme.ink.color)
                .onChange(of: address) { _, novo in preenche(novo) }
                .accessibilityLabel(L10n.tr("Endereço da conta"))
            if let provider = providerLabel {
                HStack(spacing: 6) {
                    Circle()
                        .fill(providerTint.color)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    Text(provider)
                        .font(theme.sans.font(size: 12))
                        .foregroundStyle(providerTint.color)
                        .lineLimit(1)
                }
            }
        }
        .modalFieldBox(focused: isGoogle)
    }

    private var providerLabel: String? {
        switch route {
        case .google: L10n.tr("Google Workspace")
        case .imap(let preset): preset.name
        case .manual: L10n.tr("IMAP")
        case .none: nil
        }
    }

    private var providerTint: TokenColor { isGoogle ? theme.modalGreen : theme.ink3 }

    /// Os três passos, pela rota e pelo estado do teste.
    private var pathSteps: [AccountPathSteps.Step] {
        if isGoogle {
            return [
                .init(id: 1, label: L10n.tr("Autorizar no navegador"), state: .now),
                .init(id: 2, label: L10n.tr("De volta ao app"), state: .waiting),
                .init(id: 3, label: L10n.tr("Sincronizando"), state: .waiting),
            ]
        }
        let preenchido = isImap && !password.isEmpty && endpoint != nil
        return [
            .init(id: 1, label: L10n.tr("Preencher IMAP"), state: preenchido ? .done : .now),
            .init(
                id: 2, label: L10n.tr("Testar conexão"),
                state: testando ? .now : (testado == true ? .done : (preenchido ? .now : .waiting))
            ),
            .init(
                id: 3, label: L10n.tr("Sincronizando"),
                state: testado == true ? .now : .waiting
            ),
        ]
    }

    // MARK: - Google: um botão

    private var googleRoute: some View {
        VStack(spacing: 16) {
            Button {
                Task { await model.addGoogle(address: address) }
            } label: {
                HStack(spacing: 10) {
                    Text(L10n.tr("Autorizar no Google"))
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
                    in: RoundedRectangle(cornerRadius: theme.modalFieldRadius, style: .continuous)
                )
                .shadow(theme.modalAccentGlow)
                .contentShape(RoundedRectangle(cornerRadius: theme.modalFieldRadius))
            }
            .buttonStyle(.plain)
            .disabled(model.isBusy)
            .focusRing(cornerRadius: theme.modalFieldRadius, tint: \.onAccent)
            .help(model.isBusy
                ? L10n.tr("Há outra ação em curso; ela termina em instantes.")
                : L10n.tr("Abrir o consentimento do Google para \(address)"))

            Text(L10n.tr("A autorização abre no navegador e você volta sozinho para cá. A senha nunca passa pelo OkamiUNI."))
                .font(theme.sans.font(size: 13))
                .lineSpacing(0.5 * 13)
                .foregroundStyle(theme.ink3.color)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - IMAP: três campos e o teste

    @ViewBuilder
    private var imapRoute: some View {
        HStack(alignment: .bottom, spacing: 10) {
            labelledField(L10n.tr("Servidor IMAP")) {
                TextField("imap.servidor.com", text: $host)
                    .textFieldStyle(.plain)
                    .font(theme.mono.font(size: 13.5))
                    .foregroundStyle(theme.ink.color)
                    .accessibilityLabel(L10n.tr("Servidor IMAP"))
            }
            labelledField(L10n.tr("Porta · TLS")) {
                TextField("993", text: $port)
                    .textFieldStyle(.plain)
                    .font(theme.mono.font(size: 13.5))
                    .foregroundStyle(theme.ink.color)
                    .accessibilityLabel(L10n.tr("Porta"))
            }
            .frame(width: 96)
        }

        // **Senha, e não "senha de app".** A maioria das contas que chega aqui
        // é de servidor próprio ou de hospedagem, e nelas a senha que o IMAP
        // aceita é a mesma com que a pessoa entra no webmail — não existe
        // "senha de app" para criar. Pedir uma mandava a pessoa procurar uma
        // tela que a conta dela não tem, e o campo ficava em branco. Quem usa
        // provedor com verificação em duas etapas cola aqui a senha que
        // aquele provedor gerou; para o campo, é só uma senha.
        labelledField(L10n.tr("Senha")) {
            SecureField(L10n.tr("senha da conta"), text: $password)
                .textFieldStyle(.plain)
                .font(theme.mono.font(size: 13.5))
                .foregroundStyle(theme.ink.color)
                .accessibilityLabel(L10n.tr("Senha"))
        }

        if testando || testado != nil || model.lastError != nil {
            ImapTestTrailView(
                steps: ImapTestTrail.steps(
                    running: testando, passed: testado, error: model.lastError
                )
            )
            Text(L10n.tr("Se o teste falhar, nada fica salvo."))
                .font(theme.sans.font(size: 12.5))
                .foregroundStyle(theme.ink3.color)
                .frame(maxWidth: .infinity)
        }

        // A escolha de TLS não cabe na linha do desenho (ele escreve "Porta ·
        // TLS" e mostra 993), e some se ficar implícita: STARTTLS em 143 é
        // caminho real de servidor próprio. Fica como linha discreta embaixo.
        HStack(spacing: 8) {
            ComposerSelect(
                title: L10n.tr("Forma de TLS"),
                selected: security.rawValue,
                width: 150,
                groups: [.init(title: nil, options: [
                    .init(value: ImapEndpoint.Security.tls.rawValue, label: "TLS (993)"),
                    .init(value: ImapEndpoint.Security.startTLS.rawValue, label: "STARTTLS (143)"),
                ])],
                pick: { valor in
                    security = ImapEndpoint.Security(rawValue: valor) ?? .tls
                    port = security == .tls ? "993" : "143"
                }
            )
            Spacer(minLength: 0)
        }
    }

    /// `label` de 12 semibold em `ink3` com o campo embaixo — o par do
    /// protótipo (`<label>` com `flex-direction: column; gap: 5px`).
    private func labelledField(
        _ label: String, @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(theme.sans.font(size: 12, weight: .semibold))
                .foregroundStyle(theme.ink3.color)
            content()
                .modalFieldBox(verticalPadding: 10, horizontalPadding: 12)
        }
    }

    // MARK: - Recados

    private func errorLine(_ erro: SyncError) -> some View {
        HStack(spacing: 8) {
            Text(erro.mensagem)
                .font(theme.sans.font(size: 12.5))
                .foregroundStyle(theme.danger.color)
                .fixedSize(horizontal: false, vertical: true)
            if case .semClientID = erro {
                Button { AccountsDocs.open(AccountsDocs.oauthGoogle) } label: {
                    Text(L10n.tr("Ver o roteiro"))
                        .font(theme.sans.font(size: 12.5, weight: .medium))
                        .foregroundStyle(theme.accentInk.color)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(AccountsDocs.url(AccountsDocs.oauthGoogle) == nil)
                .focusRing(cornerRadius: theme.modalButtonRadius)
            }
        }
    }

    /// A nota só faz sentido na rota que tem campo de host: na rota Google não
    /// há host nenhum para ser numérico.
    private var mostraNotaDoEnderecoNumerico: Bool {
        isImap && ImapEndpoint.ehIPLiteral(host)
    }

    /// Ela **não** impede nada. Servidor interno acessível só por endereço
    /// existe, e recusá-lo trocaria um enfraquecimento por uma impossibilidade.
    /// O que ela impede é o enfraquecimento acontecer em silêncio: o SNI do TLS
    /// não aceita IP, e sem SNI o NIOSSL valida a cadeia mas não confere se o
    /// certificado é **deste** servidor.
    private var notaDoEnderecoNumerico: some View {
        Text(L10n.tr("Endereço numérico: o certificado do servidor não é conferido pelo nome."))
            .font(theme.sans.font(size: 12))
            .foregroundStyle(theme.ink3.color)
            .fixedSize(horizontal: false, vertical: true)
            .help("""
                O SNI do TLS não aceita endereço numérico, então o app não tem \
                contra que nome conferir o certificado. A cadeia continua validada. \
                Prefira o nome do servidor quando ele existir.
                """)
    }

    // MARK: - Rodapé

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 12) {
            if isGoogle {
                Button { forceImapForGoogle() } label: {
                    Text(L10n.tr("Usar IMAP com senha de app"))
                        .font(theme.sans.font(size: 13.5, weight: .medium))
                        .foregroundStyle(theme.accentInk.color)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusRing(cornerRadius: theme.modalButtonRadius)
                .help("""
                    Sem registro no Google Cloud: crie uma senha de app em \
                    myaccount.google.com/apppasswords (exige verificação em \
                    duas etapas) e conecte como qualquer conta IMAP.
                    """)
                Spacer(minLength: 0)
            } else {
                Text(L10n.tr("Nada é salvo antes do teste passar."))
                    .font(theme.sans.font(size: 12.5))
                    .foregroundStyle(theme.ink3.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let onClose {
                ModalTextButton(L10n.tr("Cancelar"), action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            if isImap {
                ModalPrimaryButton(
                    title: testando ? L10n.tr("Testando…") : L10n.tr("Testar e adicionar"),
                    enabled: !testando && !model.isBusy && !password.isEmpty && endpoint != nil,
                    horizontalPadding: 18,
                    action: testAndAdd
                )
                .accessibilityIdentifier("add-account-primary")
                .help(ajudaDoTestar)
            }
        }
        .padding(.top, Theme.modalFooterTop)
        .padding(.horizontal, Theme.modalSide)
        .padding(.bottom, Theme.modalFooterBottom)
        .hairline(theme.modalLine, edges: .top)
        .padding(.top, 18)
    }

    private func testAndAdd() {
        guard let endpoint else { return }
        testando = true
        Task {
            defer { testando = false }
            testado = await model.testImap(
                address: address, password: password, endpoint: endpoint
            )
            guard testado == true else { return }
            await model.addImap(
                address: address, password: password, endpoint: endpoint,
                hostMark: marca, displayName: address
            )
            onClose?()
        }
    }

    /// Por que o botão está apagado — uma frase por motivo, na ordem em que a
    /// pessoa esbarra neles.
    private var ajudaDoTestar: String {
        if model.isBusy { return L10n.tr("Há outra ação em curso; ela termina em instantes.") }
        if password.isEmpty { return L10n.tr("Falta a senha desta conta.") }
        if endpoint == nil { return L10n.tr("Falta o servidor IMAP ou a porta.") }
        return L10n.tr("Conectar uma vez antes de gravar — nada é salvo se o teste falhar.")
    }

    private var endpoint: ImapEndpoint? {
        guard !host.isEmpty, let numero = Int(port), numero > 0 else { return nil }
        return ImapEndpoint(host: host, port: numero, security: security)
    }

    /// O nome que o chip mostra em versalete. Do preset quando há; do domínio
    /// quando não — nunca vazio, e nunca o id.
    private var marca: String {
        if case .imap(let preset)? = route { return preset.hostMark }
        return ProviderDetector.domain(of: address)?.split(separator: ".").first.map(String.init) ?? "imap"
    }

    /// Preenche host, porta e TLS a partir da rota. Palpite, não veredito: os
    /// três campos continuam editáveis.
    private func preenche(_ novo: String) {
        testado = nil
        imapForcadoPara = nil
        let rota = Self.route(for: novo)
        host = Self.host(of: rota)
        port = Self.port(of: rota)
        security = Self.security(of: rota)
    }

    private static func host(of rota: ProviderRoute?) -> String {
        switch rota {
        case .imap(let preset): preset.endpoint.host
        case .manual(let sugerido): sugerido.host
        case .google, .none: ""
        }
    }

    private static func port(of rota: ProviderRoute?) -> String {
        switch rota {
        case .imap(let preset): String(preset.endpoint.port)
        case .manual(let sugerido): String(sugerido.port)
        case .google, .none: "993"
        }
    }

    private static func security(of rota: ProviderRoute?) -> ImapEndpoint.Security {
        switch rota {
        case .imap(let preset): preset.endpoint.security
        case .manual(let sugerido): sugerido.security
        case .google, .none: .tls
        }
    }
}
