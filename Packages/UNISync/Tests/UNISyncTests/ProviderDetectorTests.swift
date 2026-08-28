import Foundation
import Testing
import UNICore
@testable import UNISync

@Suite("Do endereço à rota")
struct ProviderDetectorTests {
    @Test("O domínio sai do endereço, dobrado e sem espaço em volta")
    func dominio() {
        #expect(ProviderDetector.domain(of: "  Ricardo@Gmail.COM ") == "gmail.com")
        #expect(ProviderDetector.domain(of: "contato@meusite.com.br") == "meusite.com.br")
        #expect(ProviderDetector.domain(of: "sem-arroba") == nil)
        #expect(ProviderDetector.domain(of: "@so-dominio.com") == nil)
        #expect(ProviderDetector.domain(of: "so-usuario@") == nil)
        // Dois arrobas não é endereço; a última parte não vira domínio.
        #expect(ProviderDetector.domain(of: "a@b@c.com") == nil)
    }

    @Test("Domínio do Google vai por OAuth")
    func rotaGoogle() {
        #expect(ProviderDetector.route(for: "ricardo@gmail.com") == .google)
        #expect(ProviderDetector.route(for: "ricardo@googlemail.com") == .google)
    }

    @Test("Domínio conhecido traz o preset preenchido")
    func rotaPreset() throws {
        let rota = try #require(ProviderDetector.route(for: "ricardo@icloud.com"))
        guard case .imap(let preset) = rota else {
            Issue.record("esperava .imap, veio \(rota)"); return
        }
        #expect(preset.hostMark == "icloud")
        #expect(preset.endpoint.host == "imap.mail.me.com")
        #expect(preset.endpoint.port == 993)
        #expect(preset.endpoint.security == .tls)
    }

    @Test("Domínio desconhecido não é recusado — vai para o formulário manual com sugestão")
    func rotaManual() throws {
        // Este é o teste que impede a tabela de virar porteiro. Um domínio
        // próprio, de hospedagem qualquer, tem de chegar ao formulário com
        // `imap.<domínio>:993` já digitado — palpite, não veredito.
        let rota = try #require(ProviderDetector.route(for: "eu@dominio-que-ninguem-conhece.xyz"))
        guard case .manual(let sugerido) = rota else {
            Issue.record("esperava .manual, veio \(rota)"); return
        }
        #expect(sugerido.host == "imap.dominio-que-ninguem-conhece.xyz")
        #expect(sugerido.port == 993)
        #expect(sugerido.security == .tls)
    }

    @Test("Endereço inválido não tem rota — o campo diz isso em vez de adivinhar")
    func semRota() {
        #expect(ProviderDetector.route(for: "") == nil)
        #expect(ProviderDetector.route(for: "ricardo") == nil)
        #expect(ProviderDetector.route(for: "ricardo@") == nil)
        #expect(!ProviderDetector.isValidAddress("ricardo@sem-ponto"))
        #expect(ProviderDetector.isValidAddress("ricardo@empresa.com"))
    }

    @Test("A tabela é aberta: nenhum domínio aparece em dois presets, e todos têm host e porta")
    func tabelaCoerente() {
        var vistos: Set<String> = []
        for preset in ImapPresets.all {
            #expect(!preset.name.isEmpty)
            #expect(!preset.hostMark.isEmpty)
            #expect(!preset.endpoint.host.isEmpty)
            #expect(preset.endpoint.port > 0)
            #expect(!preset.domains.isEmpty)
            for dominio in preset.domains {
                #expect(dominio == dominio.lowercased(), "domínio fora de caixa baixa: \(dominio)")
                #expect(vistos.insert(dominio).inserted, "domínio repetido em dois presets: \(dominio)")
            }
        }
    }

    @Test("A busca por domínio dobra a caixa")
    func buscaPorDominioDobraCaixa() {
        #expect(ImapPresets.preset(forDomain: "ICLOUD.COM")?.hostMark == "icloud")
        #expect(ImapPresets.preset(forDomain: "nao-existe.zzz") == nil)
    }
}
