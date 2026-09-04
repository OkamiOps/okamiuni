import SwiftUI
import UNICore
import UNIDesign
#if canImport(AppKit)
import AppKit
#endif

/// A pergunta antes de abrir um link do corpo do email.
///
/// ## O defeito que ela conserta
///
/// "Para abrir link falta uma confirmação — atualmente ao clicar no link ele
/// abre direto." Abrir direto é o comportamento que esconde a única informação
/// que importa: **para onde**. O texto da âncora é escolhido por quem mandou o
/// email; `resend.com/onboarding` e `resend.com.phish.example/onboarding` se
/// escrevem iguais quando o rótulo é "Confirme sua conta".
///
/// ## As regras que ela **não** afrouxa
///
/// - Quem decide o que pode abrir continua sendo `ReaderHTMLPolicy.decide`. O
///   que ela recusa não abre e **nem pergunta**: não existe caminho novo para
///   fora daqui.
/// - Não há "não perguntar de novo" e não há lista de domínios confiáveis. O
///   dono pediu confirmação; uma exceção guardada é uma porta que ninguém
///   reabre depois de aberta. Toda vez pergunta.
/// - Cancelar é o padrão: Esc fecha, o clique no fundo fecha, e o único
///   caminho para o navegador é o botão que diz que vai para lá.
///
/// ## Por que uma classe, e não um `@State` de `View`
///
/// Duas superfícies pedem a mesma pergunta — a prévia do dashboard, que desenha
/// o corpo com `CorpoLegivelView`, e o leitor, cuja `WKWebView` intercepta a
/// navegação em `decidePolicyFor`. Com o estado na `View`, as duas teriam
/// pergunta própria e divergiriam no primeiro conserto. E o abridor entra como
/// valor pela mesma razão do "Entrar" da janela 04: **nenhum teste deste
/// projeto abre navegador** — o ensaio injeta um que anota o endereço.
@MainActor
@Observable
final class LinkConfirmation {

    /// Um pedido no ar. `id` novo a cada pedido: pedir o mesmo link duas vezes
    /// é duas perguntas, e a `View` precisa perceber a segunda.
    struct Pedido: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        let destino: LinkDoCorpo.Destino
    }

    private(set) var pendente: Pedido?

    private let abridor: @MainActor (URL) -> Void

    init(abridor: @escaping @MainActor (URL) -> Void = LinkConfirmation.navegadorDoSistema) {
        self.abridor = abridor
    }

    /// O abridor de verdade — o navegador padrão da pessoa. A `WebView` do
    /// leitor nunca navega, e a prévia também não: link sai do app.
    static let navegadorDoSistema: @MainActor (URL) -> Void = { url in
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }

    /// Levanta a pergunta. Devolve `false` — **sem abrir nada** — quando a
    /// política do leitor não deixa este endereço sair.
    @discardableResult
    func pede(_ url: URL?) -> Bool {
        guard let url,
              case .abrirNoNavegador(let destinoURL) = ReaderHTMLPolicy.decide(url: url),
              let destino = LinkDoCorpo.destino(de: destinoURL)
        else { return false }
        pendente = Pedido(url: destinoURL, destino: destino)
        return true
    }

    /// O único caminho para fora do app.
    func abre() {
        guard let pedido = pendente else { return }
        pendente = nil
        abridor(pedido.url)
    }

    func cancela() {
        pendente = nil
    }
}

// MARK: - Onde a pergunta chega

extension EnvironmentValues {
    /// Quem pergunta pela superfície corrente. `nil` onde ninguém pendurou a
    /// pergunta — e aí o link **não abre**, que é o lado certo do engano.
    @Entry var linkConfirmation: LinkConfirmation?
}

// MARK: - O cartão

