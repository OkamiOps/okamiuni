import AppKit
import SwiftUI
import UNICore
import UNIDesign
import UNISync

// MARK: - Chave de API

/// O formulário de uma conexão por chave: nome, endereço, chave e modelo.
///
/// O endereço nasce preenchido com o endpoint oficial do provedor escolhido no
/// catálogo (ver `ConfigAICatalog`, onde cada URL tem a fonte no comentário) e
/// continua editável, porque vários provedores têm endereço diferente por
/// região ou por plano.
///
/// **A chave nunca passa pelas preferências.** O campo entrega o texto a
/// `storeAPIKey`, que o grava no Keychain por `credentialID`; o documento de
/// ajustes guarda só o identificador. É por isso que o campo nasce vazio mesmo
/// quando já existe chave: esta tela não lê segredo para mostrar.
struct ConfigIntelligenceAPIKeyForm: View {
    @Environment(\.theme) private var theme
    @Environment(\.configPalette) private var palette
    @Environment(\.displayScale) private var displayScale

    @Binding var draft: AssistantSettings
    let preset: ConfigAIPreset?
    let apiKeyPresent: Bool
    let lastTest: String?
    let lastTestFailed: Bool
    let testing: Bool
    let save: () -> Void
    let test: () -> Void
    let storeAPIKey: (String) -> Void
    let removeAPIKey: () -> Void
    let openAdvancedPanel: () -> Void
    var probeLocal: @Sendable (String) async -> LocalServerState = { endpoint in
        await LocalModelCatalog().probe(endpoint: endpoint)
    }

    /// O nome é da pessoa: ele não vai para o roteador, e serve para ela
    /// reconhecer a linha na lista de conexões quando houver duas no mesmo
    /// provedor.
    @State private var name = ""
    @State private var apiKey = ""
    @State private var discovered: [LocalModel] = []
    @State private var focusedKey = false
    @State private var removing = false

    private let labelWidth: CGFloat = 150

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(spacing: 0) {
                    fieldRow(L10n.tr("Nome"), first: true) {
                        TextField("", text: $name, prompt: Text(preset?.name ?? ""))
                            .textFieldStyle(.plain)
                            .font(theme.sans.font(size: 13.5))
                    }
                    fieldRow(
                        L10n.tr("Endereço"),
                        note: L10n.tr("endpoint compatível com OpenAI")
                    ) {
                        TextField("", text: Binding(
                            get: { draft.openAICompatible.endpoint },
                            set: { draft.openAICompatible.endpoint = $0 }
                        ))
                        .textFieldStyle(.plain)
                        .font(theme.mono.font(size: 13))
                    }
                    fieldRow(
                        L10n.tr("Chave"),
                        note: apiKeyPresent && apiKey.isEmpty
                            ? L10n.tr("já guardada no Keychain deste Mac — digite aqui só para trocá-la")
                            : L10n.tr("vai para o Keychain deste Mac, nunca para o arquivo de ajustes"),
                        focused: focusedKey,
                        badge: L10n.tr("Keychain")
                    ) {
                        SecureField("", text: $apiKey, prompt: Text(verbatim: "sk-…"))
                            .textFieldStyle(.plain)
                            .font(theme.mono.font(size: 13))
                            .onSubmit { commitKey() }
                    }
                    authenticationRow
                    modelRow
                    purposeRow
                }
                .configCard(palette, radius: 14)

                actions
                if let lastTest {
                    Text(lastTest)
                        .font(theme.sans.font(size: 12.5))
                        .foregroundStyle((lastTestFailed ? palette.red : palette.green).color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(L10n.tr("A chave fica no Keychain deste Mac, nunca no arquivo de ajustes e nunca em backup de texto. O endereço é um endpoint compatível com OpenAI — o mesmo caminho vale para OpenRouter, DeepSeek, Kimi ou qualquer servidor seu."))
                    .font(theme.sans.font(size: 12.5))
                    .lineSpacing(12.5 * 0.5)
                    .foregroundStyle(palette.ink3.color)
                    .frame(maxWidth: 560, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 700, alignment: .leading)
            .padding(.bottom, 4)
        }
        .scrollBounceBehavior(.basedOnSize)
        .onAppear(perform: prefill)
        .uniConfirmation(
            removing
                ? UNIConfirmationText(
                    title: L10n.tr("Remover esta conexão?"),
                    detail: L10n.tr("A chave sai do Keychain deste Mac e o endereço sai dos ajustes. A conta no provedor não é tocada."),
                    confirm: L10n.tr("Remover a conexão"),
                    icon: "key"
                )
                : nil,
            onConfirm: { removing = false; removeAPIKey() },
            onCancel: { removing = false }
        )
    }

