import Foundation
import Testing
import UNICore
@testable import UNISync

/// `Content-Type: text/plain; format=flowed` (RFC 3676) declarado pelo
/// remetente: é o único lugar do app em que o cabeçalho ainda existe para ser
/// lido, e por isso é aqui que ele é obedecido.
@Suite("O texto que se declara flowed")
struct MimeFlowedTests {

    @Test("Espaço no fim da linha junta as duas")
    func flowedJunta() {
        let cru = """
            Content-Type: text/plain; charset=utf-8; format=flowed

            Passando para confirmar nossa call amanhã, 16 de julho, às 15h, \n\
            no horário \n\
            de Brasília.

            Até lá!
            """
        let corpo = MimeBody.decode(raw: cru)
        #expect(corpo.paragraphs == [
            "Passando para confirmar nossa call amanhã, 16 de julho, às 15h, no horário de Brasília.",
            "Até lá!",
        ])
    }

    @Test("DelSp=Yes: o espaço da quebra some em vez de virar separador")
    func delSp() {
        let cru = "Content-Type: text/plain; format=flowed; DelSp=Yes\n\nconti \nnuação"
        #expect(MimeBody.decode(raw: cru).text == "continuação")
    }

    @Test("Sem a declaração, o decodificador não mexe nas quebras")
    func semDeclaracaoNaoMexe() {
        let cru = "Content-Type: text/plain; charset=utf-8\n\nprimeira linha \nsegunda linha"
        // O refluxo não-declarado é heurística, e ela mora no desenho
        // (`PlainTextReflow` no leitor) para alcançar também o que já está
        // gravado. Aqui, o texto atravessa igual.
        #expect(MimeBody.decode(raw: cru).text == "primeira linha \nsegunda linha")
    }

    @Test("A parte flowed dentro de um multipart também vale")
    func dentroDoMultipart() {
        let cru = """
            Content-Type: multipart/alternative; boundary="xyz"

            --xyz
            Content-Type: text/plain; charset=utf-8; format=flowed

            Confirmo a reunião \n\
            de amanhã.
            --xyz
            Content-Type: text/html; charset=utf-8

            <p>Confirmo a reunião de amanhã.</p>
            --xyz--
            """
        #expect(MimeBody.decode(raw: cru).text == "Confirmo a reunião de amanhã.")
    }
}
