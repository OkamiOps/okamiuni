import Foundation
import UNICore

/// Quem decide **como** uma conta IMAP se apresenta ao servidor.
///
/// Antes deste tipo, cinco lugares do pacote faziam a mesma coisa copiada —
/// ler o segredo da conta, exigir que fosse `.password`, mandar `LOGIN`:
/// a carga inicial, o ciclo de sincronização, a fila de saída, a leitura de
/// corpo por demanda e a busca do agente. Acrescentar uma segunda forma de
/// autenticar em cinco cópias é garantir cinco comportamentos diferentes no
/// primeiro erro — uma das cópias esqueceria de renovar o token, e a conta
/// cairia sozinha uma hora depois só naquele caminho.
///
/// A regra é uma e mora aqui: **o cofre decide**. Segredo `.password` fala
/// `LOGIN`; segredo `.oauth` com data center guardado fala `AUTHENTICATE
/// XOAUTH2`, renovando o token antes se ele já venceu. Nada no banco diz qual
/// é qual, e de propósito: a credencial é do Keychain, e duplicá-la numa
/// coluna criaria um segundo lugar onde a resposta pode estar errada.
public struct MailboxAuthenticator: Sendable {
    private let secrets: any SecretStore
    /// Nulo quando o build não tem as credenciais do Zoho. Uma conta Zoho por
    /// OAuth não existiria nesse build — e se existir (o app foi atualizado
    /// para um build sem as credenciais), ela falha dizendo isso em vez de
    /// mandar um token vazio.
    private let zoho: ZohoMailAuth?

    public init(secrets: any SecretStore, zoho: ZohoMailAuth? = nil) {
        self.secrets = secrets
        self.zoho = zoho
    }

    /// Como esta conta se autentica, sem tocar na rede.
    public enum Forma: Sendable, Hashable {
        case senha
        case xoauth2
    }

    /// A forma que o cofre indica. Lança quando não há segredo nenhum —
    /// `.autenticacao`, que a janela traduz em "Reconectar".
    ///
    /// Síncrono e sem rede de propósito: quem abre conexão pergunta **antes**
    /// de abrir o socket, que é a ordem que `addImapAccount` já seguia — abrir
    /// uma conexão para descobrir que não há credencial é trabalho jogado fora
    /// e um socket a mais na conta de quem está sem rede.
    public func forma(for accountID: String) throws -> Forma {
        switch try secrets.secret(for: accountID) {
        case .password: .senha
        case .oauth(let tokens) where tokens.isZohoMail: .xoauth2
        // `.oauth` do Google numa conta IMAP não existe hoje (a conta Google
        // fala pela API do Gmail, não por IMAP) e não vale inventar: dizer
        // `.autenticacao` manda reconectar, que é a saída certa.
        default: throw SyncError.autenticacao
        }
    }

    /// Autentica a sessão IMAP já conectada.
    ///
    /// No caminho OAuth, uma recusa dispara **um** replay: renova o token e
    /// tenta de novo, uma vez só. É o mesmo remédio do replay pós-401 do
    /// Gmail (`GoogleAuth.renewedAccessToken`), e existe pelo mesmo motivo —
    /// o token no cofre pode estar morto do lado do servidor enquanto este
    /// Mac ainda o considera válido: relógio adiantado, sessão encerrada no
    /// painel da conta, token revogado no meio da carga. Sem o replay, uma
    /// diferença de relógio derrubaria a conta para a faixa de "Reconectar".
    ///
    /// **Uma vez só.** Duas renovações seguidas que falham não são azar: é o
    /// refresh token morto, e repetir só adiaria a frase que a pessoa precisa
    /// ler.
    public func login(_ session: ImapSession, accountID: String, address: String) async throws {
        switch try secrets.secret(for: accountID) {
        case .password(let senha):
            try await session.login(user: address, password: senha)
        case .oauth(let tokens) where tokens.isZohoMail:
            guard let zoho else { throw SyncError.semClientID }
            let token = try await zoho.accessToken(for: accountID)
            do {
                try await session.authenticateXOAuth2(user: address, accessToken: token)
            } catch let erro as SyncError where Self.credencialRecusada(erro) {
                let novo = try await zoho.renewedAccessToken(for: accountID)
                try await session.authenticateXOAuth2(user: address, accessToken: novo)
            }
        default:
            throw SyncError.autenticacao
        }
    }

    /// O IMAP devolve a recusa como `.loginRecusado` quando o servidor diz
    /// alguma coisa (a frase vai para a tela), e como `.autenticacao` quando
    /// não diz nada. Para o replay as duas são a mesma notícia: o token não
    /// serviu, e vale renovar uma vez antes de desistir.
    static func credencialRecusada(_ erro: SyncError) -> Bool {
        switch erro {
        case .autenticacao, .loginRecusado: true
        default: false
        }
    }

    /// A mesma decisão do outro lado: o envio.
    public func login(_ session: SmtpSession, accountID: String, address: String) async throws {
        switch try secrets.secret(for: accountID) {
        case .password(let senha):
            try await session.login(user: address, password: senha)
        case .oauth(let tokens) where tokens.isZohoMail:
            guard let zoho else { throw SyncError.semClientID }
            // O consentimento que caiu na lista de reserva não tem o escopo
            // de SMTP, e tentar mesmo assim devolveria "credencial recusada"
            // — a frase que manda a pessoa trocar uma senha que não existe.
            // Dizer a causa de verdade é o mínimo enquanto o envio pela API
            // REST da caixa não existe.
            guard tokens.canSendOverZohoSMTP else {
                throw SyncError.resposta(L10n.tr(
                    "Esta conta Zoho foi autorizada sem o escopo de envio por SMTP. Conecte-a de novo pelo botão Entrar com Zoho."
                ))
            }
            let token = try await zoho.accessToken(for: accountID)
            do {
                try await session.loginXOAuth2(user: address, accessToken: token)
            } catch SyncError.autenticacao {
                let novo = try await zoho.renewedAccessToken(for: accountID)
                try await session.loginXOAuth2(user: address, accessToken: novo)
            }
        default:
            throw SyncError.autenticacao
        }
    }

    /// De onde esta conta envia.
    ///
    /// A derivação comum (`SmtpDiscovery`) troca `imap.` por `smtp.` e
    /// acertaria a caixa Zoho pessoal por acaso — mas devolveria
    /// `smtp.imappro.zoho.com` para a organização, que não existe. A exceção
    /// do Zoho tem dono (`ZohoMailEndpoints.smtp(forImapHost:)`) e é
    /// consultada primeiro; todo o resto segue como sempre seguiu.
    public static func smtp(forImap imap: ImapEndpoint?) -> SmtpEndpoint? {
        guard let imap else { return nil }
        if let zoho = ZohoMailEndpoints.smtp(forImapHost: imap.host) { return zoho }
        return SmtpDiscovery.endpoint(forImap: imap)
    }
}
