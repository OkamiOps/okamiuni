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
/// **O IMAP é o caminho principal, em toda rota.** Servidor, porta e senha
/// ficam à vista assim que o endereço vira um endereço, e a trilha do teste
/// acontece dentro da folha, com "nada fica salvo se falhar" dito no rodapé e
/// não depois do erro. O protótipo dava ao Google uma folha exclusiva, com um
/// botão e nada mais: quem tem o domínio no Workspace e não passa pelo
/// consentimento — ou quem só queria digitar três campos, como sempre fez —
/// ficava sem saída. Agora o OAuth é **uma opção a mais**: botão de acento em
/// cima no `gmail.com`, botão secundário com a pergunta "este e-mail usa
/// Google (Workspace)?" num domínio próprio, e o formulário logo abaixo nos
/// dois casos.
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
    /// Quem descobre o servidor de um domínio. Injetável porque a descoberta
    /// de verdade fala com DNS e HTTP, e nenhum teste de desenho deve abrir
    /// soquete — o desenho desta folha não depende de rede.
    private let descobre: @Sendable (String) async -> ImapSuggestion?

    @State private var address: String
    @State private var password = ""
    @State private var host: String
    @State private var port: String
    @State private var security: ImapEndpoint.Security
    @State private var testado: Bool?
    @State private var testando = false
    /// A descoberta em curso, para a tecla seguinte cancelá-la. Sem isto, uma
    /// palavra digitada rápido abriria uma consulta por letra e a última a
    /// responder — que não é a última a ser pedida — escreveria no campo.
    @State private var descoberta: Task<Void, Never>?
    /// O que a descoberta achou para o endereço que está no campo agora.
    @State private var sugestao: ImapSuggestion?

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
        onClose: (() -> Void)? = nil,
        descobre: @escaping @Sendable (String) async -> ImapSuggestion? = {
            await ImapDiscovery.suggest(for: $0)
        }
    ) {
        self.model = model
        self.onClose = onClose
        self.descobre = descobre
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

    private var route: ProviderRoute? { Self.route(for: address) }

    /// O IMAP do Gmail, para a rota do Google abrir o formulário já preenchido.
    ///
    /// Ele não está em `ImapPresets` de propósito: a tabela responde "qual é o
    /// servidor deste domínio?", e para `gmail.com` a resposta continua sendo
    /// "o Google", com OAuth do lado. O que mudou é que o OAuth deixou de ser
    /// o **único** caminho — ver `body(of:)`.
    static let gmailImap = ImapEndpoint(host: "imap.gmail.com", port: 993, security: .tls)

    private var isGoogle: Bool {
        if case .google = route { return true }
        return false
    }

    /// Há endereço bom o bastante para abrir os campos do IMAP?
    ///
    /// **Toda** rota abre: o IMAP é o caminho principal desta folha, inclusive
    /// no Gmail. Esconder os campos atrás do OAuth deixava sem saída quem tem
    /// o domínio no Google e não passa pelo consentimento — e quem só queria
    /// digitar servidor, endereço e senha, que é como isto sempre funcionou.
    private var isImap: Bool { route != nil }

    /// A oferta do Google num domínio que não é `gmail.com`.
    ///
    /// Um domínio próprio hospedado no Workspace não se distingue de um
    /// servidor IMAP qualquer sem consultar MX, e o Google recusa senha no
    /// IMAP de quase toda conta corporativa. Em vez de adivinhar, a folha
    /// **pergunta**: o formulário IMAP continua na frente e isto é um botão a
    /// mais. `GoogleAuth` manda `login_hint`, então o consentimento abre já no
    /// endereço digitado, em qualquer domínio.
    private var mostraOfertaDoGoogle: Bool {
        guard case .manual = route else { return false }
        // A descoberta já achou outro dono para o domínio (o Zoho, que ganha
        // o próprio botão logo abaixo): oferecer o Google ali seria dois
        // convites de login para uma caixa só, e um deles errado.
        return !ZohoSignInButton.applies(address: address, host: host)
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
        if isGoogle { return L10n.tr("Entre com o Google ou pelo IMAP, como preferir.") }
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
            if mostraOfertaDoGoogle { ofertaDoGoogle }
            ZohoSignInButton(model: model, address: address, host: host)
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

    /// Os três passos do **caminho principal**, que é o IMAP em toda rota.
    ///
    /// Não há mais um trio só para o Google: a folha mostra os dois caminhos
    /// ao mesmo tempo, e uma trilha que falasse de navegador descreveria o
    /// botão que a pessoa talvez nem use. O que o botão do Google faz está
    /// escrito embaixo dele, que é onde ele está.
    private var pathSteps: [AccountPathSteps.Step] {
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

    // MARK: - Google: um botão, não um pedágio

    /// O caminho do Google no `gmail.com`: botão de acento em cima, formulário
    /// IMAP logo abaixo. Os dois valem, e nenhum esconde o outro.
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

            Text(L10n.tr("Ou entre pelo IMAP, com a senha da conta:"))
                .font(theme.sans.font(size: 12, weight: .semibold))
                .foregroundStyle(theme.ink3.color)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// De onde veio o servidor que está no campo — uma linha, e só quando há o
    /// que dizer.
    ///
    /// O palpite não ganha frase: dizer "chutamos" embaixo de um campo que a
    /// pessoa vai testar em seguida é ruído. Fato ganha: quem vê
    /// `imappro.zoho.com` aparecer sozinho precisa saber que isso saiu do
    /// domínio dela, e não de uma tabela que pode estar velha.
    private var frasePelaOrigem: String? {
        switch sugestao?.origem {
        case .mx: L10n.tr("O domínio aponta para este servidor. Dá para mudar.")
        case .autoconfig: L10n.tr("O provedor publica estes dados. Dá para mudar.")
        case .palpite, nil: nil
        }
    }

    /// A pergunta e o botão, no domínio que a tabela não conhece.
    ///
    /// Pergunta e botão separados, e não tudo no rótulo: o rótulo de um botão
    /// com uma pergunta dentro cresce com a tradução e estoura a largura da
    /// folha. A pergunta é texto; o botão diz o que ele faz.
    private var ofertaDoGoogle: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(sugestao?.usaGoogle == true
                ? L10n.tr("O domínio é servido pelo Google: o IMAP com senha costuma ser recusado.")
                : L10n.tr("Este e-mail usa Google (Workspace)?"))
                .font(theme.sans.font(size: 12.5))
                .foregroundStyle(theme.ink3.color)
                .fixedSize(horizontal: false, vertical: true)
            ModalSecondaryButton(L10n.tr("Entrar com Google")) {
                Task { await model.addGoogle(address: address) }
            }
            .disabled(model.isBusy)
            .help(L10n.tr("Abrir o consentimento do Google para \(address)"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

        if let origem = frasePelaOrigem {
            Text(origem)
                .font(theme.sans.font(size: 12))
                .foregroundStyle(theme.ink3.color)
                .fixedSize(horizontal: false, vertical: true)
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
            // Uma frase só, em toda rota. O atalho "Usar IMAP com senha de
            // app" que morava aqui sumiu porque não tem mais o que atalhar: o
            // formulário IMAP está à vista desde o começo.
            Text(L10n.tr("Nada é salvo antes do teste passar."))
                .font(theme.sans.font(size: 12.5))
                .foregroundStyle(theme.ink3.color)
                .frame(maxWidth: .infinity, alignment: .leading)
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
            let passou = await model.testImapEndpoint(
                address: address, password: password, endpoint: endpoint
            )
            testado = passou != nil
            guard let passou else { return }
            // O host que passou pode não ser o digitado — o diretor tenta os
            // vizinhos conhecidos antes de desistir. Mostrar o que funcionou é
            // o que impede a folha de fechar deixando na tela um campo que
            // contradiz a conta recém-criada.
            host = passou.host
            port = String(passou.port)
            security = passou.security
            await model.addImap(
                address: address, password: password, endpoint: passou,
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
        if case .google? = route { return "gmail" }
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
        procuraOServidor(de: novo, rota: rota)
    }

    /// Pergunta ao domínio onde fica o IMAP dele — depois de a pessoa parar de
    /// digitar.
    ///
    /// **Só na rota `.manual`.** Domínio de provedor conhecido já tem resposta
    /// na tabela, e `gmail.com` tem as duas respostas na tela; gastar DNS e
    /// HTTP nesses casos seria pagar por uma informação que já está aqui.
    ///
    /// Os 600 ms não são estética: sem eles, `onChange` dispara uma consulta
    /// por tecla, e `contato@meusite.com` sairia como vinte consultas de um
    /// domínio que ainda não existe. Cada tecla cancela a anterior, e o
    /// resultado só entra se o endereço no campo ainda for o que foi
    /// perguntado — a resposta que chega atrasada de um endereço já apagado
    /// não escreve em campo nenhum.
    private func procuraOServidor(de endereco: String, rota: ProviderRoute?) {
        descoberta?.cancel()
        sugestao = nil
        guard case .manual = rota else { descoberta = nil; return }
        descoberta = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            guard let achado = await descobre(endereco) else { return }
            guard !Task.isCancelled, address == endereco else { return }
            aplica(achado, de: endereco)
        }
    }

    /// Escreve o que a descoberta achou — e **só** no que ninguém tocou.
    ///
    /// Se o host ou a porta já não são o palpite da rota, a pessoa os editou à
    /// mão enquanto a consulta corria, e sobrescrevê-los seria apagar debaixo
    /// do dedo dela o endereço que ela foi buscar no painel do provedor.
    private func aplica(_ achado: ImapSuggestion, de endereco: String) {
        sugestao = achado
        let palpite = Self.route(for: endereco)
        guard host == Self.host(of: palpite), port == Self.port(of: palpite) else { return }
        host = achado.imap.host
        port = String(achado.imap.port)
        security = achado.imap.security
    }

    private static func host(of rota: ProviderRoute?) -> String {
        switch rota {
        case .imap(let preset): preset.endpoint.host
        case .manual(let sugerido): sugerido.host
        case .google: gmailImap.host
        case .none: ""
        }
    }

    private static func port(of rota: ProviderRoute?) -> String {
        switch rota {
        case .imap(let preset): String(preset.endpoint.port)
        case .manual(let sugerido): String(sugerido.port)
        case .google: String(gmailImap.port)
        case .none: "993"
        }
    }

    private static func security(of rota: ProviderRoute?) -> ImapEndpoint.Security {
        switch rota {
        case .imap(let preset): preset.endpoint.security
        case .manual(let sugerido): sugerido.security
        case .google: gmailImap.security
        case .none: .tls
        }
    }
}
