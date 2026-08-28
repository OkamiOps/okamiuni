import CryptoKit
import Foundation

/// O par do PKCE (RFC 7636), método S256.
///
/// **É o que substitui o segredo do cliente.** Um app de desktop é público por
/// definição: qualquer pessoa abre o `.app` e lê um segredo embutido. O PKCE
/// troca o segredo fixo por um segredo **por autorização** — o `verifier`
/// nasce aleatório, só o `challenge` (o hash dele) atravessa o navegador, e a
/// troca do código exige o `verifier`, que nunca saiu do processo.
public struct PKCEPair: Sendable, Hashable {
    public let verifier: String
    public let challenge: String

    /// Determinístico, para o teste poder usar o vetor do RFC.
    public static func make(from bytes: [UInt8]) -> PKCEPair {
        let verifier = base64URL(Data(bytes))
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return PKCEPair(verifier: verifier, challenge: base64URL(Data(digest)))
    }

    public static func random() -> PKCEPair {
        make(from: randomBytes(count: 32))
    }

    /// Um token opaco aleatório em base64url — a mesma fonte de entropia do
    /// `verifier`, para o `state` do fluxo OAuth (`GoogleAuth.connect`) não
    /// abrir uma segunda rota de aleatoriedade no pacote com `UUID`, que é
    /// pensado para unicidade e não para imprevisibilidade criptográfica.
    public static func randomToken(byteCount: Int = 16) -> String {
        base64URL(Data(randomBytes(count: byteCount)))
    }

    /// Bytes do gerador aleatório do sistema.
    ///
    /// `SecRandomCopyBytes` só falha se o gerador do sistema falhar; se
    /// falhar, não há como continuar com segurança, e mascarar com
    /// `arc4random` seria fingir que houve entropia.
    private static func randomBytes(count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "O gerador aleatório do sistema falhou (\(status)).")
        return bytes
    }

    /// base64 com o alfabeto de URL e sem `=` — o RFC exige os três ajustes.
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
