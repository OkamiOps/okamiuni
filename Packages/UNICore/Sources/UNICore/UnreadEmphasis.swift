import Foundation

/// **Como a linha diz que a mensagem não foi lida.**
///
/// ## Por que isto é um tipo, e não uma decisão tomada dentro da `View`
///
/// Duas rodadas foram decididas no escuro. Na primeira, a única marca era o
/// peso da fonte do remetente, e o dono do projeto levou tempo demais para
/// perceber. Na segunda entrou um ponto de 7pt numa goteira de 13 espremida
/// entre a barra da conta e o texto — e a resposta foi "ainda não está bom,
/// nao gostei". Nas duas vezes o desenho foi escolhido por quem escreve o
/// código e mostrado depois de pronto.
///
/// Agora as três alternativas existem ao mesmo tempo, como **dado**, e são
/// renderizadas lado a lado em PNG para a escolha ser feita olhando. Trocar de
/// variante é trocar `UnreadEmphasis.standard` — uma linha.
///
/// O tipo mora em `UNICore` pelo motivo de sempre nesta base: `View` é
/// `@MainActor` implícito no Swift 6 e um `static` lá dentro herda o
/// isolamento. É a mesma razão de `SwipeMetrics` e `SwipeTint` viverem aqui —
/// e, como `SwipeTint`, ele fala em **papel**, nunca em cor: quem desenha
/// traduz para `Theme`.
public enum UnreadEmphasis: String, Sendable, Hashable, CaseIterable, Codable {
    /// **A — o ponto do Mail, sem timidez.** Um ponto de `dotDiameter` em
    /// `accent`, numa coluna própria à esquerda do conteúdo. O layout da linha
    /// desloca: o texto começa depois da coluna, e a linha lida mostra a mesma
    /// coluna **vazia**, para as duas continuarem alinhadas.
    case dot

    /// **B — barra + fundo.** Sem ponto. A barra da conta engrossa de
    /// `quietBarWidth` para `loudBarWidth`, e a linha inteira ganha um fundo um
    /// degrau à frente do das lidas — é como o Gmail separa lidas de não-lidas,
    /// pelo campo e não por um sinal pontual.
    case field

    /// **C — ponto + fundo.** As duas somadas, a mais explícita das três. É a
    /// padrão porque o relato veio duas vezes, e das duas o pedido foi o mesmo:
    /// está difícil de ver.
    case both

    /// A variante que o app usa. **Trocar aqui troca o app inteiro** — é a
    /// "troca pequena de código" que o relatório promete caso, vendo os três
    /// PNGs, a escolha seja outra.
    public static let standard = UnreadEmphasis.both

    /// Marca com um ponto na coluna própria.
    public var showsDot: Bool { self != .field }

    /// Marca pelo campo: barra grossa e fundo próprio.
    public var showsField: Bool { self != .dot }

    /// A largura da barra da conta nesta variante, para uma linha não lida.
    /// A linha lida mantém sempre a fina.
    public var barWidth: CGFloat {
        showsField ? UnreadMetrics.loudBarWidth : UnreadMetrics.quietBarWidth
    }

    /// Quanto a coluna do ponto rouba da largura do conteúdo. Zero na variante
    /// que não tem ponto.
    public var columnWidth: CGFloat {
        showsDot ? UnreadMetrics.dotColumnWidth : 0
    }

    /// O nome curto que o PNG de comparação carrega.
    public var fileTag: String {
        switch self {
        case .dot: "A"
        case .field: "B"
        case .both: "C"
        }
    }
}

/// As medidas das três variantes, juntas porque os testes de pixel precisam
/// citá-las — fronteira só vale cravada.
public enum UnreadMetrics {
    /// O ponto. Era 7 e ficou tímido; 9 é o teto da faixa que o brief pede
    /// (8–9) e o que cabe com folga na coluna de 20 depois da barra de 6.
    public static let dotDiameter: CGFloat = 9

    /// A coluna própria do ponto, à esquerda do conteúdo. Antes ele morava
    /// numa goteira de 13pt já ocupada pela barra da conta e pelo recuo do
    /// texto; agora a coluna é dele.
    public static let dotColumnWidth: CGFloat = 20

    /// O centro do ponto na coluna: 13, deixando 2,5pt entre a barra grossa
    /// (0–6) e a borda do ponto (8,5–17,5), e outros 2,5 até o conteúdo.
    public static let dotCenterX: CGFloat = 13

    /// O centro na vertical, alinhado com a linha do remetente: `rowPadding.top`
    /// (11) mais meia altura de linha de 13pt. Ele marca a mensagem, e o nome
    /// de quem escreveu é onde o olho entra na linha.
    public static let dotCenterY: CGFloat = 19

    /// A barra da conta como ela sempre foi — e como a linha **lida** continua
    /// a desenhando.
    public static let quietBarWidth: CGFloat = 3

    /// A barra engrossada da linha não lida nas variantes que usam o campo.
    public static let loudBarWidth: CGFloat = 6

    /// O recuo do conteúdo quando a coluna do ponto existe. Somado aos 20 da
    /// coluna, o texto começa em 24 — contra os 16 de `rowPadding.leading` nas
    /// variantes sem coluna.
    public static let contentInsetWithColumn: CGFloat = 4
}
