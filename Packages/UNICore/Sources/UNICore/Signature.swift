import Foundation

/// A assinatura da conta entrando no fim do corpo.
///
/// ## Divergência do protótipo, pedida pelo dono do projeto
///
/// **O protótipo não tem este botão.** A única coisa que ele diz sobre
/// assinatura é a legenda da linha "De" da tela 06 (linha 389 do `.dc.html`):
/// *"a assinatura muda com a conta"*. O botão é invenção nossa, a pedido — o
/// dono relatou "falta um botao para adicionar a assinatura" — e está
/// registrado como divergência no relatório da tarefa, como já foi feito com o
/// botão da agenda na barra.
///
/// O que **não** é invenção é a assinatura ser por conta: é exatamente o que
/// aquela legenda promete, e por isso o texto mora em `Account`, não numa
/// preferência global.
///
/// ## Por que isto é puro e mora aqui
///
/// `View` é `@MainActor` implícito no Swift 6, e regra de negócio pendurada num
/// `static` dentro dela trapa em teste nonisolated. Estas três decisões — pode
/// inserir? onde? com que estilo? — são regra, e o teste as chama direto.
public enum Signature {

    /// A linha em branco entre o corpo e a assinatura.
    ///
    /// Duas quebras, não uma: uma só encostaria a assinatura na última linha do
    /// texto como se fosse continuação dele.
    public static let separator = "\n\n"

    /// Se ainda faz sentido inserir.
    ///
    /// Duas recusas, e as duas viram `help` num botão desabilitado em vez de
    /// clique sem efeito — controle mudo é defeito:
    ///
    /// 1. **Conta sem assinatura.** Inserir texto vazio deixaria duas linhas em
    ///    branco no fim do rascunho e nada mais.
    /// 2. **Assinatura já inserida.** Clicar duas vezes é fácil, e um segundo
    ///    bloco idêntico no fim do email é constrangimento, não formatação.
    ///    A comparação é sobre o fim do corpo, ignorando espaço em branco.
    public static func canInsert(_ signature: String, into body: String) -> Bool {
        let text = trimmed(signature)
        guard !text.isEmpty else { return false }
        return !trimmed(body).hasSuffix(text)
    }

    /// Insere a assinatura no fim, com o estilo pedido.
    ///
    /// Não faz nada quando `canInsert` diria não — a `View` desabilita o botão,
    /// mas a regra não pode depender de a `View` ter lembrado.
    ///
    /// O espaço em branco do fim do corpo sai antes: quem apertou Enter duas
    /// vezes antes de clicar não quer quatro linhas em branco no meio, e o que
    /// se apaga é invisível de qualquer jeito. **Num corpo vazio não há
    /// separador nenhum** — a assinatura começa na primeira linha, em vez de
    /// empurrar o email para baixo de duas linhas vazias.
    ///
    /// O trecho novo nasce com `BodyStyleAttribute`: sem ele a barra leria a
    /// assinatura como "sem estilo" e o menu de fonte ficaria em branco quando
    /// o cursor passasse por ali.
    public static func insert(
        _ signature: String, into body: inout AttributedString, style: BodyStyle = .default
    ) {
        let text = trimmed(signature)
        guard canInsert(signature, into: String(body.characters)) else { return }
        trimTrailingWhitespace(&body)
        var tail = AttributedString(body.characters.isEmpty ? text : separator + text)
        tail[BodyStyleAttribute.self] = style
        body.append(tail)
    }

    /// O estilo com que a assinatura entra: o do fim do corpo.
    ///
    /// Assinar um email escrito em 20pt e ver a assinatura sair em 15 é a
    /// mesma classe de surpresa que a barra que não lia a seleção. Corpo vazio
    /// cai no padrão.
    ///
    /// O que **não** se herda é realce: um trecho final marcado de amarelo é
    /// destaque daquele trecho, não uma decisão sobre a assinatura.
    public static func style(endingIn body: AttributedString) -> BodyStyle {
        guard let last = body.runs.last else { return .default }
        var style = RichBody.style(of: last.attributes)
        style.highlightHex = BodyStyle.noHighlight
        return style
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Corta o espaço em branco do fim, caractere a caractere.
    ///
    /// Reconstruir a partir da `String` perderia todos os atributos do corpo —
    /// é o rascunho inteiro que passaria a texto cru. Por isso o corte é por
    /// índice, que preserva os runs do que sobra.
    private static func trimTrailingWhitespace(_ body: inout AttributedString) {
        var end = body.endIndex
        while end > body.startIndex {
            let previous = body.characters.index(before: end)
            guard body.characters[previous].isWhitespace else { break }
            end = previous
        }
        guard end < body.endIndex else { return }
        body.removeSubrange(end..<body.endIndex)
    }
}
