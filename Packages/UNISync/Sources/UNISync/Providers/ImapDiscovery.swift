import Foundation
import UNICore
#if canImport(dnssd)
import dnssd
#endif

/// O que a descoberta achou para um domínio: onde fica o IMAP, onde fica o
/// SMTP quando alguém disse, e por que ela acredita nisso.
///
/// `origem` não é enfeite de relatório: ela é o que separa "o MX do domínio
/// aponta para o Zoho" — que é um fato — de "chutamos `imap.<domínio>`", que é
/// um chute. A janela preenche o campo nos dois casos, porque o campo continua
/// editável; o que muda é o que ela pode afirmar.
public struct ImapSuggestion: Sendable, Hashable {
    /// Onde ler a caixa.
    public let imap: ImapEndpoint
    /// Onde enviar, quando o autoconfig do provedor disse. `nil` deixa a
    /// derivação de sempre (`SmtpDiscovery`) no comando.
    ///
    /// **Ainda não é gravado.** A conta guarda um endpoint só — o de leitura —
    /// e o de envio é derivado dele a cada carga da fila; guardar este aqui
    /// pede uma coluna nova e uma migração, que é mudança de banco e não de
    /// descoberta. Enquanto isso, o que o autoconfig diz serve de conferência:
    /// `SmtpDiscovery.derivaHost` conhece os mesmos prefixos
    /// (`imappro.` → `smtppro.`, `imap.` → `smtp.`) e chega no mesmo host para
    /// todos os provedores da tabela acima.
    public let smtp: SmtpEndpoint?
    /// A marca que vai para `Account.host` e aparece no chip da lateral.
    public let hostMark: String?
    /// O domínio é servido pelo Google — o botão "Entrar com Google" é o
    /// caminho que tem chance de funcionar, porque o Workspace recusa senha no
    /// IMAP de quase toda conta corporativa.
    public let usaGoogle: Bool
    public let origem: Origem

    public enum Origem: String, Sendable, Hashable {
        /// O MX do domínio entregou a hospedagem.
        case mx
        /// O provedor publica Thunderbird autoconfig (ou está na ISPDB).
        case autoconfig
        /// `imap.<domínio>`, que é o que sempre foi.
        case palpite
    }

    public init(
        imap: ImapEndpoint,
        smtp: SmtpEndpoint? = nil,
        hostMark: String? = nil,
        usaGoogle: Bool = false,
        origem: Origem
    ) {
        self.imap = imap
        self.smtp = smtp
        self.hostMark = hostMark
        self.usaGoogle = usaGoogle
        self.origem = origem
    }
}

/// Quem sabe responder "quais são os MX deste domínio?".
///
/// Protocolo, e não uma função livre, para o teste não precisar de rede: a
/// tabela MX → servidor é lógica pura, e é ela que erra ou acerta. A consulta
/// de verdade mora em `SystemMXLookup`, que é a única parte daqui que fala com
/// o mundo.
public protocol MXLookup: Sendable {
    /// Os hosts dos registros MX, **já na ordem de preferência**. Vazio quando
    /// o domínio não tem MX, quando a consulta falhou ou quando ela estourou o
    /// tempo — os três dão no mesmo para quem chama: seguir para o próximo
    /// método.
    func hosts(for domain: String, timeout: Duration) async -> [String]
}

