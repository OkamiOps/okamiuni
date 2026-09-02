import Foundation
import SwiftUI
import UNICore
import UNIDesign

/// A intenção editorial enviada ao motor que o app escolher injetar.
///
/// Este alvo não conhece Foundation Models, rede, nem `UNISync`: a janela e a
/// faixa só descrevem o trabalho e recebem uma prévia. A composição concreta
/// pertence à camada que monta o app.
public enum ComposerIntelligenceAction: String, CaseIterable, Sendable {
    case summarize
    case clarify
    case shorten
    case formal
    case cordial
    case correctPortuguese
    case createReply
    case custom

    var title: String {
        switch self {
        case .summarize: "Resumir"
        case .clarify: "Reescrever com clareza"
        case .shorten: "Encurtar"
        case .formal: "Mais formal"
        case .cordial: "Mais cordial"
        case .correctPortuguese: "Corrigir português"
        case .createReply: "Gerar resposta"
        case .custom: "Aplicar instrução"
        }
    }
}

/// O pedaço do composer que uma ação editorial deve tratar.
public enum ComposerIntelligenceTarget: String, Equatable, Sendable {
    case selection
    case draft

    var label: String {
        switch self {
        case .selection: "seleção"
        case .draft: "rascunho"
        }
    }

    var replacementLabel: String {
        switch self {
        case .selection: "Substituir seleção"
        case .draft: "Substituir rascunho"
        }
    }
}

/// Entrada estável para um gerador editorial. `source` é uma cópia: o painel
/// nunca lê o campo enquanto o motor trabalha nem altera texto por acidente.
public struct ComposerIntelligenceRequest: Equatable, Sendable {
    public let action: ComposerIntelligenceAction
    public let target: ComposerIntelligenceTarget
    public let source: String
    public let instruction: String?
    /// A mensagem que originou a resposta, quando existir. Ela é opcional
    /// porque uma mensagem nova não tem contexto anterior, mas é o que permite
    /// ao motor criar uma resposta mesmo antes de haver rascunho.
    public let sourceMessage: Message?
    /// Contexto completo da conversa, quando a superfície dona do composer
    /// consegue fornecê-lo. `sourceMessage` continua existindo para preservar
    /// a origem visual e como fallback de integrações mais simples.
    public let sourceContext: AssistantMailContext?

    public init(
        action: ComposerIntelligenceAction,
        target: ComposerIntelligenceTarget,
        source: String,
        instruction: String? = nil,
        sourceMessage: Message? = nil,
        sourceContext: AssistantMailContext? = nil
    ) {
        self.action = action
        self.target = target
        self.source = source
        self.instruction = instruction
        self.sourceMessage = sourceMessage
        self.sourceContext = sourceContext
    }
}

/// A fronteira injetável. O chamador escolhe se o texto é tratado localmente,
/// por um serviço, ou por outro mecanismo; a superfície de composição não
/// importa nem presume nenhum deles.
public typealias ComposerIntelligenceGenerator = @Sendable (ComposerIntelligenceRequest) async throws -> String

/// Uma prévia pronta, ainda sem nenhuma alteração no rascunho.
public struct ComposerIntelligenceProposal: Equatable, Sendable {
    public let request: ComposerIntelligenceRequest
    public let result: String

    public init(request: ComposerIntelligenceRequest, result: String) {
        self.request = request
        self.result = result
    }
}

enum ComposerIntelligenceError: LocalizedError {
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .emptyResult: "A inteligência não retornou texto para revisar."
        }
    }
}

/// A pequena parte assíncrona, isolada para a interface e os testes usarem o
/// mesmo caminho. Aceitar uma resposta vazia seria um botão que parece agir e
/// termina como no-op; por isso é erro explícito.
enum ComposerIntelligence {
    static func generate(
        _ request: ComposerIntelligenceRequest,
        using generator: @escaping ComposerIntelligenceGenerator
    ) async throws -> ComposerIntelligenceProposal {
        let result = try await generator(request)
        guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ComposerIntelligenceError.emptyResult
        }
        return ComposerIntelligenceProposal(request: request, result: result)
    }
}