/// O cartão da pergunta.
///
/// Cartão nosso, e não `confirmationDialog`: o diálogo do sistema não segue o
/// tema (é a queixa que abriu esta tarefa) e, pior aqui, ele não sabe desenhar
/// o **anfitrião em destaque dentro do endereço** — que é a única coisa que
/// esta pergunta existe para mostrar. A exceção do `EmptyTrashConfirmation`
/// continua valendo lá, onde o sistema é o idioma certo: aquele é uma parada
/// destrutiva, este é informação.
struct LinkConfirmCard: View {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    let destino: LinkDoCorpo.Destino
    let rotuloDeAbertura: String
    let onOpen: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.tr("Abrir link"))
                .capsLabel(size: 9.5)
                .foregroundStyle(theme.ink4.color)

            // **O anfitrião, sozinho e grande.** É a linha que responde a
            // pergunta à primeira vista; o endereço inteiro vem depois, para
            // quem quiser conferir o resto.
            Text(destino.anfitriao.isEmpty ? destino.porExtenso : destino.anfitriao)
                .font(theme.mono.font(size: 17, weight: .semibold))
                .foregroundStyle(theme.ink.color)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if let aviso = destino.aviso { avisoLinha(aviso) }

            Text(L10n.tr("Endereço completo"))
                .capsLabel(size: 9)
                .foregroundStyle(theme.ink4.color)
                .padding(.top, 2)

            // Por extenso, com o anfitrião realçado **dentro** do endereço: é
            // ali que `banco.com@malicioso.example` se desmonta na frente de
            // quem lê.
            porExtenso
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(theme.surface2.color)
                .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))

            // A fileira cabe na coluna da prévia (380pt) com o rótulo inteiro
            // de cada botão. Medido: com "Abrir no navegador" em 14pt de folga
            // o botão saía truncado como "Abrir no nave…", que é o botão mudo
            // com outro nome — ninguém confirma o que não consegue ler.
            HStack(spacing: 8) {
                ChromeButton(
                    L10n.tr("Copiar link"), appearance: .quiet, size: 11.5,
                    height: 30, horizontalPadding: 8
                ) {
                    Clipboard.copy(destino.porExtenso)
                }
                Spacer(minLength: 0)
                // Cancelar antes de abrir, e é ele o padrão: Esc fecha a
                // pergunta sem sair do app.
                ChromeButton(
                    L10n.tr("Cancelar"), appearance: .outlined, size: 12,
                    height: 30, horizontalPadding: 10
                ) { onCancel() }
                ChromeButton(
                    rotuloDeAbertura, appearance: .accent, size: 12,
                    height: 30, horizontalPadding: 10
                ) { onOpen() }
            }
            .padding(.top, 4)
        }
        .padding(18)
        .frame(maxWidth: 360, alignment: .leading)
        .background(theme.surface.color)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusLarge))
        .overlay {
            RoundedRectangle(cornerRadius: theme.radiusLarge)
                .strokeBorder(theme.line.color, lineWidth: Hairline.thickness(displayScale))
        }
        .shadow(theme.shadow)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("Abrir link em \(destino.anfitriao)"))
        .accessibilityHint(destino.porExtenso)
    }

    /// O endereço em três pedaços: o que vem antes apagado, o anfitrião aceso,
    /// o caminho apagado. Um `Text` só, para a quebra ser do endereço inteiro.
    private var porExtenso: Text {
        let corpo = theme.mono.font(size: 11.5)
        var texto = Text(destino.prefixo).font(corpo).foregroundColor(theme.ink4.color)
        if !destino.anfitriao.isEmpty {
            texto = texto + Text(destino.anfitriao)
                .font(theme.mono.font(size: 11.5, weight: .semibold))
                .foregroundColor(theme.accentInk.color)
        }
        return texto + Text(destino.resto).font(corpo).foregroundColor(theme.ink4.color)
    }

    /// O aviso de disfarce. Não é enfeite: é a diferença entre ler
    /// `banco.com@malicioso.example` e entender o que ele faz.
    private func avisoLinha(_ aviso: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold))
                .accessibilityHidden(true)
            Text(aviso)
                .font(theme.sans.font(size: 11.5))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(theme.warning.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface2.color)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
    }
}