/// De onde sai o servidor de leitura quando a pessoa só digitou o endereço.
///
/// ## Por que isto existe
///
/// O palpite antigo era `imap.<domínio>` e mais nada. Ele acerta em servidor
/// próprio de hospedagem comum e **erra em todo domínio delegado**, que é o
/// caso mais frequente hoje: quem põe o domínio no Zoho lê em
/// `imappro.zoho.com` (não em `imap.meudominio.com.br`, que nem resolve); no
/// Google, em `imap.gmail.com`; no Microsoft 365, em `outlook.office365.com`.
/// O formulário então mostrava um host que não existe, o teste falhava em
/// "servidor encontrado", e a pessoa concluía que o app não aceita a conta
/// dela.
///
/// ## A ordem, e por que ela é esta
///
/// 1. **MX.** É a única fonte que diz, sem pedir nada à pessoa, *quem hospeda
///    aquele domínio* — e quem hospeda o correio hospeda o IMAP. Custa uma
///    consulta de DNS, que é o passo mais barato dos três.
/// 2. **Autoconfig (Thunderbird).** Quando o MX não está na tabela, o próprio
///    provedor pode publicar a resposta em `autoconfig.<domínio>`; a ISPDB da
///    Mozilla cobre os que não publicam. Isto custa HTTP, por isso vem depois.
/// 3. **O palpite.** `imap.<domínio>:993`, que é o que sempre foi — agora como
///    último recurso, e não como única hipótese.
///
/// Nada disto é porteiro: o resultado **preenche** host, porta e TLS, e os três
/// continuam editáveis. A mesma regra de `ImapPresets`.
public enum ImapDiscovery {
    /// Como a descoberta busca um XML. Injetável pela mesma razão do
    /// `MXLookup`: o parse é lógica pura e o teste não deve abrir soquete.
    /// Devolve `nil` em qualquer falha — não há nada de útil a dizer sobre um
    /// autoconfig que não respondeu.
    public typealias Baixa = @Sendable (URL) async -> Data?

    // MARK: - A descoberta inteira

    /// Descobre o servidor do endereço. `nil` quando o texto ainda não é um
    /// endereço — não há domínio sobre o que perguntar.
    ///
    /// Nunca lança e nunca trava mais que `timeout` por etapa: quem chama é um
    /// campo de texto, e um campo de texto que espera DNS não é um campo de
    /// texto.
    public static func suggest(
        for address: String,
        mx: any MXLookup = SystemMXLookup(),
        baixa: @escaping Baixa = baixaPelaRede,
        timeout: Duration = .seconds(2)
    ) async -> ImapSuggestion? {
        guard ProviderDetector.isValidAddress(address),
              let dominio = ProviderDetector.domain(of: address) else { return nil }

        let registros = await mx.hosts(for: dominio, timeout: timeout)
        for host in registros {
            if let achado = hospedagem(deMX: host) { return achado }
        }

        if let achado = await porAutoconfig(
            address: address, domain: dominio, mx: registros.first, baixa: baixa
        ) {
            return achado
        }

        return palpite(para: dominio)
    }

    /// `imap.<domínio>:993` em TLS — o que o formulário sempre escreveu
    /// sozinho, agora com nome e lugar na fila.
    public static func palpite(para dominio: String) -> ImapSuggestion {
        ImapSuggestion(
            imap: ImapEndpoint(host: "imap.\(dominio)", port: 993, security: .tls),
            hostMark: dominio.split(separator: ".").first.map(String.init),
            origem: .palpite
        )
    }

    // MARK: - 1. O MX

    /// O servidor de leitura de quem é atendido por este MX. `nil` quando a
    /// tabela não reconhece o host — inclusive de propósito para os filtros de
    /// borda (Proofpoint, Mimecast, Barracuda), que recebem o correio de fora
    /// e **não** são onde a caixa mora: mapeá-los mandaria a pessoa para um
    /// servidor que não tem a caixa dela.
    public static func hospedagem(deMX host: String) -> ImapSuggestion? {
        let mx = normaliza(host)
        guard !mx.isEmpty else { return nil }

        // O Zoho primeiro, e por regra em vez de lista: ele tem um data center
        // por região (`mx.zoho.com`, `.eu`, `.in`, `.com.au`, `.jp`, `.ca`,
        // `.sa`) e a caixa só responde na região em que foi criada. E **conta
        // de domínio próprio usa `imappro`**, não `imap`: `imap.zoho.com` é o
        // host das contas pessoais `@zoho.com`, e é ele que recusa o login de
        // quem tem domínio — o sintoma que começou esta mudança.
        if let regiao = regiaoDoZoho(mx) {
            return ImapSuggestion(
                imap: ImapEndpoint(host: "imappro.zoho.\(regiao)", port: 993, security: .tls),
                smtp: SmtpEndpoint(host: "smtppro.zoho.\(regiao)", port: 587, security: .startTLS),
                hostMark: "zoho",
                origem: .mx
            )
        }

        for (sufixos, fabrica) in tabelaDeMX {
            guard sufixos.contains(where: { casa(mx, $0) }) else { continue }
            return fabrica()
        }
        return nil
    }

