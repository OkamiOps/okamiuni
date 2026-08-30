import Foundation
import Testing
@testable import UNICore

/// O endereço que o botão "Entrar" e o cartão do link abrem — a mesma pergunta,
/// feita uma vez só.
@Suite("O endereço da reunião")
struct MeetingDestinoTests {

    @Test("O link de sala vira endereço para abrir")
    func abre() throws {
        let url = try #require(MeetingLink.destino("https://meet.google.com/abc-defg-hij"))
        #expect(url.absoluteString == "https://meet.google.com/abc-defg-hij")
        #expect(MeetingLink.destino("  http://zoom.us/j/123  ") != nil)
    }

    @Test("O campo explícito aceita qualquer sala web e limpa as bordas")
    func normalizaCampoExplicito() {
        #expect(
            MeetingLink.normalizado("  https://video.empresa.example/sala/42  ")
                == "https://video.empresa.example/sala/42"
        )
    }

    @Test("Convites reconhecem os quatro provedores usados no app", arguments: [
        "https://meet.google.com/abc-defg-hij",
        "https://us02web.zoom.us/j/123456789",
        "https://empresa.webex.com/meet/marcos",
        "https://teams.microsoft.com/l/meetup-join/19%3ameeting",
    ])
    func reconheceProvedorNoConvite(link: String) {
        #expect(MeetingLink.first(in: "Entrar na reunião: \(link)") == link)
    }

    @Test("Domínio que apenas imita Webex continua recusado")
    func recusaWebexFalso() {
        #expect(MeetingLink.first(in: "https://webex.com.golpe.example/meet/1") == nil)
    }

    /// O que **não** acende o botão: um "link" que não se abre no navegador.
    /// Prometer que abre é a mesma mudez que este marco veio consertar.
    @Test("O que não se abre no navegador não vira endereço", arguments: [
        "", "   ", "Sala 3", "meet.google.com/abc", "mailto:favini@vantion.com.br",
        "ftp://arquivos.exemplo.com", "https://",
    ])
    func naoAbre(texto: String) {
        #expect(MeetingLink.destino(texto) == nil)
    }

    @Test("Sem link, sem endereço")
    func semLink() {
        #expect(MeetingLink.destino(nil) == nil)
    }
}
