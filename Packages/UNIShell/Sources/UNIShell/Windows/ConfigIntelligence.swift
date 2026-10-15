import AppKit
import SwiftUI
import UNICore
import UNIDesign
import UNISync

/// Em que passo a Inteligência está. É o que a faixa de três cartões desenha,
/// e é também o que decide se a página mostra o estado pronto ou o convite
/// para conectar.
enum ConfigIntelligenceStep: Sendable {
    case done
    case now
    case todo
}

/// Inteligência: a faixa de três passos, o diagrama do que sai deste Mac, a
/// análise automática, o modelo, o teste — e, do outro lado, como ela escreve
/// por você e as instruções por finalidade.
struct ConfigIntelligence: View {
    @Environment(\.theme) private var theme
    @Environment(\.configPalette) private var palette
    @Environment(\.displayScale) private var displayScale

    @Binding var draft: AssistantSettings
    /// `true` quando a página é o passo 2 — o convite para conectar.
    let connecting: Bool
    let connected: Bool
    let oauthStatus: AssistantProviderOAuthStatus
    let lastTest: String?
    let lastTestFailed: Bool
    let testing: Bool
    let availableModels: [AssistantProviderModel]
    let save: () -> Void
    let test: () -> Void
    let connect: () -> Void
    /// Abre o painel de conexão existente numa rota específica — é lá que
    /// moram os formulários de chave de API, LiteLLM, CLI e Apple
    /// Intelligence, com os fluxos que já funcionam.
    let openRoute: (AssistantProvider) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            steps
            if connecting {
                connectPage
            } else {
                readyPage
            }
        }
    }

    // MARK: A faixa dos três passos

    private var steps: some View {
        HStack(spacing: 10) {
            step(
                number: "1", label: L10n.tr("Onde roda"),
                value: AssistantDestination(settings: draft).label,
                state: .done
            )
            step(
                number: "2", label: L10n.tr("Conectar"),
                value: connecting ? L10n.tr("é agora") : connectedValue,
                state: connecting ? .now : (connected ? .done : .todo)
            )
            step(
                number: "3", label: L10n.tr("Testar de verdade"),
                value: lastTest ?? L10n.tr("com um e-mail seu"),
                state: lastTest == nil || lastTestFailed ? .todo : .done
            )
        }
        .padding(.bottom, 22)
    }

    private func step(
        number: String, label: String, value: String, state: ConfigIntelligenceStep
    ) -> some View {
        let circleFill: TokenColor = switch state {
        case .done: palette.green
        case .now: palette.accent
        case .todo: palette.field
        }
        let circleInk: TokenColor = switch state {
        case .done: theme.isDark ? palette.ink : palette.onAccent
        case .now: palette.onAccent
        case .todo: palette.ink3
        }
        let labelInk: TokenColor = switch state {
        case .done: palette.ink2
        case .now: palette.ink
        case .todo: palette.ink3
        }
        return HStack(spacing: 11) {
            ZStack {
                Circle().fill(circleFill.color)
                if state == .done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(circleInk.color)
                } else {
                    Text(number)
                        .font(theme.sans.font(size: 13, weight: .semibold))
                        .foregroundStyle(circleInk.color)
                }
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(theme.sans.font(size: 13, weight: .semibold))
                    .foregroundStyle(labelInk.color)
                    .lineLimit(1)
                Text(value)
                    .font(theme.sans.font(size: 12))
                    .foregroundStyle(palette.ink3.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
            if state == .now {
                shape.fill(palette.accentSoft.color)
            } else {
                shape.strokeBorder(palette.line.color, lineWidth: Hairline.thickness(displayScale))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var connectedValue: String {
        GeneralSettingsView.assistantRouteLabel(for: draft)
    }

    // MARK: A página pronta

    private var readyPage: some View {
        ScrollView {
            HStack(alignment: .top, spacing: ConfigMetrics.columnGap) {
                readyLeft.frame(maxWidth: .infinity, alignment: .leading)
                readyRight.frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.bottom, 4)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var readyLeft: some View {
        VStack(alignment: .leading, spacing: 0) {
            ConfigBlockTitle(text: L10n.tr("O que sai deste Mac")).padding(.bottom, 10)
            privacyDiagram

            ConfigRow(
                label: L10n.tr("Analisar e-mails novos sozinha"),
                note: L10n.tr("se ligar, todo e-mail novo vai para a IA assim que chega"),
                divider: .bottom,
                verticalPadding: 0
            ) {
                ConfigSwitch(
                    isOn: Binding(
                        get: { draft.automaticAnalysis == .configuredProvider },
                        set: { on in
                            draft.automaticAnalysis = on ? .configuredProvider : .onDeviceOnly
                            draft.automaticAnalysisTouchedByUser = true
                            save()
                        }
                    ),
                    label: L10n.tr("Analisar e-mails novos sozinha")
                )
                .disabled(AssistantDestination(settings: draft).isLocal)
            }
            .padding(.top, 14)
            .padding(.bottom, 12)

            ConfigRow(label: L10n.tr("Modelo"), divider: .bottom) {
                if availableModels.isEmpty {
                    Text(currentModel)
                        .font(theme.mono.font(size: 12))
                        .foregroundStyle(palette.ink2.color)
                } else {
                    ConfigPicker(
                        options: availableModels.map { ($0.id, $0.id) },
                        selection: Binding(
                            get: { currentModel },
                            set: { id in
                                switch draft.provider {
                                case .providerOAuth: draft.providerOAuth.model = id
                                default: draft.openAICompatible.model = id
                                }
                                save()
                            }
                        ),
                        accessibilityTitle: L10n.tr("Modelo"),
                        mono: true
                    )
                }
            }

            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Circle()
                        .fill((lastTestFailed ? palette.red : palette.green).color)
                        .frame(width: 7, height: 7)
                    Text(lastTest ?? L10n.tr("Ainda não testada neste Mac"))
                        .font(theme.sans.font(size: 13))
                        .foregroundStyle((lastTest == nil
                            ? palette.ink3
                            : (lastTestFailed ? palette.red : palette.green)).color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button(testing ? L10n.tr("Testando…") : L10n.tr("Testar de novo"), action: test)
                    .buttonStyle(.plain)
                    .configQuietButton(palette, font: theme.sans.font(size: 13, weight: .medium))
                    .disabled(testing)
            }
            .padding(.vertical, 12)
        }
    }

    /// `Este Mac — cadeado — provedor`. O desenho é a promessa: o que sai daqui
    /// sai porque alguém pediu.
    private var privacyDiagram: some View {
        HStack(alignment: .center, spacing: 10) {
            diagramEnd(
                symbol: "desktopcomputer",
                title: L10n.tr("Este Mac"),
                detail: L10n.tr("seus e-mails,\nsua agenda")
            )
            VStack(spacing: 5) {
                Image(systemName: "lock")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.orange.color)
                Rectangle()
                    .fill(palette.ink3.color)
                    .frame(width: 74, height: 1.5)
                    .mask(alignment: .leading) {
                        HStack(spacing: 4) {
                            ForEach(0..<8, id: \.self) { _ in
                                Rectangle().frame(width: 5)
                            }
                        }
                    }
                Text(L10n.tr("só o que você\nmandar, quando mandar"))
                    .font(theme.sans.font(size: 11, weight: .semibold))
                    .foregroundStyle(palette.ink2.color)
                    .multilineTextAlignment(.center)
            }
            diagramEnd(
                symbol: destinationSymbol,
                title: AssistantDestination(settings: draft).label,
                detail: AssistantDestination(settings: draft).isLocal
                    ? L10n.tr("responde sem\nsair daqui")
                    : L10n.tr("responde e\nesquece")
            )
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .configTile(palette)
    }

    private var destinationSymbol: String {
        AssistantDestination(settings: draft).isLocal ? "cpu" : "cloud"
    }

    private func diagramEnd(symbol: String, title: String, detail: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 21, weight: .light))
                .foregroundStyle(palette.ink2.color)
            Text(title)
                .font(theme.sans.font(size: 13, weight: .semibold))
                .foregroundStyle(palette.ink.color)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Text(detail)
                .font(theme.sans.font(size: 11.5))
                .foregroundStyle(palette.ink3.color)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private var readyRight: some View {
        VStack(alignment: .leading, spacing: 0) {
            ConfigBlockTitle(text: L10n.tr("Como ela escreve por você")).padding(.bottom, 4)

            ConfigRow(label: L10n.tr("Tom"), verticalPadding: 11) {
                ConfigSegmented(
                    options: AssistantTonePreference.allCases.map { ($0, $0.label) },
                    selection: Binding(
                        get: { draft.behavior.tone },
                        set: { draft.behavior.tone = $0; save() }
                    ),
                    fontSize: 12, horizontal: 9, vertical: 5
                )
            }
            ConfigRow(label: L10n.tr("Tamanho"), verticalPadding: 11) {
                ConfigSegmented(
                    options: AssistantDetailPreference.allCases.map { ($0, $0.label) },
                    selection: Binding(
                        get: { draft.behavior.detail },
                        set: { draft.behavior.detail = $0; save() }
                    ),
                    fontSize: 12, horizontal: 9, vertical: 5
                )
            }
            ConfigRow(label: L10n.tr("Formato"), verticalPadding: 11) {
                ConfigSegmented(
                    options: AssistantFormatPreference.allCases.map { ($0, $0.label) },
                    selection: Binding(
                        get: { draft.behavior.format },
                        set: { draft.behavior.format = $0; save() }
                    ),
                    fontSize: 12, horizontal: 9, vertical: 5
                )
            }
            ConfigRow(label: L10n.tr("Responder em"), verticalPadding: 11) {
                ConfigPicker(
                    options: AssistantLanguagePreference.allCases.map { ($0, $0.label) },
                    selection: Binding(
                        get: { draft.behavior.language },
                        set: { draft.behavior.language = $0; save() }
                    ),
                    accessibilityTitle: L10n.tr("Responder em")
                )
            }
            ConfigRow(
                label: L10n.tr("Sugerir próximos passos"),
                note: L10n.tr("“quer que eu já crie o compromisso?”"),
                verticalPadding: 11
            ) {
                ConfigSwitch(
                    isOn: Binding(
                        get: { draft.behavior.suggestNextSteps },
                        set: { draft.behavior.suggestNextSteps = $0; save() }
                    ),
                    label: L10n.tr("Sugerir próximos passos")
                )
            }

            instructions
        }
    }

    @State private var purpose: ConfigInstructionPurpose = .writing

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text(L10n.tr("Instruções suas"))
                    .font(theme.sans.font(size: 14, weight: .medium))
                    .foregroundStyle(palette.ink.color)
                Spacer(minLength: 0)
                ForEach(ConfigInstructionPurpose.allCases) { candidate in
                    let on = candidate == purpose
                    Button { purpose = candidate } label: {
                        Text(candidate.label)
                            .font(theme.sans.font(size: 12, weight: on ? .semibold : .medium))
                            .foregroundStyle((on ? palette.accentInk : palette.ink3).color)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background {
                                if on {
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(palette.accentSoft.color)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? [.isSelected] : [])
                }
            }

            TextEditor(text: instructionBinding)
                .font(theme.sans.font(size: 13))
                .foregroundStyle(palette.ink2.color)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(minHeight: 62)
                .background(palette.field.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(palette.line.color, lineWidth: Hairline.thickness(displayScale))
                }
                .accessibilityLabel(L10n.tr("Instruções para \(purpose.label)"))

            Text(L10n.tr("Perguntas e Escrita têm instruções separadas. O “Sempre” vale para tudo."))
                .font(theme.sans.font(size: 12))
                .foregroundStyle(palette.ink3.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 13)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(palette.line.color)
                .frame(height: Hairline.thickness(displayScale))
        }
    }

    private var instructionBinding: Binding<String> {
        Binding(
            get: {
                switch purpose {
                case .questions: draft.behavior.questionsInstructions
                case .writing: draft.behavior.writingInstructions
                case .always: draft.additionalInstructions
                }
            },
            set: { value in
                switch purpose {
                case .questions: draft.behavior.questionsInstructions = value
                case .writing: draft.behavior.writingInstructions = value
                case .always: draft.additionalInstructions = value
                }
            }
        )
    }

    private var currentModel: String {
        switch draft.provider {
        case .providerOAuth: draft.providerOAuth.model
        case .openAICompatible: draft.openAICompatible.model
        case .cli: draft.cli.kind.displayName
        case .foundationModels: L10n.tr("Apple Intelligence")
        }
    }

    // MARK: A página de conectar — o passo 2

    private var connectPage: some View {
        // `grid-template-columns: minmax(0, 1.25fr) minmax(0, 1fr)`: o convite
        // é a coluna larga, e o combinado, a estreita.
        GeometryReader { proxy in
            let util = proxy.size.width - ConfigMetrics.columnGap
            let esquerda = util * 1.25 / 2.25
            ScrollView {
                HStack(alignment: .top, spacing: ConfigMetrics.columnGap) {
                    VStack(alignment: .leading, spacing: 14) {
                        inviteCard
                        otherRoutes
                    }
                    .frame(width: max(0, esquerda), alignment: .leading)
                    promise
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.bottom, 4)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var inviteCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(palette.accentInk.color)
                .frame(width: 52, height: 52)
                .background(palette.accentSoft.color, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            Text(L10n.tr("Entrar com a sua conta ChatGPT"))
                .font(theme.sans.font(size: 19, weight: .bold))
                .tracking(-0.015 * 19)
                .foregroundStyle(palette.ink.color)
            Text(L10n.tr("Abre o navegador, você aprova lá, e volta pronto. Sem colar chave, sem cobrança nova — usa a assinatura que você já paga."))
                .font(theme.sans.font(size: 13.5))
                .lineSpacing(13.5 * 0.45)
                .foregroundStyle(palette.ink3.color)
                .fixedSize(horizontal: false, vertical: true)

            if case .awaitingDeviceCode(let authorization) = oauthStatus {
                deviceCode(authorization)
            } else {
                Button(L10n.tr("Conectar agora"), action: connect)
                    .buttonStyle(.plain)
                    .configPrimaryButton(
                        palette, font: theme.sans.font(size: 14, weight: .semibold),
                        radius: 11, horizontal: 20, vertical: 12
                    )
                    .padding(.top, 4)
            }

            if case .failed(let message) = oauthStatus {
                Text(message)
                    .font(theme.sans.font(size: 12.5))
                    .foregroundStyle(palette.red.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .configCard(palette)
    }

    /// O código do fluxo de dispositivo, quando o provedor pede um.
    private func deviceCode(_ authorization: AssistantProviderOAuthDeviceAuthorization) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.tr("Abra o endereço e digite este código:"))
                .font(theme.sans.font(size: 13))
                .foregroundStyle(palette.ink2.color)
            Text(authorization.userCode)
                .font(theme.mono.font(size: 20, weight: .semibold))
                .foregroundStyle(palette.ink.color)
                .textSelection(.enabled)
            Button(authorization.verificationURL.absoluteString) {
                NSWorkspace.shared.open(authorization.verificationURL)
            }
            .buttonStyle(.plain)
            .font(theme.sans.font(size: 13, weight: .medium))
            .foregroundStyle(palette.accentInk.color)
        }
        .padding(.top, 4)
    }

    /// `flex-wrap: wrap`: os quatro caminhos cabem numa linha quando a janela
    /// é larga e **quebram inteiros** quando não cabem. Um `HStack` os
    /// espremeria letra a letra, que é o que punha "Apple Intelligence, sem
    /// internet" em três linhas de duas palavras.
    private var otherRoutes: some View {
        FlowLayout(spacing: 8, rowSpacing: 6) {
            Text(L10n.tr("Prefere outro caminho?"))
                .font(theme.sans.font(size: 13))
                .foregroundStyle(palette.ink3.color)
            route(L10n.tr("Grok"), provider: .providerOAuth)
            dot
            route(L10n.tr("Chave de API ou LiteLLM"), provider: .openAICompatible)
            dot
            route(L10n.tr("CLI deste Mac"), provider: .cli)
            dot
            route(L10n.tr("Apple Intelligence, sem internet"), provider: .foundationModels)
        }
        .padding(.horizontal, 4)
    }

    private var dot: some View {
        Text("·")
            .font(theme.sans.font(size: 13))
            .foregroundStyle(palette.ink3.color)
    }

    private func route(_ label: String, provider: AssistantProvider) -> some View {
        Button(label) { openRoute(provider) }
            .buttonStyle(.plain)
            .font(theme.sans.font(size: 13, weight: .medium))
            .foregroundStyle(palette.accentInk.color)
            .lineLimit(1)
            .fixedSize()
    }

    private var promise: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 8) {
                Image(systemName: "lock")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.orange.color)
                Text(L10n.tr("O combinado, antes de conectar"))
                    .font(theme.sans.font(size: 13, weight: .semibold))
                    .foregroundStyle(palette.ink2.color)
            }
            promiseLine(true, L10n.tr("Manda só o e-mail que você pedir para analisar ou responder."))
            promiseLine(true, L10n.tr("Você escolhe o modelo e testa antes de usar de verdade."))
            promiseLine(false, L10n.tr("Nunca lê a sua caixa sozinha — a análise automática nasce desligada."))
            promiseLine(false, L10n.tr("Nada seu fica guardado fora deste Mac."))
            Text(L10n.tr("Dá para trocar de provedor quando quiser, sem perder nada."))
                .font(theme.sans.font(size: 12))
                .foregroundStyle(palette.ink3.color)
                .padding(.top, 11)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(palette.line.color)
                        .frame(height: Hairline.thickness(displayScale))
                }
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .configTile(palette, radius: 16)
    }

    private func promiseLine(_ yes: Bool, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: yes ? "checkmark" : "xmark")
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle((yes ? palette.green : palette.red).color)
                .padding(.top, 2)
            Text(text)
                .font(theme.sans.font(size: 13))
                .lineSpacing(13 * 0.45)
                .foregroundStyle(palette.ink2.color)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// As três finalidades de instrução que o desenho mostra como abas.
enum ConfigInstructionPurpose: String, CaseIterable, Identifiable {
    case questions
    case writing
    case always

    var id: String { rawValue }

    var label: String {
        switch self {
        case .questions: L10n.tr("Perguntas")
        case .writing: L10n.tr("Escrita")
        case .always: L10n.tr("Sempre")
        }
    }
}
