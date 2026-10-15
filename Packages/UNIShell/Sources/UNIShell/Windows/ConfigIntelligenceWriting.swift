import SwiftUI
import UNICore
import UNIDesign
import UNISync

/// As três finalidades de instrução que o desenho mostra como abas pequenas.
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

/// A aba "Como ela escreve": tom, tamanho, formato, idioma, próximos passos e
/// as instruções por finalidade.
///
/// A lógica é a mesma que já existia na metade direita da página antiga — tom,
/// detalhe, formato e idioma são `AssistantBehaviorPreferences`, e as três
/// instruções continuam indo para `questionsInstructions`,
/// `writingInstructions` e `additionalInstructions`. Só o lugar mudou: elas
/// deixaram de dividir a página com as conexões e ganharam a aba que o desenho
/// lhes dá.
struct ConfigIntelligenceWriting: View {
    @Environment(\.theme) private var theme
    @Environment(\.configPalette) private var palette
    @Environment(\.displayScale) private var displayScale

    @Binding var draft: AssistantSettings
    let save: () -> Void

    @State private var purpose: ConfigInstructionPurpose = .writing

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(spacing: 0) {
                    row(L10n.tr("Tom")) {
                        ConfigSegmented(
                            options: AssistantTonePreference.allCases.map { ($0, $0.label) },
                            selection: Binding(
                                get: { draft.behavior.tone },
                                set: { draft.behavior.tone = $0; save() }
                            ),
                            fontSize: 12, horizontal: 9, vertical: 5
                        )
                    }
                    row(L10n.tr("Tamanho"), first: false) {
                        ConfigSegmented(
                            options: AssistantDetailPreference.allCases.map { ($0, $0.label) },
                            selection: Binding(
                                get: { draft.behavior.detail },
                                set: { draft.behavior.detail = $0; save() }
                            ),
                            fontSize: 12, horizontal: 9, vertical: 5
                        )
                    }
                    row(L10n.tr("Formato"), first: false) {
                        ConfigSegmented(
                            options: AssistantFormatPreference.allCases.map { ($0, $0.label) },
                            selection: Binding(
                                get: { draft.behavior.format },
                                set: { draft.behavior.format = $0; save() }
                            ),
                            fontSize: 12, horizontal: 9, vertical: 5
                        )
                    }
                    row(L10n.tr("Responder em"), first: false) {
                        ConfigPicker(
                            options: AssistantLanguagePreference.allCases.map { ($0, $0.label) },
                            selection: Binding(
                                get: { draft.behavior.language },
                                set: { draft.behavior.language = $0; save() }
                            ),
                            accessibilityTitle: L10n.tr("Responder em")
                        )
                    }
                    row(
                        L10n.tr("Sugerir próximos passos"),
                        note: L10n.tr("“quer que eu já crie o compromisso?”"),
                        first: false
                    ) {
                        ConfigSwitch(
                            isOn: Binding(
                                get: { draft.behavior.suggestNextSteps },
                                set: { draft.behavior.suggestNextSteps = $0; save() }
                            ),
                            label: L10n.tr("Sugerir próximos passos")
                        )
                    }
                }
                .configCard(palette, radius: 14, shadow: palette.sectionShadow, shadowOnlyBelow: true)

                instructions
            }
            .frame(maxWidth: 820, alignment: .leading)
            .padding(.bottom, 4)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func row<Control: View>(
        _ label: String,
        note: String? = nil,
        first: Bool = true,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(theme.sans.font(size: 14, weight: .medium))
                    .foregroundStyle(palette.ink.color)
                if let note {
                    Text(note)
                        .font(theme.sans.font(size: 12.5))
                        .foregroundStyle(palette.ink3.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control()
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

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 4) {
                Text(L10n.tr("Instruções suas"))
                    .font(theme.sans.font(size: 15, weight: .semibold))
                    .tracking(-0.01 * 15)
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

            TextEditor(text: binding)
                .font(theme.sans.font(size: 13))
                .foregroundStyle(palette.ink2.color)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(minHeight: 86)
                .background(
                    palette.field.color,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(palette.line.color, lineWidth: Hairline.thickness(displayScale))
                }
                .accessibilityLabel(L10n.tr("Instruções para \(purpose.label)"))

            Text(L10n.tr("Perguntas e Escrita têm instruções separadas. O “Sempre” vale para tudo."))
                .font(theme.sans.font(size: 12.5))
                .foregroundStyle(palette.ink3.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var binding: Binding<String> {
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
}