    /// `mx.zoho.eu` → `eu`; `mx2.zoho.com.au` → `com.au`. `nil` para o que não
    /// é Zoho.
    static func regiaoDoZoho(_ mx: String) -> String? {
        guard let faixa = mx.range(of: ".zoho.") else { return nil }
        let regiao = String(mx[faixa.upperBound...])
        return regiao.isEmpty ? nil : regiao
    }

    /// Os sufixos de MX que a gente sabe de cor, e onde eles leem.
    ///
    /// Sufixo, e não host exato: todo provedor publica vários MX numerados
    /// (`mx1`, `alt2`, `in1`) e o que identifica a hospedagem é o fim do nome.
    private static let tabelaDeMX: [(sufixos: [String], fabrica: @Sendable () -> ImapSuggestion)] = [
        (["l.google.com", "googlemail.com", "google.com"], {
            ImapSuggestion(
                imap: ImapEndpoint(host: "imap.gmail.com", port: 993, security: .tls),
                smtp: SmtpEndpoint(host: "smtp.gmail.com", port: 587, security: .startTLS),
                hostMark: "gmail",
                // O Workspace recusa senha no IMAP de quase toda conta
                // corporativa (a tal "acesso de app menos seguro", que acabou).
                // Preencher o host sem dizer isto deixaria a pessoa testando
                // uma senha que nunca vai passar.
                usaGoogle: true,
                origem: .mx
            )
        }),
        (["mail.protection.outlook.com", "outlook.com", "hotmail.com"], {
            ImapSuggestion(
                imap: ImapEndpoint(host: "outlook.office365.com", port: 993, security: .tls),
                smtp: SmtpEndpoint(host: "smtp.office365.com", port: 587, security: .startTLS),
                hostMark: "outlook",
                origem: .mx
            )
        }),
        (["titan.email"], {
            ImapSuggestion(
                imap: ImapEndpoint(host: "imap.titan.email", port: 993, security: .tls),
                smtp: SmtpEndpoint(host: "smtp.titan.email", port: 587, security: .startTLS),
                hostMark: "titan",
                origem: .mx
            )
        }),
        (["hostinger.com", "hostinger.com.br"], {
            ImapSuggestion(
                imap: ImapEndpoint(host: "imap.hostinger.com", port: 993, security: .tls),
                hostMark: "hostinger",
                origem: .mx
            )
        }),
        (["locaweb.com.br", "locaweb.com"], {
            ImapSuggestion(
                imap: ImapEndpoint(host: "imap.locaweb.com.br", port: 993, security: .tls),
                hostMark: "locaweb",
                origem: .mx
            )
        }),
        (["uol.com.br", "bol.com.br"], {
            ImapSuggestion(
                imap: ImapEndpoint(host: "imap.uol.com.br", port: 993, security: .tls),
                hostMark: "uol",
                origem: .mx
            )
        }),
        (["secureserver.net", "godaddy.com"], {
            ImapSuggestion(
                imap: ImapEndpoint(host: "imap.secureserver.net", port: 993, security: .tls),
                hostMark: "secureserver",
                origem: .mx
            )
        }),
        (["yahoodns.net"], {
            ImapSuggestion(
                imap: ImapEndpoint(host: "imap.mail.yahoo.com", port: 993, security: .tls),
                hostMark: "yahoo",
                origem: .mx
            )
        }),
        (["icloud.com", "me.com", "mac.com", "apple.com"], {
            ImapSuggestion(
                imap: ImapEndpoint(host: "imap.mail.me.com", port: 993, security: .tls),
                hostMark: "icloud",
                origem: .mx
            )
        }),
        (["messagingengine.com", "fastmail.com"], {
            ImapSuggestion(
                imap: ImapEndpoint(host: "imap.fastmail.com", port: 993, security: .tls),
                hostMark: "fastmail",
                origem: .mx
            )
        }),
        (["yandex.net", "yandex.ru"], {
            ImapSuggestion(
                imap: ImapEndpoint(host: "imap.yandex.com", port: 993, security: .tls),
                hostMark: "yandex",
                origem: .mx
            )
        }),
    ]

