import Foundation
import Testing
@testable import UNISync

/// O decodificador de `=?charset?codificação?carga?=` (RFC 2047).
///
/// O defeito que originou este arquivo: procurar o terminador `?=` a partir do
/// `=?` de abertura acha, numa carga Q que começa com `=` — o caso de qualquer
/// acento em português —, o `?` que fecha o token de codificação somado ao `=`
/// que abre o primeiro octeto. O assunto sai picado ao meio.
@Suite("RFC 2047: cabeçalhos codificados")
struct RFC2047Tests {
    @Test("Carga Q que começa com `=` não corta no separador de codificação")
    func cargaQComecandoComIgual() {
        let cru = "Nova resposta: Teste de configura=?UTF-8?Q?=C3=A7=C3=A3o?="
        #expect(MailAddress.decodeRFC2047(cru) == "Nova resposta: Teste de configuração")
    }

    @Test("A variante B continua correta")
    func base64() {
        let carga = Data("Reunião de segunda".utf8).base64EncodedString()
        #expect(MailAddress.decodeRFC2047("=?UTF-8?B?\(carga)?=") == "Reunião de segunda")
    }

    @Test("Palavras codificadas adjacentes: o espaço entre elas some")
    func adjacentes() {
        let cru = "=?UTF-8?Q?Reuni=C3=A3o?= =?UTF-8?Q?_de_hoje?="
        #expect(MailAddress.decodeRFC2047(cru) == "Reunião de hoje")
    }

    @Test("Espaço entre palavra codificada e texto comum é preservado")
    func espacoComTextoComum() {
        let cru = "=?UTF-8?Q?Reuni=C3=A3o?= com a Marina"
        #expect(MailAddress.decodeRFC2047(cru) == "Reunião com a Marina")
    }

    @Test("`_` vale espaço na codificação Q")
    func sublinhadoEhEspaco() {
        #expect(MailAddress.decodeRFC2047("=?UTF-8?Q?Revis=C3=A3o_do_contrato?=")
            == "Revisão do contrato")
    }

    @Test("ISO-8859-1 é lido como latin-1, não como UTF-8")
    func isoLatin1() {
        #expect(MailAddress.decodeRFC2047("=?ISO-8859-1?Q?Jos=E9_Concei=E7=E3o?=")
            == "José Conceição")
    }

    @Test("Entrada sem codificação atravessa intacta")
    func textoComum() {
        let cru = "Contrato revisado — segue em anexo (2ª via)"
        #expect(MailAddress.decodeRFC2047(cru) == cru)
    }

    @Test("`=?` órfão não engole o resto da linha")
    func orfao() {
        let semFechamento = "Orçamento =?UTF-8?Q?parcial sem terminador"
        #expect(MailAddress.decodeRFC2047(semFechamento) == semFechamento)

        let soAbertura = "Assunto =? com sinal solto"
        #expect(MailAddress.decodeRFC2047(soAbertura) == soAbertura)
    }

    @Test("Charset desconhecido devolve o texto original em vez de lixo")
    func charsetDesconhecido() {
        let cru = "=?KOI8-R?B?8NLJ18XU?="
        #expect(MailAddress.decodeRFC2047(cru) == cru)
    }

    @Test("Uma palavra codificada no meio de outras palavras comuns")
    func noMeioDaFrase() {
        let cru = "Re: =?UTF-8?Q?a=C3=A7=C3=A3o?= judicial"
        #expect(MailAddress.decodeRFC2047(cru) == "Re: ação judicial")
    }
}
