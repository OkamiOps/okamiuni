import Testing
import Foundation
@testable import UNICore

/// Catálogo propositalmente **fora** da ordem de frequência: se estivesse
/// ordenado, um teste de ordenação passaria mesmo com o `sorted` removido.
private let shuffledPool: [DirectoryContact] = [
    DirectoryContact(name: "Ana Rara", address: "ana@raro.com", org: "Fornecedor", frequency: 3),
    DirectoryContact(name: "Zeca Frequente", address: "zeca@empresa.com", org: "Interno", frequency: 90),
    DirectoryContact(name: "Meio Termo", address: "meio@empresa.com", org: "Interno", frequency: 40),
]

@Suite("Catálogo de contatos")
struct ContactDirectoryTests {

    @Test("Sem busca, o mais escrito vem primeiro")
    func rankedByFrequency() {
        let list = ContactDirectory.suggestions(matching: "", excluding: [], in: shuffledPool)
        #expect(list.map(\.address) == [
            "zeca@empresa.com",   // 90
            "meio@empresa.com",   // 40
            "ana@raro.com",       // 3
        ])
    }

    @Test("A busca alcança nome, endereço e organização")
    func searchesEveryColumn() {
        let byName = ContactDirectory.suggestions(matching: "zeca", excluding: [], in: shuffledPool)
        #expect(byName.map(\.address) == ["zeca@empresa.com"])

        let byAddress = ContactDirectory.suggestions(matching: "raro.com", excluding: [], in: shuffledPool)
        #expect(byAddress.map(\.address) == ["ana@raro.com"])

        let byOrg = ContactDirectory.suggestions(matching: "fornecedor", excluding: [], in: shuffledPool)
        #expect(byOrg.map(\.address) == ["ana@raro.com"])
    }

    @Test("Quem já é etiqueta some do menu, sem olhar a caixa das letras")
    func excludesChosen() {
        let chosen = [Contact(name: "Zeca", address: "ZECA@EMPRESA.COM")]
        let list = ContactDirectory.suggestions(matching: "", excluding: chosen, in: shuffledPool)
        #expect(list.map(\.address) == ["meio@empresa.com", "ana@raro.com"])
    }

    @Test("O menu para em cinco linhas")
    func capsAtFive() {
        let pool = (1...12).map {
            DirectoryContact(name: "Pessoa \($0)", address: "p\($0)@x.com", org: "X", frequency: $0)
        }
        let list = ContactDirectory.suggestions(matching: "", excluding: [], in: pool)
        #expect(list.count == 5)
        #expect(list.first?.address == "p12@x.com")
    }

    @Test("O rótulo do menu muda com a busca")
    func menuLabel() {
        #expect(ContactDirectory.menuLabel(query: "   ") == "Mais usados")
        #expect(ContactDirectory.menuLabel(query: "mar") == "Contatos")
    }

    @Test("Endereço solto vira etiqueta quando ninguém casa")
    func resolvesTyped() {
        let hit = ContactDirectory.resolve(typed: "zeca", in: shuffledPool)
        #expect(hit?.address == "zeca@empresa.com")

        let miss = ContactDirectory.resolve(typed: "ninguem@fora.com", in: shuffledPool)
        #expect(miss?.address == "ninguem@fora.com")
        #expect(miss?.name == "ninguem@fora.com")
        #expect(miss?.frequency == 0)

        #expect(ContactDirectory.resolve(typed: "   ", in: shuffledPool) == nil)
    }
}

@Suite("Rótulos do rascunho")
struct DraftMetaTests {

    @Test("Contagem de palavras: vazio, uma, muitas")
    func countLabel() {
        #expect(DraftMeta.countLabel("   \n ") == "rascunho vazio")
        #expect(DraftMeta.countLabel("Marina") == "1 palavra")
        // O travessão é palavra, como no `split(/\s+/)` do protótipo:
        // "Marina," "fechado" "—" "quinta" "às" "15h".
        #expect(DraftMeta.countLabel("Marina, fechado — quinta às 15h") == "6 palavras")
    }

