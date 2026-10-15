import Foundation
import UNICore

/// O Meet, ligado ao OAuth Google que o app já usa para a caixa de correio.
///
/// É o único dos quatro que funciona hoje. Conectar aqui abre o **mesmo**
/// consentimento do Google da conta de e-mail, pedindo o escopo do Meet; a
/// conta que aparece na linha é a caixa Google que vai assinar as salas.
///
/// Zoom, Teams e Zoho esperam conectores irmãos deste — mesma assinatura, o
/// OAuth de cada um no lugar do Google. Ver `MeetingConnector`.
@MainActor
public final class GoogleMeetConnector: MeetingConnector {
    public let service: MeetingService = .meet

    private let auth: GoogleAuth?
    private let factory: MeetingRoomFactory?
    /// As caixas Google do app, lidas na hora: a lista muda enquanto a janela
    /// está aberta.
    private let googleAccounts: @MainActor () -> [Account]

    public init(
        auth: GoogleAuth?,
        factory: MeetingRoomFactory?,
        googleAccounts: @escaping @MainActor () -> [Account]
    ) {
        self.auth = auth
        self.factory = factory
        self.googleAccounts = googleAccounts
    }

    /// Sem client ID no build, não há OAuth Google nenhum — e o app inteiro já
    /// diz isso na janela de Contas.
    public var isAvailable: Bool {
        auth != nil && MeetingClientIDs.clientID(for: .meet) != nil
    }

    public func currentAccount() async -> String? {
        guard let auth else { return nil }
        for account in googleAccounts() {
            if await auth.hasMeetAccess(for: account.id) == true { return account.address }
        }
        return nil
    }

    public func connect() async throws -> String {
        guard let auth else { throw MeetingConnectorError.missingClientID(.meet) }
        guard let account = googleAccounts().first else {
            throw MeetingConnectorError.refused(
                L10n.tr("Conecte uma caixa Google em Contas — o Meet nasce do OAuth dela.")
            )
        }
        if let factory {
            try await factory.reconnectGoogle(accountID: account.id, loginHint: account.address)
        } else {
            _ = try await auth.connect(accountID: account.id, loginHint: account.address)
        }
        return account.address
    }

    /// O consentimento acontece numa sessão do navegador que o
    /// `GoogleAuth` controla; cancelar aqui é desistir da espera, e a tarefa
    /// cancelada já derruba a sessão.
    public func cancel() {}

    public func disconnect() async {
        guard let auth else { return }
        for account in googleAccounts() {
            try? await auth.revoke(accountID: account.id)
        }
    }
}
