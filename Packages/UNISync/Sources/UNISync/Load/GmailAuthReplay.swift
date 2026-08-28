import Foundation

/// O `GmailClient` com uma segunda chance: **um** 401 renova o token e repete
/// a chamada; o segundo 401 é revogação de verdade.
///
/// Por que existe, e por que aqui:
///
/// O `GoogleAuth` renova por **expiração local** — ele olha o relógio deste
/// computador e decide. Isso cobre o caso comum e deixa três de fora, todos
/// reais: relógio adiantado em relação ao Google, token revogado no painel da
/// conta no meio da carga, sessão encerrada por troca de senha. Nos três o
/// token continua "válido" para nós e o servidor devolve 401 — e uma carga de
/// noventa dias morria ali, com a conta caindo em `erroDeAutenticacao` e a
/// pessoa recebendo um "Reconectar" para um problema que um refresh resolvia.
///
/// **Por que um envoltório, e não dentro do `GmailClient`.** O cliente HTTP
/// conhece o token como uma closure opaca — ele pede um token, não sabe que
/// existe OAuth, refresh ou cofre. Ensiná-lo a renovar inverteria isso, e as
/// quatro chamadas dele repetiriam a mesma dança. **Por que não dentro do
/// `GoogleAuth`.** Ele nunca vê o 401: quem chama a Gmail API é o cliente, e
/// o `GoogleAuth` só fala com o servidor de token. **Por que não dentro do
/// `InitialLoader`.** Ali seria mais uma preocupação num tipo que já integra
/// quatro, e a carga incremental do Marco 3 teria de copiar a regra em vez de
/// herdá-la — a mesma razão que tirou a projeção de bandeiras de dentro do
/// laço.
///
/// **Uma tentativa, nunca duas.** Repetir mais faria um token de fato revogado
/// virar um laço de renovações que o Google trata como abuso, e a pessoa
/// esperaria em silêncio por uma reconexão que só ela pode fazer.
public struct GmailAuthReplay: Sendable {
    private let client: GmailClient
    /// Buscar um token **forçando** a renovação. Nulo quando não há quem
    /// renove (um cliente montado com token fixo, como nos testes do próprio
    /// `GmailClient`): aí o 401 é terminal na primeira, que é o comportamento
    /// que já existia.
    private let renew: (@Sendable () async throws -> Void)?

    public init(client: GmailClient, renew: (@Sendable () async throws -> Void)? = nil) {
        self.client = client
        self.renew = renew
    }

    public func profile() async throws -> GmailProfile {
        try await comReplay { try await client.profile() }
    }

    public func labels() async throws -> [GmailLabel] {
        try await comReplay { try await client.labels() }
    }

    public func messageIDs(query: String, pageToken: String?) async throws -> GmailPage {
        try await comReplay { try await client.messageIDs(query: query, pageToken: pageToken) }
    }

    public func message(id: String, format: GmailFormat) async throws -> GmailMessage {
        try await comReplay { try await client.message(id: id, format: format) }
    }

    /// A dança inteira, num lugar só.
    ///
    /// O segundo 401 vira `autorizacaoRevogada`, e não `autenticacao`, porque
    /// as duas frases pedem coisas diferentes: depois de um refresh bem
    /// sucedido, um 401 novo significa que a autorização morreu do lado do
    /// Google — reconectar é a única saída, e é isso que
    /// `autorizacaoRevogada` diz.
    private func comReplay<T>(_ chamada: @Sendable () async throws -> T) async throws -> T {
        do {
            return try await chamada()
        } catch SyncError.autenticacao {
            guard let renew else { throw SyncError.autenticacao }
            // Se a própria renovação falhar, o erro dela é o que vale: um
            // `invalid_grant` já é `autorizacaoRevogada`, e uma rede caída no
            // meio do refresh é `.rede` — que não pode virar "reconecte".
            try await renew()
            do {
                return try await chamada()
            } catch SyncError.autenticacao {
                throw SyncError.autorizacaoRevogada
            }
        }
    }
}
