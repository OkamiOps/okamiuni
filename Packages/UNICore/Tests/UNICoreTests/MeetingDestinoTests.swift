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
