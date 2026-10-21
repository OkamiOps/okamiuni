import Foundation
import Testing
import UNICore
@testable import UNISync

/// O MX diz quem hospeda; quem hospeda diz onde fica o IMAP.
///
/// Tudo aqui é puro: a consulta de DNS e o `GET` do autoconfig entram
/// injetados, e é de propósito — o que erra ou acerta nesta história é a
/// tabela e o parse, não o socket.
@Suite("Descoberta do servidor de leitura")
struct ImapDiscoveryTests {
    // MARK: A tabela de MX

    @Test("Domínio próprio no Zoho lê em imappro, e na região do próprio MX")
    func zohoPorRegiao() throws {
        // Este é o caso que começou a mudança. `imap.zoho.com` existe, atende
        // na 993 e **recusa** a conta de domínio próprio — que é
        // indistinguível de senha errada para quem está na frente da tela.
        let brasil = try #require(ImapDiscovery.hospedagem(deMX: "mx.zoho.com"))
        #expect(brasil.imap.host == "imappro.zoho.com")
        #expect(brasil.imap.port == 993)
        #expect(brasil.imap.security == .tls)
        #expect(brasil.smtp?.host == "smtppro.zoho.com")
        #expect(brasil.origem == .mx)

        // A região sai do próprio MX, e não de uma lista de domínios: a conta
        // só responde no data center em que foi criada.
        #expect(ImapDiscovery.hospedagem(deMX: "mx2.zoho.eu")?.imap.host == "imappro.zoho.eu")
        #expect(ImapDiscovery.hospedagem(deMX: "mx.zoho.in")?.imap.host == "imappro.zoho.in")
        #expect(
            ImapDiscovery.hospedagem(deMX: "mx3.zoho.com.au.")?.imap.host == "imappro.zoho.com.au"
        )
    }

    @Test("MX do Google manda para o IMAP do Gmail e acende a oferta do OAuth")
    func google() throws {
        for mx in ["aspmx.l.google.com", "ALT1.ASPMX.L.GOOGLE.COM", "aspmx2.googlemail.com"] {
            let achado = try #require(ImapDiscovery.hospedagem(deMX: mx))
            #expect(achado.imap.host == "imap.gmail.com")
            // Sem isto, a folha preencheria um host que o Workspace recusa em
            // quase toda conta corporativa e deixaria a pessoa testando uma
            // senha que nunca vai passar.
            #expect(achado.usaGoogle)
        }
    }

    @Test("Os outros provedores da tabela, pelo sufixo do MX")
    func outrosProvedores() {
        let casos: [(String, String)] = [
            ("empresa-com-br.mail.protection.outlook.com", "outlook.office365.com"),
            ("mx1.titan.email", "imap.titan.email"),
            ("mx1.hostinger.com", "imap.hostinger.com"),
            ("mx.locaweb.com.br", "imap.locaweb.com.br"),
            ("mx.uol.com.br", "imap.uol.com.br"),
            ("mailstore1.secureserver.net", "imap.secureserver.net"),
            ("mta5.am0.yahoodns.net", "imap.mail.yahoo.com"),
            ("in1-smtp.messagingengine.com", "imap.fastmail.com"),
            ("mx01.mail.icloud.com", "imap.mail.me.com"),
        ]
        for (mx, esperado) in casos {
            #expect(ImapDiscovery.hospedagem(deMX: mx)?.imap.host == esperado, "\(mx)")
        }
    }

    @Test("Filtro de borda não vira servidor de caixa")
    func filtrosNaoEntram() {
        // Proofpoint, Mimecast e companhia **recebem** o correio e o entregam
        // adiante; a caixa mora noutro lugar. Mapeá-los mandaria a pessoa a um
        // servidor que não tem mensagem nenhuma dela.
        for mx in ["mx1.pphosted.com", "br-smtp-inbound-1.mimecast.com", "cluster.barracudanetworks.com"] {
            #expect(ImapDiscovery.hospedagem(deMX: mx) == nil, "\(mx)")
        }
    }

    @Test("Sufixo é rótulo inteiro, nunca pedaço de texto")
    func sufixoNaoEhSubstring() {
        // `naogoogle.com` não é do Google, e um `hasSuffix` solto diria que é.
        #expect(ImapDiscovery.casa("aspmx.l.google.com", "google.com"))
        #expect(ImapDiscovery.casa("google.com", "google.com"))
        #expect(!ImapDiscovery.casa("naogoogle.com", "google.com"))
    }

    // MARK: O autoconfig do Thunderbird

    @Test("O autoconfig entrega host, porta e forma de TLS — do IMAP e do SMTP")
    func autoconfigCompleto() throws {
        let xml = Data("""
        <?xml version="1.0"?>
        <clientConfig version="1.1">
          <emailProvider id="exemplo.com.br">
            <incomingServer type="pop3">
              <hostname>pop.exemplo.com.br</hostname><port>995</port>
              <socketType>SSL</socketType>
            </incomingServer>
            <incomingServer type="imap">
              <hostname>Imap.Exemplo.com.br</hostname><port>993</port>
              <socketType>SSL</socketType>
            </incomingServer>
            <outgoingServer type="smtp">
              <hostname>smtp.exemplo.com.br</hostname><port>587</port>
              <socketType>STARTTLS</socketType>
            </outgoingServer>
          </emailProvider>
        </clientConfig>
        """.utf8)

        let achado = try #require(ImapDiscovery.autoconfig(xml, hostMark: "exemplo"))
        // O `pop3` que vem antes não pode ser confundido com o IMAP.
        #expect(achado.imap.host == "imap.exemplo.com.br")
        #expect(achado.imap.port == 993)
        #expect(achado.imap.security == .tls)
        #expect(achado.smtp?.host == "smtp.exemplo.com.br")
        #expect(achado.smtp?.security == .startTLS)
        #expect(achado.origem == .autoconfig)
    }

    @Test("Autoconfig sem TLS não preenche campo nenhum")
    func autoconfigEmClaroNaoVale() {
        // O app não abre sessão sem canal cifrado. Escrever o host assim mesmo
        // seria preencher o formulário com um servidor que ele vai recusar.
        let xml = Data("""
        <clientConfig><emailProvider id="x.com"><incomingServer type="imap">
        <hostname>imap.x.com</hostname><port>143</port><socketType>plain</socketType>
        </incomingServer></emailProvider></clientConfig>
        """.utf8)
        #expect(ImapDiscovery.autoconfig(xml) == nil)
        #expect(ImapDiscovery.autoconfig(Data("isto não é xml".utf8)) == nil)
    }

    @Test("O endereço completo só vai para o servidor do próprio domínio")
    func privacidadeDoAutoconfig() throws {
        let urls = ImapDiscovery.urlsDeAutoconfig(
            address: "contato@meusite.com.br", domain: "meusite.com.br", mx: "mx1.titan.email"
        ).map(\.absoluteString)

        #expect(urls.count == 3)
        #expect(urls[0].hasPrefix("https://autoconfig.meusite.com.br/"))
        #expect(urls[0].contains("contato"))
        // A ISPDB da Mozilla é um terceiro: ela recebe o domínio, e nada mais.
        #expect(urls[1] == "https://autoconfig.thunderbird.net/v1.1/meusite.com.br")
        #expect(urls[2] == "https://autoconfig.thunderbird.net/v1.1/titan.email")
        #expect(!urls[1].contains("contato"))
        #expect(!urls[2].contains("contato"))
    }

    // MARK: Os bytes do registro MX

    @Test("O RDATA de um MX vira preferência e host")
    func rdata() throws {
        // 10, depois `mx` (2) + `zoho` (4) + `com` (3) + fim.
        let bytes: [UInt8] = [0, 10]
            + [2, 0x6D, 0x78]
            + [4, 0x7A, 0x6F, 0x68, 0x6F]
            + [3, 0x63, 0x6F, 0x6D]
            + [0]
        let lido = try #require(MXRecord.leia(bytes))
        #expect(lido.preferencia == 10)
        #expect(lido.host == "mx.zoho.com")
    }

    @Test("RDATA truncado ou comprimido não vira host pela metade")
    func rdataRuim() {
        // Ponteiro de compressão (`0xC0`) aponta para a mensagem inteira, que
        // não chega até aqui. Desistir manda a descoberta para o autoconfig;
        // adivinhar devolveria um host truncado, que é pior.
        #expect(MXRecord.leia([0, 10, 0xC0, 0x0C]) == nil)
        // Rótulo que promete 9 bytes e só tem 2.
        #expect(MXRecord.leia([0, 10, 9, 0x6D, 0x78]) == nil)
        #expect(MXRecord.leia([0, 10]) == nil)
    }

    // MARK: A descoberta inteira, com a rede fingida

    @Test("MX primeiro: achando ali, nenhum HTTP acontece")
    func ordemComMX() async throws {
        let http = Contagem()
        let achado = await ImapDiscovery.suggest(
            for: "financeiro@meusite.com.br",
            mx: LookupFixo(["mx.zoho.com"]),
            baixa: { _ in await http.mais(); return nil }
        )
        #expect(achado?.imap.host == "imappro.zoho.com")
        #expect(achado?.origem == .mx)
        #expect(await http.total == 0)
    }

    @Test("MX desconhecido cai no autoconfig")
    func ordemComAutoconfig() async throws {
        let xml = Data("""
        <clientConfig><emailProvider id="meusite.com.br"><incomingServer type="imap">
        <hostname>mail.servidor-da-hospedagem.net</hostname><port>993</port>
        <socketType>SSL</socketType></incomingServer></emailProvider></clientConfig>
        """.utf8)
        let achado = await ImapDiscovery.suggest(
            for: "financeiro@meusite.com.br",
            mx: LookupFixo(["mx.hospedagem-desconhecida.net"]),
            baixa: { _ in xml }
        )
        #expect(achado?.imap.host == "mail.servidor-da-hospedagem.net")
        #expect(achado?.origem == .autoconfig)
    }

    @Test("Sem MX e sem autoconfig, sobra o palpite de sempre — e ele não é erro")
    func ordemComPalpite() async throws {
        let achado = await ImapDiscovery.suggest(
            for: "financeiro@meusite.com.br", mx: LookupFixo([]), baixa: { _ in nil }
        )
        #expect(achado?.imap.host == "imap.meusite.com.br")
        #expect(achado?.imap.port == 993)
        #expect(achado?.origem == .palpite)
    }

    @Test("Texto que ainda não é endereço não vira consulta nenhuma")
    func semEndereco() async {
        #expect(await ImapDiscovery.suggest(
            for: "contato@", mx: LookupFixo(["mx.zoho.com"]), baixa: { _ in nil }
        ) == nil)
    }

    // MARK: Os dublês

    private struct LookupFixo: MXLookup {
        let hosts: [String]
        init(_ hosts: [String]) { self.hosts = hosts }
        func hosts(for domain: String, timeout: Duration) async -> [String] { hosts }
    }

    private actor Contagem {
        private(set) var total = 0
        func mais() { total += 1 }
    }
}

