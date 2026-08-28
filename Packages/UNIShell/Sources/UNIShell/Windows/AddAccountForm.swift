import SwiftUI
import UNICore
import UNIDesign
import UNISync

/// Endereço → rota → OAuth ou formulário IMAP.
public struct AddAccountForm: View {
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL

    private let model: AccountsModel

    @State private var address: String
    @State private var password = ""
    @State private var host: String
    @State private var port: String
    @State private var security: ImapEndpoint.Security
    @State private var testado: Bool?

    /// `initialAddress` existe para o formulário ser **dirigível**: o harness
    /// desenha fora da tela e não digita, e o ensaio do app (`--ensaiar-contas`)
    /// precisa chegar num estado sem sintetizar tecla. Vazio é o caso normal,
    /// e é o que a janela usa.
    public init(model: AccountsModel, initialAddress: String = "") {
        self.model = model
        _address = State(initialValue: initialAddress)
        // Os campos nascem já preenchidos pela rota, pela mesma razão que
        // `preenche(_:)` os preenche a cada tecla: palpite, não veredito.
        let palpite = Self.route(for: initialAddress)
        _host = State(initialValue: Self.host(of: palpite))
        _port = State(initialValue: Self.port(of: palpite))
        _security = State(initialValue: Self.security(of: palpite))
    }

    /// A rota do endereço digitado. Estático e puro para o teste não precisar
    /// de `View` nenhuma — é a mesma regra de "lógica pura fora de View".
    public static func route(for address: String) -> ProviderRoute? {
        ProviderDetector.route(for: address)
    }

    private var route: ProviderRoute? { Self.route(for: address) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ADICIONAR CONTA").capsLabel()

            TextField("endereço@qualquerdominio.com", text: $address)
                .textFieldStyle(.plain)
                .font(theme.sans.font(size: 12.5))
                .foregroundStyle(theme.ink.color)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(theme.surface2.color, in: RoundedRectangle(cornerRadius: theme.radiusSmall))
                .onChange(of: address) { _, novo in preenche(novo) }

            switch route {
            case .none:
                Text("Digite o endereço da conta.")
                    .font(theme.sans.font(size: 11.5))
                    .foregroundStyle(theme.ink4.color)

            case .google:
                Text("Conta do Google: a autorização abre no navegador.")
                    .font(theme.sans.font(size: 11.5))
                    .foregroundStyle(theme.ink3.color)
                Button("Autorizar no Google") {
                    Task { await model.addGoogle(address: address) }
                }
                .buttonStyle(.plain)
                .font(theme.sans.font(size: 12, weight: .medium))
                .foregroundStyle(theme.accent.color)
                .disabled(model.isBusy)
                // Desabilitado diz por quê — a regra do Marco 1, inteira.
                .help(model.isBusy
                    ? "Há outra ação em curso; ela termina em instantes."
                    : "Abrir o consentimento do Google para \(address)")
                .focusRing(cornerRadius: theme.radiusSmall)

            case .imap, .manual:
                imapFields
            }

            if let erro = model.lastError {
                // Erro nunca engolido: a causa e a ação, sempre.
                HStack(spacing: 8) {
                    Text(erro.mensagem)
                        .font(theme.sans.font(size: 11.5))
                        .foregroundStyle(theme.accent.color)
                        .fixedSize(horizontal: false, vertical: true)
                    if case .semClientID = erro {
                        Button("Ver o roteiro") {
                            openURL(Self.roteiroDoOAuth)
                        }
                        .buttonStyle(.plain)
                        .font(theme.sans.font(size: 11.5, weight: .medium))
                        .foregroundStyle(theme.accent.color)
                        .help("Abrir docs/oauth-google.md, que diz o que falta")
                        .focusRing(cornerRadius: theme.radiusSmall)
                    }
                }
            } else if testado == true {
                Text("Conexão testada com sucesso.")
                    .font(theme.sans.font(size: 11.5))
                    .foregroundStyle(theme.ink3.color)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface.color)
    }

    @ViewBuilder
    private var imapFields: some View {
        SecureField("senha de app", text: $password)
            .textFieldStyle(.plain)
            .font(theme.sans.font(size: 12.5))
            .foregroundStyle(theme.ink.color)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(theme.surface2.color, in: RoundedRectangle(cornerRadius: theme.radiusSmall))

        Button("O que é uma senha de app?") {
            openURL(Self.roteiroDaSenhaDeApp)
        }
        .buttonStyle(.plain)
        .font(theme.sans.font(size: 11))
        .foregroundStyle(theme.ink4.color)
        .help("Provedores com verificação em duas etapas recusam a senha da conta; a senha de app é a que o IMAP aceita.")
        .focusRing(cornerRadius: theme.radiusSmall)

        HStack(spacing: 8) {
            TextField("imap.servidor.com", text: $host)
                .textFieldStyle(.plain)
                .font(theme.sans.font(size: 12.5))
                .foregroundStyle(theme.ink.color)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(theme.surface2.color, in: RoundedRectangle(cornerRadius: theme.radiusSmall))
            TextField("993", text: $port)
                .textFieldStyle(.plain)
                .font(theme.mono.font(size: 12))
                .foregroundStyle(theme.ink.color)
                .frame(width: 64, height: 32)
                .padding(.horizontal, 8)
                .background(theme.surface2.color, in: RoundedRectangle(cornerRadius: theme.radiusSmall))
            // O mesmo dropdown do design, e não um `Picker` do sistema — a
            // regra que `ComposerSelect` existe para cumprir.
            ComposerSelect(
                title: "Forma de TLS",
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

        HStack(spacing: 10) {
            Button("Testar e adicionar") {
                Task {
                    guard let endpoint else { return }
                    testado = await model.testImap(address: address, password: password, endpoint: endpoint)
                    guard testado == true else { return }
                    await model.addImap(
                        address: address, password: password, endpoint: endpoint,
                        hostMark: marca, displayName: address
                    )
                }
            }
            .buttonStyle(.plain)
            .font(theme.sans.font(size: 12, weight: .medium))
            .foregroundStyle(theme.accent.color)
            .disabled(model.isBusy || password.isEmpty || endpoint == nil)
            .help(ajudaDoTestar)
            .focusRing(cornerRadius: theme.radiusSmall)

            if model.isBusy { ProgressView().controlSize(.small) }
        }
    }

    /// Por que o botão está apagado — uma frase por motivo, na ordem em que a
    /// pessoa esbarra neles.
    private var ajudaDoTestar: String {
        if model.isBusy { return "Há outra ação em curso; ela termina em instantes." }
        if password.isEmpty { return "Falta a senha de app desta conta." }
        if endpoint == nil { return "Falta o servidor IMAP ou a porta." }
        return "Conectar uma vez antes de gravar — nada é salvo se o teste falhar."
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

    /// Os dois roteiros do repositório. Vão pela web porque o app instalado não
    /// carrega a árvore de `docs/` dentro do bundle — apontar para um caminho
    /// local abriria um "arquivo não encontrado" na máquina de quem instalou.
    static let roteiroDoOAuth = URL(
        string: "https://github.com/OkamiOps/okamiuni/blob/main/docs/oauth-google.md"
    )!
    static let roteiroDaSenhaDeApp = URL(
        string: "https://github.com/OkamiOps/okamiuni/blob/main/docs/senha-de-app.md"
    )!
}