    @Test("Carimbo de salvamento")
    func savedLabel() {
        #expect(DraftMeta.savedLabel(nil) == "não salvo")
        #expect(DraftMeta.savedLabel("") == "não salvo")
        #expect(DraftMeta.savedLabel("14:07") == "rascunho salvo 14:07")
    }
}

@Suite("Compromisso — horário e detalhe")
struct EventDetailTests {

    @Test("Faixa e duração do compromisso")
    func rangeAndDuration() {
        let short = AgendaItem(id: "a", title: "1:1", startMinute: 660, endMinute: 705, accountID: "zoho")
        #expect(short.rangeLabel == "11:00 – 11:45")
        #expect(short.durationLabel == "45min")

        let round = AgendaItem(id: "b", title: "Retro", startMinute: 900, endMinute: 960, accountID: "zoho")
        #expect(round.durationLabel == "1h")   // hora cheia não vira "1h00"

        let long = AgendaItem(id: "c", title: "Foco", startMinute: 990, endMinute: 1080, accountID: "host")
        #expect(long.durationLabel == "1h30")
    }

    @Test("Título sem metadados cai no padrão, e os apelidos apontam para o mesmo detalhe")
    func lookupAndAliases() {
        let unknown = Fixtures.eventDetail(for: "Almoço — bloqueado")
        #expect(unknown.place == "Sem local definido")
        #expect(unknown.link == nil)
        #expect(unknown.agenda.isEmpty)

        #expect(Fixtures.eventDetail(for: "Standup produto") == Fixtures.eventDetail(for: "Standup"))
        #expect(Fixtures.eventDetail(for: "1:1 Marina Duarte").place == "Zoom · sala pessoal")
        #expect(Fixtures.eventDetail(for: "Foco: proposta TransRota").link == nil)
    }

    @Test("O roster põe o organizador na frente e marca quem é o dono da caixa")
    func guestRoster() {
        let detail = Fixtures.eventDetail(for: "Revisão do contrato")
        let guests = detail.guests(me: "ricardo@empresa.com")

        #expect(guests.map(\.address) == [
            "marina@clientepremium.com",  // organizadora, sempre primeiro
            "ricardo@empresa.com",
            "juridico@empresa.com",
        ])
        #expect(guests[1].role == "você")           // já dizia "você": não duplica
        #expect(guests[2].role == "obrigatório")    // não sou eu: intacto
        #expect(detail.guestCount == 3)
    }

    @Test("Dono de caixa com outro papel ganha o sufixo")
    func rosterMarksOtherRole() {
        let detail = Fixtures.eventDetail(for: "Standup")
        let guests = detail.guests(me: "pedro@empresa.com")
        let pedro = guests.first { $0.address == "pedro@empresa.com" }
        #expect(pedro?.role == "obrigatório · você")

        let ana = guests.first { $0.address == "ana.beatriz@transrota.com.br" }
        #expect(ana?.role == "opcional")
        #expect(ana?.status.label == "talvez")
    }

    @Test("O organizador não é contado duas vezes quando também está na lista")
    func organizerNotDuplicated() {
        let organizer = EventPerson(name: "Chefe", address: "chefe@x.com", role: "organizador", status: .yes)
        let detail = EventDetail(
            place: "Sala", link: nil, organizer: organizer,
            people: [
                EventPerson(name: "Chefe", address: "CHEFE@X.COM", role: "obrigatório", status: .yes),
                EventPerson(name: "Outra", address: "outra@x.com", role: "opcional", status: .pending),
            ],
            note: "", recurrence: "", notice: "", agenda: [], thread: []
        )
        #expect(detail.guests(me: "ninguem@x.com").map(\.address) == ["chefe@x.com", "outra@x.com"])
        #expect(detail.guestCount == 2)
        #expect(detail.guests(me: "outra@x.com").last?.status.label == "aguardando")
    }

    @Test("A data do compromisso perde o '-feira' e ganha maiúscula")
    func eventDateLabel() {
        #expect(DateLabels.eventDate(Fixtures.today) == "Terça, 25 de agosto")
    }
}
