import Foundation

public struct Account: Sendable, Hashable, Identifiable {
    /// Como o app conversa com o servidor — não quem é o provedor.
    ///
    /// `imap` é o caso geral e cobre qualquer provedor em qualquer domínio.
    /// `gmail` e `microsoft` existem só onde a API nativa rende sync melhor;
    /// uma conta desses dois continua funcionando por `imap`. Nunca tratar
    /// `imap` como exceção nem presumir que a lista de provedores é fechada.
    public enum Provider: String, Sendable, CaseIterable {
        case imap, gmail, microsoft
    }

    public let id: String
    public let address: String
    public let displayName: String
    public let provider: Provider
    /// Matiz OKLCH que o design dá a cada caixa, já convertida para sRGB.
    public let tintHex: String

    public init(
        id: String, address: String, displayName: String,
        provider: Provider, tintHex: String
    ) {
        self.id = id
        self.address = address
        self.displayName = displayName
        self.provider = provider
        self.tintHex = tintHex
    }

    /// O host que a linha da lista mostra em miúdo: "zoho", "gmail", ...
    public var host: String { id }
}