/// Quando o primeiro host recusa, qual é o vizinho que vale uma tentativa.
@Suite("Os hosts alternativos")
struct ImapFallbacksTests {
    @Test("Zoho: o par imap/imappro da mesma região vem primeiro")
    func zoho() {
        let hosts = ImapFallbacks.alternativas(
            para: ImapEndpoint(host: "imap.zoho.com", port: 993, security: .tls)
        ).map(\.host)
        #expect(hosts.first == "imappro.zoho.com")
        #expect(hosts.count <= ImapFallbacks.teto)

        // E o caminho de volta, para quem digitou `imappro` numa conta pessoal.
        let volta = ImapFallbacks.alternativas(
            para: ImapEndpoint(host: "imappro.zoho.eu", port: 993, security: .tls)
        ).map(\.host)
        #expect(volta.first == "imap.zoho.eu")
        #expect(volta.contains("imappro.zoho.com"))
    }

    @Test("Palpite genérico tenta os dois vizinhos de hospedagem compartilhada")
    func hospedagemComum() {
        let hosts = ImapFallbacks.alternativas(
            para: ImapEndpoint(host: "imap.meusite.com.br", port: 993, security: .startTLS)
        )
        #expect(hosts.map(\.host) == ["mail.meusite.com.br", "meusite.com.br"])
        // Porta e forma de TLS são as que a pessoa escolheu: a alternativa é
        // de **host**, e trocar a porta junto seria adivinhar duas coisas.
        #expect(hosts.allSatisfy { $0.port == 993 && $0.security == .startTLS })
    }

    @Test("Host que já é o servidor do provedor não ganha alternativa inventada")
    func semAlternativa() {
        for host in ["outlook.office365.com", "mail.empresa.com", "127.0.0.1"] {
            #expect(ImapFallbacks.alternativas(
                para: ImapEndpoint(host: host, port: 993, security: .tls)
            ).isEmpty, "\(host)")
        }
    }

    @Test("Só as falhas que mudam de figura com outro host valem a segunda ida")
    func quaisErrosValem() {
        #expect(ImapFallbacks.valePorOutroHost(.autenticacao))
        #expect(ImapFallbacks.valePorOutroHost(.loginRecusado(resposta: "NO")))
        #expect(ImapFallbacks.valePorOutroHost(.rede("sem rota")))
        #expect(ImapFallbacks.valePorOutroHost(.tls("nome não confere")))
        // Keychain e banco não melhoram em outro servidor; a espera seria pura.
        #expect(!ImapFallbacks.valePorOutroHost(.keychain(status: -25_300)))
        #expect(!ImapFallbacks.valePorOutroHost(.quota))
        #expect(!ImapFallbacks.valePorOutroHost(.banco("disco cheio")))
    }
}
