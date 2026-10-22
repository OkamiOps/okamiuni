import Foundation
import Observation

/// Em que pé está a ligação com um serviço de reunião.
///
/// É o vocabulário que a aba Agendas desenha: uma bolinha, uma frase e um
/// botão. Nada de client ID, segredo nem tenant — o desenho tirou os três
/// campos da tela de propósito, e o estado não os traz de volta.
public enum MeetingConnectionState: Sendable, Hashable {
    /// Este build não tem o client ID do serviço. A linha explica e **não**
    /// mostra "Conectar": um botão que só pode falhar não é um botão.
    case unavailable
    case disconnected
    /// O navegador está aberto esperando o login.
    case waitingInBrowser
    /// Conectado, com a conta que entrou.
    case connected(String)
    case failed(String)

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    /// A frase ao lado da bolinha.
    public var label: String {
        switch self {
        case .unavailable: L10n.tr("ainda não disponível neste build")
        case .disconnected: L10n.tr("não conectado")
        case .waitingInBrowser: L10n.tr("esperando no navegador")
        case .connected(let account): account
        case .failed(let reason): reason
        }
    }
}

/// O que um serviço de reunião precisa saber fazer para caber na aba Agendas.
///
/// Três verbos e um fato. `connect()` abre o login **no navegador** e devolve
/// a conta; `cancel()` desiste de uma espera; `disconnect()` apaga o que foi
/// guardado. Quem implementa guarda token no Keychain, nunca aqui.
///
/// O Meet já tem um: `GoogleMeetConnector`, em cima do OAuth Google que o app
/// usa para a caixa de correio. Zoom, Teams e Zoho esperam o seu — a
/// interface está pronta e testada contra `StubMeetingConnector`.
@MainActor
public protocol MeetingConnector: AnyObject {
    var service: MeetingService { get }

    /// `false` quando falta o client ID no `Info.plist` deste build.
    var isAvailable: Bool { get }

    /// Abre o login no navegador e devolve o identificador da conta que
    /// entrou (o e-mail, em geral). Lança quando a pessoa desiste ou o
    /// serviço recusa.
    func connect() async throws -> String

    /// Desiste de uma espera em andamento. Não lança: desistir sempre dá
    /// certo.
    func cancel()

    /// Esquece a conta e apaga o que estiver guardado.
    func disconnect() async

    /// A conta já conectada, lida do cofre na abertura da janela. `nil`
    /// quando não há nenhuma. Com várias, é a primeira.
    func currentAccount() async -> String?

    /// Todas as contas conectadas. A padrão devolve a única que
    /// `currentAccount` já conhece; quem guarda mais de uma sobrescreve.
    func accounts() async -> [String]

    /// Esquece **esta** conta. A padrão desconecta o serviço inteiro.
    func disconnect(account: String) async
}

extension MeetingConnector {
    public func accounts() async -> [String] {
        if let account = await currentAccount() { return [account] }
        return []
    }

    public func disconnect(account: String) async {
        await disconnect()
    }
}

/// Os client IDs dos serviços de reunião, vindos do `Info.plist`.
///
/// Mesma regra do Google: o valor é de quem publica o app, vem de
/// `Config/Meetings.xcconfig` (fora do repositório) e **nunca** está no
/// código. Sem ele o serviço aparece na lista dizendo que ainda não está
/// disponível neste build, em vez de oferecer um botão que só pode falhar.
public enum MeetingClientIDs {
    public static func infoKey(for service: MeetingService) -> String? {
        switch service {
        case .meet: "OkamiUNIGoogleClientID"
        case .zoom: "OkamiUNIZoomClientID"
        case .teams: "OkamiUNIMicrosoftClientID"
        case .zoho: "OkamiUNIZohoClientID"
        }
    }

    /// Quem **de fato** precisa de segredo.
    ///
    /// Só dois dos quatro. O Google exige `client_secret` no client de app
    /// desktop (sem ele o token endpoint responde `400 client_secret is
    /// missing`, PKCE ou não) e o Zoho exige na troca do código, por
    /// documentação. Zoom e Teams são clientes **públicos**: o PKCE S256
    /// ocupa o lugar do segredo, e pedir um segredo que não é usado só
    /// daria à pessoa que publica o app a impressão de que ele guarda
    /// confidência — o que um `.app` instalado nunca faz.
    public static func secretKey(for service: MeetingService) -> String? {
        switch service {
        case .meet: "OkamiUNIGoogleClientSecret"
        case .zoom, .teams: nil
        case .zoho: "OkamiUNIZohoClientSecret"
        }
    }

