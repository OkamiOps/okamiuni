import Foundation
import Observation
import UNICore

/// Como a atualização chega até a pessoa.
///
/// Os valores brutos fazem parte da persistência. Não os renomeie sem uma
/// migração das preferências já gravadas — a mesma regra do `AppLanguage`.
public enum UpdateInstallMode: String, CaseIterable, Identifiable, Sendable {
    /// O padrão: a versão nova baixa sozinha e um botão discreto aparece na
    /// lateral. Quem instala e quando é a pessoa.
    case notify
    /// Sem botão e sem painel: o Sparkle instala ao fechar o app, e a abertura
    /// seguinte diz uma vez o que mudou.
    case silentOnQuit

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .notify: L10n.tr("Avisar quando estiver pronta")
        case .silentOnQuit: L10n.tr("Instalar em silêncio ao fechar o app")
        }
    }
}

/// O que o app sabe sobre atualizações neste momento.
public enum UpdateState: Sendable, Equatable {
    /// Nada a dizer. É o estado em que o app passa 99% do tempo.
    case idle
    case checking
    /// Procurou e não havia nada. Distinto de `idle` porque é uma **resposta**
    /// a um pedido da pessoa: só ele faz a frase "você está na versão mais
    /// recente" aparecer em Ajustes.
    case upToDate
    case downloading(progress: Double?)
    case ready(UpdateRelease)
    /// A versão instalada em silêncio, anunciada uma vez na abertura seguinte.
    case justUpdated(version: String, changelog: UpdateChangelog)
    case error(message: String)
}

/// O estado das atualizações, e a única coisa que a interface lê.
///
/// Toda a interface do atualizador — o botão da lateral, o painel, o cartão de
/// Ajustes, o item do menu — depende deste objeto e de mais nada. O Sparkle não
/// aparece em nenhum `View`: o que atravessa é o `UpdateEngine`, e é por isso
/// que existe teste de estado para um atualizador, que costuma ser a parte do
/// app que ninguém verifica porque "só dá para ver em produção".
///
/// As preferências moram em `UserDefaults` (injetável, para os testes não
/// escreverem no domínio do app) e são **espelhadas no motor** a cada
/// mudança — não no `start()` apenas: desligar a busca automática tem de
/// chegar ao Sparkle na hora, não na próxima abertura.
@MainActor
@Observable
public final class UpdateController {

    /// As chaves gravadas. Prefixo comum para a limpeza dos testes poder
    /// apagar só o que é do atualizador.
    enum Keys {
        static let automaticChecks = "updates.automaticChecks"
        static let installMode = "updates.installMode"
        /// A versão que rodou na última vez que o app abriu. É a comparação
        /// com `CFBundleShortVersionString` que detecta "instalou em silêncio".
        static let lastRunVersion = "updates.lastRunVersion"
        /// O último release que ficou pronto, em JSON — é dele que sai o
        /// changelog do anúncio da abertura seguinte.
        static let pendingRelease = "updates.pendingRelease"
        /// O aviso de assinatura inválida sobrevive a fechar o app de
        /// propósito: ou alguém trocou o arquivo no caminho, ou a chave do
        /// release está errada, e as duas coisas pedem alguém olhando.
        static let signatureWarning = "updates.signatureWarning"
    }

    public private(set) var state: UpdateState = .idle

    /// O painel de mudanças está aberto? Mora aqui, e não num `@State` da
    /// `View`, porque duas superfícies o abrem: o botão da lateral e o anúncio
    /// "atualizado para X" do cartão de Ajustes.
    public private(set) var isShowingChangelog = false

    /// O aviso que fica quando uma assinatura não bateu. `nil` no caso normal.
    public private(set) var signatureWarning: String?

    public var checksAutomatically: Bool {
        didSet {
            guard checksAutomatically != oldValue else { return }
            defaults.set(checksAutomatically, forKey: Keys.automaticChecks)
            engine.automaticallyChecksForUpdates = checksAutomatically
        }
    }

    public var installMode: UpdateInstallMode {
        didSet {
            guard installMode != oldValue else { return }
            defaults.set(installMode.rawValue, forKey: Keys.installMode)
        }
    }

    private let engine: any UpdateEngine
    private let defaults: UserDefaults