/// O contexto que o painel congela no instante de gerar. A aplicação compara
/// essa cópia ao editor atual, evitando substituir outra seleção se a pessoa
/// continuou editando enquanto a prévia estava aberta.
struct ComposerIntelligenceContext: Equatable {
    let target: ComposerIntelligenceTarget
    let source: String
}

enum ComposerIntelligenceApplyResult: Equatable {
    case applied
    case sourceChanged
    case emptyResult

    var errorMessage: String {
        switch self {
        case .applied: ""
        case .sourceChanged:
            "O texto de origem mudou; gere uma nova prévia antes de substituir."
        case .emptyResult:
            "A prévia está vazia e não foi aplicada."
        }
    }
}

/// Painel editorial próprio, ancorado ao botão da barra. Não é um `Menu`: tem
/// alvo explícito, estado de geração, erro e uma prévia que pede confirmação.
struct ComposerIntelligencePanel: View {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    enum Phase: Equatable {
        case ready
        case loading(ComposerIntelligenceAction)
        case preview(ComposerIntelligenceProposal)
        case failure(String)
    }

    let context: ComposerIntelligenceContext?
    let available: Bool
    let sourceMessage: Message?
    let phase: Phase
    @Binding var instruction: String
    let generate: (ComposerIntelligenceAction, String?) -> Void
    let apply: (ComposerIntelligenceProposal) -> Void
    let cancel: () -> Void

    private var targetLabel: String {
        context?.target.label ?? "rascunho"
    }

