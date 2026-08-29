import Testing
import SwiftUI
import UNIDesign
import UNICore
@testable import UNIShell

@Suite("SidebarRail")
struct SidebarRailTests {

    // `SidebarRail` é uma `View`, logo `@MainActor` implícito: quem lê um
    // `static` dela tem de estar no ator principal, senão o Swift 6 avisa.
    @Test("a trilha tem a largura do design")
    @MainActor
    func railWidth() {
        #expect(SidebarRail.width == 72)
    }

    @Test("as abreviações das quatro pastas estão na ordem certa", arguments: [
        (TriageBucket.today, "hoje"),
        (TriageBucket.later, "dep"),
        (TriageBucket.all, "tudo"),
        (TriageBucket.archived, "arq"),
    ])
    @MainActor
    func bucketAbbreviations(bucket: TriageBucket, expected: String) {
        let abbr = SidebarRail.abbreviation(for: bucket)
        #expect(
            abbr == expected,
            "abreviação para \(bucket) deve ser '\(expected)', obteve '\(abbr)'"
        )
    }

    /// A trilha recolhida encurta **ao desenhar**. Estes testes chamam
    /// `HostMark.rail` — o mesmo que a trilha chama — em vez de repetir
    /// `prefix(3).uppercased()` na asserção, que é o que faziam antes: um
    /// teste que reimplementa a regra passa mesmo com a regra errada.
    @Test("a marca da trilha são as 3 primeiras letras do host, em maiúsculas", arguments: [
        ("zoho", "ZOH"),
        ("gmail", "GMA"),
        ("hostinger", "HOS"),
        ("icloud", "ICL"),
    ])
    func railMark(host: String, expected: String) {
        #expect(HostMark.rail(host) == expected)
    }

    @Test("um host mais curto que a marca sai inteiro, sem preenchimento")
    func railMarkShorterThanLimit() {
        #expect(HostMark.rail("me") == "ME")
        #expect(HostMark.rail("") == "")
    }

    @Test("o corte conta letra, não byte — host acentuado não perde o acento")
    func railMarkCountsCharacters() {
        // "ção" tem 3 letras e 5 bytes em UTF-8; cortar por byte devolveria lixo.
        #expect(HostMark.rail("çãofinal") == "ÇÃO")
    }

    /// O caso que a Task Y existe para consertar: "hostinger" é o nome que a
    /// conta declara, e é ele — não o `id` "host" — que a trilha encurta.
    @Test("a trilha encurta o nome do provedor, não a chave interna da conta")
    func railMarkComesFromHostNotID() {
        let account = Account(
            id: "host", address: "contato@meusite.com",
            displayName: "Site", provider: .imap, host: "hostinger",
            tintLightHex: "#397852", tintDarkHex: "#88D1A2"
        )
        #expect(HostMark.rail(account.host) == "HOS")
        // Não basta olhar o resultado: "host" também começaria com "HOS".
        // O que prova a origem é a fonte ter o nome inteiro.
        #expect(account.host == "hostinger")
        #expect(account.host != account.id)
    }

    /// A barra expandida tem 248pt e mostra o nome inteiro. O encurtamento é
    /// só da trilha de 72 — se o modelo guardasse a versão curta, este teste
    /// não teria como distinguir os dois lugares.
    @Test("a conta entrega o nome inteiro; encurtar é escolha de quem desenha")
    @MainActor
    func modelKeepsWholeHost() async {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let hosts = store.accounts.map(\.host)
        #expect(hosts.contains("hostinger"))
        #expect(hosts.contains("host") == false)
    }

    @Test("a trilha fixa chama a mesma intenção de perguntar")
    @MainActor
    func railAssistantCallsItsClosure() async {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        var opens = 0

        CliqueDeEnsaio.em(
            SidebarRail(store: store, onOpenAssistant: { opens += 1 }),
            size: CGSize(width: SidebarRail.width, height: 620),
            aY: 580,
            x: SidebarRail.width / 2
        )

        #expect(opens == 1)
    }

    @Test("a trilha renderiza o botão de perguntas no rodapé")
    @MainActor
    func railRendersAssistantAction() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()

        let rep = try #require(Render.snapshot(
            SidebarRail(store: store),
            named: "m5-assistant-sidebar-rail",
            size: CGSize(width: SidebarRail.width, height: 620),
            theme: .tinta
        ))
        #expect(rep.pixelsHigh == 620)
    }
}
