import Foundation
import Testing
@testable import UNICore

@Suite("Resposta rápida — catálogo e sugestões")
struct QuickReplyDirectoryTests {

    /// Remetentes inventados, de domínios que não existem nas fixtures. Se
    /// alguma regra filtrasse por conta, host ou provedor, estes sumiriam.
    private static func message(
        _ id: String, _ name: String, _ address: String, account: String = "qualquer"
    ) -> Message {
        Message(
            id: id, accountID: account,
            from: Contact(name: name, address: address),
            receivedAt: Date(timeIntervalSince1970: 0),
            subject: "assunto \(id)", snippet: "", body: [], tags: [],
            bucket: .today, isRead: true, summary: nil, detectedEvent: nil
        )
    }

    @Test("o catálogo sai das mensagens que existem, de qualquer domínio")
    func directoryComesFromMessages() {
        let messages = [
            Self.message("a", "Yuki Tanaka", "yuki@example.co.jp", account: "conta-a"),
            Self.message("b", "Ana Ø", "ana@nordisk.no", account: "conta-b"),
            Self.message("c", "Sem Nome", "root@10-0-0-1.local", account: "conta-c"),
        ]
        let pool = QuickReply.directory(messages: messages)

        #expect(pool.map(\.address) == [
            "ana@nordisk.no",
            "root@10-0-0-1.local",
            "yuki@example.co.jp",
        ])
        #expect(pool.allSatisfy { $0.frequency == 1 })
    }

    @Test("quem escreve mais vem antes")
    func frequencyOrdersTheDirectory() {
        let messages = [
            Self.message("a", "Zeta", "zeta@z.example"),
            Self.message("b", "Alfa", "alfa@a.example"),
            Self.message("c", "Alfa", "alfa@a.example"),
        ]
        let pool = QuickReply.directory(messages: messages)

        #expect(pool.map(\.address) == ["alfa@a.example", "zeta@z.example"])
        #expect(pool[0].frequency == 2)
        #expect(pool[1].frequency == 1)
    }

    @Test("quem está nos dois lugares soma, e fica com o nome do caderno")
    func catalogAndMessagesMerge() throws {
        let messages = [Self.message("a", "marina", "MARINA@clientepremium.com")]
        let catalog = [
            DirectoryContact(name: "Marina Duarte", address: "marina@clientepremium.com",
                             org: "Cliente Premium", frequency: 42)
        ]
        let pool = QuickReply.directory(messages: messages, catalog: catalog)

        #expect(pool.count == 1)
        let marina = try #require(pool.first)
        #expect(marina.name == "Marina Duarte")
        #expect(marina.org == "Cliente Premium")
        #expect(marina.frequency == 43)
    }

    @Test("mensagem sem endereço não vira contato")
    func emptyAddressIsNotAContact() {
        let pool = QuickReply.directory(messages: [Self.message("a", "Fantasma", "")])
        #expect(pool.isEmpty)
    }
}

@Suite("Resposta rápida — busca sem acento e sem caixa")
struct QuickReplySearchTests {

    private static let pool = [
        DirectoryContact(name: "Cláudia Rocha", address: "claudia@transrota.com.br",
                         org: "TransRota", frequency: 19),
        DirectoryContact(name: "Marina Duarte", address: "marina@clientepremium.com",
                         org: "Cliente Premium", frequency: 42),
        // "Parceiro" não aparece no nome nem no endereço dele: é o único
        // jeito de provar que a organização fica de fora da busca.
        DirectoryContact(name: "João Gonçalves", address: "joao@exemplo.pt",
                         org: "Parceiro", frequency: 3),
        // Guardado sem acento, como muito caderno de endereços faz.
        DirectoryContact(name: "Luis Inacio", address: "luis.inacio@exemplo.com",
                         org: "", frequency: 1),
    ]

