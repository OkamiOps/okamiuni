import SwiftUI
import UNICore
import UNIDesign

/// O corpo do email numa janela que **rola e diz que rola**.
///
/// ## O defeito que ela conserta
///
/// Na proposta longa da caixa real, a última linha visível — "As a reminder,
/// this is the topic of our consultation:" — ficava cortada ao meio logo acima
/// de "Gerar resposta / Responder / Arquivar / Depois". A rolagem existia, mas
/// nada na tela dizia isso: sem barra (o macOS só a mostra durante o gesto),
/// sem esmaecimento, sem "continua". A aresta dura do recorte tem exatamente a
/// aparência do fim do email.
///
/// Para o dono desta caixa isso é o pior defeito possível: ele perde o fio de
/// leitura, e um texto que some sem avisar o faz decidir achando que leu tudo.
///
/// Três peças, e cada uma faz uma coisa:
///
/// 1. **Um respiro embaixo do texto.** O conteúdo termina com uma folga do
///    tamanho do véu, para a última linha nunca morrer colada na aresta.
/// 2. **Um véu de `paper`**, e não um corte. O texto entra no fundo da coluna
///    em vez de ser fatiado — a diferença entre "acabou" e "continua".
/// 3. **Um aviso escrito**, com seta: "MAIS ABAIXO". É a única peça que
///    responde à pergunta sem exigir o gesto.
///
/// As três somem juntas quando o email cabe inteiro: aviso que aparece sempre
/// vira moldura e para de ser lido.
///
/// A decisão de "tem mais abaixo?" é `RolagemDoCorpo`, em UNICore — aqui não
/// mora regra nenhuma, pelo contrato de `docs/decisoes-de-engenharia.md`.
struct CorpoRolavel: View {

    @Environment(\.theme) private var theme

    let corpo: CorpoLegivel
    var tamanho: CGFloat = DashboardMetrics.previewExcerptSize

    var body: some View {
        ScrollView {
            CorpoLegivelView(corpo: corpo, tamanho: tamanho)
                .frame(maxWidth: .infinity, alignment: .leading)
                // A medida da linha: uma calha à direita encurta a linha e
                // deixa a barra de rolagem passar sem sentar em cima da
                // palavra. Linha longa demais cansa, e cansaço é o assunto.
                .padding(.trailing, DashboardMetrics.previewBodyGutter)
                .padding(.bottom, DashboardMetrics.previewBodyFade)
        }
        .scrollBounceBehavior(.basedOnSize)
        .avisaQueRola(L10n.tr("O email continua abaixo. Role para ver o resto."))
    }
}

/// O véu e o aviso de `CorpoRolavel`, aplicáveis a **qualquer** `ScrollView`.
///
/// Nasceu no corpo do email e mudou de casa quando a lista de prioridades do
/// dashboard repetiu o mesmo defeito: a linha da Maria sumia na aresta dura do
/// recorte, com o rodapé "Tirei da lista" logo abaixo. Uma rolagem que não se
/// anuncia tem exatamente a aparência de "acabou", e quem lê decide achando
/// que leu tudo.
///
/// A decisão de "tem mais abaixo?" continua sendo `RolagemDoCorpo`, em
/// UNICore: aqui não mora regra nenhuma.
struct AvisoDeRolagem: ViewModifier {

    @Environment(\.theme) private var theme

    let rotulo: String
    @State private var maisAbaixo = false

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Bool.self) { geometria in
                RolagemDoCorpo.temMaisAbaixo(
                    conteudo: geometria.contentSize.height,
                    visivel: geometria.containerSize.height,
                    deslocamento: geometria.contentOffset.y
                )
            } action: { _, novo in
                maisAbaixo = novo
            }
            .overlay(alignment: .bottom) { rodape }
    }

    @ViewBuilder
    private var rodape: some View {
        if maisAbaixo {
            ZStack(alignment: .bottom) {
                LinearGradient(
                    colors: [theme.paper.color.opacity(0), theme.paper.color],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: DashboardMetrics.previewBodyFade)
                HStack(spacing: 5) {
                    // Versalete à mão: `capsLabel` pinta `ink3` por dentro e
                    // não deixa a cor de fora entrar.
                    Text(L10n.tr("mais abaixo"))
                        .font(theme.mono.font(size: DashboardMetrics.capsSize, weight: .semibold))
                        .tracking(theme.capsTracking(at: DashboardMetrics.capsSize))
                        .textCase(.uppercase)
                    Image(systemName: "arrow.down")
                        .font(.system(size: DashboardMetrics.capsSize, weight: .bold))
                }
                .foregroundStyle(theme.accentInk.color)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(theme.accentSoft.color)
                .clipShape(Capsule())
                .padding(.bottom, 2)
                // À direita, e não no meio: uma pílula centrada senta em cima
                // do começo da frase que ela está justamente pedindo para ler.
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel(rotulo)
        }
    }
}

extension View {
    /// Põe o véu e a pílula "MAIS ABAIXO" nesta rolagem.
    func avisaQueRola(_ rotulo: String) -> some View {
        modifier(AvisoDeRolagem(rotulo: rotulo))
    }
}
