import AppKit
import SwiftUI
import UNICore
import UNIDesign

/// O corpo do email **desenhado como estrutura**, e não despejado como texto.
///
/// ## O que ela conserta
///
/// O dono desta caixa tem TDAH e disse, sobre a prévia anterior: "está muito
/// mal formatado, eu odeio ficar lendo texto, eu perco, não consigo prestar
/// atenção". Isso não é preferência estética — é o requisito. Um bloco de
/// quarenta linhas em que a informação nova é a primeira delas não é um texto
/// mal diagramado; é uma tarefa de busca visual que custa caro a ele.
///
/// Então cada regra aqui é uma linha a menos para varrer:
///
/// - **O histórico citado começa fechado.** Vira um controle de uma linha com
///   a contagem — "Mostrar histórico · 39 linhas" —, e a contagem é o que
///   permite decidir sem abrir. Assinatura e rodapé de newsletter, idem.
/// - **A lista é uma lista**, com a calha do marcador alinhada.
/// - **`Chave: valor` é uma coluna**, com a chave em versalete à esquerda: o
///   olho desce pela coluna em vez de ler quatro frases.
/// - **O link é o domínio**, e não sessenta caracteres de URL no meio da frase.
///
/// ## Onde a lógica mora
///
/// Nenhuma. O fatiamento inteiro é `CorpoLegivel`, em UNICore, `nonisolated` e
/// testado sem janela. Esta `View` só desenha o que aquele decidiu — que é o
/// contrato de `docs/decisoes-de-engenharia.md` para lógica pura.
struct CorpoLegivelView: View {

    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL

    let corpo: CorpoLegivel
    /// O corpo da fonte. A prévia usa o dela; o leitor, se um dia reusar isto,
    /// usa o dele.
    var tamanho: CGFloat = DashboardMetrics.previewExcerptSize

