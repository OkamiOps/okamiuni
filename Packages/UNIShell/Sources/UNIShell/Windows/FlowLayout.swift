import SwiftUI

/// `flex-wrap: wrap` — o que os campos Para/Cc/Cco fazem com as etiquetas de
/// destinatário quando elas não cabem numa linha só.
///
/// Protótipo: `display: flex; flex-wrap: wrap; align-items: center; gap: 5px`.
/// O `HStack` do SwiftUI não quebra linha, e as etiquetas têm largura de texto:
/// sem isto, o quarto destinatário empurra o campo de digitação para fora.
struct FlowLayout: Layout {
    var spacing: CGFloat = 5
    var rowSpacing: CGFloat = 5
    var alignment: VerticalAlignment = .center
    /// O último item recebe a largura que sobra na fila dele — o `flex: 1` que
    /// o protótipo põe no campo de digitação. Sem isto o campo mede só o texto
    /// do placeholder, e clicar à direita dele não foca coisa nenhuma.
    var stretchesLast = false

    struct Rows {
        var rows: [[Int]] = []
        var size: CGSize = .zero
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        var size = arrange(width: proposal.width ?? .infinity, subviews: subviews).size
        // Com `stretchesLast`, o container ocupa a largura oferecida — é o que
        // `flex: 1` no último item significa. Devolver só a soma dos itens
        // encolhia a área de toque: o campo de digitação ficava com a largura
        // do texto do placeholder e clicar à direita dele não focava nada.
        if stretchesLast, let width = proposal.width, width.isFinite {
            size.width = max(size.width, width)
        }
        return size
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void
    ) {
        let plan = arrange(width: bounds.width, subviews: subviews)
        let last = subviews.indices.last
        var y = bounds.minY
        for row in plan.rows {
            let heights = row.map { subviews[$0].sizeThatFits(.unspecified).height }
            let rowHeight = heights.max() ?? 0
            var x = bounds.minX
            for index in row {
                var size = subviews[index].sizeThatFits(.unspecified)
                if stretchesLast, index == last {
                    size.width = max(size.width, bounds.maxX - x)
                }
                let dy: CGFloat = alignment == .center ? (rowHeight - size.height) / 2 : 0
                subviews[index].place(
                    at: CGPoint(x: x, y: y + dy),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += rowHeight + rowSpacing
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> Rows {
        var plan = Rows()
        var row: [Int] = []
        var x: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var widest: CGFloat = 0

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.isEmpty ? size.width : x + spacing + size.width
            if !row.isEmpty && needed > width {
                plan.rows.append(row)
                widest = max(widest, x)
                totalHeight += rowHeight + rowSpacing
                row = []
                x = 0
                rowHeight = 0
            }
            x = row.isEmpty ? size.width : x + spacing + size.width
            rowHeight = max(rowHeight, size.height)
            row.append(index)
        }
        if !row.isEmpty {
            plan.rows.append(row)
            widest = max(widest, x)
            totalHeight += rowHeight
        }
        plan.size = CGSize(width: min(widest, width), height: totalHeight)
        return plan
    }
}
