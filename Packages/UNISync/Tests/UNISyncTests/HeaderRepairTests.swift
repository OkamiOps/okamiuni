import Foundation
import Testing
import UNICore
@testable import UNISync

/// O assunto que o dono continua vendo quebrado.
///
/// O decodificador foi consertado em `2fa68d3`, mas o texto **já gravado** é o
/// que a tela mostra, e ele foi gravado pelo decodificador velho. Consertar na
/// leitura é o único caminho que não pede migração de dados nem ressincronia.
@Suite("Cabeçalho consertado na leitura")
struct HeaderRepairTests {

    /// O assunto exato do dono, nas três formas em que ele pode estar gravado.
    private let esperado = "Nova resposta: Teste de configuração"

    @Test("uma palavra codificada ainda inteira é lida na hora de mostrar")
    func stillEncodedSubjectIsDecodedOnRead() {
        #expect(
            MailAddress.repairedHeader("Nova resposta: Teste de configura=?UTF-8?Q?=C3=A7=C3=A3o?=")
                == esperado
        )
    }

    @Test("a cicatriz do decodificador velho é remontada e lida")
    func theOldDecoderScarIsRebuilt() {
        // O que o decodificador velho gravou: ele comeu o `=?` de abertura, o
        // `?` que separava a codificação da carga e o `=` do primeiro octeto,
        // e deixou o `?=` de fechamento para trás.
        #expect(
            MailAddress.repairedHeader("Nova resposta: Teste de configuraUTF-8?QC3=A7=C3=A3o?=")
                == esperado
        )
    }

    @Test("a palavra partida pela dobra do cabeçalho volta inteira")
    func theFoldedWordIsPutBackTogether() {
        // A forma que aparece nas capturas do dono: o espaço da dobra ficou
        // entre "configura" e a palavra codificada.
        #expect(
            MailAddress.repairedHeader("Nova resposta: Teste de configura UTF-8?QC3=A7=C3=A3o?=")
                == esperado
        )
    }

    @Test("duas palavras de verdade continuam duas: o espaço só some no meio de uma")
    func aRealSpaceSurvives() {
        // "Época" começa em maiúscula: é palavra nova, e o espaço fica.
        #expect(
            MailAddress.repairedHeader("Notícia da UTF-8?QC3=89poca?=") == "Notícia da Época"
        )
    }

    @Test("a mesma cicatriz na variante B")
    func theScarAlsoRebuildsBase64() {
        // `=?UTF-8?B?=?=` nunca acontece — a carga B não começa com `=` — mas
        // a remontagem não pode inventar texto se aparecer algo assim.
        let intacto = "Reunião ?B sem palavra codificada"
        #expect(MailAddress.repairedHeader(intacto) == intacto)
    }

    @Test("assunto normal não é tocado")
    func plainSubjectsAreLeftAlone() {
        for texto in [
            "Nova resposta: Teste de configuração",
            "Re: contrato assinado",
            "",
            "Preço: R$ 1.200 (?) — confirmar",
            "Quem? Ninguém.",
        ] {
            #expect(MailAddress.repairedHeader(texto) == texto)
        }
    }

    @Test("charset que não sabemos ler devolve o texto como está")
    func unknownCharsetIsLeftAlone() {
        let cru = "=?KOI8-R?Q?=C1=C2?="
        #expect(MailAddress.repairedHeader(cru) == cru)
    }

    @Test("a leitura é idempotente: consertar o consertado não muda nada")
    func repairIsIdempotent() {
        let uma = MailAddress.repairedHeader(
            "Nova resposta: Teste de configuraUTF-8?QC3=A7=C3=A3o?="
        )
        #expect(MailAddress.repairedHeader(uma) == uma)
    }

    @Test("a mensagem lida do banco já sai com o assunto certo")
    func recordsDecodeOnTheWayOut() {
        // A linha do banco do dono: gravada com o assunto já quebrado.
        let gravada = Message(
            id: "m1", accountID: "a1",
            from: Contact(name: "Google Forms", address: "forms@google.com"),
            receivedAt: Date(timeIntervalSince1970: 0),
            subject: "Nova resposta: Teste de configuraUTF-8?QC3=A7=C3=A3o?=",
            snippet: "", body: [],
            tags: [], bucket: .today, isRead: false,
            summary: nil, detectedEvent: nil
        )
        let record = MessageRecord(gravada, folderID: "f1")
        #expect(record.subject == gravada.subject, "a gravação não mexe no que já está lá")
        #expect(record.message(body: []).subject == esperado)
    }
}
