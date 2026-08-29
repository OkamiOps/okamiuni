import Foundation
import Testing
@testable import UNICore

/// As duas seções recolhíveis da janela do compromisso.
@Suite("As seções do compromisso")
struct EventSectionsTests {

    private func pessoa(_ nome: String) -> EventPerson {
        EventPerson(
            name: nome, address: "\(nome.lowercased())@vantion.com.br",
            role: "convidado", status: .pending
        )
    }

    @Test("As duas nascem recolhidas")
    func nascemRecolhidas() {
        let sections = EventSections()
        #expect(sections.participants == false)
        #expect(sections.origin == false)
    }

    @Test("O cabeçalho alterna nos dois sentidos")
    func alterna() {
        var sections = EventSections()
        sections.toggleParticipants()
        #expect(sections.participants)
        sections.toggleParticipants()
        #expect(sections.participants == false)

        sections.toggleOrigin()
        #expect(sections.origin)
        // Uma seção não mexe na outra.
        #expect(sections.participants == false)
    }

    /// Recolhida mostra o organizador — a primeira linha do roster — e esconde
    /// os outros sete. Era esta a queixa: oito participantes tomando a janela.
    @Test("Recolhida mostra só o organizador")
    func recolhidaMostraOOrganizador() {
        let gente = ["Favini", "Marcos", "Ana", "Bruno", "Carla", "Diego", "Elis", "Fabio"]
            .map(pessoa)
        #expect(EventSections.visibleGuests(gente, expanded: false).map(\.name) == ["Favini"])
        #expect(EventSections.hiddenGuestCount(gente, expanded: false) == 7)

        #expect(EventSections.visibleGuests(gente, expanded: true).count == 8)
        #expect(EventSections.hiddenGuestCount(gente, expanded: true) == 0)
    }

    @Test("Sem ninguém, nenhuma linha em branco")
    func semNinguem() {
        #expect(EventSections.visibleGuests([], expanded: false).isEmpty)
        #expect(EventSections.hiddenGuestCount([], expanded: false) == 0)
    }

    /// Recolhida, a seção ainda responde alguma coisa: **de quando** é o email.
    @Test("O cabeçalho diz de quando é o email")
    func cabecalhoDoEmail() {
        let thread = [
            EventThreadEntry(
                when: "21 de jul., 14:30", who: "Favini",
                what: "Convite: DreamSquad", kind: .email
            ),
            EventThreadEntry(when: "21 de jul.", who: "OkamiUNI", what: "Detectado", kind: .ai),
        ]
        #expect(EventSections.originHeader(thread) == "O que gerou · email de 21 de jul., 14:30")
    }

    /// Sem email no histórico não há "email de …" a prometer.
    @Test("Sem email, o título de sempre")
    func semEmail() {
        #expect(EventSections.originHeader([]) == "O que gerou este compromisso")
        #expect(
            EventSections.originHeader([
                EventThreadEntry(when: "18 ago", who: "Equipe", what: "Série criada", kind: .system)
            ]) == "O que gerou este compromisso"
        )
    }

    /// A prévia do corpo: o email **inteiro**.
    ///
    /// O defeito da M3-14: aberta, a seção mostrava o cabeçalho do email (quem,
    /// assunto, data) e a nota — nada do que o email dizia. O da M3-21: mostrava
    /// três parágrafos, e o dono queria **ler** a mensagem dali. Quem limita
    /// agora é a altura da seção, que rola por dentro.
    @Test("A prévia leva o email inteiro, e não uma amostra")
    func previaDoCorpo() {
        let corpo = ["Primeiro.", "Segundo.", "Terceiro.", "Quarto.", "Quinto."]
        #expect(EventSections.bodyPreview(corpo) == corpo)
    }

    /// Parágrafo em branco não vira linha em branco na janela: o que vem do
    /// decodificador tem sobra de espaço e de quebra de linha.
    @Test("A prévia descarta parágrafos vazios e apara o que sobra")
    func previaAparaOVazio() {
        #expect(
            EventSections.bodyPreview(["  ", "\n", " Oi, tudo bem?\n", "", "Segundo."])
                == ["Oi, tudo bem?", "Segundo."]
        )
    }

    /// Mensagem sem corpo no banco é caso legítimo — as que ainda não foram
    /// buscadas. A seção fica com a linha do email e o "Abrir no leitor", e
    /// esta janela não pede rede para preencher o resto.
    @Test("Sem corpo, a prévia é vazia — e não uma linha em branco")
    func semCorpo() {
        #expect(EventSections.bodyPreview([]).isEmpty)
        #expect(EventSections.bodyPreview(["", "   "]).isEmpty)
    }
}
