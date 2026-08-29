import Foundation

/// O protocolo SMTP como **texto puro** — comandos montados, respostas lidas,
/// erros traduzidos. Nenhum socket entra aqui.
///
/// É o par do `ImapWire`, e existe pelo mesmo motivo: a parte do protocolo que
/// dá para errar em silêncio (um ponto no começo da linha, um código 4xx lido
/// como permanente, uma senha montada fora de ordem no AUTH PLAIN) fica
/// separada da parte que precisa de rede, e por isso é provável sem servidor
/// nenhum.
public enum SmtpWire {
    /// Uma resposta do servidor: o código, o texto e as linhas que vieram
    /// antes numa resposta de várias linhas.
    public struct Reply: Sendable, Hashable {
        public let code: Int
        /// O texto da **última** linha, que é a que fecha a resposta.
        public let text: String
        /// Todas as linhas, sem o código. É onde ficam as capacidades do EHLO.
        public let lines: [String]

        public init(code: Int, text: String, lines: [String]) {
            self.code = code
            self.text = text
            self.lines = lines
        }
    }

    /// Uma linha de resposta está **fechando** a resposta?
    ///
    /// `250-STARTTLS` continua; `250 OK` termina. É o hífen na quarta coluna
    /// que decide, e ler isso errado é a diferença entre esperar para sempre
    /// (tratando a última como continuação) e mandar o próximo comando no meio
    /// do EHLO (tratando uma continuação como fim).
    public static func ehFinal(_ linha: String) -> Bool {
        let bytes = Array(linha.utf8)
        guard bytes.count >= 4 else { return bytes.count == 3 }
        return bytes[3] != UInt8(ascii: "-")
    }

    /// O código de três dígitos de uma linha, ou `nil` se ela não começa com
    /// um. Servidor que fala fora do protocolo não vira código zero em
    /// silêncio.
    public static func codigo(_ linha: String) -> Int? {
        let prefixo = String(linha.prefix(3))
        guard prefixo.count == 3, prefixo.allSatisfy(\.isNumber) else { return nil }
        return Int(prefixo)
    }

    /// O texto de uma linha, sem o código nem o separador.
    public static func texto(_ linha: String) -> String {
        String(linha.dropFirst(min(4, linha.count)))
    }

    // MARK: Comandos

    public static func ehlo(host: String) -> String { "EHLO \(host)" }
    public static func startTLS() -> String { "STARTTLS" }
    public static func mailFrom(_ endereco: String) -> String { "MAIL FROM:<\(endereco)>" }
    public static func rcptTo(_ endereco: String) -> String { "RCPT TO:<\(endereco)>" }
    public static func data() -> String { "DATA" }
    public static func quit() -> String { "QUIT" }

    /// `AUTH PLAIN`, com a credencial no formato do RFC 4616:
    /// `identidade NUL usuário NUL senha`, em base64. A identidade é vazia —
    /// é o caso de quem entra como si mesmo, que é o único caso que este app
    /// tem.
    public static func authPlain(user: String, password: String) -> String {
        var bytes = Data([0])
        bytes.append(Data(user.utf8))
        bytes.append(Data([0]))
        bytes.append(Data(password.utf8))
        return "AUTH PLAIN \(bytes.base64EncodedString())"
    }

    public static func authLogin() -> String { "AUTH LOGIN" }

    /// Cada metade do `AUTH LOGIN` vai em base64 sozinha, respondendo aos dois
    /// pedidos (`334 VXNlcm5hbWU6` e `334 UGFzc3dvcmQ6`) do servidor.
    public static func base64(_ texto: String) -> String {
        Data(texto.utf8).base64EncodedString()
    }

    /// O servidor anuncia a capacidade nas linhas do EHLO?
    ///
    /// Comparação por **palavra**, e não por "contém": `AUTH PLAIN LOGIN` tem
    /// `LOGIN` como mecanismo; `250-AUTHENTICATION` não anuncia `AUTH` nenhum.
    public static func anuncia(_ capacidade: String, em linhas: [String]) -> Bool {
        let alvo = capacidade.uppercased()
        return linhas.contains { linha in
            linha.uppercased().split(whereSeparator: { $0 == " " || $0 == "=" }).contains(alvo[...])
        }
    }

    /// Os mecanismos de autenticação anunciados, em maiúsculas.
    public static func mecanismos(em linhas: [String]) -> Set<String> {
        for linha in linhas {
            let palavras = linha.uppercased().split(separator: " ").map(String.init)
            guard palavras.first == "AUTH" else { continue }
            return Set(palavras.dropFirst())
        }
        return []
    }

    // MARK: O corpo do DATA

    /// O corpo pronto para o `DATA`: quebras normalizadas, ponto duplicado no
    /// começo de linha, e o `.` sozinho que fecha.
    ///
    /// **O ponto duplicado é a regra que ninguém vê falhar.** Uma linha que
    /// começa com `.` — uma citação com "...", uma lista numerada colada de
    /// outro lugar — encerraria o `DATA` no meio da mensagem, e o servidor
    /// leria o resto do corpo como se fossem comandos. O que chega ao
    /// destinatário é uma mensagem cortada; o que sobra na conexão é um
    /// `500 command not recognized` que ninguém relaciona com o texto.
    public static func dotStuffed(_ raw: String) -> String {
        let normalizado = OutgoingMime.normalizaQuebras(raw)
        let linhas = normalizado.components(separatedBy: "\r\n").map { linha in
            linha.hasPrefix(".") ? "." + linha : linha
        }
        return linhas.joined(separator: "\r\n") + "\r\n.\r\n"
    }

    // MARK: Erros

    /// A resposta vira o erro que pede a ação certa.
    ///
    /// A linha divisória é a mesma do resto do pacote — **o que retry cura e o
    /// que não cura** — e o SMTP a escreve no primeiro dígito:
    ///
    /// - `4yz` é falha **temporária** por definição do RFC 5321: caixa
    ///   ocupada, servidor sob carga, greylisting (que é o caso mais comum de
    ///   todos, e o único jeito de passar por ele é tentar de novo mais
    ///   tarde). Vira `.transitorio`, que o executor da fila recua e repete.
    /// - `535`, `530` e `534` são credencial recusada: `.autenticacao`, que
    ///   pede à pessoa uma senha de app nova.
    /// - O resto de `5yz` é recusa definitiva — endereço que não existe,
    ///   mensagem grande demais, relay negado. `.servidor`, que para a fila e
    ///   mostra a frase do servidor.
    public static func erro(_ resposta: Reply) -> SyncError {
        switch resposta.code {
        case 530, 534, 535: return .autenticacao
        case 421, 450, 451, 452, 454, 455: return .transitorio(mensagem(resposta))
        case 400..<500: return .transitorio(mensagem(resposta))
        default: return .recusado(mensagem(resposta))
        }
    }

    private static func mensagem(_ resposta: Reply) -> String {
        "o servidor de envio respondeu \(resposta.code): \(resposta.text)"
    }
}
