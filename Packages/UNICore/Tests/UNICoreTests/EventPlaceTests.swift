import Foundation
import Testing
@testable import UNICore

/// **A linha "LOCAL" da tela do dono.** Ela mostrava, num campo de uma linha, o
/// cartão de entrada do Google Meet inteiro: título repetido, dia, horário,
/// fuso, "Google Meet joining info" e o link — que a janela já desenha no
/// cartão dele, logo acima.
@Suite("O local do convite")
struct EventPlaceTests {

    /// O texto literal do `LOCATION` que o Google Agenda mandou. Uma linha só,
    /// que é como ele chega quando o `\n` do iCalendar não é usado — e é o que
    /// o print do dono mostra.
    private static let despejoDoDono = """
        DreamSquad <> Vantion Friday, July 24 · 2:00 – 3:00pm \
        Time zone: America/Argentina/Buenos_Aires Google Meet joining info \
        Video call link: https://meet.google.com/abc-defg-hij
        """

    @Test("O despejo do Google Meet não é local nenhum")
    func despejoNaoEhLocal() {
        #expect(EventPlace.limpa(Self.despejoDoDono, summary: "DreamSquad <> Vantion") == nil)
    }

    /// **O contrário, que é o erro caro.** Uma limpeza mais agressiva — cortar
    /// vírgulas, números, tudo que "parece endereço de cartão" — comeria a sala
    /// de uma reunião presencial, e a pessoa apareceria no prédio errado.
    @Test("O endereço físico atravessa intacto", arguments: [
        "Av. Paulista, 1000, sala 3",
        "Sala Vantion, 4º andar",
        "Rua da Consolação 222 — 12º, São Paulo",
        "Zoom · sala pessoal",
    ])
    func enderecoFisicoIntacto(endereco: String) {
        #expect(EventPlace.limpa(endereco) == endereco)
    }

    /// Quando o despejo vem em linhas — o caso do `\n` do iCalendar — o que é
    /// lugar de verdade sobrevive, e só ele.
    @Test("Do despejo em linhas sobra o que é lugar")
    func sobraOQueEhLugar() {
        let location = """
            DreamSquad <> Vantion
            Av. Paulista, 1000, sala 3
            Google Meet joining info
            Video call link: https://meet.google.com/abc-defg-hij
            """
        #expect(
            EventPlace.limpa(location, summary: "DreamSquad <> Vantion")
                == "Av. Paulista, 1000, sala 3"
        )
    }

    @Test("Sem local, sem texto")
    func semLocal() {
        #expect(EventPlace.limpa(nil) == nil)
        #expect(EventPlace.limpa("") == nil)
        #expect(EventPlace.limpa("   \n  ") == nil)
    }

    /// O caso do dono, ponta a ponta: o convite inteiro virando o que a janela
    /// mostra. O campo LOCAL diz "Sem local definido" e o link continua sendo
    /// extraído — ele não se perde na limpeza, porque quem o acha é o
    /// `MeetingLink`, e não o campo do local.
    @Test("O convite do dono: local vazio, link extraído")
    func oConviteDoDono() throws {
        let ics = """
            BEGIN:VCALENDAR
            METHOD:REQUEST
            BEGIN:VEVENT
            UID:dreamsquad-1
            SUMMARY:DreamSquad <> Vantion
            DTSTART:20260724T170000Z
            DTEND:20260724T180000Z
            LOCATION:\(Self.despejoDoDono)
            ORGANIZER;CN=Favini:mailto:favini@vantion.com.br
            END:VEVENT
            END:VCALENDAR
            """
        let invite = try #require(ICalendar.parse(ics))
        #expect(invite.meetingURL == "https://meet.google.com/abc-defg-hij")

        let detail = InviteAgenda.detail(
            for: invite, subject: "Convite: DreamSquad <> Vantion",
            sender: Contact(name: "Favini", address: "favini@vantion.com.br"),
            when: "21 de jul., 14:30", accountHost: "vantion"
        )
        #expect(detail.place == EventPlace.semLocal)
        #expect(detail.link == "https://meet.google.com/abc-defg-hij")
    }

    /// E a sala de verdade continua chegando na janela: mesmo convite, mesmo
    /// caminho, `LOCATION` legítimo.
    @Test("A sala de verdade chega à janela")
    func aSalaDeVerdadeChega() throws {
        let ics = """
            BEGIN:VCALENDAR
            BEGIN:VEVENT
            SUMMARY:Revisão do contrato
            DTSTART:20260724T170000Z
            LOCATION:Av. Paulista\\, 1000\\, sala 3
            END:VEVENT
            END:VCALENDAR
            """
        let invite = try #require(ICalendar.parse(ics))
        let detail = InviteAgenda.detail(
            for: invite, subject: "Convite", sender: Contact(name: "", address: "x@y.com"),
            when: "21 de jul.", accountHost: nil
        )
        #expect(detail.place == "Av. Paulista, 1000, sala 3")
    }
}