// MARK: - Pendurar a pergunta numa superfície

/// Quem desenha corpo de email pendura isto uma vez, e todo link de dentro
/// passa a perguntar.
private struct LinkConfirmationHost: ViewModifier {
    @Environment(\.theme) private var theme
    @State private var confirmation = LinkConfirmation()

    func body(content: Content) -> some View {
        content
            .environment(\.linkConfirmation, confirmation)
            .overlay {
                if let pedido = confirmation.pendente {
                    camada(pedido)
                }
            }
            // Esc cancela — cancelar é o padrão desta pergunta.
            .onExitCommand { confirmation.cancela() }
    }

    private func camada(_ pedido: LinkConfirmation.Pedido) -> some View {
        ZStack {
            theme.ink.color.opacity(theme.isDark ? 0.55 : 0.28)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { confirmation.cancela() }
            LinkConfirmCard(
                destino: pedido.destino,
                rotuloDeAbertura: LinkConfirmation.rotuloDoBotao(pedido.url),
                onOpen: { confirmation.abre() },
                onCancel: { confirmation.cancela() }
            )
            .padding(12)
        }
        .accessibilityAddTraits(.isModal)
    }
}

extension LinkConfirmation {
    /// O verbo do botão. Curto de propósito: o item de menu pode dizer
    /// "Escrever para este endereço…" porque a linha dele é larga; o botão do
    /// cartão divide 324pt com outros dois, e rótulo truncado num botão de
    /// confirmação é pior do que rótulo curto.
    static func rotuloDoBotao(_ url: URL) -> String {
        switch url.scheme?.lowercased() {
        case "mailto": L10n.tr("Escrever email")
        case "tel": L10n.tr("Ligar")
        default: L10n.tr("Abrir no navegador")
        }
    }
}

extension View {
    /// Pendura a pergunta de link nesta superfície.
    func linkConfirmation() -> some View {
        modifier(LinkConfirmationHost())
    }

    /// O menu de contexto de uma linha do corpo que tem link.
    ///
    /// Irmão de `uniContextMenu`, e não uma segunda máquina: mesmo
    /// `RightClickCatcher`, mesmo `ContextMenuPresenter`, mesmo painel. O que
    /// muda é só quem executa — aqui não há `MailStore` nem janela para abrir,
    /// e `abrirLink` **pergunta** em vez de abrir.
    func uniLinkMenu(trechos: [Trecho]) -> some View {
        modifier(LinkMenuModifier(entries: LinkDoCorpo.menu(trechos: trechos)))
    }
}

/// Ver `uniLinkMenu`.
private struct LinkMenuModifier: ViewModifier {
    @Environment(\.theme) private var theme
    @Environment(\.linkConfirmation) private var confirmation

    let entries: [ContextMenuEntry]

    func body(content: Content) -> some View {
        // Linha sem link não tem menu: um painel com só "Copiar" por cima de
        // uma prosa seria o menu do sistema de volta, com outra roupa.
        if entries.isEmpty {
            content
        } else {
            content.overlay {
                RightClickCatcher { point, window in
                    ContextMenuPresenter.shared.present(
                        entries, at: point, in: window, theme: theme
                    ) { command in
                        executa(command)
                    }
                }
            }
        }
    }

    private func executa(_ command: ContextCommand) {
        switch command {
        case .abrirLink(let url):
            // Nem o item de menu abre sozinho: ele levanta a mesma pergunta do
            // clique esquerdo.
            confirmation?.pede(url)
        case .copy(let texto):
            Clipboard.copy(texto)
        default:
            // O menu do link não monta outro comando. Um `MailStore` aqui só
            // existiria para atender o que não chega.
            break
        }
    }
}
