import SwiftUI
import UNIDesign

/// O bloco de HTML dentro do leitor: a faixa das imagens bloqueadas em cima, a
/// `WebView` embaixo.
///
/// Uma `View` própria, e não mais uma função dentro do `ReaderPane`, por causa
/// do `@State`: a permissão de carregar imagens remotas é **por mensagem**, e
/// morar aqui é o que permite ao leitor a jogar fora com um `.id(message.id)`.
/// Guardada no `ReaderPane`, ela sobreviveria à troca de mensagem — e o
/// "Carregar" que a pessoa deu numa valeria para a seguinte, que é a permissão
/// global que esta tela não tem.
struct ReaderHTMLSection: View {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    let html: String
    /// O endereço de quem mandou. É o que a faixa escreve no botão do "sempre"
    /// e o que fica gravado — ver `UNICore.SenderTrust` para por que o
    /// endereço inteiro, e não o domínio.
    var remetente: String = ""
    /// Este remetente já foi confiado? Vem de fora (do `MailStore`) porque a
    /// resposta sobrevive ao fechar o app, e esta `View` não.
    var confiavel: Bool = false
    var aoConfiar: () -> Void = {}
    var aoRevogar: () -> Void = {}

    @State private var carregaRemotas = false
    @State private var altura: CGFloat = 1

    /// As imagens desta mensagem carregam?
    ///
    /// Duas portas para o mesmo lugar: o "Carregar" desta abertura (que não
    /// fica guardado em lugar nenhum) e a confiança no remetente (que fica).
    private var permiteRemotas: Bool { carregaRemotas || confiavel }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if ReaderHTMLPolicy.pedeRecursoRemoto(html) {
                if confiavel {
                    faixaConfiavel
                        .padding(.horizontal, 28)
                        .padding(.bottom, 12)
                } else if !carregaRemotas {
                    faixa
                        .padding(.horizontal, 28)
                        .padding(.bottom, 12)
                }
            }

            ReaderHTMLBody(
                html: html,
                permiteRemotas: permiteRemotas,
                fundo: Self.css(theme.surface),
                tinta: Self.css(theme.ink),
                link: Self.css(theme.accent),
                fonte: Self.familia(theme),
                altura: $altura
            )
            .frame(height: max(1, altura))
            .padding(.horizontal, 28)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A frase, e o que ela oferece.
    ///
    /// **Discreta de propósito.** Ela não é um alerta: o padrão está certo, e
    /// nada deu errado. É uma linha dizendo o que faltou e um botão para quem
    /// quiser o resto — a mesma gramática do "Tentar de novo" do corpo que
    /// falhou.
    nonisolated static let imagensBloqueadas = "Imagens remotas bloqueadas"
    nonisolated static let carregar = "Carregar"
    nonisolated static let imagensCarregadas = "Imagens carregadas · remetente confiável"
    nonisolated static let rever = "Rever"

    /// "Sempre carregar de noreply@calendly.com" — o endereço **inteiro**,
    /// escrito no botão.
    ///
    /// O rótulo é a promessa, e ele diz exatamente o que vai ser gravado: o
    /// endereço, não o domínio. Um botão que dissesse "Sempre carregar do
    /// Calendly" e liberasse `calendly.com` estaria concedendo mais do que
    /// mostrou — ver `UNICore.SenderTrust`.
    ///
    /// Sem endereço (uma mensagem cujo `From` não trouxe nenhum) o botão não
    /// aparece: não há o que confiar, e um "sempre" sobre o vazio valeria para
    /// todo remetente sem endereço que chegasse depois.
    nonisolated static func sempreCarregar(de remetente: String) -> String? {
        let podado = remetente.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !podado.isEmpty else { return nil }
        return "Sempre carregar de \(podado)"
    }

    private var faixa: some View {
        HStack(spacing: 8) {
            Text(Self.imagensBloqueadas)
                .font(theme.sans.font(size: 11.5))
                .foregroundStyle(theme.ink3.color)
            Text("·")
                .font(theme.sans.font(size: 11.5))
                .foregroundStyle(theme.ink4.color)
            ChromeButton(
                Self.carregar, appearance: .outlined,
                size: 11.5, height: 24, horizontalPadding: 10
            ) {
                carregaRemotas = true
            }
            .help(
                "Carrega as imagens que esta mensagem busca na internet. "
                + "Vale só para ela — carregar avisa o remetente de que você a abriu."
            )
            // A segunda ação, no mesmo idioma da primeira e ao lado dela: o
            // "uma vez" e o "sempre" são a mesma decisão em duas durações.
            if let sempre = Self.sempreCarregar(de: remetente) {
                ChromeButton(
                    sempre, appearance: .outlined,
                    size: 11.5, height: 24, horizontalPadding: 10
                ) {
                    aoConfiar()
                }
                .help(
                    "Passa a carregar as imagens deste endereço sozinho, em toda "
                    + "mensagem dele. Vale só para este endereço, e pode ser desfeito."
                )
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A linha mínima da mensagem de um remetente confiável.
    ///
    /// Ela existe por uma razão só: **a saída**. Sem ela, a confiança dada num
    /// clique não teria onde ser desfeita, e uma decisão de mão única sobre
    /// privacidade é um beco. Diz o que aconteceu (as imagens carregaram, e
    /// por quê) e traz o "Rever" que revoga.
    private var faixaConfiavel: some View {
        HStack(spacing: 8) {
            Text(Self.imagensCarregadas)
                .font(theme.sans.font(size: 11.5))
                .foregroundStyle(theme.ink4.color)
            ChromeButton(
                Self.rever, appearance: .outlined,
                size: 11.5, height: 24, horizontalPadding: 10
            ) {
                aoRevogar()
            }
            .help(
                "Deixa de confiar neste endereço: as imagens dele voltam a ser "
                + "bloqueadas, aqui e nas próximas mensagens."
            )
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// O token do tema virando cor de CSS.
    ///
    /// `rgba()` e não hexadecimal: os tokens têm opacidade, e um token
    /// semitransparente escrito como `#RRGGBB` perderia justamente a
    /// transparência que o desenho pediu.
    nonisolated static func css(_ token: TokenColor) -> String {
        let canal = { (valor: Double) in Int((max(0, min(1, valor)) * 255).rounded()) }
        return "rgba(\(canal(token.red)), \(canal(token.green)), \(canal(token.blue)), \(token.opacity))"
    }

    /// A família de fontes que o documento pede — a do leitor primeiro, e as
    /// de sistema atrás dela: a `WebView` desenha com o que o sistema tem, e
    /// uma família sem alternativa cairia no Times de 1994.
    nonisolated static func familia(_ theme: Theme) -> String {
        // `name` é nulo quando o design pediu a face do sistema — e um
        // `"", ui-serif` é CSS quebrado, não uma família a menos.
        guard let nome = theme.serif.name else { return "ui-serif, Georgia, serif" }
        return "\"\(nome)\", ui-serif, Georgia, serif"
    }
}