    private var inputIsUsable: Bool {
        guard let context else { return false }
        return !context.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var unavailableReason: String? {
        if !available { return "A inteligência de escrita ainda não foi conectada a esta tela." }
        if !inputIsUsable, sourceMessage == nil {
            return "Escreva ou selecione algum texto antes de usar a inteligência."
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "apple.intelligence")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.info.color)
                    .frame(width: 24, height: 24)
                    .background(theme.infoSoft.color, in: RoundedRectangle(cornerRadius: theme.radiusSmall))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Inteligência de escrita")
                        .font(theme.sans.font(size: 12, weight: .semibold))
                        .foregroundStyle(theme.ink.color)
                    Text("Vai atuar no \(targetLabel)")
                        .font(theme.sans.font(size: 10.5))
                        .foregroundStyle(theme.ink4.color)
                }
                Spacer(minLength: 0)
            }

            if let unavailableReason {
                Text(unavailableReason)
                    .font(theme.sans.font(size: 11))
                    .foregroundStyle(theme.ink3.color)
                    .fixedSize(horizontal: false, vertical: true)
            }

            switch phase {
            case .ready, .failure:
                actionGrid
                createReplyButton
                instructionRow
            case .loading(let action):
                loading(action)
            case .preview(let proposal):
                preview(proposal)
            }

            if case .failure(let message) = phase {
                Text(message)
                    .font(theme.sans.font(size: 11))
                    .foregroundStyle(theme.danger.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(width: 316, alignment: .leading)
        .background(theme.surface.color)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusLarge))
        .overlay {
            RoundedRectangle(cornerRadius: theme.radiusLarge)
                .strokeBorder(theme.line.color, lineWidth: Hairline.thickness(displayScale))
        }
        .shadow(color: .black.opacity(0.20), radius: 16, x: 0, y: 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inteligência de escrita para \(targetLabel)")
    }

    private var actionGrid: some View {
        let actions: [ComposerIntelligenceAction] = [
            .summarize, .clarify, .shorten, .formal, .cordial, .correctPortuguese
        ]
        return LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)],
            spacing: 6
        ) {
            ForEach(actions, id: \.self) { action in
                panelButton(action.title, enabled: available && inputIsUsable) {
                    generate(action, nil)
                }
            }
        }
    }

    @ViewBuilder
    private var createReplyButton: some View {
        if sourceMessage != nil {
            panelButton(ComposerIntelligenceAction.createReply.title, enabled: available) {
                generate(.createReply, nil)
            }
            .help("Cria uma prévia a partir da mensagem recebida, sem alterar o rascunho")
        }
    }

    private var instructionRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Instrução livre")
                .font(theme.mono.font(size: 9.5))
                .foregroundStyle(theme.ink4.color)
                .textCase(.uppercase)
            HStack(spacing: 6) {
                TextField("Ex.: deixe mais objetivo", text: $instruction)
                    .textFieldStyle(.plain)
                    .font(theme.sans.font(size: 11.5))
                    .foregroundStyle(theme.ink.color)
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(theme.surface2.color, in: RoundedRectangle(cornerRadius: theme.radiusSmall))
                    .overlay {
                        RoundedRectangle(cornerRadius: theme.radiusSmall)
                            .strokeBorder(theme.btnLine.color, lineWidth: Hairline.thickness(displayScale))
                    }

                panelButton(
                    "Gerar",
                    enabled: available && inputIsUsable && !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ) {
                    generate(.custom, instruction)
                }
                .frame(width: 58)
            }
        }
    }

    private func loading(_ action: ComposerIntelligenceAction) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("\(action.title)…")
                .font(theme.sans.font(size: 11.5, weight: .medium))
                .foregroundStyle(theme.ink2.color)
            Spacer(minLength: 0)
            panelButton("Cancelar", enabled: true, action: cancel)
                .frame(width: 68)
        }
        .padding(.vertical, 6)
    }

    private func preview(_ proposal: ComposerIntelligenceProposal) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Prévia · \(proposal.request.action.title)")
                .font(theme.mono.font(size: 9.5))
                .foregroundStyle(theme.ink4.color)
                .textCase(.uppercase)
            ScrollView {
                Text(proposal.result)
                    .font(theme.serif.font(size: 13.5))
                    .foregroundStyle(theme.ink.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(9)
                    .textSelection(.enabled)
            }
            // Sem uma altura mínima, `ScrollView` não oferece tamanho ideal
            // ao painel ancorado e colapsa para zero: a geração acontece, mas
            // só aparecem o rótulo “Prévia” e os botões. A faixa mantém uma
            // resposta curta legível e passa a rolar apenas quando necessário.
            .frame(minHeight: 82, maxHeight: 148, alignment: .topLeading)
            .background(theme.surface2.color, in: RoundedRectangle(cornerRadius: theme.radiusSmall))
            .overlay {
                RoundedRectangle(cornerRadius: theme.radiusSmall)
                    .strokeBorder(theme.line2.color, lineWidth: Hairline.thickness(displayScale))
            }

            HStack(spacing: 6) {
                panelButton(proposal.request.target.replacementLabel, enabled: true) {
                    apply(proposal)
                }
                panelButton("Cancelar", enabled: true, action: cancel)
                Spacer(minLength: 0)
            }
        }
    }

    private func panelButton(
        _ label: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(theme.sans.font(size: 10.5, weight: .medium))
                .foregroundStyle(enabled ? theme.ink2.color : theme.ink4.color.opacity(0.65))
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .background(enabled ? theme.btn.color : theme.surface2.color)
                .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
                .overlay {
                    RoundedRectangle(cornerRadius: theme.radiusSmall)
                        .strokeBorder(theme.btnLine.color, lineWidth: Hairline.thickness(displayScale))
                }
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .focusRing(cornerRadius: theme.radiusSmall)
    }
}

extension ComposerToolbar {
    /// A parte visual do painel fica ao lado dos controles porque a âncora é a
    /// barra; estado e escrita continuam em `ComposerToolbar`/`ComposerEditor`.
    func intelligencePanel(
        context: ComposerIntelligenceContext?,
        phase: ComposerIntelligencePanel.Phase,
        instruction: Binding<String>,
        generate: @escaping (ComposerIntelligenceAction, String?) -> Void,
        apply: @escaping (ComposerIntelligenceProposal) -> Void,
        cancel: @escaping () -> Void
    ) -> some View {
        ComposerIntelligencePanel(
            context: context,
            available: intelligence != nil,
            sourceMessage: intelligenceSourceMessage,
            phase: phase,
            instruction: instruction,
            generate: generate,
            apply: apply,
            cancel: cancel
        )
    }
}
