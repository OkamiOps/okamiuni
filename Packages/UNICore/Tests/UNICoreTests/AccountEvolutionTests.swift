import Foundation
import Testing
@testable import UNICore

@Suite("Account e Message com os campos do Marco 2")
struct AccountEvolutionTests {
    @Test("Os campos novos são aditivos: as fixtures do Marco 1 continuam válidas")
    func fixturesIntactas() {
        for account in Fixtures.accounts {
            #expect(account.imap == nil)
            #expect(account.state == .ativa)
            #expect(account.lastSyncedAt == nil)
        }
        for message in Fixtures.messages {
            #expect(message.serverID == nil)
            #expect(message.uidValidity == nil)
        }
    }

    @Test("Uma conta IMAP guarda host, porta e forma de TLS")
    func contaImap() {
        let conta = Account(
            id: "novo", address: "eu@meudominio.com.br", displayName: "Meu",
            provider: .imap, host: "meudominio",
            tintLightHex: "#3F6AA1", tintDarkHex: "#8CBAF7",
            imap: ImapEndpoint(host: "imap.meudominio.com.br", port: 993, security: .tls)
        )
        #expect(conta.imap?.host == "imap.meudominio.com.br")
        #expect(conta.imap?.port == 993)
        #expect(conta.imap?.security == .tls)
        #expect(conta.state == .ativa)
    }

    @Test("Os copiadores preservam tudo o que não pediram para mudar")
    func copiadoresPreservam() {
        let base = Account(
            id: "novo", address: "eu@meudominio.com.br", displayName: "Meu",
            provider: .imap, host: "meudominio",
            tintLightHex: "#3F6AA1", tintDarkHex: "#8CBAF7",
            signature: "Eu",
            imap: ImapEndpoint(host: "imap.meudominio.com.br", port: 143, security: .startTLS)
        )
        let carregando = base.withState(.carregando)
        #expect(carregando.state == .carregando)
        #expect(carregando.signature == "Eu")
        #expect(carregando.imap?.security == .startTLS)
        #expect(carregando.address == base.address)

        let carimbada = carregando.withLastSynced(Date(timeIntervalSince1970: 1_800_000_000))
        #expect(carimbada.lastSyncedAt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(carimbada.state == .carregando)

        let semImap = carimbada.withImap(nil)
        #expect(semImap.imap == nil)
        #expect(semImap.lastSyncedAt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(semImap.sendAliases.isEmpty)
    }

    @Test("aliases extraem o principal, duplicata e o From padrão")
    func aliasesDeEnvio() {
        let aliases = SendAlias.normalized([
            SendAlias(address: "eu@meudominio.com.br", displayName: "Eu"),
            SendAlias(address: "financeiro@meudominio.com.br", displayName: "Financeiro", isDefault: true),
            SendAlias(address: "FINANCEIRO@meudominio.com.br", displayName: "Dup"),
            SendAlias(address: "invalido", displayName: "X"),
        ], excluding: "eu@meudominio.com.br")
        #expect(aliases.map(\.address) == ["financeiro@meudominio.com.br"])
        #expect(aliases.first?.isDefault == true)

        let conta = Account(
            id: "novo", address: "eu@meudominio.com.br", displayName: "Meu",
            provider: .imap, host: "meudominio",
            tintLightHex: "#725B9A", tintDarkHex: "#C2A7F4",
            sendAliases: aliases
        )
        #expect(conta.defaultSendAddress == "financeiro@meudominio.com.br")
        #expect(conta.sendIdentities.map(\.address) == [
            "eu@meudominio.com.br", "financeiro@meudominio.com.br",
        ])
        #expect(conta.withState(.carregando).sendAliases.count == 1)
    }

    @Test("Os ids de servidor da mensagem sobrevivem a mover, ler e sinalizar")
    func idsDeServidorSobrevivem() {
        let original = Message(
            id: "gmail:g:18f", accountID: "gmail",
            from: Contact(name: "Marina", address: "marina@x.com"),
            receivedAt: Date(timeIntervalSince1970: 1_800_000_000),
            subject: "Assunto", snippet: "Trecho", body: ["Corpo"],
            tags: [], bucket: .today, isRead: false,
            summary: nil, detectedEvent: nil,
            serverID: "18f0a1b2c3", uidValidity: 42
        )
        #expect(original.serverID == "18f0a1b2c3")
        #expect(original.uidValidity == 42)

        let arquivada = original.withBucket(.archived).withRead(true).withFlagged(true)
        #expect(arquivada.serverID == "18f0a1b2c3")
        #expect(arquivada.uidValidity == 42)
        #expect(arquivada.bucket == .archived)
    }

    @Test("`erroDeAutenticacao` é um estado, não um texto solto")
    func estadoDeErro() {
        #expect(Account.State(rawValue: "erroDeAutenticacao") == .erroDeAutenticacao)
        #expect(Account.State.allCases.count == 3)
    }
}