    public static func clientID(for service: MeetingService, bundle: Bundle = .main) -> String? {
        guard let key = infoKey(for: service) else { return nil }
        return value(forKey: key, bundle: bundle)
    }

    public static func clientSecret(for service: MeetingService, bundle: Bundle = .main) -> String? {
        guard let key = secretKey(for: service) else { return nil }
        return value(forKey: key, bundle: bundle)
    }

    /// Vazio e `$(VAR)` não substituído contam como ausente — é o que um
    /// `xcconfig` sem valor deixa no `Info.plist`.
    private static func value(forKey key: String, bundle: Bundle) -> String? {
        let raw = bundle.object(forInfoDictionaryKey: key) as? String
        let clean = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !clean.hasPrefix("$(") else { return nil }
        return clean
    }
}

/// Os quatro serviços num lugar só, com o estado que a aba Agendas desenha.
///
/// O estado mora **aqui**, e não dentro de cada conector, para a tela
/// atualizar sem depender de o conector ser `@Observable`: quem escrever o
/// OAuth do Zoom amanhã só precisa de um objeto com três verbos.
@MainActor
@Observable
public final class MeetingConnections {
    public private(set) var states: [MeetingService: MeetingConnectionState] = [:]
    /// As contas ligadas a cada serviço, na ordem em que entraram.
    public private(set) var accountsByService: [MeetingService: [String]] = [:]
    /// Um login em andamento. A lista de contas que já existem continua na tela.
    public private(set) var linking: Set<MeetingService> = []
    /// A última tentativa de conectar outra conta falhou, e as que já estavam
    /// continuam. Some na próxima tentativa.
    public private(set) var linkError: [MeetingService: String] = [:]

    @ObservationIgnored
    private var connectors: [MeetingService: any MeetingConnector] = [:]
    @ObservationIgnored
    private var running: [MeetingService: Task<Void, Never>] = [:]

    public init(connectors: [any MeetingConnector] = []) {
        for connector in connectors {
            self.connectors[connector.service] = connector
            states[connector.service] = connector.isAvailable ? .disconnected : .unavailable
        }
        for service in MeetingService.allCases where states[service] == nil {
            states[service] = .unavailable
        }
    }

    public func state(of service: MeetingService) -> MeetingConnectionState {
        states[service] ?? .unavailable
    }

    public func accounts(of service: MeetingService) -> [String] {
        accountsByService[service] ?? []
    }

    /// Lê do cofre quem já está conectado. Chamado quando a aba abre.
    public func refresh() async {
        for (service, connector) in connectors {
            guard connector.isAvailable else { continue }
            // Uma conexão em andamento não pode ser atropelada pela leitura.
            if linking.contains(service) { continue }
            let lista = await connector.accounts()
            guardar(lista, em: service)
        }
    }

    public func connect(_ service: MeetingService) {
        guard let connector = connectors[service], connector.isAvailable else { return }
        guard running[service] == nil else { return }
        var erros = linkError
        erros[service] = nil
        linkError = erros
        var emCurso = linking
        emCurso.insert(service)
        linking = emCurso
        // A primeira conta usa o estado que a linha já desenhava. As
        // seguintes ficam na lista e o login corre por baixo.
        if accounts(of: service).isEmpty {
            states[service] = .waitingInBrowser
        }
        running[service] = Task { [weak self] in
            do {
                let account = try await connector.connect()
                guard !Task.isCancelled else { return }
                var lista = await connector.accounts()
                if !lista.contains(where: { $0.caseInsensitiveCompare(account) == .orderedSame }) {
                    lista.append(account)
                }
                self?.guardar(lista, em: service)
            } catch is CancellationError {
                self?.encerrarEspera(service)
            } catch {
                guard !Task.isCancelled else { return }
                self?.falhou(service, error.localizedDescription)
            }
            self?.running[service] = nil
            if var emCurso = self?.linking {
                emCurso.remove(service)
                self?.linking = emCurso
            }
        }
    }

