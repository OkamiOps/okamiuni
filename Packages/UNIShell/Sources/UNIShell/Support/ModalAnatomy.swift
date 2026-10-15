import SwiftUI
import UNICore
import UNIDesign

// As peças que **todo** modal do app monta: a moldura, o cabeçalho, o rodapé,
// os dois botões e a confirmação destrutiva. Os números vêm de
// `Theme+Modal.swift` (que os copiou dos protótipos); aqui está só o arranjo.
//
// Nada disto conhece uma tela específica de propósito: a folha de novo
// compromisso, a de adicionar conta e a de reconectar têm cabeçalho e rodapé
// idênticos ao pixel no desenho, e é por isso que elas chamam a mesma peça em
// vez de cada uma desenhar o seu.

// MARK: - A moldura

/// Que tipo de superfície esta é — só o raio muda.
enum ModalSurfaceKind {
    /// Folha que pende do topo, confirmação centrada, janela própria: raio 20.
    case sheet
    /// Balão preso ao gatilho: raio 16.
    case popover
}

/// Fundo opaco, aresta de um pixel, raio do tipo e a sombra da folha.
struct ModalSurface: ViewModifier {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale
    let kind: ModalSurfaceKind

    private var radius: CGFloat {
        kind == .sheet ? theme.modalSheetRadius : theme.modalPopoverRadius
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(theme.modalSheet.color)
            .clipShape(shape)
            .overlay {
                // `strokeBorder`, nunca `.stroke`: o traçado do `.stroke` fica
                // metade para fora da forma e sai lavado em 1×.
                shape.strokeBorder(
                    theme.modalSheetEdge.color, lineWidth: Hairline.thickness(displayScale)
                )
            }
            .shadow(theme.modalShadow)
    }
}

extension View {
    /// Ver `ModalSurface`.
    func modalSurface(_ kind: ModalSurfaceKind = .sheet) -> some View {
        modifier(ModalSurface(kind: kind))
    }
}

/// O véu que separa o modal do app por trás.
struct ModalScrim: View {
    @Environment(\.theme) private var theme
    let onTap: (() -> Void)?

    init(onTap: (() -> Void)? = nil) { self.onTap = onTap }

    var body: some View {
        theme.modalScrim.color
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { onTap?() }
            .accessibilityHidden(true)
    }
}

// MARK: - Cabeçalho

/// `padding: 26px 28px 0`, título de 20–24 com `-0.02em` e **uma** linha de
/// apoio em `ink3`.
///
/// Uma linha, e não duas: o protótipo dá ao cabeçalho exatamente um subtítulo
/// em todas as folhas, e foi assim que ele ficou lendo como frase em vez de
/// bloco de texto.
struct ModalHeader: View {
    @Environment(\.theme) private var theme
    let title: String
    let subtitle: String?
    var titleSize: CGFloat = 23

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(theme.sans.font(size: titleSize, weight: .bold))
                .tracking(theme.modalTitleTracking(at: titleSize))
                .foregroundStyle(theme.ink.color)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle {
                Text(subtitle)
                    .font(theme.sans.font(size: 14))
                    .foregroundStyle(theme.ink3.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, Theme.modalHeaderTop)
        .padding(.horizontal, Theme.modalSide)
    }
}

// MARK: - Rodapé

/// A linha de um pixel, `padding: 16px 28px 20px`, **uma** frase de contexto à
/// esquerda em `ink3` 12,5, "Cancelar" como texto e o primário cheio com halo.
///
/// A frase não é decoração: é o que o protótipo põe no lugar de um alerta
/// separado ("Nada é salvo antes do teste passar", "Enter cria do jeito que
/// está"). Quem não tem nada a dizer passa `nil` e o espaço vira a folga que
/// empurra os botões para a direita.
struct ModalFooter<Primary: View>: View {
    @Environment(\.theme) private var theme
    let context: String?
    let cancelTitle: String
    let onCancel: () -> Void
    @ViewBuilder var primary: Primary

    init(
        context: String?,
        cancelTitle: String = L10n.tr("Cancelar"),
        onCancel: @escaping () -> Void,
        @ViewBuilder primary: () -> Primary
    ) {
        self.context = context
        self.cancelTitle = cancelTitle
        self.onCancel = onCancel
        self.primary = primary()
    }