    /// A pessoa está esperando a resposta de um "Procurar agora"? É o que faz
    /// uma atualização encontrada **abrir** o painel em vez de só acender o
    /// botão: quem acabou de clicar em "procurar" quer ver o que achou.
    private var awaitingManualResult = false

    public init(engine: any UpdateEngine, defaults: UserDefaults = .standard) {
        self.engine = engine
        self.defaults = defaults
        // `object(forKey:) == nil` em vez de `bool(forKey:)`: o segundo
        // devolve `false` para chave ausente, e o padrão do projeto é ligado.
        checksAutomatically = defaults.object(forKey: Keys.automaticChecks) as? Bool ?? true
        installMode = defaults.string(forKey: Keys.installMode)
            .flatMap(UpdateInstallMode.init(rawValue:)) ?? .notify
        signatureWarning = defaults.string(forKey: Keys.signatureWarning)
        engine.onEvent = { [weak self] evento in self?.handle(evento) }
    }

    // MARK: - Leituras da interface

    /// A linha "Versão 0.5.5 (build 10)" do cartão de Ajustes.
    public var versionLine: String {
        L10n.tr("Versão \(engine.currentVersion) (build \(engine.currentBuild))")
    }

    /// O botão da lateral existe? Só com atualização pronta **e** no modo de
    /// avisar. No modo silencioso ele não aparece nunca — é essa a promessa que
    /// a pessoa aceitou ao escolher o silêncio.
    public var showsReadyButton: Bool {
        guard case .ready = state else { return false }
        return installMode == .notify
    }

    /// A versão que o painel anuncia: a pronta, ou a que acabou de ser
    /// instalada. `nil` quando não há nenhuma das duas.
    public var readyVersion: String? {
        switch state {
        case let .ready(release): release.version
        case let .justUpdated(version, _): version
        default: nil
        }
    }

    public var releaseURL: URL? {
        if case let .ready(release) = state { return release.releaseURL }
        return storedRelease(matching: readyVersion)?.releaseURL
    }

    /// Os marcadores do "O que mudou", já no idioma da interface.
    public var changelogBullets: [String] {
        let notas: UpdateChangelog? = switch state {
        case let .ready(release): release.changelog
        case let .justUpdated(_, changelog): changelog
        default: nil
        }
        return notas?.bullets(for: L10n.language) ?? []
    }

    /// O anúncio discreto da abertura seguinte a uma instalação silenciosa.
    public var justUpdatedNotice: String? {
        guard case let .justUpdated(version, _) = state else { return nil }
        return L10n.tr("Atualizado para \(version) · O que mudou")
    }

    /// O convite para abrir o painel de mudanças, quando há um. É o que
    /// Configurações ▸ Geral mostra: a versão que acabou de ser instalada em
    /// silêncio, ou a que está pronta esperando.
    ///
    /// `nil` no modo silencioso com atualização pronta — ali não há botão nem
    /// painel por escolha da pessoa, e a conversa só acontece depois, quando a
    /// versão já estiver instalada.
    public var changelogNotice: String? {
        if let justUpdatedNotice { return justUpdatedNotice }
        guard showsReadyButton, let version = readyVersion else { return nil }
        return L10n.tr("Atualização \(version) pronta · O que mudou")
    }

    /// A frase ao lado de "Procurar agora". `nil` quando não há o que dizer —
    /// e é `nil` que faz a busca de fundo não escrever nada na tela.
    public var manualCheckMessage: String? {
        switch state {
        case .checking: L10n.tr("Procurando…")
        case .upToDate: L10n.tr("Você está na versão mais recente")
        case .downloading: L10n.tr("Baixando a atualização…")
        case let .error(message): message
        default: nil
        }
    }

    public var isChecking: Bool {
        if case .checking = state { return true }
        return false
    }

    // MARK: - Ações

    /// Liga o atualizador. Chamada uma vez, na primeira montagem da janela
    /// principal.
    ///
    /// A ordem importa: as preferências vão ao motor **antes** de ele começar a
    /// procurar, senão a primeira busca sairia com o padrão do Sparkle em vez
    /// do que a pessoa escolheu.
    public func start() {
        engine.automaticallyChecksForUpdates = checksAutomatically
        // Ligado nos dois modos, de propósito — ver `UpdateEngine`.
        engine.automaticallyDownloadsUpdates = true
        announceSilentInstallIfNeeded()
        engine.start()
    }