    /// Host igual ao sufixo, ou terminando em `.sufixo` — e nunca um sufixo
    /// de texto solto: `naogoogle.com` não casa com `google.com`.
    static func casa(_ host: String, _ sufixo: String) -> Bool {
        host == sufixo || host.hasSuffix("." + sufixo)
    }

    static func normaliza(_ host: String) -> String {
        var limpo = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while limpo.hasSuffix(".") { limpo.removeLast() }
        return limpo
    }

    // MARK: - 2. Autoconfig

    /// As URLs que a descoberta tenta, nesta ordem.
    ///
    /// **O endereço só vai para o servidor do próprio domínio.** A ISPDB da
    /// Mozilla recebe o domínio e nada mais — é o que o Thunderbird faz, e
    /// mandar o endereço inteiro para um terceiro para descobrir uma porta
    /// seria pagar com dado de quem usa.
    static func urlsDeAutoconfig(address: String, domain: String, mx: String?) -> [URL] {
        var urls: [URL] = []
        let endereco = address.addingPercentEncoding(
            withAllowedCharacters: .alphanumerics
        ) ?? address
        if let url = URL(string: "https://autoconfig.\(domain)/mail/config-v1.1.xml?emailaddress=\(endereco)") {
            urls.append(url)
        }
        if let url = URL(string: "https://autoconfig.thunderbird.net/v1.1/\(domain)") {
            urls.append(url)
        }
        // O domínio do MX na ISPDB: um domínio próprio cujo MX aponta para um
        // provedor que a tabela acima não tem ainda costuma estar lá pelo nome
        // do provedor (`zoho.com`, `titan.email`), não pelo do cliente.
        if let mx, let base = dominioBase(de: mx), base != domain,
           let url = URL(string: "https://autoconfig.thunderbird.net/v1.1/\(base)") {
            urls.append(url)
        }
        return urls
    }

    /// `mx1.titan.email` → `titan.email`. Dois rótulos, que é o bastante para
    /// a ISPDB; `co.uk` e companhia dariam `co.uk`, e a consulta volta vazia —
    /// custo de uma requisição que não acha nada, não de um erro.
    static func dominioBase(de host: String) -> String? {
        let partes = normaliza(host).split(separator: ".")
        guard partes.count >= 2 else { return nil }
        return partes.suffix(2).joined(separator: ".")
    }

    private static func porAutoconfig(
        address: String, domain: String, mx: String?, baixa: @escaping Baixa
    ) async -> ImapSuggestion? {
        for url in urlsDeAutoconfig(address: address, domain: domain, mx: mx) {
            guard let dados = await baixa(url) else { continue }
            if let achado = autoconfig(dados, hostMark: domain.split(separator: ".").first.map(String.init)) {
                return achado
            }
        }
        return nil
    }

