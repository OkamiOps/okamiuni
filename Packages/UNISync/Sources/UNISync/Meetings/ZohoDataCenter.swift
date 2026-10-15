import Foundation

/// Em qual data center do Zoho a conta mora.
///
/// **O detalhe que mais quebra integração Zoho.** A conta de uma pessoa na
/// Europa não existe em `zoho.com`: ela vive em `zoho.eu`, e um token nascido
/// lá é recusado aqui. O login diz qual é — o callback traz `location` e
/// `accounts-server` — e a partir daí **tudo** (troca do código, renovação,
/// criação da sala) tem de ir para o mesmo lugar. Trocar o `.eu` pelo `.com`
/// no meio do caminho dá `invalid_code` ou `INVALID_OAUTHTOKEN`, sem dizer o
/// motivo.
///
/// Os nomes são os data centers publicados pelo Zoho. `zohocloud.ca` é a
/// exceção que impede o mapeamento ingênuo "troque o TLD": o domínio inteiro
/// muda, não só o sufixo. Daí a lista explícita.
public enum ZohoDataCenter {
    /// O que vem **depois** de `accounts.` num accounts-server válido.
    public static let domains = [
        "zoho.com",
        "zoho.eu",
        "zoho.in",
        "zoho.com.au",
        "zoho.jp",
        "zohocloud.ca",
        "zoho.sa",
        "zoho.uk",
        "zoho.com.cn",
    ]

    /// `https://accounts.zoho.eu` → `meeting.zoho.eu`.
    ///
    /// Aceita o accounts-server com ou sem esquema, porque o Zoho manda com
    /// (`https://accounts.zoho.eu`) e um cadastro feito à mão pode não ter.
    /// Devolve `nil` quando o domínio não é um data center conhecido — e aí a
    /// chamada falha com uma frase, em vez de postar uma sala num host
    /// inventado.
    public static func meetingHost(accountsServer: String) -> String? {
        guard let host = normalizedHost(accountsServer) else { return nil }
        guard let domain = domains.first(where: { host == "accounts.\($0)" }) else { return nil }
        return "meeting.\(domain)"
    }

    /// A base da API de reunião do data center, pronta para `URL(string:relativeTo:)`.
    public static func meetingAPIBase(accountsServer: String) -> URL? {
        guard let host = meetingHost(accountsServer: accountsServer) else { return nil }
        return URL(string: "https://\(host)/api/v2/")
    }

    /// O accounts-server normalizado para guardar no cofre:
    /// `https://accounts.zoho.eu`, sem barra no fim.
    public static func canonicalAccountsServer(_ raw: String) -> String? {
        guard let host = normalizedHost(raw),
              domains.contains(where: { host == "accounts.\($0)" })
        else { return nil }
        return "https://\(host)"
    }

    private static func normalizedHost(_ raw: String) -> String? {
        var texto = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !texto.isEmpty else { return nil }
        if !texto.contains("://") { texto = "https://" + texto }
        guard let url = URL(string: texto), let host = url.host, !host.isEmpty else { return nil }
        return host
    }
}
