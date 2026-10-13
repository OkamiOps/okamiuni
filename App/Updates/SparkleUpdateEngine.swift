import Foundation
import Sparkle
import UNIShell
import UNISync
import os

/// O atualizador de verdade: o Sparkle, atrás do `UpdateEngine`.
///
/// ## Por que ele mora aqui, e não no `UNIShell`
///
/// O Sparkle é um framework com dois XPC Services assinados dentro
/// (`Installer.xpc` e `Downloader.xpc`), baixado como binário pelo SPM. Pô-lo
/// num pacote local faria `swift test` do `UNIShell` — que roda testes de
/// desenho, fora da tela — baixar um binário da rede para compilar. O alvo do
/// app é quem embarca e assina o framework, então é aqui que ele entra; o
/// `UNIShell` conhece apenas o protocolo e é testado contra um motor de
/// mentira.
///
/// ## Nenhuma janela do Sparkle
///
/// Esta classe **é** o `SPUUserDriver`: todo diálogo que o Sparkle mostraria
/// (encontrou, baixando, pronto, erro) vira um `UpdateEngineEvent` e aparece na
/// interface do OkamiUNI. É o que impede uma janela cinza de sistema de
/// aparecer no meio de um app que desenha cada pixel.
///
/// ## O que não acontece em Debug
///
/// Nada: esta classe nunca é construída num build de desenvolvimento. Ver
/// `UpdaterComposition.make()` — um release instalado por cima de um build
/// local apagaria o trabalho do dia.
@MainActor
final class SparkleUpdateEngine: NSObject, UpdateEngine, SPUUpdaterDelegate, SPUUserDriver {

    // MARK: - UpdateEngine

    var onEvent: (@MainActor (UpdateEngineEvent) -> Void)?