    /// Lê um `clientConfig` do Thunderbird e devolve o `incomingServer` de IMAP
    /// (mais o `outgoingServer`, quando há). `nil` quando o XML não traz um
    /// IMAP utilizável — inclusive quando traz um em texto claro: o app não
    /// abre sessão sem TLS, e preencher o campo com um host que ele vai se
    /// recusar a usar seria mentir no formulário.
    public static func autoconfig(_ dados: Data, hostMark: String? = nil) -> ImapSuggestion? {
        let leitor = AutoconfigReader()
        let parser = XMLParser(data: dados)
        parser.delegate = leitor
        guard parser.parse() else { return nil }
        guard let imap = leitor.imap else { return nil }
        return ImapSuggestion(
            imap: imap, smtp: leitor.smtp, hostMark: hostMark, origem: .autoconfig
        )
    }

    // MARK: - A rede, a única parte que não é pura

    /// `GET` de 2 segundos, sem cache e sem corpo grande. Redirecionamento é
    /// o normal aqui (muito provedor serve o autoconfig de outro host), e por
    /// isso nada é desligado.
    public static let baixaPelaRede: Baixa = { url in
        var pedido = URLRequest(url: url)
        pedido.timeoutInterval = 2
        pedido.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (dados, resposta) = try? await URLSession.shared.data(for: pedido),
              let http = resposta as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              dados.count < 256 * 1024 else { return nil }
        return dados
    }
}

/// Os outros hosts que valem uma tentativa quando o primeiro recusou.
///
/// **Por que tentar sozinho em vez de dar o erro.** O caso que motivou isto é
/// o Zoho: `imap.zoho.com` é o host das contas pessoais `@zoho.com` e
/// `imappro.zoho.com` é o das contas de domínio próprio, os dois existem, os
/// dois atendem na 993 com TLS, e o errado responde à conexão e **recusa o
/// login**. Para quem está na frente da tela isso é idêntico a senha errada —
/// e a pessoa passa a tarde trocando uma senha que estava certa. Tentar o
/// vizinho custa uma conexão e responde a pergunta.
///
/// A lista é curta de propósito: cada item é uma conexão a mais antes do erro
/// aparecer, e um formulário que demora dez segundos para dizer "não deu" é
/// pior que um que erra rápido.
public enum ImapFallbacks {
    /// No máximo três — ver a nota acima.
    public static let teto = 3

    public static func alternativas(para endpoint: ImapEndpoint) -> [ImapEndpoint] {
        let host = ImapDiscovery.normaliza(endpoint.host)
        var hosts: [String] = []

        if let regiao = ImapDiscovery.regiaoDoZoho(host) {
            // O par da mesma região primeiro: trocar de data center muda a
            // conta de lugar, trocar `imap`/`imappro` muda só o tipo dela.
            hosts.append(host.hasPrefix("imappro.") ? "imap.zoho.\(regiao)" : "imappro.zoho.\(regiao)")
            for outra in ["com", "eu", "in", "com.au"] where outra != regiao {
                hosts.append("imappro.zoho.\(outra)")
            }
        } else if host.hasPrefix("imap.") {
            // O palpite genérico tem dois vizinhos clássicos em hospedagem
            // compartilhada: `mail.<domínio>` (cPanel, Plesk) e o domínio
            // pelado, que muito provedor pequeno usa para tudo.
            let resto = String(host.dropFirst("imap.".count))
            hosts.append("mail.\(resto)")
            hosts.append(resto)
        }

        return hosts
            .filter { $0 != host && !$0.isEmpty }
            .prefix(teto)
            .map { ImapEndpoint(host: $0, port: endpoint.port, security: endpoint.security) }
    }

    /// Esta falha vale uma segunda tentativa noutro host?
    ///
    /// Credencial recusada e servidor que não respondeu, sim — são as duas
    /// caras de "é o host que está errado". Erro de Keychain, de banco ou de
    /// quota, não: trocar de host não muda nada neles, e a espera seria pura.
    public static func valePorOutroHost(_ erro: SyncError) -> Bool {
        switch erro {
        case .autenticacao, .loginRecusado, .rede, .tls: true
        default: false
        }
    }
}

