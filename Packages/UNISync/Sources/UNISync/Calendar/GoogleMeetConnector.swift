import Foundation
import UNICore

/// O Meet, ligado ao OAuth Google que o app já usa para a caixa de correio.
///
/// Cada caixa Google é uma conta de Meet. Conectar de novo autoriza a
/// próxima que ainda não cria sala; quando todas já criam, `addAccount` abre
/// o navegador para a pessoa entrar com outra conta Google. Desconectar tira
/// **aquela** caixa da lista do Meet e não revoga o e-mail das outras — o
/// token é o mesmo da caixa, e revogar apagaria a correspondência.
@MainActor
public final class GoogleMeetConnector: MeetingConnector {
    public let service: MeetingService = .meet

    private static let hiddenKey = "okamiuni.meet.hiddenAccounts"

    private let auth: GoogleAuth?
    private let factory: MeetingRoomFactory?
    /// As caixas Google do app, lidas na hora: a lista muda enquanto a janela
    /// está aberta.
    private let googleAccounts: @MainActor () -> [Account]
    /// Abre o consentimento de uma conta Google que ainda não está no app.
    /// Devolve o endereço que entrou.
    private let addAccount: (() async throws -> String)?
    private let defaults: UserDefaults
    /// Endereços que acabaram de entrar e a lista de caixas ainda não viu.
    private var remembered: [String] = []

    public init(
        auth: GoogleAuth?,
        factory: MeetingRoomFactory?,
        googleAccounts: @escaping @MainActor () -> [Account],
        addAccount: (() async throws -> String)? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.auth = auth
        self.factory = factory
        self.googleAccounts = googleAccounts
        self.addAccount = addAccount
        self.defaults = defaults
    }

    /// Sem client ID no build, não há OAuth Google nenhum — e o app inteiro já
    /// diz isso na janela de Contas.
    public var isAvailable: Bool {
        auth != nil && MeetingClientIDs.clientID(for: .meet) != nil
    }

    public func currentAccount() async -> String? {
        await accounts().first
    }

    public func accounts() async -> [String] {
        guard let auth else { return [] }
        let ocultas = hiddenAddresses()
        var lista: [String] = []
        for account in googleAccounts() {
            if ocultas.contains(account.address.lowercased()) { continue }
            if await auth.hasMeetAccess(for: account.id) == true {
                lista.append(account.address)
            }
        }
        for address in remembered {
            if ocultas.contains(address.lowercased()) { continue }
            if lista.contains(where: { $0.caseInsensitiveCompare(address) == .orderedSame }) {
                continue
            }
            // A caixa já está na lista e não tem Meet: não reaparece por memória.
            if googleAccounts().contains(where: { $0.address.caseInsensitiveCompare(address) == .orderedSame }) {
                continue
            }
            lista.append(address)
        }
        return lista
    }

    public func connect() async throws -> String {
        guard let auth else { throw MeetingConnectorError.missingClientID(.meet) }
        let ocultas = hiddenAddresses()
        for account in googleAccounts() {
            if ocultas.contains(account.address.lowercased()) { continue }
            // Só `false` pede o consentimento desta caixa. `nil` é a consulta
            // que falhou: tratar como "falta Meet" prenderia o botão na mesma
            // conta para sempre e a pessoa nunca chegaria no seletor.
            if await auth.hasMeetAccess(for: account.id) != false { continue }
            try await authorize(account)
            unhide(account.address)
            remember(account.address)
            return account.address
        }
        guard let addAccount else {
            throw MeetingConnectorError.refused(
                L10n.tr("Conecte uma caixa Google em Contas — o Meet nasce do OAuth dela.")
            )
        }
        let address = try await addAccount()
        unhide(address)
        remember(address)
        return address
    }

    /// O consentimento acontece numa sessão do navegador que o
    /// `GoogleAuth` controla; cancelar aqui é desistir da espera, e a tarefa
    /// cancelada já derruba a sessão.
    public func cancel() {}

    /// Tira todas as contas da lista do Meet. Não revoga o OAuth: isso
    /// apagaria a caixa de correio junto.
    public func disconnect() async {
        for address in await accounts() {
            hide(address)
        }
        remembered.removeAll()
    }

    public func disconnect(account: String) async {
        hide(account)
        remembered.removeAll { $0.caseInsensitiveCompare(account) == .orderedSame }
    }

    private func authorize(_ account: Account) async throws {
        if let factory {
            try await factory.reconnectGoogle(accountID: account.id, loginHint: account.address)
        } else if let auth {
            _ = try await auth.connect(accountID: account.id, loginHint: account.address)
        }
    }

    private func remember(_ address: String) {
        guard !remembered.contains(where: { $0.caseInsensitiveCompare(address) == .orderedSame }) else {
            return
        }
        remembered.append(address)
    }

    private func hiddenAddresses() -> Set<String> {
        Set((defaults.stringArray(forKey: Self.hiddenKey) ?? []).map { $0.lowercased() })
    }

    private func hide(_ address: String) {
        var conjunto = hiddenAddresses()
        conjunto.insert(address.lowercased())
        defaults.set(Array(conjunto).sorted(), forKey: Self.hiddenKey)
    }

    private func unhide(_ address: String) {
        var conjunto = hiddenAddresses()
        conjunto.remove(address.lowercased())
        defaults.set(Array(conjunto).sorted(), forKey: Self.hiddenKey)
    }
}