    @Test("digitar sem acento acha quem tem acento")
    func diacriticInsensitive() {
        #expect(
            QuickReply.suggestions(matching: "claudia", excluding: [], in: Self.pool)
                .map(\.address) == ["claudia@transrota.com.br"]
        )
        #expect(
            QuickReply.suggestions(matching: "goncalves", excluding: [], in: Self.pool)
                .map(\.address) == ["joao@exemplo.pt"]
        )
    }

    @Test("digitar com acento acha quem está guardado sem acento")
    func diacriticInsensitiveBothWays() {
        #expect(
            QuickReply.suggestions(matching: "Luís Inácio", excluding: [], in: Self.pool)
                .map(\.address) == ["luis.inacio@exemplo.com"]
        )
    }

    @Test("caixa não importa, no nome nem no email")
    func caseInsensitive() {
        #expect(
            QuickReply.suggestions(matching: "MARINA DUARTE", excluding: [], in: Self.pool)
                .map(\.address) == ["marina@clientepremium.com"]
        )
        #expect(
            QuickReply.suggestions(matching: "CLIENTEPREMIUM", excluding: [], in: Self.pool)
                .map(\.address) == ["marina@clientepremium.com"]
        )
    }

    /// Este teste afirmava o **contrário** — "a organização não conta" — e era
    /// o par que travava a segunda máquina de sugestão contra a primeira: o
    /// campo de destinatário da janela cheia procurava na organização e a faixa
    /// do leitor não, cada uma com um teste exigindo a sua regra. Com
    /// `ContactDirectory` como única, a faixa passou a procurar na organização
    /// também, e o teste diz agora o que o app faz.
    @Test("a busca conta a organização, como no campo de destinatário")
    func organisationIsSearched() {
        // "Parceiro" não está no nome nem no endereço do João: só na coluna da
        // organização, que é o que o menu mostra à direita da linha.
        #expect(
            QuickReply.suggestions(matching: "Parceiro", excluding: [], in: Self.pool)
                .map(\.address) == ["joao@exemplo.pt"]
        )
        // E o mesmo trecho, quando está no endereço, continua achando.
        #expect(
            QuickReply.suggestions(matching: "transrota", excluding: [], in: Self.pool)
                .map(\.address) == ["claudia@transrota.com.br"]
        )
    }

    /// Trecho vazio é o estado "Mais usados" — e agora ele de fato ordena por
    /// frequência nas duas superfícies. A faixa devolvia a ordem crua do pool.
    @Test("sem busca, o menu mostra o catálogo inteiro, do mais escrito para o menos")
    func emptyQueryShowsEverything() {
        #expect(
            QuickReply.suggestions(matching: "   ", excluding: [], in: Self.pool)
                .map(\.address) == Self.pool.sorted { $0.frequency > $1.frequency }.map(\.address)
        )
        // E a ordem é mesmo por frequência, não a de chegada: Marina (42) vem
        // antes de Cláudia (19), que no pool está escrita primeiro.
        #expect(
            QuickReply.suggestions(matching: "   ", excluding: [], in: Self.pool)
                .first?.address == "marina@clientepremium.com"
        )
        #expect(QuickReply.menuLabel(query: "   ") == "Mais usados")
        #expect(QuickReply.menuLabel(query: "ma") == "Contatos")
    }

    /// A dobra de acento era exclusividade desta máquina; agora é a das duas.
    /// Provado pelo caminho do **campo de destinatário**, que antes não dobrava.
    @Test("o campo de destinatário passou a dobrar acento, como a faixa")
    func directoryFoldsAccentsToo() {
        #expect(
            ContactDirectory.suggestions(matching: "claudia", excluding: [], in: Self.pool)
                .map(\.address) == ["claudia@transrota.com.br"]
        )
        #expect(
            ContactDirectory.suggestions(matching: "Luís Inácio", excluding: [], in: Self.pool)
                .map(\.address) == ["luis.inacio@exemplo.com"]
        )
        // E as duas superfícies respondem a mesma coisa para o mesmo trecho.
        for term in ["claudia", "Luís Inácio", "Parceiro", "transrota", "MARINA"] {
            #expect(
                ContactDirectory.suggestions(matching: term, excluding: [], in: Self.pool)
                    == QuickReply.suggestions(matching: term, excluding: [], in: Self.pool),
                "as duas máquinas discordam em \(term)"
            )
        }
    }

    @Test("quem já é etiqueta sai do menu")
    func chosenAreExcluded() {
        let chosen = [Contact(name: "qualquer coisa", address: "MARINA@ClientePremium.com")]
        #expect(
            QuickReply.suggestions(matching: "", excluding: chosen, in: Self.pool)
                .map(\.address) == [
                    "claudia@transrota.com.br", "joao@exemplo.pt", "luis.inacio@exemplo.com",
                ]
        )
    }

    @Test("o menu mostra no máximo cinco linhas")
    func fiveLines() {
        let many = (1...9).map {
            DirectoryContact(name: "Pessoa \($0)", address: "p\($0)@exemplo.com",
                             org: "", frequency: 10 - $0)
        }
        let shown = QuickReply.suggestions(matching: "", excluding: [], in: many)
        #expect(shown.count == 5)
        #expect(shown.map(\.address) == [
            "p1@exemplo.com", "p2@exemplo.com", "p3@exemplo.com",
            "p4@exemplo.com", "p5@exemplo.com",
        ])
    }

    @Test("endereço de fora do catálogo entra como está")
    func typedAddressIsAccepted() throws {
        let hit = try #require(QuickReply.resolve(typed: " novo@dominio.desconhecido ", in: Self.pool))
        #expect(hit.address == "novo@dominio.desconhecido")
        #expect(hit.frequency == 0)

        let known = try #require(QuickReply.resolve(typed: "claudia", in: Self.pool))
        #expect(known.address == "claudia@transrota.com.br")

        #expect(QuickReply.resolve(typed: "   ", in: Self.pool) == nil)
    }
}