    /// Preenche o endereço do preset quando ele ainda não foi gravado. Não
    /// sobrescreve um endereço que a pessoa já editou.
    private func prefill() {
        if let baseURL = preset?.baseURL, draft.openAICompatible.endpoint.isEmpty {
            draft.openAICompatible.endpoint = baseURL
        }
        if name.isEmpty { name = preset?.name ?? "" }
        if draft.openAICompatible.authenticationMode == .none {
            draft.openAICompatible.authenticationMode = .apiKey
        }
    }

    // MARK: As linhas

    /// `grid-template-columns: 150px minmax(0, 1fr); padding: 13px 18px`, com o
    /// rótulo alinhado à direita.
    private func fieldRow<Field: View>(
        _ label: String,
        note: String? = nil,
        first: Bool = false,
        focused: Bool = false,
        badge: String? = nil,
        @ViewBuilder field: () -> Field
    ) -> some View {
        HStack(alignment: .center, spacing: 18) {
            Text(label)
                .font(theme.sans.font(size: 13.5))
                .foregroundStyle(palette.ink2.color)
                .frame(width: labelWidth, alignment: .trailing)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    field()
                        .foregroundStyle(palette.ink.color)
                    if let badge {
                        HStack(spacing: 5) {
                            Image(systemName: "lock")
                                .font(.system(size: 10, weight: .medium))
                            Text(badge)
                                .font(theme.sans.font(size: 11.5))
                        }
                        .foregroundStyle(palette.ink3.color)
                        .fixedSize()
                    }
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(palette.field.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            (focused ? palette.accent : palette.line).color,
                            lineWidth: focused ? 1 : Hairline.thickness(displayScale)
                        )
                }
                .background {
                    if focused {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(palette.accentSoft.color)
                            .padding(-3)
                    }
                }
                if let note {
                    Text(note)
                        .font(theme.sans.font(size: 12))
                        .foregroundStyle(palette.ink3.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .overlay(alignment: .top) {
            if !first {
                Rectangle()
                    .fill(palette.line.color)
                    .frame(height: Hairline.thickness(displayScale))
            }
        }
    }

    /// Como este endereço autentica.
    ///
    /// Três modos, porque os três existem no roteador: sem autenticação (um
    /// servidor local), chave de API (o caso desta página) e o OAuth do
    /// LiteLLM. O terceiro abre o painel antigo em vez de reimplementar o
    /// PKCE — o fluxo de lá funciona, e refazê-lo aqui só criaria uma segunda
    /// chance de errar.
    private var authenticationRow: some View {
        HStack(alignment: .center, spacing: 18) {
            Text(L10n.tr("Autenticação"))
                .font(theme.sans.font(size: 13.5))
                .foregroundStyle(palette.ink2.color)
                .frame(width: labelWidth, alignment: .trailing)
            HStack(spacing: 8) {
                purposeButton(
                    L10n.tr("Chave de API"),
                    on: draft.openAICompatible.authenticationMode == .apiKey
                ) {
                    draft.openAICompatible.authenticationMode = .apiKey
                    save()
                }
                purposeButton(
                    L10n.tr("Sem autenticação"),
                    on: draft.openAICompatible.authenticationMode == .none
                ) {
                    draft.openAICompatible.authenticationMode = .none
                    save()
                }
                purposeButton(
                    L10n.tr("OAuth do LiteLLM"),
                    on: draft.openAICompatible.authenticationMode == .litellmOAuthPKCE,
                    action: openAdvancedPanel
                )
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(palette.line.color)
                .frame(height: Hairline.thickness(displayScale))
        }
    }

    /// O modelo. Quando o endereço é de loopback, a lista vem do próprio
    /// servidor; num endpoint remoto o modelo é digitado, porque pedir o
    /// catálogo exigiria mandar a chave antes de a pessoa salvar.
    private var modelRow: some View {
        HStack(alignment: .center, spacing: 18) {
            Text(L10n.tr("Modelo"))
                .font(theme.sans.font(size: 13.5))
                .foregroundStyle(palette.ink2.color)
                .frame(width: labelWidth, alignment: .trailing)
            HStack(spacing: 10) {
                if discovered.isEmpty {
                    HStack(spacing: 8) {
                        TextField("", text: Binding(
                            get: { draft.openAICompatible.model },
                            set: { draft.openAICompatible.model = $0 }
                        ), prompt: Text(preset?.note ?? ""))
                        .textFieldStyle(.plain)
                        .font(theme.mono.font(size: 13))
                        .foregroundStyle(palette.ink.color)
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .frame(maxWidth: 260)
                    .background(palette.field.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(palette.line.color, lineWidth: Hairline.thickness(displayScale))
                    }
                } else {
                    ConfigPicker(
                        options: discovered.map { ($0.id, $0.id) },
                        selection: Binding(
                            get: { draft.openAICompatible.model },
                            set: { draft.openAICompatible.model = $0; save() }
                        ),
                        accessibilityTitle: L10n.tr("Escolher o modelo"),
                        mono: true
                    )
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                        Text(L10n.tr("\(discovered.count) modelos encontrados"))
                            .font(theme.sans.font(size: 12.5))
                    }
                    .foregroundStyle(palette.green.color)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(palette.line.color)
                .frame(height: Hairline.thickness(displayScale))
        }
        .task(id: draft.openAICompatible.endpoint) {
            // Só loopback: pedir catálogo a um endpoint remoto exigiria mandar
            // a chave antes de a pessoa ter clicado em salvar.
            guard LocalModelCatalog.loopbackHost(of: draft.openAICompatible.endpoint) != nil else {
                discovered = []
                return
            }
            discovered = await probeLocal(draft.openAICompatible.endpoint).models
        }
    }

    /// "Usar para".
    ///
    /// O desenho põe três finalidades aqui. O app tem **um** motor ativo: a
    /// mesma conexão serve escrita e conversas, e o que varia de verdade é se a
    /// análise automática também passa por ela. Três botões independentes
    /// seriam enfeite — dois estados reais dizem a verdade.
    private var purposeRow: some View {
        let ativa = draft.provider == .openAICompatible
        return HStack(alignment: .center, spacing: 18) {
            Text(L10n.tr("Usar para"))
                .font(theme.sans.font(size: 13.5))
                .foregroundStyle(palette.ink2.color)
                .frame(width: labelWidth, alignment: .trailing)
            HStack(spacing: 8) {
                purposeButton(L10n.tr("Escrita e conversas"), on: ativa) {
                    draft.provider = .openAICompatible
                    draft.agent.enabled = false
                    save()
                }
                purposeButton(
                    L10n.tr("E a análise automática"),
                    on: ativa && draft.automaticAnalysis == .configuredProvider
                ) {
                    draft.provider = .openAICompatible
                    draft.automaticAnalysis =
                        draft.automaticAnalysis == .configuredProvider ? .onDeviceOnly : .configuredProvider
                    draft.automaticAnalysisTouchedByUser = true
                    save()
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18)
        .padding(.top, 13)
        .padding(.bottom, 15)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(palette.line.color)
                .frame(height: Hairline.thickness(displayScale))
        }
    }

    private func purposeButton(
        _ label: String, on: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(theme.sans.font(size: 12.5, weight: on ? .semibold : .medium))
                .foregroundStyle((on ? palette.accentInk : palette.ink2).color)
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(on ? palette.accentSoft.color : .clear)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            (on ? palette.accent : palette.line).color,
                            lineWidth: Hairline.thickness(displayScale)
                        )
                }
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    // MARK: Os botões

    private var actions: some View {
        HStack(spacing: 10) {
            Button(testing ? L10n.tr("Testando…") : L10n.tr("Testar e salvar")) {
                commitKey()
                draft.provider = .openAICompatible
                save()
                test()
            }
            .buttonStyle(.plain)
            .configPrimaryButton(
                palette, font: theme.sans.font(size: 13.5, weight: .semibold),
                radius: 10, horizontal: 17, vertical: 10
            )
            .disabled(testing)

            Button(L10n.tr("Testar sem salvar")) {
                commitKey()
                test()
            }
            .buttonStyle(.plain)
            .configQuietButton(
                palette, font: theme.sans.font(size: 13.5, weight: .medium),
                radius: 10, horizontal: 15, vertical: 9
            )
            .disabled(testing)

            Spacer(minLength: 0)

            Button(L10n.tr("Remover conexão")) { removing = true }
                .buttonStyle(.plain)
                .font(theme.sans.font(size: 13, weight: .medium))
                .foregroundStyle(palette.red.color)
        }
    }

    /// Entrega a chave ao Keychain e **esquece** o texto digitado. O campo não
    /// guarda segredo depois de o cofre o receber.
    private func commitKey() {
        let value = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        draft.openAICompatible.authenticationMode = .apiKey
        storeAPIKey(value)
        apiKey = ""
    }
}

// MARK: - Neste Mac

/// "Neste Mac": Apple Intelligence e os servidores de loopback, com o seletor
/// dos modelos que cada servidor **respondeu** ter.
///
/// Nenhuma linha aqui afirma que um servidor está de pé sem ter perguntado: o
/// estado de cada um vem de `LocalModelCatalog.probe`, e "não está rodando" é
/// um estado desenhado, com o caminho de volta ao lado.
struct ConfigIntelligenceLocalPage: View {
    @Environment(\.theme) private var theme
    @Environment(\.configPalette) private var palette
    @Environment(\.displayScale) private var displayScale

    @Binding var draft: AssistantSettings
    let save: () -> Void
    let probe: @Sendable (String) async -> LocalServerState

    @State private var states: [String: LocalServerState] = [:]

    /// Os servidores de loopback do catálogo, na ordem dele.
    private var servers: [ConfigAIPreset] {
        ConfigAICatalog.all.filter {
            if case .localServer = $0.route { return true }
            return false
        }
    }

    /// Qual servidor ganha o cartão grande: o que está gravado nos ajustes, ou
    /// o primeiro que respondeu, ou o primeiro da lista.
    private var featured: ConfigAIPreset? {
        if let current = servers.first(where: {
            $0.baseURL?.caseInsensitiveCompare(draft.openAICompatible.endpoint) == .orderedSame
        }) { return current }
        if let running = servers.first(where: { states[$0.id]?.isRunning == true }) { return running }
        return servers.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                appleIntelligence
                if let featured { serverCard(featured) }
                others
                Text(L10n.tr("Com uma IA daqui, nenhum pedaço do seu e-mail sai deste Mac — nem assunto, nem texto, nem anexo. É a opção mais privada e a única que funciona sem rede."))
                    .font(theme.sans.font(size: 12.5))
                    .lineSpacing(12.5 * 0.5)
                    .foregroundStyle(palette.ink3.color)
                    .frame(maxWidth: 620, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 820, alignment: .leading)
            .padding(.bottom, 4)
        }
        .scrollBounceBehavior(.basedOnSize)
        .task { await probeAll() }
    }

    private func probeAll() async {
        for server in servers {
            guard let baseURL = server.baseURL else { continue }
            states[server.id] = .probing
            states[server.id] = await probe(baseURL)
        }
    }

    // MARK: Apple Intelligence

    private var appleIntelligence: some View {
        let chosen = draft.provider == .foundationModels
        return HStack(spacing: 15) {
            Image(systemName: "sparkles")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(palette.accentInk.color)
                .frame(width: 40, height: 40)
                .background(palette.accentSoft.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 9) {
                    Text(L10n.tr("Apple Intelligence"))
                        .font(theme.sans.font(size: 15, weight: .semibold))
                        .foregroundStyle(palette.ink.color)
                    Text(L10n.tr("Sem configuração"))
                        .font(theme.sans.font(size: 11, weight: .semibold))
                        .foregroundStyle(palette.accentInk.color)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            palette.accentSoft.color,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                }
                Text(L10n.tr("Roda no chip deste Mac. Sem conta, sem chave, sem internet. Boa para resumir e classificar; curta demais para rascunhos longos."))
                    .font(theme.sans.font(size: 12.5))
                    .lineSpacing(12.5 * 0.45)
                    .foregroundStyle(palette.ink3.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 10) {
                stateLabel(L10n.tr("Pronta"), color: palette.green)
                Button(chosen ? L10n.tr("Em uso") : L10n.tr("Usar")) {
                    draft.provider = .foundationModels
                    draft.automaticAnalysis = .onDeviceOnly
                    save()
                }
                .buttonStyle(.plain)
                .configQuietButton(
                    palette, font: theme.sans.font(size: 12.5, weight: .semibold),
                    radius: 10, horizontal: 14, vertical: 8
                )
                .disabled(chosen)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
        .frame(maxWidth: .infinity)
        .configCard(palette, radius: 14)
    }

    // MARK: O servidor em destaque

    private func serverCard(_ server: ConfigAIPreset) -> some View {
        let state = states[server.id] ?? .unknown
        return VStack(spacing: 0) {
            HStack(spacing: 15) {
                ConfigAIMonogram(
                    letter: server.monogram, hue: server.hue,
                    side: 40, radius: 10, fontSize: 15
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text(server.name)
                        .font(theme.sans.font(size: 15, weight: .semibold))
                        .foregroundStyle(palette.ink.color)
                    Text(server.address)
                        .font(theme.mono.font(size: 12.5))
                        .foregroundStyle(palette.ink3.color)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                switch state {
                case .running:
                    stateLabel(L10n.tr("Encontrado neste Mac"), color: palette.green)
                case .notRunning:
                    stateLabel(L10n.tr("Não está rodando"), color: palette.orange)
                case .probing, .unknown:
                    stateLabel(L10n.tr("Perguntando…"), color: palette.ink3)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 15)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(palette.line.color)
                    .frame(height: Hairline.thickness(displayScale))
            }

            switch state {
            case .running(let models):
                modelPicker(server, models: models)
            case .notRunning:
                notRunning(server)
            case .probing, .unknown:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity)
        .configCard(palette, radius: 14)
    }

    private func modelPicker(_ server: ConfigAIPreset, models: [LocalModel]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(L10n.tr("Qual modelo ela usa"))
                    .font(theme.sans.font(size: 13, weight: .semibold))
                    .foregroundStyle(palette.ink.color)
                Text(models.count == 1
                    ? L10n.tr("1 baixado")
                    : L10n.tr("\(models.count) baixados"))
                    .font(theme.sans.font(size: 12.5))
                    .foregroundStyle(palette.ink3.color)
                Spacer(minLength: 0)
                Button(L10n.tr("Atualizar a lista")) {
                    Task { await probeAll() }
                }
                .buttonStyle(.plain)
                .font(theme.sans.font(size: 12.5))
                .foregroundStyle(palette.accentInk.color)
            }
            .padding(.horizontal, 18)
            .padding(.top, 13)
            .padding(.bottom, 6)

            if models.isEmpty {
                Text(L10n.tr("O servidor está de pé e ainda não tem modelo baixado."))
                    .font(theme.sans.font(size: 12.5))
                    .foregroundStyle(palette.ink3.color)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 14)
            }

            VStack(spacing: 2) {
                ForEach(models) { model in
                    modelOption(server, model: model)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 14)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L10n.tr("Modelo de \(server.name)"))
        }
    }

    /// `grid-template-columns: 17px minmax(0, 1fr) auto auto; padding: 9px 10px`.
    private func modelOption(_ server: ConfigAIPreset, model: LocalModel) -> some View {
        let on = draft.provider == .openAICompatible
            && draft.openAICompatible.model == model.id
            && draft.openAICompatible.endpoint.caseInsensitiveCompare(server.baseURL ?? "") == .orderedSame
        return Button {
            draft.provider = .openAICompatible
            draft.openAICompatible.endpoint = server.baseURL ?? ""
            draft.openAICompatible.model = model.id
            // Um servidor local não pede chave, e mandar uma para um processo
            // qualquer escutando na porta seria pior do que não autenticar.
            draft.openAICompatible.authenticationMode = .none
            draft.agent.enabled = false
            save()
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .strokeBorder((on ? palette.accent : palette.line).color, lineWidth: 2)
                    if on {
                        Circle()
                            .fill(palette.accent.color)
                            .frame(width: 7, height: 7)
                    }
                }
                .frame(width: 15, height: 15)
                .frame(width: 17, alignment: .leading)
                Text(model.id)
                    .font(theme.mono.font(size: 13, weight: on ? .semibold : .medium))
                    .foregroundStyle(palette.ink.color)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let size = model.sizeLabel {
                    Text(size)
                        .font(theme.mono.font(size: 12))
                        .foregroundStyle(palette.ink3.color)
                    Text(fitsLabel(model))
                        .font(theme.sans.font(size: 12, weight: .medium))
                        .foregroundStyle(fitsColor(model).color)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background {
                if on {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(palette.accentSoft.color)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    /// Cabe nesta máquina?
    ///
    /// O desenho escreve "rápido"/"lento" ao lado de cada modelo. Velocidade
    /// não dá para saber sem rodar; **memória** dá: o tamanho do modelo contra
    /// a RAM desta máquina é um fato, e é o que decide se ele vai nadar ou
    /// engasgar.
    private func fitsLabel(_ model: LocalModel) -> String {
        guard let size = model.sizeBytes else { return "" }
        let ram = Double(ProcessInfo.processInfo.physicalMemory)
        return Double(size) > ram * 0.6
            ? L10n.tr("pede memória")
            : L10n.tr("cabe folgado")
    }

    private func fitsColor(_ model: LocalModel) -> TokenColor {
        guard let size = model.sizeBytes else { return palette.ink3 }
        let ram = Double(ProcessInfo.processInfo.physicalMemory)
        return Double(size) > ram * 0.6 ? palette.ink3 : palette.green
    }

    private func notRunning(_ server: ConfigAIPreset) -> some View {
        HStack(spacing: 10) {
            Text(L10n.tr("Abra o \(server.name) e deixe o servidor dele no ar; aí a lista de modelos aparece aqui."))
                .font(theme.sans.font(size: 12.5))
                .foregroundStyle(palette.ink3.color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(L10n.tr("Tentar de novo")) {
                Task { await probeAll() }
            }
            .buttonStyle(.plain)
            .configQuietButton(
                palette, font: theme.sans.font(size: 12.5, weight: .medium),
                radius: 10, horizontal: 13, vertical: 7
            )
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }

    // MARK: Os outros servidores

    private var others: some View {
        let rest = servers.filter { $0.id != featured?.id }
        return VStack(spacing: 2) {
            ForEach(rest) { server in
                let state = states[server.id] ?? .unknown
                HStack(spacing: 12) {
                    ConfigAIMonogram(
                        letter: server.monogram, hue: server.hue,
                        side: 26, radius: 7, fontSize: 11
                    )
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(server.name)
                            .font(theme.sans.font(size: 13.5, weight: .semibold))
                            .foregroundStyle(palette.ink2.color)
                            .fixedSize()
                        Text(server.address)
                            .font(theme.mono.font(size: 12))
                            .foregroundStyle(palette.ink3.color)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 12) {
                        Text(othersStateLabel(state))
                            .font(theme.sans.font(size: 12.5))
                            .foregroundStyle(palette.ink3.color)
                        Button(state.isRunning ? L10n.tr("Usar") : L10n.tr("Tentar de novo")) {
                            if state.isRunning {
                                draft.provider = .openAICompatible
                                draft.openAICompatible.endpoint = server.baseURL ?? ""
                                draft.openAICompatible.authenticationMode = .none
                                draft.openAICompatible.model =
                                    state.models.first?.id ?? draft.openAICompatible.model
                                save()
                            } else {
                                Task { await probeAll() }
                            }
                        }
                        .buttonStyle(.plain)
                        .font(theme.sans.font(size: 12.5, weight: .medium))
                        .foregroundStyle(palette.accentInk.color)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity)
        .configTile(palette, radius: 14)
    }

    private func othersStateLabel(_ state: LocalServerState) -> String {
        switch state {
        case .running(let models):
            models.count == 1
                ? L10n.tr("de pé, 1 modelo")
                : L10n.tr("de pé, \(models.count) modelos")
        case .notRunning: L10n.tr("não está rodando")
        case .probing: L10n.tr("perguntando…")
        case .unknown: L10n.tr("ainda não perguntamos")
        }
    }

    // MARK: Peças

    private func stateLabel(_ text: String, color: TokenColor) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color.color)
                .frame(width: 7, height: 7)
            Text(text)
                .font(theme.sans.font(size: 12.5, weight: .medium))
                .foregroundStyle(color.color)
                .fixedSize()
        }
    }
}