    var automaticallyChecksForUpdates: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { updater.automaticallyDownloadsUpdates }
        set { updater.automaticallyDownloadsUpdates = newValue }
    }

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    var currentBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    // MARK: - Estado interno

    /// O `SPUUpdater` guarda o `SPUUserDriver` com referência forte, e o driver
    /// aqui é `self` — então este par é um ciclo de retenção deliberado. Ele é
    /// de vida do app: quem o cria é a `OkamiUNIApp`, que nunca o solta. A
    /// alternativa (um objeto-ponte fraco entre os dois) só trocaria um ciclo
    /// por uma indireção que ninguém consegue verificar.
    ///
    /// Implicitamente desembrulhado porque `self` não existe antes do
    /// `super.init()` e o `init` do `SPUUpdater` exige o driver.
    private var updater: SPUUpdater!
    private let pendingSends: PendingSendProbe?
    private let log: Logger

    /// O bloco que instala agora, entregue pelo
    /// `updater:willInstallUpdateOnQuit:immediateInstallationBlock:`. É o
    /// caminho normal: a atualização baixou sozinha no ciclo de fundo.
    private var immediateInstall: (() -> Void)?

    /// A resposta pendente de um diálogo do ciclo **pedido pela pessoa**
    /// ("Procurar agora"). `.install` instala, `.dismiss` devolve a
    /// atualização ao ciclo — que a instala ao fechar o app.
    private var pendingChoice: ((SPUUserUpdateChoice) -> Void)?

    /// O release que a tela está mostrando. Guardado porque
    /// `showReadyToInstallAndRelaunch` não recebe o `SUAppcastItem` de novo.
    private var currentRelease: UpdateRelease?

    private var expectedBytes: UInt64 = 0
    private var receivedBytes: UInt64 = 0

    /// O ciclo em andamento foi pedido pela pessoa? Decide se um erro de rede
    /// aparece na tela ou morre no log.
    private var userInitiated = false

    /// Quanto esperar pela fila de saída antes de instalar, e de quanto em
    /// quanto tempo perguntar. Quinze segundos é o teto: é o que um envio
    /// SMTP normal leva com folga, e mais do que isso vira um botão que não
    /// responde.
    static let outboxGraceSeconds: Double = 15
    static let outboxPollNanoseconds: UInt64 = 250_000_000

    init(pendingSends: PendingSendProbe?) {
        self.pendingSends = pendingSends
        log = Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "com.okamiops.okamiuni",
            category: "updates"
        )
        super.init()
        // Depois do `super.init()`, porque `userDriver` e `delegate` são
        // `self` — ver o comentário de `updater`.
        let bundle = Bundle.main
        updater = SPUUpdater(
            hostBundle: bundle, applicationBundle: bundle,
            userDriver: self, delegate: self
        )
    }

    /// Já ligou? O `.task` que chama `start()` pode rodar de novo se a cena
    /// trocar de identidade, e um segundo `startUpdater:` faz o Sparkle
    /// reclamar no log e não fazer nada.
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        do {
            try updater.start()
        } catch {
            // Falha de configuração (feed sem HTTPS, chave pública ausente,
            // bundle inválido) nunca é fatal: o app abre e a pessoa fica sem
            // atualização automática, não sem app.
            log.error("o atualizador não subiu: \(error.localizedDescription, privacy: .public)")
            report(error, userInitiated: false)
            return
        }
        // A busca de abertura. O Sparkle já agenda a dele pelo
        // `SUScheduledCheckInterval`, mas ela só sai quando o intervalo
        // venceu — e quem abre o app uma vez por dia nunca veria a de seis
        // horas. Esta é de fundo: silenciosa, sem janela, sem erro na tela.
        guard updater.canCheckForUpdates, automaticallyChecksForUpdates else { return }
        updater.checkForUpdatesInBackground()
    }

    func checkNow() {
        userInitiated = true
        updater.checkForUpdates()
    }

    /// **Só releases estáveis.**
    ///
    /// Isto não é código, é a ausência dele: o Sparkle 2 só aceita itens do
    /// canal padrão a menos que `allowedChannelsForUpdater:` devolva outros, e
    /// este motor não implementa esse método. Um item do appcast marcado com
    /// `<sparkle:channel>beta</sparkle:channel>` é ignorado. Está escrito aqui
    /// para que ninguém implemente o método "só para testar" sem saber o que
    /// está abrindo.

    /// "Instalar e reabrir".
    ///
    /// Não instala na hora: primeiro espera a fila de saída esvaziar, até
    /// quinze segundos. Ver `PendingSendProbe` para por que isso importa.
    func installImmediately() {
        guard immediateInstall != nil || pendingChoice != nil else {
            log.error("pedido de instalar sem atualização pronta")
            return
        }
        Task { @MainActor in
            await aguardaFilaDeEnvio()
            if let immediateInstall {
                immediateInstall()
            } else if let reply = pendingChoice {
                pendingChoice = nil
                reply(.install)
            }
        }
    }

    /// "Ao fechar o app".
    ///
    /// No caminho normal não há nada a fazer: o Sparkle já prometeu instalar ao
    /// encerrar quando devolvemos `true` ao
    /// `willInstallUpdateOnQuit` — é literalmente o nome do método. No caminho
    /// pedido pela pessoa, `.dismiss` devolve a atualização baixada ao ciclo,
    /// que a instala no encerramento. `.skip` seria outra coisa: "nunca mais me
    /// ofereça esta versão", e não é isso que o botão diz.
    func deferInstallationToQuit() {
        if let reply = pendingChoice {
            pendingChoice = nil
            reply(.dismiss)
        }
    }

    // MARK: - A espera da fila de saída

    private func aguardaFilaDeEnvio() async {
        guard let pendingSends else { return }
        let limite = Date().addingTimeInterval(Self.outboxGraceSeconds)
        while Date() < limite {
            // A leitura é SQLite síncrono: fora do ator principal, senão ela
            // congela a janela justamente enquanto a pessoa espera.
            let emVoo = await Task.detached { pendingSends.hasSendInFlight() }.value
            guard emVoo else { return }
            try? await Task.sleep(nanoseconds: Self.outboxPollNanoseconds)
        }
        log.notice("a fila de saída não esvaziou em 15 s; instalando de todo jeito")
    }

    // MARK: - Eventos

    private func emit(_ evento: UpdateEngineEvent) {
        onEvent?(evento)
    }

    private func report(_ error: any Error, userInitiated: Bool) {
        guard let falha = Self.failure(for: error) else { return }
        if falha == .invalidSignature {
            // Assinatura que não bate é a única hipótese de alguém ter trocado
            // o arquivo no caminho. Vai para o log do sistema **sempre**, mesmo
            // quando a tela já diz — é o registro que sobrevive ao clique.
            log.fault("atualização recusada: assinatura inválida (\((error as NSError).code, privacy: .public))")
        } else {
            log.error("falha do atualizador: \(error.localizedDescription, privacy: .public)")
        }
        emit(.failed(falha, userInitiated: userInitiated))
    }

    /// Traduz o `NSError` do Sparkle para a categoria que muda o que o app faz.
    ///
    /// `nil` quando não é falha nenhuma: "não há atualização" chega por aqui
    /// como erro (`SUNoUpdateError`) e é a resposta normal de um ciclo, e
    /// "a pessoa cancelou a autorização" é uma decisão dela, não um defeito.
    static func failure(for error: any Error) -> UpdateFailure? {
        let erro = error as NSError
        guard erro.domain == SUSparkleErrorDomain else {
            // `NSURLErrorDomain` cobre o avião, o Wi-Fi do hotel e o GitHub
            // fora do ar — as três são a mesma conversa com a pessoa.
            if erro.domain == NSURLErrorDomain { return .network }
            return .other(erro.localizedDescription)
        }
        switch OSStatus(erro.code) {
        case SUError.noUpdateError.rawValue,
             SUError.installationCanceledError.rawValue,
             SUError.installationAuthorizeLaterError.rawValue:
            return nil
        case SUError.signatureError.rawValue,
             SUError.validationError.rawValue,
             SUError.notValidUpdateError.rawValue,
             SUError.noPublicDSAFoundError.rawValue,
             SUError.insufficientSigningError.rawValue:
            return .invalidSignature
        case SUError.installationWriteNoPermissionError.rawValue,
             SUError.runningFromDiskImageError.rawValue,
             SUError.runningTranslocated.rawValue,
             SUError.authenticationFailure.rawValue:
            return .notWritable
        case SUError.downloadError.rawValue,
             SUError.appcastError.rawValue,
             SUError.appcastParseError.rawValue,
             SUError.resumeAppcastError.rawValue,
             SUError.temporaryDirectoryError.rawValue:
            return .network
        default:
            return .other(erro.localizedDescription)
        }
    }

    /// O que a tela precisa saber de um item do appcast.
    ///
    /// As notas vão para `undetermined` de propósito. O Sparkle guarda **uma**
    /// `<description>` por item — ele escolhe pelo idioma preferido do
    /// **sistema** e descarta as outras (ver `-[SUAppcast bestNodeInNodes:]`) —
    /// então o idioma da lista que chega aqui não é conhecido. Dizer "não sei"
    /// é melhor do que carimbar a lista com um idioma adivinhado: o recuo de
    /// `UpdateChangelog.bullets(for:)` mostra a única lista que existe em
    /// qualquer interface, que é o comportamento certo nos dois casos.
    static func release(from item: SUAppcastItem) -> UpdateRelease {
        let notas: [String]
        if let descricao = item.itemDescription {
            notas = item.itemDescriptionFormat?.lowercased() == "plaintext"
                ? descricao
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                : UpdateChangelog.bullets(fromHTML: descricao)
        } else {
            notas = []
        }
        return UpdateRelease(
            version: item.displayVersionString,
            changelog: UpdateChangelog(undetermined: notas),
            // A página do release, na ordem em que o appcast pode declará-la.
            releaseURL: item.fullReleaseNotesURL ?? item.releaseNotesURL ?? item.infoURL
        )
    }

    // MARK: - SPUUpdaterDelegate

    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        let release = Self.release(from: item)
        currentRelease = release
        immediateInstall = immediateInstallHandler
        log.notice("atualização \(release.version, privacy: .public) baixada e pronta")
        emit(.ready(release))
        // `true`: a instalação é nossa a partir daqui. O Sparkle para de
        // oferecer a atualização por conta própria (nenhuma janela de sistema
        // aparece) e ainda instala no encerramento se ninguém clicar em nada.
        return true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        let pedido = userInitiated
        userInitiated = false
        report(error, userInitiated: pedido)
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: (any Error)?
    ) {
        if error == nil { userInitiated = false }
    }

    // MARK: - SPUUserDriver

    /// Nunca deveria ser chamado: `SUEnableAutomaticChecks` no Info.plist já
    /// responde a pergunta. Se for, a resposta é a preferência em vigor — e não
    /// um diálogo do sistema perguntando de novo.
    func show(
        _ request: SPUUpdatePermissionRequest,
        reply: @escaping (SUUpdatePermissionResponse) -> Void
    ) {
        reply(SUUpdatePermissionResponse(
            automaticUpdateChecks: automaticallyChecksForUpdates,
            sendSystemProfile: false
        ))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        userInitiated = true
        emit(.checkStarted(userInitiated: true))
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        let release = Self.release(from: appcastItem)
        currentRelease = release
        switch state.stage {
        case .notDownloaded:
            // Baixa antes de oferecer: o painel diz "Instalar e reabrir", e
            // isso tem de ser instantâneo, não o começo de um download.
            emit(.downloading(progress: nil))
            reply(.install)
        default:
            pendingChoice = reply
            emit(.ready(release))
        }
    }

    /// Notas externas não são usadas: as deste app vêm embutidas no appcast,
    /// em `<description>`. Baixar uma página HTML para mostrar dentro de um
    /// popover seria a janela do Sparkle de volta por outro caminho.
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        let pedido = userInitiated
        userInitiated = false
        emit(.upToDate(userInitiated: pedido))
        acknowledgement()
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        let pedido = userInitiated
        userInitiated = false
        report(error, userInitiated: pedido)
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        expectedBytes = 0
        receivedBytes = 0
        emit(.downloading(progress: nil))
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedBytes = expectedContentLength
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedBytes += length
        // Sem tamanho declarado não há fração honesta: `nil` deixa a barra
        // indeterminada em vez de inventar uma porcentagem.
        guard expectedBytes > 0 else {
            emit(.downloading(progress: nil))
            return
        }
        let fracao = min(1, Double(receivedBytes) / Double(expectedBytes))
        emit(.downloading(progress: fracao))
    }

    func showDownloadDidStartExtractingUpdate() {
        emit(.downloading(progress: nil))
    }

    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        pendingChoice = reply
        guard let currentRelease else { return }
        emit(.ready(currentRelease))
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        // Nada a desenhar: a janela já está indo embora.
        //
        // E ela vai pelo caminho de sempre. O instalador do Sparkle manda um
        // **quit event** ao app antes de trocar o bundle (está escrito em
        // `SPUUserDriver.h`: "a quit event is sent to the running application
        // before installing the update"), e um quit event entra pelo
        // `NSApplication` como ⌘Q — `applicationShouldTerminate` e
        // `applicationWillTerminate` correm, e nada que dependa deles é
        // pulado. Não há `exit()` nem `SIGKILL` nesse caminho.
    }

    func showUpdateInstalledAndRelaunched(
        _ relaunched: Bool,
        acknowledgement: @escaping () -> Void
    ) {
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        pendingChoice = nil
        immediateInstall = nil
        userInitiated = false
    }
}
