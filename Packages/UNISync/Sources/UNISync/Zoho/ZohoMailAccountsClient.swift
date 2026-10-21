import Foundation
import UNICore

/// Quem é a caixa que acabou de autorizar.
///
/// `GET /api/accounts` no data center da conta, com o escopo
/// `ZohoMail.accounts.READ` (documentado em
/// `zoho.com/mail/help/api/get-all-users-accounts.html`). O que interessa daqui
/// são três campos de uma resposta enorme:
///
/// - `primaryEmailAddress`: o endereço **de verdade**. Sem ele o app teria de
///   acreditar no que a pessoa digitou antes de abrir o navegador, e quem
///   entrou com outra conta lá acabaria com a caixa de uma pendurada no id da
///   outra — o mesmo defeito que `AccountDirector.confereEndereco` evita na
///   reconexão do Google.
/// - `accountId`: o caminho de envio pela API REST
///   (`/api/accounts/{accountId}/messages`), que é a saída de quem não
///   conseguir o SMTP com XOAUTH2.
/// - `displayName`: o nome que a lista de contas mostra.
///
/// O que a resposta **não** traz é o plano da organização, que é justamente o
/// que decidiria entre `imap.zoho…` e `imappro.zoho…` — ver a nota de
/// `ZohoMailEndpoints`.
public struct ZohoMailAccount: Sendable, Hashable {
    public let accountID: String
    public let address: String
    public let displayName: String

    public init(accountID: String, address: String, displayName: String) {
        self.accountID = accountID
        self.address = address
        self.displayName = displayName
    }
}

public struct ZohoMailAccountsClient: Sendable {
    private let session: URLSession
    private let apiBase: URL
    /// O token vem pronto, e não de um cofre: nesta chamada a conta ainda
    /// **não existe** no app, então não há id com que consultar o
    /// `SecretStore`. Quem chama acabou de recebê-lo do consentimento.
    private let accessToken: String

    public init(session: URLSession, apiBase: URL, accessToken: String) {
        self.session = session
        self.apiBase = apiBase
        self.accessToken = accessToken
    }

    /// A conta principal da pessoa. A API devolve uma lista (uma caixa Zoho
    /// pode ter contas POP/IMAP externas conectadas), e a que interessa é a
    /// nativa — `type == "ZOHO_ACCOUNT"`. Sem nenhuma nativa, a primeira da
    /// lista; é o que resta, e é melhor que falhar depois de o consentimento
    /// já ter sido dado.
    public func primary() async throws -> ZohoMailAccount {
        var request = URLRequest(url: URL(string: "accounts", relativeTo: apiBase)!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // `Zoho-oauthtoken`, e não `Bearer`: é o esquema que o Zoho exige nas
        // APIs dele, e um `Bearer` correto volta `INVALID_OAUTHTOKEN`.
        request.setValue("Zoho-oauthtoken \(accessToken)", forHTTPHeaderField: "Authorization")

        let (dados, resposta) = try await session.data(for: request)
        guard let http = resposta as? HTTPURLResponse else {
            throw SyncError.resposta(L10n.tr("A API do Zoho respondeu sem cabeçalho HTTP."))
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw SyncError.autenticacao }
            throw SyncError.servidor(
                codigo: http.statusCode,
                mensagem: String(data: dados, encoding: .utf8) ?? L10n.tr("sem detalhe")
            )
        }

        struct Wire: Decodable {
            struct Conta: Decodable {
                let accountId: String?
                let primaryEmailAddress: String?
                let mailboxAddress: String?
                let incomingUserName: String?
                let displayName: String?
                let accountDisplayName: String?
                let type: String?
            }
            let data: [Conta]?
        }
        guard let fio = try? JSONDecoder().decode(Wire.self, from: dados),
              let contas = fio.data, !contas.isEmpty
        else {
            throw SyncError.resposta(
                L10n.tr("A API do Zoho devolveu a lista de contas num formato que não conhecemos.")
            )
        }
        let nativa = contas.first { $0.type?.uppercased() == "ZOHO_ACCOUNT" } ?? contas[0]
        guard let id = nativa.accountId,
              let endereco = nativa.primaryEmailAddress
                ?? nativa.mailboxAddress ?? nativa.incomingUserName
        else {
            throw SyncError.resposta(
                L10n.tr("A API do Zoho não disse qual é o endereço desta caixa.")
            )
        }
        return ZohoMailAccount(
            accountID: id,
            address: endereco,
            displayName: nativa.displayName ?? nativa.accountDisplayName ?? endereco
        )
    }
}
