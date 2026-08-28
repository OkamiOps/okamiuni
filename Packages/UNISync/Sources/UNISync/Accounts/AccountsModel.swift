import Foundation
import Observation
import UNICore

/// O que a janela de Contas observa.
///
/// `@Observable` vem do módulo `Observation`, não do SwiftUI — este pacote
/// continua sem importar SwiftUI, como a arquitetura manda. É a mesma escolha
/// que o `MailStore` do `UNICore` já faz.
///
/// **Nada de estado em dois lugares.** O modelo não guarda cópia de conta
/// nenhuma: ele repassa as ações ao diretor e desenha o que o fluxo publicar.
/// O banco é a verdade; isto aqui é a janela dela.
@MainActor
@Observable
public final class AccountsModel {
    public private(set) var statuses: [AccountStatus] = []
    /// O erro da última ação que a **janela** disparou (adicionar, testar,
    /// remover). Separado do erro por conta: um teste de conta que ainda não
    /// existe não tem conta a que pertencer.
    public private(set) var lastError: SyncError?
    public private(set) var isBusy = false

    private let director: AccountDirector

    public init(director: AccountDirector) {
        self.director = director
    }

    /// Assina o diretor. Chamada uma vez, na montagem da cena.
    public func start() async {
        for await lista in await director.statuses() {
            statuses = lista
        }
    }

    public func addGoogle(address: String) async {
        await roda { _ = try await self.director.addGoogleAccount(address: address) }
    }

    /// Testa sem gravar. Devolve `true` quando passou, para a janela mostrar o
    /// resultado — e `lastError` explica quando não.
    @discardableResult
    public func testImap(address: String, password: String, endpoint: ImapEndpoint) async -> Bool {
        await roda {
            try await self.director.testImap(
                address: address, password: password, endpoint: endpoint
            )
        }
        return lastError == nil
    }

    public func addImap(
        address: String, password: String, endpoint: ImapEndpoint,
        hostMark: String, displayName: String
    ) async {
        await roda {
            let conta = try await self.director.addImapAccount(
                address: address, password: password, endpoint: endpoint,
                hostMark: hostMark, displayName: displayName
            )
            await self.director.loadInitial(accountID: conta.id)
        }
    }

    public func remove(_ accountID: String) async {
        await roda { try await self.director.remove(accountID: accountID) }
    }

    public func loadInitial(_ accountID: String) async {
        await director.loadInitial(accountID: accountID)
    }

    /// Uma ação, com o ocupado ligado e o erro capturado.
    ///
    /// O `catch` é largo de propósito e **não** engole: todo erro vira
    /// `lastError`, que a janela mostra. O que não pode acontecer é a janela
    /// ficar com o botão girando para sempre porque alguém lançou algo que não
    /// era `SyncError`.
    private func roda(_ acao: @escaping () async throws -> Void) async {
        isBusy = true
        lastError = nil
        do {
            try await acao()
        } catch let erro as SyncError {
            lastError = erro
        } catch {
            lastError = .rede(error.localizedDescription)
        }
        isBusy = false
    }
}