@Suite("Resposta rápida — etiquetas e rascunho")
struct QuickReplyChipTests {

    private static let marina = Contact(name: "Marina Duarte", address: "marina@clientepremium.com")

    @Test("a etiqueta entra uma vez só, mesmo com caixa diferente")
    func noDuplicates() {
        let once = QuickReply.adding(Self.marina, to: [])
        #expect(once.map(\.address) == ["marina@clientepremium.com"])

        let again = QuickReply.adding(
            Contact(name: "Marina D.", address: "MARINA@CLIENTEPREMIUM.COM"), to: once
        )
        #expect(again.map(\.address) == ["marina@clientepremium.com"])
        #expect(again.count == 1)
    }

    @Test("a etiqueta sai pelo endereço, não pelo nome")
    func removeByAddress() {
        let chips = [Self.marina, Contact(name: "Jurídico", address: "juridico@empresa.com")]
        let left = QuickReply.removing(
            Contact(name: "outro nome qualquer", address: "marina@clientepremium.com"),
            from: chips
        )
        #expect(left.map(\.address) == ["juridico@empresa.com"])
    }

    @Test("a ordem em que as etiquetas entraram é a ordem em que ficam")
    func orderIsPreserved() {
        var chips: [Contact] = []
        for address in ["a@x.com", "b@x.com", "c@x.com"] {
            chips = QuickReply.adding(Contact(name: "", address: address), to: chips)
        }
        #expect(chips.map(\.address) == ["a@x.com", "b@x.com", "c@x.com"])
    }

    @Test("rascunho só com espaço em branco não conta como escrito")
    func draftEmptiness() {
        #expect(ReplyDraft().isEmpty)
        #expect(ReplyDraft(to: [], text: "   \n  ").isEmpty)
        #expect(ReplyDraft(to: [Self.marina], text: "").isEmpty == false)
        #expect(ReplyDraft(to: [Self.marina], text: "").hasText == false)
        #expect(ReplyDraft(to: [], text: "oi").hasText)
    }
}

@Suite("Resposta rápida — o rascunho atravessa a sessão")
struct QuickReplyDraftStoreTests {

    @Test("o rascunho fica guardado por mensagem e volta inteiro")
    @MainActor
    func draftSurvives() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()

        #expect(store.replyDraft(for: "m1") == nil)

        let draft = ReplyDraft(
            to: [Contact(name: "Marina Duarte", address: "marina@clientepremium.com")],
            text: "Fecho quinta às 15h.",
            savedAt: Date(timeIntervalSince1970: 1_000)
        )
        store.setReplyDraft(draft, for: "m1")

        let back = try #require(store.replyDraft(for: "m1"))
        #expect(back.text == "Fecho quinta às 15h.")
        #expect(back.to.map(\.address) == ["marina@clientepremium.com"])
        #expect(back.savedAt == Date(timeIntervalSince1970: 1_000))
        // Um rascunho não vaza para a mensagem do lado.
        #expect(store.replyDraft(for: "m2") == nil)
    }

    @Test("rascunho vazio não fica ocupando lugar")
    @MainActor
    func emptyDraftIsDropped() async {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()

        store.setReplyDraft(ReplyDraft(to: [], text: "  "), for: "m1")
        #expect(store.replyDraft(for: "m1") == nil)

        store.setReplyDraft(ReplyDraft(to: [], text: "algo"), for: "m1")
        #expect(store.replyDraft(for: "m1") != nil)

        store.setReplyDraft(nil, for: "m1")
        #expect(store.replyDraft(for: "m1") == nil)
    }
}