    var body: some View {
        HStack(spacing: 12) {
            if let context {
                Text(context)
                    .font(theme.sans.font(size: 12.5))
                    .foregroundStyle(theme.ink3.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer(minLength: 0)
            }
            ModalTextButton(cancelTitle, action: onCancel)
                .keyboardShortcut(.cancelAction)
            primary
        }
        .padding(.top, Theme.modalFooterTop)
        .padding(.horizontal, Theme.modalSide)
        .padding(.bottom, Theme.modalFooterBottom)
        .hairline(theme.modalLine, edges: .top)
    }
}

// MARK: - Botões

/// "Cancelar" é **texto**, não botão com borda: `background: none; color:
/// ink2; padding: 10px 12px`. Dar borda aos dois deixa os dois com o mesmo
/// peso, e o protótipo quer o primário sozinho em evidência.
struct ModalTextButton: View {
    @Environment(\.theme) private var theme
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(theme.sans.font(size: 14))
                .foregroundStyle(theme.ink2.color)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.modalButtonRadius)
    }
}

/// O primário: acento cheio, `padding: 11px 20px`, 14 semibold, raio de botão
/// e o halo do acento — que no clássico não existe.
struct ModalPrimaryButton: View {
    @Environment(\.theme) private var theme
    let title: String
    var enabled = true
    /// `padding` horizontal do protótipo: 20 no compromisso, 18 nas contas.
    var horizontalPadding: CGFloat = 20
    var icon: String?
    /// `true` quando o botão divide a largura com outro numa grade de duas
    /// colunas iguais — o "Mover e reabrir" e o "Instalar e reabrir" do
    /// protótipo. `false` (o normal) é o botão do rodapé, que tem a largura do
    /// próprio rótulo.
    var fills = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11.5, weight: .semibold))
                        .accessibilityHidden(true)
                }
            }
            .font(theme.sans.font(size: 14, weight: .semibold))
            .lineLimit(1)
            // O primário **não cede**. Sem isto a frase de contexto do rodapé,
            // que cresce para preencher, espremia o botão até "Testar e
            // recon…" — e quem cede sob aperto tem de ser a frase.
            .fixedSize()
            .foregroundStyle(enabled ? theme.onAccent.color : theme.ink4.color)
            .padding(.horizontal, horizontalPadding)
            .frame(maxWidth: fills ? .infinity : nil)
            .padding(.vertical, 11)
            .background(
                (enabled ? theme.accent : theme.modalSoft).color,
                in: RoundedRectangle(cornerRadius: theme.modalButtonRadius, style: .continuous)
            )
            .shadow(enabled ? theme.modalAccentGlow : [])
            .contentShape(RoundedRectangle(cornerRadius: theme.modalButtonRadius))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .focusRing(cornerRadius: theme.modalButtonRadius, tint: \.onAccent)
    }
}

/// O secundário cheio do protótipo (`btn2`): borda de um pixel, fundo claro,
/// tinta `ink`. É o "Agora não" e o "Ao fechar o app", que dividem a largura
/// com o primário em grade de duas colunas.
struct ModalSecondaryButton: View {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(theme.sans.font(size: 14, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(theme.ink.color)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    theme.modalButton.color,
                    in: RoundedRectangle(cornerRadius: theme.modalButtonRadius, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: theme.modalButtonRadius, style: .continuous)
                        .strokeBorder(
                            theme.modalButtonEdge.color,
                            lineWidth: Hairline.thickness(displayScale)
                        )
                }
                .contentShape(RoundedRectangle(cornerRadius: theme.modalButtonRadius))
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.modalButtonRadius)
    }
}

// MARK: - A folha que pende do topo

/// `left: 50%; top: 56px; transform: translateX(-50%)` — a folha não nasce no
/// meio da janela: ela desce do topo, e o app continua visível embaixo dela.
///
/// É o que separa "folha" de "diálogo" neste desenho, e a diferença não é
/// estética: a folha fala de uma coisa que está acontecendo **no app** (criar
/// um compromisso, ligar uma conta), e ver o app atrás é o que a mantém ligada
/// ao lugar de onde veio. O diálogo centrado é para a parada — ver
/// `UNIConfirmation`.
struct TopHangingSheet<Sheet: View>: ViewModifier {
    let isPresented: Bool
    let onDismiss: (() -> Void)?
    @ViewBuilder var sheet: Sheet

    func body(content: Content) -> some View {
        content.overlay {
            if isPresented {
                ZStack(alignment: .top) {
                    ModalScrim(onTap: onDismiss)
                    sheet
                        .padding(.top, Theme.modalSheetTop)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                .accessibilityAddTraits(.isModal)
            }
        }
    }
}

/// O diálogo **centrado**: a outra metade da regra.
///
/// Confirmação destrutiva e primeiro abrir ficam no meio da janela, na
/// vertical e na horizontal, porque eles não são um pedaço do app — são uma
/// parada. Ver `TopHangingSheet` para a folha, que é o contrário.
struct CenteredModal<Sheet: View>: ViewModifier {
    let isPresented: Bool
    let onDismiss: (() -> Void)?
    @ViewBuilder var sheet: Sheet

