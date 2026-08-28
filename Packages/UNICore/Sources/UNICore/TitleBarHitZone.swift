import CoreGraphics

/// Que parte da barra de título é **barra**, e que parte é controle.
///
/// ## Por que isto existe, e por que fora da `View`
///
/// Numa janela `.hiddenTitleBar` a barra nativa fica atrás do conteúdo do app,
/// então o duplo clique nunca chega nela e a janela ignora o ajuste do sistema.
/// A Task AL pendurou uma `NSView` de captura como **fundo** da barra; o ensaio
/// da Task AQ (`--ensaiar-barra`) mediu quem de fato responde ao ponto e a
/// resposta foi `AppKitWindowHostingView` — a hospedeira do SwiftUI. Uma
/// `NSView` de fundo nunca é consultada pelo teste de acerto do AppKit: quem
/// está na frente responde primeiro, e a hospedeira responde por si.
///
/// A captura tem de vir por cima. E vindo por cima ela passa a poder roubar o
/// clique dos controles da barra — botão da lateral, abas, busca, temas,
/// "Escrever". Daí esta decisão: **o duplo clique só é da janela onde não há
/// controle nenhum.** As molduras dos controles são medidas pelo próprio
/// SwiftUI e chegam aqui como dado.
///
/// Mora em `UNICore`, e não na `View`, porque é aritmética sobre retângulos: um
/// `NSView` não se instancia num teste sem janela, e a Task AL provou que testar
/// o `hitTest` da view não prova o caminho.
public enum TitleBarHitZone {

    /// O ponto (em coordenadas da barra, y para baixo, origem no canto superior
    /// esquerdo) pertence à área vazia da barra?
    ///
    /// - Fora da faixa de `barHeight` não é barra — o conteúdo abaixo dela é da
    ///   tela, não da janela.
    /// - Dentro de qualquer moldura de controle não é vazio: ali o clique é do
    ///   controle, e um duplo clique num botão tem de ser dois cliques no botão,
    ///   como em qualquer app nativo.
    public static func isEmptyArea(
        _ point: CGPoint, barHeight: CGFloat, controls: [CGRect]
    ) -> Bool {
        guard point.y >= 0, point.y <= barHeight else { return false }
        return !controls.contains { $0.contains(point) }
    }
}