    public func cancel(_ service: MeetingService) {
        running[service]?.cancel()
        running[service] = nil
        var emCurso = linking
        emCurso.remove(service)
        linking = emCurso
        connectors[service]?.cancel()
        encerrarEspera(service)
    }

    public func disconnect(_ service: MeetingService) {
        guard let connector = connectors[service] else { return }
        running[service]?.cancel()
        running[service] = nil
        var emCurso = linking
        emCurso.remove(service)
        linking = emCurso
        guardar([], em: service)
        Task { await connector.disconnect() }
    }

    /// Tira uma conta e deixa as outras.
    public func disconnect(_ service: MeetingService, account: String) {
        guard let connector = connectors[service] else { return }
        var lista = accounts(of: service)
        lista.removeAll { $0.caseInsensitiveCompare(account) == .orderedSame }
        guardar(lista, em: service)
        Task { await connector.disconnect(account: account) }
    }

    private func guardar(_ lista: [String], em service: MeetingService) {
        var mapa = accountsByService
        mapa[service] = lista
        accountsByService = mapa
        if let primeira = lista.first {
            states[service] = .connected(primeira)
        } else if connectors[service]?.isAvailable == true {
            states[service] = .disconnected
        } else {
            states[service] = .unavailable
        }
    }

    /// O login desta tentativa acabou sem conta nova. Quem já estava ligado
    /// continua; quem não tinha ninguém volta a "não conectado".
    private func encerrarEspera(_ service: MeetingService) {
        if accounts(of: service).isEmpty {
            states[service] = connectors[service]?.isAvailable == true ? .disconnected : .unavailable
        }
    }

    private func falhou(_ service: MeetingService, _ motivo: String) {
        if accounts(of: service).isEmpty {
            states[service] = .failed(motivo)
        } else {
            var erros = linkError
            erros[service] = motivo
            linkError = erros
        }
    }
}

/// Um conector de mentira, para a interface ser testável antes de o OAuth de
/// verdade existir. Fora dos testes, só é usado por um retrato.
@MainActor
public final class StubMeetingConnector: MeetingConnector {
    public let service: MeetingService
    public var isAvailable: Bool
    private var account: String?
    /// Quando `true`, `connect()` nunca termina: é o estado "esperando no
    /// navegador" que o desenho mostra.
    private let hangs: Bool
    private let failure: String?

    public init(
        service: MeetingService,
        isAvailable: Bool = true,
        account: String? = nil,
        hangs: Bool = false,
        failure: String? = nil
    ) {
        self.service = service
        self.isAvailable = isAvailable
        self.account = account
        self.hangs = hangs
        self.failure = failure
    }

    public func connect() async throws -> String {
        if let failure { throw MeetingConnectorError.refused(failure) }
        if hangs {
            // Espera até ser cancelada, sem queimar processador.
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
            }
            throw CancellationError()
        }
        account = account ?? "pessoa@exemplo.com"
        return account!
    }

    public func cancel() {}

    public func disconnect() async { account = nil }

    public func currentAccount() async -> String? { account }
}

/// O que a linha de um serviço oferece, dado o estado.
///
/// É um tipo, e não um `switch` dentro do corpo da `View`, porque a regra que
/// importa aqui — **sem client ID, sem botão Conectar** — precisa ser
/// verificável sem contar pixels. A linha desenha o que este enum disser.
public enum MeetingRoomAction: Sendable, Hashable {
    /// Nenhum botão. É o caso de um serviço que este build não tem.
    case none
    case connect
    case disconnect
    /// "Cancelar" e "Abrir de novo", lado a lado.
    case waiting

    public init(_ state: MeetingConnectionState) {
        switch state {
        case .unavailable: self = .none
        case .connected: self = .disconnect
        case .waitingInBrowser: self = .waiting
        case .disconnected, .failed: self = .connect
        }
    }
}

public enum MeetingConnectorError: LocalizedError, Sendable, Hashable {
    case missingClientID(MeetingService)
    case refused(String)

    public var errorDescription: String? {
        switch self {
        case .missingClientID(let service):
            L10n.tr("Este build não tem o client ID do \(service.label).")
        case .refused(let reason): reason
        }
    }
}