// MARK: - O leitor do XML

/// O delegado do `XMLParser` que recolhe os dois servidores.
///
/// Classe e não struct porque é isto que o `XMLParser` exige; `@unchecked
/// Sendable` não aparece aqui porque ela nunca atravessa tarefa — nasce,
/// trabalha e morre dentro de `ImapDiscovery.autoconfig`.
private final class AutoconfigReader: NSObject, XMLParserDelegate {
    private(set) var imap: ImapEndpoint?
    private(set) var smtp: SmtpEndpoint?

    private var dentro: String?
    private var tipo: String?
    private var host: String?
    private var porta: Int?
    private var socket: String?
    private var texto = ""

    func parser(
        _ parser: XMLParser, didStartElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        texto = ""
        switch elementName {
        case "incomingServer", "outgoingServer":
            dentro = elementName
            tipo = attributeDict["type"]?.lowercased()
            host = nil; porta = nil; socket = nil
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        texto += string
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?
    ) {
        let valor = texto.trimmingCharacters(in: .whitespacesAndNewlines)
        texto = ""
        switch elementName {
        case "hostname": host = valor.lowercased()
        case "port": porta = Int(valor)
        case "socketType": socket = valor.lowercased()
        case "incomingServer":
            if tipo == "imap", let endpoint = fecha() { imap = imap ?? endpoint }
            dentro = nil
        case "outgoingServer":
            if tipo == "smtp", let endpoint = fecha() {
                smtp = smtp ?? SmtpEndpoint(
                    host: endpoint.host, port: endpoint.port, security: endpoint.security
                )
            }
            dentro = nil
        default: break
        }
    }

    /// O par host/porta do bloco que acabou, se ele der um canal cifrado.
    ///
    /// `SSL` é TLS implícito (993, 465); `STARTTLS` é o outro; `plain` e o
    /// ausente ficam de fora — ver a nota em `ImapDiscovery.autoconfig`.
    private func fecha() -> ImapEndpoint? {
        guard let host, !host.isEmpty, let porta, porta > 0 else { return nil }
        let seguranca: ImapEndpoint.Security
        switch socket {
        case "ssl", "tls": seguranca = .tls
        case "starttls": seguranca = .startTLS
        default: return nil
        }
        return ImapEndpoint(host: host, port: porta, security: seguranca)
    }
}

// MARK: - A consulta de MX de verdade

/// A consulta de MX pelo resolvedor do sistema (`dnssd`, o mesmo
/// mDNSResponder que o resto do macOS usa).
///
/// `dnssd` e não `res_query` da libresolv: aquele exigiria linkar `resolv` e
/// ler `/etc/resolv.conf` por fora, e não enxerga as configurações de DNS por
/// interface que o macOS tem — VPN ligada, resolvedor por domínio. O
/// mDNSResponder já resolve tudo isso e é quem o sistema inteiro consulta.
public struct SystemMXLookup: MXLookup {
    public init() {}

    public func hosts(for domain: String, timeout: Duration) async -> [String] {
        #if canImport(dnssd)
        let limpo = ImapDiscovery.normaliza(domain)
        guard !limpo.isEmpty else { return [] }
        let segundos = Double(timeout.components.seconds)
            + Double(timeout.components.attoseconds) / 1e18
        return await withCheckedContinuation { continuacao in
            // Fora da fila cooperativa: o laço abaixo bloqueia numa `poll`, e
            // bloquear uma thread do pool de Swift Concurrency é como se
            // prende o app inteiro.
            DispatchQueue.global(qos: .userInitiated).async {
                continuacao.resume(returning: Self.consulta(limpo, segundos: segundos))
            }
        }
        #else
        return []
        #endif
    }

