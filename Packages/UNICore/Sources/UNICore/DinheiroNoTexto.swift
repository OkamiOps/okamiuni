import Foundation

/// O valor em dinheiro que o **texto** afirma — e só ele.
///
/// A coluna "Dinheiro e prazos" do painel 11 escreve um número grande à
/// direita, e esse número não pode ser palpite: ou o email diz "R$ 4.200",
/// "USD 250" ou "6.000 créditos", ou a linha mostra só o prazo. Sem valor
/// reconhecível, **nada** aparece — um "—" no lugar seria a tela fingindo que
/// mediu algo.
public enum DinheiroNoTexto {

    /// Um valor lido do texto: como escrevê-lo, quanto é e em que moeda.
    public struct Valor: Sendable, Hashable {
        public let texto: String
        public let amount: Double
        public let currency: String

        public init(texto: String, amount: Double, currency: String) {
            self.texto = texto
            self.amount = amount
            self.currency = currency
        }
    }

    /// As moedas que o app reconhece, e como as escreve.
    private static let moedas: [(marca: String, símbolo: String)] = [
        ("R$", "R$"), ("US$", "USD"), ("USD", "USD"), ("EUR", "€"), ("€", "€"),
    ]

    /// O primeiro valor que aparecer nos textos dados, na ordem em que vieram.
    public static func primeiro(em textos: [String]) -> Valor? {
        for texto in textos {
            if let valor = primeiro(em: texto) { return valor }
        }
        return nil
    }

    public static func primeiro(em texto: String) -> Valor? {
        for (marca, símbolo) in moedas {
            guard let faixa = texto.range(of: marca) else { continue }
            let resto = texto[faixa.upperBound...]
            guard let número = número(no: String(resto.prefix(24))) else { continue }
            return Valor(
                texto: "\(símbolo) \(número.escrito)",
                amount: número.valor, currency: símbolo
            )
        }
        // "6.000 créditos" — moeda que não é dinheiro, mas que expira e por
        // isso conta como coisa em jogo.
        for palavra in ["créditos", "creditos", "credits"] {
            guard let faixa = texto.range(of: palavra, options: .caseInsensitive) else { continue }
            let antes = String(texto[..<faixa.lowerBound].suffix(24))
            guard let número = últimoNúmero(em: antes) else { continue }
            return Valor(
                texto: "\(número.escrito) créditos",
                amount: número.valor, currency: "créditos"
            )
        }
        return nil
    }

    /// O primeiro número do trecho, tal como escrito e já convertido.
    private static func número(no texto: String) -> (escrito: String, valor: Double)? {
        var escrito = ""
        var vendo = false
        for char in texto {
            if char.isNumber {
                escrito.append(char)
                vendo = true
            } else if vendo, char == "." || char == "," {
                escrito.append(char)
            } else if vendo {
                break
            } else if char == " " {
                continue
            } else {
                return nil
            }
        }
        return finaliza(escrito)
    }

    private static func últimoNúmero(em texto: String) -> (escrito: String, valor: Double)? {
        var escrito = ""
        for char in texto.reversed() {
            if char.isNumber || ((char == "." || char == ",") && !escrito.isEmpty) {
                escrito.append(char)
            } else if escrito.isEmpty {
                continue
            } else {
                break
            }
        }
        return finaliza(String(escrito.reversed()))
    }

    /// "4.200" → 4200; "250,50" → 250.5. Ponto é milhar em pt-BR, vírgula é
    /// decimal — e um número que termina em separador perde o rabo.
    private static func finaliza(_ bruto: String) -> (escrito: String, valor: Double)? {
        var escrito = bruto
        while let última = escrito.last, última == "." || última == "," {
            escrito.removeLast()
        }
        guard !escrito.isEmpty, escrito.contains(where: \.isNumber) else { return nil }
        let normalizado = escrito
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: ",", with: ".")
        guard let valor = Double(normalizado) else { return nil }
        return (escrito, valor)
    }
}
