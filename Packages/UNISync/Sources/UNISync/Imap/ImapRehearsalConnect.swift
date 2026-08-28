import Foundation
import NIOCore
import UNICore

extension ImapEndpoint {
    /// O host é a **própria máquina**?
    ///
    /// Comparação exata, e nunca por sufixo: `evil-localhost.com` e
    /// `127.0.0.1.evil.com` são nomes que qualquer um registra, e um `hasSuffix`
    /// os deixaria passar por casa. É esta função que decide se a conexão em
    /// claro do ensaio é permitida, então ela é a tranca — e tranca que aceita
    /// sufixo não é tranca.
    public static func ehLoopback(_ host: String) -> Bool {
        ["127.0.0.1", "::1", "[::1]", "localhost"]
            .contains(host.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// O host é um **endereço literal**, e não um nome?
    ///
    /// Uma pergunta, uma resposta, dois consumidores: `ImapSession.sni` — que
    /// devolve `nil` aqui, e com isso perde a verificação de nome do certificado
    /// — e o `AddAccountForm`, que mostra a nota dizendo isso à pessoa. Escritas
    /// em dois lugares, as duas divergiriam, e a nota apareceria onde não há
    /// perda ou (pior) faltaria onde há.
    ///
    /// IP literal continua sendo host **permitido**: servidor interno acessível
    /// só por endereço existe, e recusá-lo trocaria um enfraquecimento por uma
    /// impossibilidade. O que ele deixa de ser é silencioso.
    public static func ehIPLiteral(_ host: String) -> Bool {
        let limpo = host.trimmingCharacters(in: .whitespaces)
        // IPv6 vem com dois-pontos, com ou sem colchetes; nome de host nunca
        // tem dois-pontos (a porta viaja em campo próprio).
        if limpo.contains(":") { return true }
        let partes = limpo.split(separator: ".", omittingEmptySubsequences: false)
        return partes.count == 4 && partes.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }
}

// A porta insegura **não existe em Release**.
//
// Confinar o entitlement `network.server` ao Debug fechou a escuta e deixou a
// saída aberta: uma API pública que fala IMAP em claro compilava para o binário
// que sai para o mundo, ao alcance de qualquer importador do módulo. Endurecer
// de um lado só não endurece. Com o `#if DEBUG`, a promessa "produção sempre
// TLS" volta a ser fato do compilador — em Release o símbolo não existe, e
// quem o chamasse não compilaria.
//
// `ehLoopback` fica de fora do guarda de propósito: é uma função pura sobre uma
// string, não abre conexão nenhuma, e serve a quem precisar decidir o mesmo em
// qualquer configuração.
#if DEBUG
extension ImapSession {
    /// A única porta pública que fala IMAP **em claro** — e só com a própria
    /// máquina, e só em Debug.
    ///
    /// ## Por que ela existe
    ///
    /// `connect(endpoint:group:)` não tem como pedir conexão insegura: a
    /// promessa "produção sempre TLS" é do compilador, e assim deve continuar.
    /// Mas o ensaio `--ensaiar-contas` roda **no alvo de produção**, contra um
    /// servidor falso em `127.0.0.1` que não tem certificado nenhum — e gerar,
    /// instalar e confiar num certificado só para provar um fluxo que não é
    /// sobre TLS trocaria uma prova por uma cerimônia.
    ///
    /// A promessa que se mantém é a que importa: **nenhuma credencial sai
    /// desta máquina em claro**. Quem garante isso não é mais o `internal`, é a
    /// guarda de `ehLoopback` — explícita, testada, e que lança em vez de
    /// degradar em silêncio. Qualquer host que não seja a própria máquina bate
    /// aqui e morre com `.tls`.
    public static func connectForRehearsal(
        endpoint: ImapEndpoint,
        group: any EventLoopGroup
    ) async throws -> ImapSession {
        guard ImapEndpoint.ehLoopback(endpoint.host) else {
            throw SyncError.tls(
                "A conexão de ensaio só fala com 127.0.0.1 — \(endpoint.host) foi recusado."
            )
        }
        return try await connect(
            endpoint: endpoint, group: group, allowInsecure: true, teto: .seconds(10)
        )
    }
}
#endif
