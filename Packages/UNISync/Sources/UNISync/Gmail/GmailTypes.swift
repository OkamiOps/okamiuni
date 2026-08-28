import Foundation
import UNICore

public struct GmailProfile: Sendable, Hashable {
    public let emailAddress: String
    /// O ponto de partida do sync incremental do Marco 3. Guardado já aqui,
    /// na carga inicial: capturá-lo depois abriria uma janela em que as
    /// mensagens chegadas no meio nunca apareceriam.
    public let historyID: String
}

public struct GmailLabel: Sendable, Hashable {
    public let id: String
    public let name: String
}

public struct GmailPage: Sendable, Hashable {
    public let ids: [String]
    public let nextPageToken: String?
}

public enum GmailFormat: String, Sendable {
    /// Cabeçalhos e nada de corpo — o que a lista precisa.
    case metadata
    /// A mensagem inteira.
    case full
}

public struct GmailMessage: Sendable, Hashable {
    public let id: String
    public let labelIDs: [String]
    public let internalDate: Date
    public let from: Contact
    public let to: [Contact]
    public let cc: [Contact]
    public let subject: String
    public let snippet: String
    /// Vazio em formato `metadata` — ausência legítima, não erro.
    public let body: [String]
}

/// Cabeçalhos de endereço, do jeito que eles chegam de verdade.
public enum MailAddress {
    /// `"Duarte, Marina" <marina@x.com>` → nome e endereço separados.
    ///
    /// Sem nome, o **endereço** vira o nome: uma linha da lista com o campo de
    /// remetente em branco é pior do que uma com o endereço cru.
    public static func parse(_ header: String) -> Contact? {
        let limpo = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !limpo.isEmpty else { return nil }

        if let abre = limpo.lastIndex(of: "<"), let fecha = limpo.lastIndex(of: ">"), abre < fecha {
            let endereco = String(limpo[limpo.index(after: abre)..<fecha])
                .trimmingCharacters(in: .whitespaces)
            var nome = String(limpo[limpo.startIndex..<abre])
                .trimmingCharacters(in: .whitespaces)
            if nome.hasPrefix("\""), nome.hasSuffix("\""), nome.count >= 2 {
                nome = String(nome.dropFirst().dropLast())
            }
            nome = decodeRFC2047(nome)
            guard !endereco.isEmpty else { return nil }
            return Contact(name: nome.isEmpty ? endereco : nome, address: endereco)
        }
        return Contact(name: limpo, address: limpo)
    }

    /// A lista de `To`/`Cc`, cortada por vírgula **fora das aspas**.
    ///
    /// Cortar por vírgula sem olhar as aspas parte `"Duarte, Marina"` em dois
    /// destinatários, e o "Responder a todos" passa a mandar email para
    /// alguém chamado "Duarte".
    public static func parseList(_ header: String) -> [Contact] {
        var partes: [String] = []
        var atual = ""
        var dentroDeAspas = false
        for caractere in header {
            switch caractere {
            case "\"": dentroDeAspas.toggle(); atual.append(caractere)
            case "," where !dentroDeAspas: partes.append(atual); atual = ""
            default: atual.append(caractere)
            }
        }
        partes.append(atual)
        return partes.compactMap(parse)
    }

    /// `=?UTF-8?B?…?=` e `=?UTF-8?Q?…?=` (RFC 2047).
    ///
    /// O Foundation não traz isto pronto, e sem ele todo assunto acentuado
    /// aparece como uma linha de gibberish na lista — que é a primeira coisa
    /// que se vê ao conectar uma conta em português.
    static func decodeRFC2047(_ text: String) -> String {
        guard text.contains("=?") else { return text }
        var resultado = ""
        var resto = Substring(text)
        while let inicio = resto.range(of: "=?"), let fim = resto.range(of: "?=", range: inicio.upperBound..<resto.endIndex) {
            resultado += resto[resto.startIndex..<inicio.lowerBound]
            let miolo = resto[inicio.upperBound..<fim.lowerBound]
            let campos = miolo.split(separator: "?", maxSplits: 2, omittingEmptySubsequences: false)
            if campos.count == 3 {
                let charset = String(campos[0]).uppercased()
                let codificacao = String(campos[1]).uppercased()
                let carga = String(campos[2])
                let encoding: String.Encoding = charset.hasPrefix("ISO-8859") ? .isoLatin1 : .utf8
                if codificacao == "B", let dados = Data(base64Encoded: carga),
                   let texto = String(data: dados, encoding: encoding) {
                    resultado += texto
                } else if codificacao == "Q" {
                    resultado += decodeQuotedPrintable(carga, encoding: encoding)
                } else {
                    resultado += miolo
                }
            } else {
                resultado += miolo
            }
            resto = resto[fim.upperBound...]
        }
        resultado += resto
        return resultado
    }

    private static func decodeQuotedPrintable(_ text: String, encoding: String.Encoding) -> String {
        var bytes: [UInt8] = []
        var indice = text.startIndex
        while indice < text.endIndex {
            let caractere = text[indice]
            if caractere == "=", let fim = text.index(indice, offsetBy: 3, limitedBy: text.endIndex),
               let byte = UInt8(text[text.index(after: indice)..<fim], radix: 16) {
                bytes.append(byte)
                indice = fim
            } else if caractere == "_" {
                bytes.append(0x20)
                indice = text.index(after: indice)
            } else {
                bytes.append(contentsOf: Array(String(caractere).utf8))
                indice = text.index(after: indice)
            }
        }
        return String(data: Data(bytes), encoding: encoding) ?? text
    }
}
