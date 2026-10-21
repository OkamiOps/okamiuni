import Foundation
import UNICore

/// Onde ficam o IMAP, o SMTP e a API de uma caixa Zoho, por data center.
///
/// É o irmão de `ZohoDataCenter` para a **caixa de correio**: aquele resolve o
/// host de reunião (`meeting.zoho.eu`), este resolve os três que o e-mail
/// precisa. A base é a mesma e por isso o domínio vem de lá — manter duas
/// listas de data centers garantiria que uma delas ficaria para trás no dia em
/// que o Zoho abrir o próximo.
///
/// ## Os dois pares de hosts, e por que a escolha não é adivinhação limpa
///
/// A documentação do Zoho (`zoho.com/mail/help/imap-access.html` e
/// `zoho.com/mail/help/zoho-smtp.html`) divide assim:
///
/// - conta pessoal (`você@zohomail.com`, `você@zoho.com`) **e organização
///   gratuita** → `imap.zoho.<dc>` / `smtp.zoho.<dc>`
/// - organização **paga** com domínio próprio (`você@suaempresa.com`) →
///   `imappro.zoho.<dc>` / `smtppro.zoho.<dc>`
///
/// Note o "organização gratuita" do primeiro grupo: ele é o que impede a regra
/// de ser "domínio do Zoho → imap, domínio próprio → imappro". Uma organização
/// no plano gratuito tem domínio próprio e fala em `imap.zoho.com`, e a API de
/// contas não publica o plano. Por isso `candidates(for:)` devolve **os dois
/// na ordem mais provável** em vez de um só: quem adiciona a conta tenta o
/// primeiro, e o segundo quando o primeiro recusa. Escolher um e errar
/// mandaria a pessoa de volta para um formulário manual que o login por
/// navegador existe justamente para evitar.
public enum ZohoMailEndpoints {
    /// Os domínios que o Zoho usa para caixa **pessoal**. Um endereço nestes
    /// domínios nunca é organização com domínio próprio, então ele decide a
    /// ordem das tentativas sem margem de dúvida.
    public static let personalDomains: Set<String> = [
        "zoho.com", "zohomail.com", "zoho.eu", "zohomail.eu",
        "zoho.in", "zohomail.in", "zoho.com.au", "zoho.jp",
        "zohomail.ca", "zoho.sa", "zoho.uk", "zoho.com.cn",
    ]

    /// `https://accounts.zoho.eu` → `zoho.eu`. Nulo quando o accounts-server
    /// não é de um data center que conhecemos — e aí a conta falha com uma
    /// frase, em vez de tentar IMAP num host inventado.
    public static func dataCenterDomain(accountsServer: String) -> String? {
        guard let canonico = ZohoDataCenter.canonicalAccountsServer(accountsServer),
              let host = URL(string: canonico)?.host
        else { return nil }
        return ZohoDataCenter.domains.first { host == "accounts.\($0)" }
    }

    /// O IMAP de um data center. `organization` escolhe entre o par `pro` e o
    /// comum — ver a nota do tipo.
    public static func imap(accountsServer: String, organization: Bool) -> ImapEndpoint? {
        guard let dominio = dataCenterDomain(accountsServer: accountsServer) else { return nil }
        let prefixo = organization ? "imappro" : "imap"
        return ImapEndpoint(host: "\(prefixo).\(dominio)", port: 993, security: .tls)
    }

    /// O SMTP do mesmo data center, na 465 com TLS implícito — que é a porta
    /// que o Zoho documenta para SSL e a única em que o túnel já começa no
    /// primeiro byte, sem depender de um `STARTTLS` que alguém no meio possa
    /// tirar do EHLO.
    public static func smtp(accountsServer: String, organization: Bool) -> SmtpEndpoint? {
        guard let dominio = dataCenterDomain(accountsServer: accountsServer) else { return nil }
        let prefixo = organization ? "smtppro" : "smtp"
        return SmtpEndpoint(host: "\(prefixo).\(dominio)", port: 465, security: .tls)
    }

    /// O SMTP que corresponde a um IMAP já gravado.
    ///
    /// `SmtpDiscovery.endpoint(forImap:)` trocaria `imap.` por `smtp.` e
    /// acertaria a caixa pessoal por acaso — mas devolveria `smtp.imappro…`
    /// para a organização, que não existe. Esta função é a exceção do Zoho,
    /// e quem chama é o `MailboxAuthenticator`, não o `SmtpDiscovery`: a
    /// tabela de exceções de lá é por host literal e teria de listar um host
    /// por data center.
    public static func smtp(forImapHost host: String) -> SmtpEndpoint? {
        let limpo = host.trimmingCharacters(in: .whitespaces).lowercased()
        if limpo.hasPrefix("imappro.") {
            return SmtpEndpoint(host: "smtppro." + limpo.dropFirst("imappro.".count),
                                port: 465, security: .tls)
        }
        if limpo.hasPrefix("imap."), limpo.contains("zoho") {
            return SmtpEndpoint(host: "smtp." + limpo.dropFirst("imap.".count),
                                port: 465, security: .tls)
        }
        return nil
    }

    /// `https://mail.zoho.eu/api/` — a base da API REST da caixa, de onde sai
    /// o endereço de verdade da conta que acabou de autorizar.
    public static func apiBase(accountsServer: String) -> URL? {
        guard let dominio = dataCenterDomain(accountsServer: accountsServer) else { return nil }
        return URL(string: "https://mail.\(dominio)/api/")
    }

    /// Os dois IMAP candidatos, na ordem de tentar.
    ///
    /// Endereço em domínio do Zoho começa pelo comum; qualquer outro domínio
    /// começa pelo `pro`, que é o caso da organização paga — e a organização
    /// gratuita, que também tem domínio próprio, cai no segundo.
    public static func candidates(
        accountsServer: String, address: String
    ) -> [ImapEndpoint] {
        let dominio = ProviderDetector.domain(of: address) ?? ""
        let organizacao = !personalDomains.contains(dominio)
        return [
            imap(accountsServer: accountsServer, organization: organizacao),
            imap(accountsServer: accountsServer, organization: !organizacao),
        ].compactMap(\.self)
    }
}