    /// Quais dobras a pessoa abriu. Estado da tela, e por isso mora aqui: nada
    /// disso volta para o modelo.
    @State private var abertas: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: tamanho * 0.85) {
            ForEach(corpo.blocos) { bloco in
                desenho(de: bloco)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // **A mesma política de link do leitor.** `ReaderHTMLPolicy.decide` é
        // quem diz o que um clique pode fazer, e ela não é afrouxada aqui: o
        // que não for `http`/`https`/`mailto`/`tel` não abre nada, e o que for
        // sai para o navegador da pessoa — nunca navega dentro do app.
        .environment(\.openURL, OpenURLAction { url in
            switch ReaderHTMLPolicy.decide(url: url) {
            case let .abrirNoNavegador(destino):
                NSWorkspace.shared.open(destino)
                return .handled
            case .permitir, .rsvp, .recusar:
                return .discarded
            }
        })
    }

    // MARK: - Um bloco de cada vez

    @ViewBuilder
    private func desenho(de bloco: BlocoDeCorpo) -> some View {
        switch bloco {
        case let .paragrafo(paragrafo): self.paragrafo(paragrafo)
        case let .lista(lista): self.lista(lista)
        case let .campos(campos): self.campos(campos)
        case let .dobra(dobra): self.dobra(dobra)
        }
    }

    private func paragrafo(_ paragrafo: Paragrafo) -> some View {
        texto(paragrafo.trechos, nivel: paragrafo.nivel)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A calha do marcador é fixa, e é por isso que a lista **parece** lista:
    /// os números ficam alinhados entre si e o texto começa todo na mesma
    /// coluna, mesmo quando um item quebra em três linhas.
    private func lista(_ lista: Lista) -> some View {
        VStack(alignment: .leading, spacing: tamanho * 0.5) {
            ForEach(lista.itens) { item in
                HStack(alignment: .firstTextBaseline, spacing: tamanho * 0.55) {
                    Text(item.marcador)
                        .font(theme.mono.font(size: tamanho * 0.86))
                        .foregroundStyle(theme.ink4.color)
                        .monospacedDigit()
                        .frame(width: tamanho * 1.5, alignment: .trailing)
                    texto(item.trechos, nivel: 0)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// `Chave: valor` como coluna: a chave em versalete e o valor ao lado.
    ///
    /// A chave usa a mesma legenda de todo rótulo do app (`capsLabel`), e é o
    /// que faz o olho descer pela esquerda em vez de ler quatro frases inteiras
    /// para achar o e-mail de quem preencheu o formulário.
    private func campos(_ campos: Campos) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(campos.pares) { par in
                HStack(alignment: .firstTextBaseline, spacing: tamanho * 0.7) {
                    Text(par.chave)
                        .capsLabel(size: DashboardMetrics.capsSize)
                        // Larga o bastante para "RECEBIDO EM" caber numa linha:
                        // a chave que quebra em duas desalinha a coluna, que é
                        // a única coisa que esta forma tinha a oferecer.
                        .frame(width: tamanho * 6.4, alignment: .leading)
                        .lineLimit(2)
                    texto(par.valor, nivel: 0)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, tamanho * 0.3)
                .accessibilityElement(children: .combine)
                if par.id != campos.pares.last?.id {
                    Rectangle()
                        .fill(theme.line2.color)
                        .frame(height: Hairline.thickness(displayScale))
                        .accessibilityHidden(true)
                }
            }
        }
    }

    /// O controle de uma linha que devolve o que está dobrado.
    ///
    /// Fechado é o padrão, e é o ponto inteiro: as trinta e nove linhas de
    /// histórico da captura viram uma. Aberto, o texto aparece com a calha de
    /// citação à esquerda — para continuar sendo óbvio que aquilo é repetição.
    private func dobra(_ dobra: Dobra) -> some View {
        let aberta = abertas.contains(dobra.id)
        return VStack(alignment: .leading, spacing: tamanho * 0.6) {
            Button {
                if aberta { abertas.remove(dobra.id) } else { abertas.insert(dobra.id) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: aberta ? "chevron.down" : "chevron.right")
                        .font(.system(size: DashboardMetrics.capsSize, weight: .semibold))
                        .accessibilityHidden(true)
                    Text(aberta ? dobra.rotuloAberto : dobra.rotulo)
                        .capsLabel(size: DashboardMetrics.capsSize)
                }
                .foregroundStyle(theme.ink3.color)
                .padding(.vertical, tamanho * 0.35)
                .padding(.horizontal, tamanho * 0.6)
                .background(theme.surface2.color)
                .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
            }
            .buttonStyle(.plain)
            .focusRing(cornerRadius: theme.radiusSmall)
            .help(aberta ? "Oculta o \(dobra.genero.substantivoAcessivel)"
                  : "Mostra o \(dobra.genero.substantivoAcessivel), com \(dobra.linhas) linhas")

            if aberta {
                Text(dobra.texto)
                    .font(theme.mono.font(size: tamanho * 0.86))
                    .foregroundStyle(theme.ink3.color)
                    .lineSpacing(tamanho * 0.4)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, tamanho * 0.9)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(theme.line.color)
                            .frame(width: Hairline.thickness(displayScale) * 2)
                            .accessibilityHidden(true)
                    }
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Trechos

    @Environment(\.displayScale) private var displayScale

    /// Os trechos de uma linha viram **um** `Text`, para a quebra de linha ser
    /// do parágrafo inteiro e não de cada pedaço.
    ///
    /// O link entra como `AttributedString` com `.link`: quem clica passa pelo
    /// `OpenURLAction` lá em cima, que é a política do leitor. O endereço real
    /// vai para o tooltip do parágrafo — o rótulo curto nunca esconde o destino.
    private func texto(_ trechos: [Trecho], nivel: Int) -> some View {
        var atribuido = AttributedString()
        for trecho in trechos {
            var pedaco = AttributedString(trecho.texto)
            if let destino = trecho.destino {
                pedaco.link = destino
                pedaco.underlineStyle = .single
                pedaco.foregroundColor = theme.accentInk.color
                pedaco.toolTip = destino.absoluteString
            } else {
                pedaco.foregroundColor = (nivel > 0 ? theme.ink : theme.ink2).color
            }
            if trecho.forte {
                pedaco.font = fonte(nivel: nivel).weight(.semibold)
            } else if trecho.italico {
                pedaco.font = fonte(nivel: nivel).italic()
            }
            atribuido.append(pedaco)
        }
        let destinos = trechos.compactMap(\.destino).map(\.absoluteString)
        return Text(atribuido)
            .font(fonte(nivel: nivel))
            .foregroundStyle((nivel > 0 ? theme.ink : theme.ink2).color)
            .lineSpacing(tamanho * (nivel > 0 ? 0.3 : 0.55))
            // O azul de link do sistema não é token de tema nenhum. `tint` é
            // quem manda na cor de `.link` dentro de um `Text`.
            .tint(theme.accentInk.color)
            .textSelection(.enabled)
            .help(destinos.isEmpty ? "" : destinos.joined(separator: "\n"))
    }

    private func fonte(nivel: Int) -> Font {
        nivel > 0
            ? theme.sans.font(size: tamanho * (nivel <= 2 ? 1.15 : 1.05), weight: .semibold)
            : theme.serif.font(size: tamanho)
    }
}

extension Dobra.Genero {
    /// O mesmo substantivo do rótulo, para o `help` e o VoiceOver.
    var substantivoAcessivel: String {
        switch self {
        case .historico: "histórico da conversa"
        case .assinatura: "bloco de assinatura"
        case .rodape: "rodapé da newsletter"
        }
    }
}
