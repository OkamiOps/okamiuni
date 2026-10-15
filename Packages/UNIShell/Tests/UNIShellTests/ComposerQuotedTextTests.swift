import Foundation
import Testing
@testable import UNIShell

/// A citação em texto puro, sem montar janela nenhuma.
@Suite("Citação sem HTML")
struct ComposerQuotedTextTests {

    private static let rastreio = "https://click.e.todoist.com/f/a/8kQb3Zx9/AA/H1Jk2Lm3"
        + "?utm_source=digest&utm_medium=email&cid=99173402"

    @Test("o endereço vira o domínio, e o www some")
    func labelIsTheDomain() throws {
        #expect(ComposerQuotedText.rotulo(de: try #require(URL(string: Self.rastreio)))
                == "click.e.todoist.com")
        #expect(ComposerQuotedText.rotulo(de: try #require(URL(string: "https://www.todoist.com/app")))
                == "todoist.com")
    }

    @Test("o link encurta mas o destino inteiro continua inteiro")
    func theLinkKeepsItsDestination() throws {
        let pedacos = ComposerQuotedText.pedacos("Abrir no Todoist: \(Self.rastreio) agora")
        #expect(pedacos.map(\.texto) == ["Abrir no Todoist: ", "click.e.todoist.com", " agora"])
        #expect(pedacos[1].destino?.absoluteString == Self.rastreio)
    }

    @Test("linha sem endereço nenhum sai inteira e sem link")
    func plainLineIsUntouched() {
        let pedacos = ComposerQuotedText.pedacos("Você tem 4 tarefas para hoje.")
        #expect(pedacos.count == 1)
        #expect(pedacos[0].texto == "Você tem 4 tarefas para hoje.")
        #expect(pedacos[0].destino == nil)
    }

    /// Um `mailto:` **é** o que a pessoa precisa ler: encurtá-lo para o
    /// domínio esconderia justamente o endereço.
    @Test("mailto não é encurtado")
    func mailtoIsNotShortened() {
        let pedacos = ComposerQuotedText.pedacos("Responda a marina@cliente.com")
        #expect(pedacos.count == 1)
        #expect(pedacos[0].texto == "Responda a marina@cliente.com")
    }
}