    public func checkNow() {
        awaitingManualResult = true
        engine.checkNow()
    }

    /// "Instalar e reabrir". O adiamento do fechamento (fila de saída com
    /// envio em curso) é do motor; aqui só se pede.
    public func installAndRelaunch() {
        isShowingChangelog = false
        engine.installImmediately()
    }

    /// "Ao fechar o app": apaga o botão e deixa a instalação para o
    /// encerramento. Não é "pular esta versão" — ela vai ser instalada.
    public func installOnQuit() {
        isShowingChangelog = false
        state = .idle
        engine.deferInstallationToQuit()
    }

    public func showChangelog() {
        isShowingChangelog = true
    }

    /// Fecha o painel e limpa o que era resposta a um pedido. Nada é adiado
    /// nem instalado aqui.
    public func dismiss() {
        isShowingChangelog = false
        switch state {
        case .justUpdated, .upToDate, .error:
            state = .idle
        default:
            break
        }
    }

    /// Apaga o aviso de assinatura — a saída depois de o release ser
    /// republicado com a assinatura certa.
    public func dismissSignatureWarning() {
        signatureWarning = nil
        defaults.removeObject(forKey: Keys.signatureWarning)
    }

    // MARK: - O que o motor conta

    private func handle(_ evento: UpdateEngineEvent) {
        switch evento {
        case let .checkStarted(userInitiated):
            guard userInitiated else { return }
            state = .checking

        case let .upToDate(userInitiated):
            guard userInitiated else { return }
            awaitingManualResult = false
            state = .upToDate

        case let .downloading(progress):
            // Uma atualização que já está pronta não volta a baixar: o Sparkle
            // reemite progresso ao retomar um download concluído, e aceitar
            // isso apagaria o botão que já está na lateral.
            if case .ready = state { return }
            state = .downloading(progress: progress)

        case let .ready(release):
            remember(release)
            state = .ready(release)
            // Resposta a um pedido explícito: o painel abre sozinho. Fora
            // disso ele espera o clique no botão da lateral — uma atualização
            // que chega sozinha não interrompe o que a pessoa está fazendo.
            if awaitingManualResult, installMode == .notify {
                isShowingChangelog = true
            }
            awaitingManualResult = false

        case let .failed(failure, userInitiated):
            if userInitiated { awaitingManualResult = false }
            if failure == .invalidSignature {
                signatureWarning = failure.message
                defaults.set(failure.message, forKey: Keys.signatureWarning)
            }
            guard userInitiated || !failure.isSilentWhenScheduled else {
                state = .idle
                return
            }
            state = .error(message: failure.message)
        }
    }

    // MARK: - "Atualizado para X", uma vez

    /// Anuncia a instalação silenciosa, se houve uma.
    ///
    /// A detecção é por comparação de versão gravada, e não por uma bandeira
    /// que o Sparkle deixaria: o app que grava a bandeira é o **antigo**, e
    /// quem a leria é o novo — e entre os dois há uma substituição de bundle.
    /// Versão gravada contra `CFBundleShortVersionString` sobrevive a isso.
    ///
    /// A gravação da versão atual acontece **sempre**, mesmo quando não há nada
    /// a anunciar. É isso que faz o anúncio aparecer uma vez só.
    private func announceSilentInstallIfNeeded() {
        let atual = engine.currentVersion
        defer { defaults.set(atual, forKey: Keys.lastRunVersion) }

        guard let anterior = defaults.string(forKey: Keys.lastRunVersion),
              anterior != atual,
              installMode == .silentOnQuit,
              let release = storedRelease(matching: atual)
        else { return }

        state = .justUpdated(version: atual, changelog: release.changelog)
    }

    private func remember(_ release: UpdateRelease) {
        guard let dados = try? JSONEncoder().encode(release) else { return }
        defaults.set(dados, forKey: Keys.pendingRelease)
    }

    /// O release gravado, quando ele é o desta versão. O filtro por versão
    /// importa: sem ele, um release antigo que nunca foi instalado emprestaria
    /// o changelog errado ao anúncio.
    private func storedRelease(matching version: String?) -> UpdateRelease? {
        guard let version,
              let dados = defaults.data(forKey: Keys.pendingRelease),
              let release = try? JSONDecoder().decode(UpdateRelease.self, from: dados),
              release.version == version
        else { return nil }
        return release
    }
}
