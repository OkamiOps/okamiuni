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

    /// Os nomes dos dois recursos, para quem verifica o empacotamento.
    public static let all = [oauthGoogle, senhaDeApp]

    /// O arquivo dentro do bundle. Nulo quando o app não foi empacotado com ele
    /// — o que acontece num alvo de teste, e é por isso que o botão que o abre
    /// pergunta antes de se acender.
    public static func url(_ name: String, in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: name, withExtension: "md")
    }

    /// Abre o roteiro. Devolve `false` quando não havia o que abrir — quem
    /// chama já desabilitou o botão nesse caso; isto é a segunda tranca.
    @discardableResult
    public static func open(_ name: String) -> Bool {
        guard let url = url(name) else { return false }
        return NSWorkspace.shared.open(url)
    }
}

/// Endereço → rota → OAuth ou formulário IMAP.
///
/// ## De onde vêm os números
///
/// Como a lista, **este formulário não tem protótipo**, e o design não tem
/// campo de formulário nenhum para copiar: o que a 06 chama de campo é uma
/// calha de 24pt dentro de uma linha de texto (`RecipientField`), não uma caixa
/// que se preenche.
///
/// O que é herdado: o `padding(20)` da caixa e o `spacing: 12` entre os blocos
/// são o recuo de corpo da 04 (`EventWindow`, linha 176) e o respiro entre os
/// blocos dela; os corpos 12,5pt sans (valor) e 11,5pt (apoio) são os mesmos da
/// lista de contas e da 04; o `ComposerSelect` é o dropdown do design, e não um
/// `Picker` do sistema.
///
/// O que é **desta tela, e não veio de lugar nenhum**: os 32pt de altura do
/// campo e os 10pt de recuo interno dele. Uma caixa de formulário precisa ser
/// maior que a calha de 24 da 06, que vive apertada dentro de uma linha; 32 é o
/// menor valor em que o campo e o `ComposerSelect` ao lado ficam da mesma
/// altura. Fica registrado como escolha, não como medida do design.
public struct AddAccountForm: View {
    @Environment(\.theme) private var theme

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
    ///
    /// `initialHost` é a mesma porta, pela mesma razão, para o único estado que
    /// o endereço não alcança: a nota do endereço numérico depende do que está
    /// no campo de **host**, e a rota nunca sugere um IP. Nulo — o caso normal,
    /// e o que a janela usa — deixa o palpite da rota falar.
    public init(model: AccountsModel, initialAddress: String = "", initialHost: String? = nil) {
        self.model = model
        _address = State(initialValue: initialAddress)
        // Os campos nascem já preenchidos pela rota, pela mesma razão que
        // `preenche(_:)` os preenche a cada tecla: palpite, não veredito.
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

                // A saída sem console: o Gmail também fala IMAP com senha de
                // app (verificação em duas etapas ligada). É o caminho de quem
                // não quer registrar um OAuth Client — dois minutos em
                // myaccount.google.com/apppasswords, nenhum projeto no Google
                // Cloud. O OAuth continua sendo o melhor sync (histórico
                // incremental); a escolha é da pessoa, não nossa.
                Button("Ou conectar por IMAP com senha de app") {
                    forceImapForGoogle()
                }
                .buttonStyle(.plain)
                .font(theme.sans.font(size: 11.5))
                .foregroundStyle(theme.ink3.color)
                .help("""
                    Sem registro no Google Cloud: crie uma senha de app em \
                    myaccount.google.com/apppasswords (exige verificação em \
                    duas etapas) e conecte como qualquer conta IMAP.
                    """)
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
                            AccountsDocs.open(AccountsDocs.oauthGoogle)
                        }
                        .buttonStyle(.plain)
                        .font(theme.sans.font(size: 11.5, weight: .medium))
                        .foregroundStyle(theme.accent.color)
                        .disabled(AccountsDocs.url(AccountsDocs.oauthGoogle) == nil)
                        .help(AccountsDocs.url(AccountsDocs.oauthGoogle) == nil
                            ? "Este aplicativo não trouxe o roteiro; ele está em docs/oauth-google.md, no repositório."
                            : "Abrir docs/oauth-google.md, que diz o que falta")
                        .focusRing(cornerRadius: theme.radiusSmall)
                    }
                }
            } else if testado == true {
                Text("Conexão testada com sucesso.")
                    .font(theme.sans.font(size: 11.5))
                    .foregroundStyle(theme.ink3.color)
            }

            // A nota do endereço numérico, no bloco de recado — junto do erro e
            // do "testada com sucesso", que é onde já mora tudo o que a janela
            // tem a dizer **sobre esta tentativa**. É disso que ela fala: do que
            // vai acontecer quando o botão for apertado.
            if mostraNotaDoEnderecoNumerico { notaDoEnderecoNumerico }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface.color)
    }

    /// A nota só faz sentido na rota que tem campo de host: na rota Google não
    /// há host nenhum para ser numérico.
    private var mostraNotaDoEnderecoNumerico: Bool {
        switch route {
        case .imap, .manual: ImapEndpoint.ehIPLiteral(host)
        case .none, .google: false
        }
    }

    /// Ela **não** impede nada. Servidor interno acessível só por endereço
    /// existe, e recusá-lo trocaria um enfraquecimento por uma impossibilidade.
    /// O que ela impede é o enfraquecimento acontecer em silêncio: o SNI do TLS
    /// não aceita IP, e sem SNI o NIOSSL valida a cadeia mas não confere se o
    /// certificado é **deste** servidor.
    ///
    /// Quem decide se o host é literal é a mesma função que a sessão usa
    /// (`ImapEndpoint.ehIPLiteral`): escritas em dois lugares, as duas
    /// divergiriam, e a nota apareceria onde não há perda ou — pior — faltaria
    /// onde há.
    private var notaDoEnderecoNumerico: some View {
        Text("Endereço numérico: o certificado do servidor não é conferido pelo nome.")
            .font(theme.sans.font(size: 11))
            .foregroundStyle(theme.ink4.color)
            .fixedSize(horizontal: false, vertical: true)
            .help("""
                O SNI do TLS não aceita endereço numérico, então o app não tem \
                contra que nome conferir o certificado. A cadeia continua validada. \
                Prefira o nome do servidor quando ele existir.
                """)
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
            AccountsDocs.open(AccountsDocs.senhaDeApp)
        }
        .buttonStyle(.plain)
        .font(theme.sans.font(size: 11))
        .foregroundStyle(theme.ink4.color)
        .disabled(AccountsDocs.url(AccountsDocs.senhaDeApp) == nil)
        .help(AccountsDocs.url(AccountsDocs.senhaDeApp) == nil
            ? "Este aplicativo não trouxe a explicação; ela está em docs/senha-de-app.md, no repositório."
            : "Provedores com verificação em duas etapas recusam a senha da conta; a senha de app é a que o IMAP aceita.")
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
