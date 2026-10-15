import Foundation
import SwiftUI

/// A citação de uma mensagem **sem HTML**, escrita de modo a caber.
///
/// O e-mail só-texto moderno vem com link de rastreio: duzentos caracteres de
/// `utm_`, `?t=`, hash e id de campanha, escritos por extenso no meio do
/// parágrafo. No leitor eles ficam escondidos atrás do texto do link; aqui,
/// onde não há HTML para esconder nada, eles tomavam quatro linhas cada e
/// empurravam a frase que importa para fora da vista.
///
/// Esta peça troca o endereço inteiro pelo **domínio**, e o domínio continua
/// sendo o link. O destino real não se perde: ele vai para o `toolTip`, como
/// no corpo legível do leitor — o rótulo curto nunca esconde para onde se vai.
///
/// É tipo puro, sem `View` nenhuma: `ComposerQuotedTextTests` o afirma sem
/// montar janela.
enum ComposerQuotedText {

    /// `example.com/muito/longo?utm=…` → "example.com", ligado ao endereço
    /// inteiro. O `www.` sai: ele não distingue nada e come quatro caracteres
    /// de uma linha já apertada.
    static func rotulo(de url: URL) -> String {
        guard var host = url.host(percentEncoded: false), !host.isEmpty else {
            return url.absoluteString
        }
        if host.lowercased().hasPrefix("www.") { host = String(host.dropFirst(4)) }
        return host
    }

    /// Os pedaços de uma linha: texto comum e endereços, na ordem em que
    /// aparecem.
    ///
    /// `NSDataDetector` e não uma expressão regular nossa: ele é o mesmo
    /// detector que o resto do sistema usa, e um endereço no fim de uma frase
    /// ("veja em example.com.") já vem sem o ponto final.
    static func pedacos(_ linha: String) -> [(texto: String, destino: URL?)] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return [(linha, nil)] }
        let inteiro = NSRange(linha.startIndex..<linha.endIndex, in: linha)
        var saida: [(texto: String, destino: URL?)] = []
        var cursor = linha.startIndex
        for achado in detector.matches(in: linha, range: inteiro) {
            guard let faixa = Range(achado.range, in: linha), let url = achado.url else { continue }
            // Só `http`/`https` viram rótulo curto: um `mailto:` já **é** o
            // endereço que a pessoa precisa ler por inteiro.
            guard let esquema = url.scheme?.lowercased(), esquema == "http" || esquema == "https"
            else { continue }
            if cursor < faixa.lowerBound {
                saida.append((String(linha[cursor..<faixa.lowerBound]), nil))
            }
            saida.append((rotulo(de: url), url))
            cursor = faixa.upperBound
        }
        if cursor < linha.endIndex { saida.append((String(linha[cursor...]), nil)) }
        return saida.isEmpty ? [(linha, nil)] : saida
    }

    /// A linha pronta para um `Text`: um `AttributedString` só, para a quebra
    /// de linha ser do parágrafo inteiro e não de cada pedaço.
    static func atribuido(_ linha: String, link: Color, tinta: Color) -> AttributedString {
        var saida = AttributedString()
        for pedaco in pedacos(linha) {
            var trecho = AttributedString(pedaco.texto)
            if let destino = pedaco.destino {
                trecho.link = destino
                trecho.underlineStyle = .single
                trecho.foregroundColor = link
                trecho.toolTip = destino.absoluteString
            } else {
                trecho.foregroundColor = tinta
            }
            saida.append(trecho)
        }
        return saida
    }
}
