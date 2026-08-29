import Foundation
import UNICore

/// Por onde falar com a conta que a pessoa acabou de digitar.
public enum ProviderRoute: Sendable, Hashable {
    /// Domínio do Google: OAuth, com a Gmail API por cima.
    case google
    /// Domínio conhecido: IMAP com o preset já preenchido.
    case imap(ImapPreset)
    /// Qualquer outro domínio: IMAP com o formulário aberto e um palpite.
    ///
    /// **Este é o caso geral**, não a exceção. `suggested` é chute — host,
    /// porta e TLS ficam editáveis, e é a pessoa que decide.
    case manual(suggested: ImapEndpoint)
}

public enum ProviderDetector {
    /// Os domínios que o Google atende com a conta pessoal.
    ///
    /// Note o que **não** está aqui: nenhum domínio de Google Workspace. Uma
    /// empresa com o Gmail atrás do domínio próprio cai em `.manual`, digita o
    /// IMAP do Google e funciona. Tentar adivinhar Workspace pelo domínio
    /// exigiria consultar MX, que é rede no caminho da digitação — e errar
    /// mandaria a pessoa para um consentimento OAuth que o domínio dela não
    /// aceita, que é pior do que um formulário.
    private static let googleDomains: Set<String> = ["gmail.com", "googlemail.com"]

    /// O domínio, em caixa baixa. Nulo quando não é um endereço.
    public static func domain(of address: String) -> String? {
        let limpo = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let partes = limpo.split(separator: "@", omittingEmptySubsequences: false)
        guard partes.count == 2 else { return nil }
        guard !partes[0].isEmpty, !partes[1].isEmpty else { return nil }
        return String(partes[1])
    }

    /// Serve como endereço? Um ponto no domínio é o piso — `eu@localhost` não
    /// é o caso que este app atende, e aceitá-lo mandaria a pessoa para um
    /// formulário que nunca ligaria em lugar nenhum.
    public static func isValidAddress(_ address: String) -> Bool {
        guard let dominio = domain(of: address) else { return false }
        guard dominio.contains(".") else { return false }
        guard !dominio.hasPrefix("."), !dominio.hasSuffix(".") else { return false }
        return true
    }

    /// A rota. Nulo quando o texto ainda não é um endereço — o campo mostra
    /// isso em vez de propor uma rota inventada.
    public static func route(for address: String) -> ProviderRoute? {
        guard isValidAddress(address), let dominio = domain(of: address) else { return nil }
        if googleDomains.contains(dominio) { return .google }
        if let preset = ImapPresets.preset(forDomain: dominio) { return .imap(preset) }
        return .manual(suggested: ImapEndpoint(host: "imap.\(dominio)", port: 993, security: .tls))
    }
}
