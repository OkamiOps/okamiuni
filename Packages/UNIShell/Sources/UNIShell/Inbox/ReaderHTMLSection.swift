import SwiftUI
import UNIDesign
import UNICore

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
    /// O texto plano da mesma mensagem, já refluído — o que o leitor mostra
    /// **enquanto** o HTML não pintou.
    ///
    /// **É a metade honesta do conserto da M3-22.** O corpo texto já está no
    /// banco quando a mensagem abre; segurá-lo escondido atrás de uma coluna
    /// vazia enquanto onze imagens remotas descem por trinta segundos é
    /// esconder o que se tem. A pessoa começa a ler na hora, e o desenho do
    /// remetente entra por cima quando ficar pronto.
    var paragrafos: [String] = []
    /// O endereço de quem mandou. É o que a faixa escreve no botão do "sempre"
    /// e o que fica gravado — ver `UNICore.SenderTrust` para por que o
    /// endereço inteiro, e não o domínio.
    var remetente: String = ""
    /// Este remetente já foi confiado? Vem de fora (do `MailStore`) porque a
    /// resposta sobrevive ao fechar o app, e esta `View` não.
    var confiavel: Bool = false
    var aoConfiar: () -> Void = {}
    var aoRevogar: () -> Void = {}
    /// Clique em Sim/Não/Talvez no HTML do convite.
    var aoRSVP: (InviteRSVPResponse) -> Void = { _ in }

    /// O estado de "já pintou" forçado, para o retrato conseguir medir os dois
    /// lados da espera. Mesmo idioma do `debugSections` da janela 04: a `View`
    /// desenha o que desenharia, e o teste escolhe o instante — em vez de um
    /// interruptor que só existe no teste e muda o caminho do código.
    var debugPintou: Bool?

    @State private var carregaRemotas = false
    @State private var altura: CGFloat = 1
    /// A mensagem já está desenhada na `WebView`?
    @State private var pintou = false
    /// `nil` segue o HTML. A pessoa pode forçar papel ou o tema nesta abertura.
    @State private var paletaForcada: ReaderHTMLPolicy.Paleta?

    private var jaPintou: Bool { debugPintou ?? pintou }

    /// A frase da espera, no idioma do "Carregando corpo…" da M3-3 — mesma
    /// `ReaderNote`, mesma tipografia, momento diferente: lá o corpo está
    /// vindo do servidor, aqui ele já chegou e está sendo desenhado.
    nonisolated static var carregando: String { L10n.tr("Carregando a mensagem…") }

    /// Quanto a espera dura, contada **do começo da carga**.
    ///
    /// Imagem remota de rastreio (HubSpot e similares) nunca dispara
    /// `didFinish`. Sem teto na abertura, "Carregando a mensagem…" girava
    /// para sempre, com o texto já na tela.
    nonisolated static let tetoDaEspera: Duration = .seconds(5)

    /// As imagens desta mensagem carregam?
    ///
    /// Duas portas para o mesmo lugar: o "Carregar" desta abertura (que não
    /// fica guardado em lugar nenhum) e a confiança no remetente (que fica).
    private var permiteRemotas: Bool { carregaRemotas || confiavel }

    private var paletaEfetiva: ReaderHTMLPolicy.Paleta {
        ReaderHTMLPolicy.paleta(para: html, forçada: paletaForcada)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // **A faixa quieta, nos 28 temas.** Duas pastilhas com moldura
            // logo acima do email gritavam mais que o email, e o dono as viu
            // antes do assunto; só os dois temas de vidro tinham sido
            // consertados. As quatro decisões continuam todas alcançáveis.
            faixaQuieta
                .padding(.horizontal, 28)
            .padding(.bottom, 12)

            // **O vazio que parecia defeito.** A `WebView` nasce com um ponto
            // de altura e só cresce quando a régua responde; até lá o leitor
            // mostrava uma coluna em branco, e o dono achou que o email tinha
            // aberto quebrado — ele carregou enquanto a reclamação era escrita.
            // A espera agora tem cara de espera.
            ZStack(alignment: .topLeading) {
                ReaderHTMLBody(
                    html: html,
                    permiteRemotas: permiteRemotas,
                    paleta: paletaForcada,
                    fundo: Self.css(theme.surface),
                    tinta: Self.css(paletaForcada == .doTema ? theme.ink : theme.ink2),
                    link: Self.css(theme.link),
                    fonte: Self.familia(theme),
                    altura: $altura,
                    pintou: $pintou,
                    aoRSVP: aoRSVP
                )
                .frame(height: max(1, altura))
                .padding(.horizontal, 28)
                // Escondida, e não ausente: tirá-la da hierarquia enquanto
                // espera seria destruí-la e recomeçar a carga a cada redesenho.
                .opacity(jaPintou ? 1 : 0)

                // A espera: a roda que gira, e o texto que a pessoa já pode
                // ler. As duas trazem os mesmos 28 de folga do corpo.
                if !jaPintou {
                    VStack(alignment: .leading, spacing: 18) {
                        ReaderSpinnerNote(Self.carregando)
                        if !paragrafos.isEmpty { ReaderPlainText(paragrafos: paragrafos) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A frase, e o que ela oferece.
    ///
    /// **Na altura dos vizinhos, desde a M3-18.** Os botões daqui mediam 24 de
    /// altura e 10 de folga lateral; tudo o mais que o leitor desenha — as
    /// pastilhas da fila de triagem, o "Colocar na agenda", o "Desfazer" da
    /// confirmação, o "Tentar de novo" do corpo que falhou — mede 26 e 12, que
    /// é o que o protótipo especifica para o controle desta tela. Dois pontos de
    /// diferença não se notam num botão; notam-se numa faixa que fica logo acima
    /// do corpo, com a barra de 26 logo acima dela.
    ///
    /// **Discreta de propósito.** Ela não é um alerta: o padrão está certo, e
    /// nada deu errado. É uma linha dizendo o que faltou e um botão para quem
    /// quiser o resto — a mesma gramática do "Tentar de novo" do corpo que
    /// falhou.
    nonisolated static var imagensBloqueadas: String { L10n.tr("Imagens remotas bloqueadas") }
    nonisolated static var carregar: String { L10n.tr("Carregar") }
    nonisolated static var imagensCarregadas: String { L10n.tr("Imagens carregadas · remetente confiável") }
    nonisolated static var rever: String { L10n.tr("Rever") }
    nonisolated static var comoEnviado: String { L10n.tr("Como enviado") }
    nonisolated static var comoOTema: String { L10n.tr("Como o tema") }

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
        return L10n.tr("Sempre carregar de \(podado)")
    }

    /// A mesma faixa, calada.
    ///
    /// Ela é **uma linha de 11pt em `ink4`**: duas
    /// pastilhas com moldura logo acima do email gritavam mais que o email, e
    /// o dono as viu antes do assunto. As quatro decisões continuam todas
    /// alcançáveis — carregar, confiar, rever, trocar a paleta —, agora como
    /// palavras ligadas em vez de controles desenhados.
    private var faixaQuieta: some View {
        HStack(spacing: 7) {
            if ReaderHTMLPolicy.pedeRecursoRemoto(html) {
                if confiavel {
                    nota(Self.imagensCarregadas)
                    elo(Self.rever, action: aoRevogar)
                } else if !carregaRemotas {
                    nota(Self.imagensBloqueadas)
                    elo(Self.carregar) { carregaRemotas = true }
                    if let sempre = Self.sempreCarregar(de: remetente) {
                        elo(sempre, action: aoConfiar)
                    }
                }
            }
            Spacer(minLength: 8)
            elo(
                paletaEfetiva == .papel ? Self.comoOTema : Self.comoEnviado,
                help: L10n.tr("Como enviado guarda as cores do remetente. Como o tema pinta com as cores do app.")
            ) {
                paletaForcada = paletaEfetiva == .papel ? .doTema : .papel
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func nota(_ texto: String) -> some View {
        Text(texto)
            .font(theme.sans.font(size: 11))
            .foregroundStyle(theme.ink4.color)
            .lineLimit(1)
    }

    /// Uma palavra que faz alguma coisa. Sem moldura, sem fundo: o acento é a
    /// única marca de que é clicável.
    private func elo(
        _ rotulo: String, help: String? = nil, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(rotulo)
                .font(theme.sans.font(size: 11, weight: .semibold))
                .foregroundStyle(theme.accentInk.color)
                .lineLimit(1)
                .fixedSize()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: 4)
        .help(help ?? rotulo)
        .accessibilityLabel(rotulo)
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