    func body(content: Content) -> some View {
        content.overlay {
            if isPresented {
                ZStack {
                    ModalScrim(onTap: onDismiss)
                    sheet.transition(.opacity)
                }
                .accessibilityAddTraits(.isModal)
                .onExitCommand { onDismiss?() }
            }
        }
    }
}

extension View {
    func centeredModal<Sheet: View>(
        isPresented: Bool,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder sheet: () -> Sheet
    ) -> some View {
        modifier(CenteredModal(isPresented: isPresented, onDismiss: onDismiss) { sheet() })
    }

    func topHangingSheet<Sheet: View>(
        isPresented: Bool,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder sheet: () -> Sheet
    ) -> some View {
        modifier(TopHangingSheet(isPresented: isPresented, onDismiss: onDismiss) { sheet() })
    }
}

// MARK: - A confirmação, uma só para o app inteiro

/// O texto de **uma** pergunta destrutiva: o que vai acontecer, por que a
/// pergunta existe e o que o botão vermelho diz.
///
/// O rótulo do botão repete o número ("Apagar as 23") de propósito: é a última
/// coisa que a pessoa lê antes de clicar, e "OK" ali não diz nada sobre o que
/// está a ponto de acontecer.
struct UNIConfirmationText: Equatable {
    /// `font-size: 18px; font-weight: 700; line-height: 1.3`.
    let title: String
    /// `13.5px` em `ink3`. É onde mora o "isso não dá para desfazer — por isso
    /// a pergunta".
    let detail: String
    /// O rótulo do botão destrutivo.
    let confirm: String
    var cancel: String = L10n.tr("Cancelar")
    /// O símbolo dentro do quadrado vermelho de 44pt.
    var icon: String = "trash"
    /// `false` quando a ação é apenas significativa, e não destrutiva: o botão
    /// primário sai no acento em vez do vermelho.
    var isDestructive = true
}

/// **A** confirmação do app — a única peça que desenha "tem certeza?".
///
/// Protótipo (`ModalSistema.dc.html`, bloco `isConfirmar`): 420 de largura,
/// centrada na vertical **e** na horizontal, `padding: 26px 28px`, quadrado de
/// 44pt com o ícone em `redSoft`/`red`, título de 18 em bold, a frase de 13,5
/// em `ink3`, e duas colunas iguais de botão com 10 de folga.
///
/// Centrada, e não pendendo do topo como as folhas: ela é uma parada, não um
/// pedaço do app. Ver `TopHangingSheet` para a outra metade da regra.
///
/// Por que uma peça, e não `confirmationDialog`: o diálogo do sistema não vira
/// com o tema (o magenta do Remover sumia nele), não aceita o número no rótulo
/// do botão com o peso que o desenho pede, e deixava este app com dois
/// idiomas de pergunta — o do macOS na Lixeira e o nosso na janela do
/// compromisso. Esta substitui os dois.
struct UNIConfirmation: View {
    @Environment(\.theme) private var theme
    let text: UNIConfirmationText
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: text.icon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle((text.isDestructive ? theme.modalRed : theme.accentInk).color)
                    .frame(width: 44, height: 44)
                    .background(
                        (text.isDestructive ? theme.modalRedSoft : theme.accentSoft).color,
                        in: RoundedRectangle(cornerRadius: theme.modalFieldRadius, style: .continuous)
                    )
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(text.title)
                        .font(theme.sans.font(size: 18, weight: .bold))
                        .tracking(theme.modalTitleTracking(at: 18) / 2)   // -0.01em
                        .lineSpacing(0.3 * 18)                           // line-height: 1.3
                        .foregroundStyle(theme.ink.color)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(text.detail)
                        .font(theme.sans.font(size: 13.5))
                        .lineSpacing(0.45 * 13.5)
                        .foregroundStyle(theme.ink3.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 10) {
                ModalSecondaryButton(text.cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                UNIConfirmationDestructive(
                    title: text.confirm, isDestructive: text.isDestructive, action: onConfirm
                )
            }
            .padding(.top, 4)
        }
        .padding(.vertical, 26)
        .padding(.horizontal, Theme.modalSide)
        .frame(width: Theme.ModalWidth.confirm, alignment: .leading)
        .modalSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(text.title)
        .accessibilityHint(text.detail)
        .accessibilityAddTraits(.isModal)
    }
}