    #if canImport(dnssd)
    /// Uma caixa para o callback em C escrever — ele recebe um ponteiro, não
    /// um closure com contexto.
    private final class Resultado {
        var registros: [(preferencia: UInt16, host: String)] = []
    }

    private static func consulta(_ domain: String, segundos: Double) -> [String] {
        let caixa = Resultado()
        var referencia: DNSServiceRef?
        let contexto = Unmanaged.passUnretained(caixa).toOpaque()

        let abriu = DNSServiceQueryRecord(
            &referencia, 0, 0, domain,
            UInt16(kDNSServiceType_MX), UInt16(kDNSServiceClass_IN),
            { _, _, _, erro, _, _, _, tamanho, dados, _, contexto in
                guard erro == kDNSServiceErr_NoError,
                      let contexto, let dados, tamanho > 2 else { return }
                let caixa = Unmanaged<Resultado>.fromOpaque(contexto).takeUnretainedValue()
                let bytes = [UInt8](
                    UnsafeRawBufferPointer(start: dados, count: Int(tamanho))
                )
                if let registro = MXRecord.leia(bytes) { caixa.registros.append(registro) }
            },
            contexto
        )
        guard abriu == kDNSServiceErr_NoError, let referencia else { return [] }
        defer { DNSServiceRefDeallocate(referencia) }

        let descritor = DNSServiceRefSockFD(referencia)
        guard descritor >= 0 else { return [] }

        let fim = Date().addingTimeInterval(segundos)
        // Depois da primeira resposta, dá uma última espiada curta: um domínio
        // com vários MX os entrega em chamadas separadas do callback, e parar
        // no primeiro descartaria a ordem de preferência.
        var sobra = 0.15
        while Date() < fim {
            var canal = pollfd(fd: descritor, events: Int16(POLLIN), revents: 0)
            let espera = caixa.registros.isEmpty ? 200 : Int32(sobra * 1000)
            let pronto = poll(&canal, 1, espera)
            if pronto < 0 { break }
            if pronto == 0 {
                if !caixa.registros.isEmpty { break }
                continue
            }
            if DNSServiceProcessResult(referencia) != kDNSServiceErr_NoError { break }
            if !caixa.registros.isEmpty { sobra = 0.05 }
        }
        return caixa.registros
            .sorted { $0.preferencia < $1.preferencia }
            .map(\.host)
    }
    #endif
}

/// O RDATA de um registro MX, que é onde o nome do servidor mora.
///
/// Separado e `internal` porque é **lógica pura sobre bytes** — a única parte
/// da consulta de DNS que dá para testar sem rede, e a única onde um erro de
/// um byte vira um host silenciosamente errado.
enum MXRecord {
    /// `[preferência de 16 bits][nome em rótulos][0]`, na forma do RFC 1035.
    ///
    /// Ponteiro de compressão (`0xC0`) faz a leitura desistir: ele aponta para
    /// um deslocamento da **mensagem inteira**, que não chega até aqui — o
    /// `dnssd` entrega só o RDATA. Desistir devolve `nil` e a descoberta segue
    /// para o autoconfig; adivinhar devolveria um host truncado.
    static func leia(_ bytes: [UInt8]) -> (preferencia: UInt16, host: String)? {
        guard bytes.count > 3 else { return nil }
        let preferencia = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        var rotulos: [String] = []
        var i = 2
        while i < bytes.count {
            let tamanho = Int(bytes[i])
            if tamanho == 0 {
                guard !rotulos.isEmpty else { return nil }
                return (preferencia, rotulos.joined(separator: "."))
            }
            if tamanho & 0xC0 != 0 { return nil }
            let inicio = i + 1
            let fim = inicio + tamanho
            guard fim <= bytes.count else { return nil }
            guard let rotulo = String(bytes: bytes[inicio..<fim], encoding: .utf8) else {
                return nil
            }
            rotulos.append(rotulo.lowercased())
            i = fim
        }
        return nil
    }
}
