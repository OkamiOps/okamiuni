import Foundation
@testable import UNISync

/// Guarda a última requisição de CLI recebida e devolve uma saída válida no
/// formato de cada CLI da allowlist, para testar o roteador sem abrir
/// processos de verdade.
actor RecordingAssistantCLIExecutor: AssistantCLIProcessExecuting {
    private(set) var lastRequest: AssistantCLIProcessRequest?
    private let output: AssistantCLIKind

    init(output: AssistantCLIKind) {
        self.output = output
    }

    func execute(_ request: AssistantCLIProcessRequest) async throws -> AssistantCLIProcessResult {
        lastRequest = request
        return .init(exitStatus: 0, standardOutput: Data(responseBody.utf8))
    }

    private var responseBody: String {
        switch output {
        case .codex:
            """
            {"type":"item.completed","item":{"type":"agent_message","text":"Resposta via Codex."}}
            """
        case .claude:
            """
            {"type":"result","is_error":false,"result":"Resposta via sessão Claude."}
            """
        case .openCode:
            """
            {"type":"text","text":"Resposta via OpenCode."}
            """
        }
    }
}

/// Fingimento de assinatura sempre presente e sempre pronta a devolver um
/// token: cobre o caminho de sucesso sem tocar o Keychain nem o coordenador
/// real de OAuth.
struct AlwaysAuthorizedProviderOAuth: AssistantProviderOAuthTokenProviding {
    func hasAccessToken(for configuration: AssistantProviderOAuthConfiguration) async -> Bool {
        true
    }

    func accessToken(for configuration: AssistantProviderOAuthConfiguration) async throws -> String? {
        "token"
    }
}

/// Contador simples e thread-safe para provar quantas vezes o disco foi
/// varrido — o mesmo padrão usado em `CachedAssistantCLIDiscoveryTests`.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func bump() { lock.withLock { count += 1 } }
}