/// O botão vermelho cheio da confirmação. Sem halo mesmo no Vidro: o
/// protótipo não dá glow ao destrutivo — ele não é a ação que se convida a
/// fazer, é a que se confirma.
private struct UNIConfirmationDestructive: View {
    @Environment(\.theme) private var theme
    let title: String
    let isDestructive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(theme.sans.font(size: 14, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle((isDestructive ? theme.onRemove : theme.onAccent).color)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    (isDestructive ? theme.modalRed : theme.accent).color,
                    in: RoundedRectangle(cornerRadius: theme.modalButtonRadius, style: .continuous)
                )
                .shadow(isDestructive ? [] : theme.modalAccentGlow)
                .contentShape(RoundedRectangle(cornerRadius: theme.modalButtonRadius))
        }
        .buttonStyle(.plain)
        .focusRing(
            cornerRadius: theme.modalButtonRadius,
            tint: isDestructive ? \.onRemove : \.onAccent
        )
        .accessibilityIdentifier("uni-confirmation-confirm")
    }
}

extension View {
    /// Põe `UNIConfirmation` por cima desta tela, centrada, com véu e `esc`
    /// para voltar.
    ///
    /// É isto que as telas chamam: `EmptyTrashConfirmation`, a janela do
    /// compromisso (cancelar reunião, remover do calendário), o aviso da
    /// Caixa — e o que a seção de Ajustes pode adotar para remover conta,
    /// apagar regra e ligar o reencaminhamento automático.
    func uniConfirmation(
        _ text: UNIConfirmationText?,
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) -> some View {
        overlay {
            if let text {
                ZStack {
                    ModalScrim(onTap: onCancel)
                    UNIConfirmation(text: text, onConfirm: onConfirm, onCancel: onCancel)
                }
                .onExitCommand(perform: onCancel)
            }
        }
    }
}

// MARK: - Peças pequenas que mais de um modal usa

/// O rótulo de bloco do protótipo: `12px`, semibold, `letter-spacing: 0.04em`,
/// caixa alta, na tinta do acento ("ENTENDI ASSIM", "PARA CHEGAR PRONTO") ou
/// em `ink3` ("QUINTA 15", "RECENTES", "O QUE MUDOU").
struct ModalEyebrow: View {
    @Environment(\.theme) private var theme
    let text: String
    var size: CGFloat = 12
    var accented = false
    var tracking: CGFloat = 0.04

    var body: some View {
        Text(text)
            .font(theme.sans.font(size: size, weight: .semibold))
            .tracking(size * tracking)
            .textCase(.uppercase)
            .foregroundStyle((accented ? theme.accentInk : theme.ink3).color)
    }
}

/// Um ponto de 7pt na tinta do acento, com o deslocamento de `-2px` que o
/// protótipo dá para ele sentar na linha de base do texto ao lado.
struct ModalBullet: View {
    @Environment(\.theme) private var theme
    var size: CGFloat = 7
    var color: TokenColor?

    var body: some View {
        Circle()
            .fill((color ?? theme.accentInk).color)
            .frame(width: size, height: size)
            .offset(y: -2)
            .accessibilityHidden(true)
    }
}

/// O campo de texto de dentro de uma folha: fundo `field`, raio 12, e — quando
/// é o campo em foco do desenho — a borda de 1,5 no acento com o anel de 4pt
/// em `accentSoft`.
struct ModalFieldBox: ViewModifier {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale
    let focused: Bool
    var verticalPadding: CGFloat = 12
    var horizontalPadding: CGFloat = 14

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: theme.modalFieldRadius, style: .continuous)
        content
            .padding(.vertical, verticalPadding)
            .padding(.horizontal, horizontalPadding)
            .background(theme.modalField.color, in: shape)
            .overlay {
                shape.strokeBorder(
                    (focused ? theme.accent : theme.modalFieldEdge).color,
                    lineWidth: focused ? 1.5 : Hairline.thickness(displayScale)
                )
            }
            // `box-shadow: 0 0 0 4px accentSoft` — um anel, não um borrão.
            .overlay {
                if focused {
                    shape
                        .inset(by: -4)
                        .strokeBorder(theme.accentSoft.color, lineWidth: 4)
                        .allowsHitTesting(false)
                }
            }
    }
}

extension View {
    func modalFieldBox(
        focused: Bool = false, verticalPadding: CGFloat = 12, horizontalPadding: CGFloat = 14
    ) -> some View {
        modifier(ModalFieldBox(
            focused: focused,
            verticalPadding: verticalPadding,
            horizontalPadding: horizontalPadding
        ))
    }
}
