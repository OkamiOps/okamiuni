import Foundation
import Testing
import UNICore
@testable import UNIShell

/// O motor de mentira.
///
/// Ele existe porque o `UpdateController` é a única parte do atualizador que
/// pode ser verificada sem rede, sem Keychain e sem um app assinado no disco:
/// o Sparkle mora no alvo do app justamente para este arquivo poder afirmar o
/// comportamento sem baixar nada.
@MainActor
final class MotorDeMentira: UpdateEngine {
    var onEvent: (@MainActor (UpdateEngineEvent) -> Void)?
    var automaticallyChecksForUpdates = false
    var automaticallyDownloadsUpdates = false
    /// A versão "em uso" do motor de mentira é a **anterior** à do release de
    /// exemplo: é essa diferença que os casos de instalação silenciosa medem.
    var currentVersion = "0.5.5"
    var currentBuild = "10"

    var inicios = 0
    var buscas = 0
    var instalacoesImediatas = 0
    var adiamentos = 0

    func start() { inicios += 1 }

    func checkNow() {
        buscas += 1
        emite(.checkStarted(userInitiated: true))
    }

    func installImmediately() { instalacoesImediatas += 1 }
    func deferInstallationToQuit() { adiamentos += 1 }

    /// Entrega um evento como o motor de verdade entregaria.
    func emite(_ evento: UpdateEngineEvent) { onEvent?(evento) }
}

@MainActor
private func controlador(
    _ nome: String,
    motor: MotorDeMentira = MotorDeMentira(),
    semente: [String: Any] = [:]
) throws -> (UpdateController, MotorDeMentira, UserDefaults) {
    let defaults = try #require(UserDefaults(suiteName: "updates-\(nome)"))
    for chave in defaults.dictionaryRepresentation().keys where chave.hasPrefix("updates.") {
        defaults.removeObject(forKey: chave)
    }
    for (chave, valor) in semente { defaults.set(valor, forKey: chave) }
    return (UpdateController(engine: motor, defaults: defaults), motor, defaults)
}

private let releaseDeExemplo = UpdateRelease(
    version: "0.5.6",
    changelog: UpdateChangelog(
        portuguese: ["Convites aceitos não duplicam mais no Google Calendar"],
        english: ["Accepted invites no longer duplicate in Google Calendar"]
    ),
    releaseURL: URL(string: "https://github.com/okamiops/okamiuni/releases/tag/v0.5.6")
)

@Suite("O controlador de atualizações")
@MainActor
struct UpdateControllerTests {

    // MARK: - Estados

    @Test("nasce parado e não promete nada antes da primeira busca")
    func nasceParado() throws {
        let (controller, motor, _) = try controlador(#function)
        #expect(controller.state == .idle)
        #expect(!controller.showsReadyButton)
        #expect(motor.inicios == 0)
    }

    @Test("a busca manual passa por procurando antes de responder")
    func buscaManualPassaPorProcurando() throws {
        let (controller, motor, _) = try controlador(#function)
        controller.checkNow()
        #expect(motor.buscas == 1)
        #expect(controller.state == .checking)
    }

    @Test("sem novidade, a busca manual diz que a versão é a mais recente")
    func semNovidade() throws {
        let (controller, motor, _) = try controlador(#function)
        controller.checkNow()
        motor.emite(.upToDate(userInitiated: true))
        #expect(controller.state == .upToDate)
        #expect(controller.manualCheckMessage == "Você está na versão mais recente")
        #expect(!controller.showsReadyButton)
    }

    /// A busca de fundo é a que roda a cada seis horas, sem ninguém pedindo.
    /// Ela não pode escrever nada na tela — nem "tudo em ordem", nem erro.
    @Test("a busca de fundo não escreve nada na tela")
    func buscaDeFundoNaoFalaNada() throws {
        let (controller, motor, _) = try controlador(#function)
        motor.emite(.checkStarted(userInitiated: false))
        #expect(controller.state == .idle)
        motor.emite(.upToDate(userInitiated: false))
        #expect(controller.state == .idle)
        motor.emite(.failed(.network, userInitiated: false))
        #expect(controller.state == .idle)
        #expect(controller.manualCheckMessage == nil)
    }

    @Test("o download aparece com o progresso que o motor relatou")
    func downloadComProgresso() throws {
        let (controller, motor, _) = try controlador(#function)
        motor.emite(.downloading(progress: 0.4))
        #expect(controller.state == .downloading(progress: 0.4))
        #expect(!controller.showsReadyButton)
    }

    @Test("pronta para instalar acende o botão e carrega versão, notas e link")
    func prontaParaInstalar() throws {
        let (controller, motor, _) = try controlador(#function)
        motor.emite(.ready(releaseDeExemplo))
        #expect(controller.state == .ready(releaseDeExemplo))
        #expect(controller.showsReadyButton)
        #expect(controller.readyVersion == "0.5.6")
        #expect(controller.releaseURL?.absoluteString
            == "https://github.com/okamiops/okamiuni/releases/tag/v0.5.6")
        #expect(controller.changelogBullets
            == ["Convites aceitos não duplicam mais no Google Calendar"])
    }

    @Test("offline numa busca manual explica sem prometer o que não pode")
    func offlineNaBuscaManual() throws {
        let (controller, motor, _) = try controlador(#function)
        controller.checkNow()
        motor.emite(.failed(.network, userInitiated: true))
        #expect(controller.state == .error(message: "Não foi possível verificar agora. Tente de novo mais tarde."))
        #expect(controller.manualCheckMessage == "Não foi possível verificar agora. Tente de novo mais tarde.")
        #expect(!controller.showsReadyButton)
        #expect(controller.signatureWarning == nil)
    }

    /// Assinatura inválida não é "tente mais tarde": é um aviso que **fica**,
    /// porque ou o arquivo foi trocado no caminho ou a chave do release está
    /// errada — e as duas coisas pedem alguém olhando, não outra tentativa.
    @Test("assinatura inválida nunca instala e deixa o aviso gravado")
    func assinaturaInvalida() throws {
        let (controller, motor, defaults) = try controlador(#function)
        motor.emite(.failed(.invalidSignature, userInitiated: false))
        #expect(controller.state == .error(message: UpdateFailure.invalidSignature.message))
        #expect(controller.signatureWarning == UpdateFailure.invalidSignature.message)
        #expect(!controller.showsReadyButton)
        #expect(motor.instalacoesImediatas == 0)

        // O aviso sobrevive a fechar e reabrir o app.
        let outro = UpdateController(engine: MotorDeMentira(), defaults: defaults)
        #expect(outro.signatureWarning == UpdateFailure.invalidSignature.message)
    }

    @Test("app em lugar sem permissão de escrita pede a mudança para Aplicativos")
    func lugarSemPermissao() throws {
        let (controller, motor, _) = try controlador(#function)
        motor.emite(.failed(.notWritable, userInitiated: true))
        #expect(controller.state == .error(message: "Mova o OkamiUNI para Aplicativos para atualizar."))
    }

    // MARK: - Ações

    @Test("instalar e reabrir chama o motor uma vez")
    func instalarEReabrir() throws {
        let (controller, motor, _) = try controlador(#function)
        motor.emite(.ready(releaseDeExemplo))
        controller.installAndRelaunch()
        #expect(motor.instalacoesImediatas == 1)
        #expect(motor.adiamentos == 0)
    }

    @Test("ao fechar o app adia a instalação e apaga o botão")
    func aoFecharOApp() throws {
        let (controller, motor, _) = try controlador(#function)
        motor.emite(.ready(releaseDeExemplo))
        #expect(controller.showsReadyButton)
        controller.installOnQuit()
        #expect(motor.adiamentos == 1)
        #expect(!controller.showsReadyButton)
        #expect(controller.state == .idle)
    }

    @Test("dispensar fecha o painel sem adiar nem instalar")
    func dispensar() throws {
        let (controller, motor, _) = try controlador(#function)
        motor.emite(.ready(releaseDeExemplo))
        controller.showChangelog()
        #expect(controller.isShowingChangelog)
        controller.dismiss()
        #expect(!controller.isShowingChangelog)
        #expect(motor.adiamentos == 0)
        #expect(motor.instalacoesImediatas == 0)
    }

    /// Quem clicou em "Procurar agora" está esperando ver o que foi achado.
    /// Uma atualização que chega sozinha, no ciclo de fundo, não abre painel
    /// nenhum — ela só acende o botão e espera.
    @Test("a atualização achada por pedido abre o painel; a de fundo, não")
    func painelAbreSoNaBuscaPedida() throws {
        let (pedida, motorPedido, _) = try controlador("\(#function)-pedida")
        pedida.checkNow()
        motorPedido.emite(.ready(releaseDeExemplo))
        #expect(pedida.isShowingChangelog)

        let (fundo, motorDeFundo, _) = try controlador("\(#function)-fundo")
        motorDeFundo.emite(.ready(releaseDeExemplo))
        #expect(!fundo.isShowingChangelog)
        #expect(fundo.showsReadyButton)
    }

    @Test("no modo silencioso nem a busca pedida abre o painel")
    func modoSilenciosoNaoAbrePainelNaBuscaPedida() throws {
        let (controller, motor, _) = try controlador(#function)
        controller.installMode = .silentOnQuit
        controller.checkNow()
        motor.emite(.ready(releaseDeExemplo))
        #expect(!controller.isShowingChangelog)
        #expect(controller.changelogNotice == nil)
    }

    @Test("o convite de Ajustes nomeia a versão pronta e a recém-instalada")
    func conviteDeAjustes() throws {
        let (parado, motor, _) = try controlador("\(#function)-parado")
        #expect(parado.changelogNotice == nil)

        motor.emite(.ready(releaseDeExemplo))
        #expect(parado.changelogNotice == "Atualização 0.5.6 pronta · O que mudou")
    }

    // MARK: - Preferências

    @Test("as preferências chegam ao motor no start, com os padrões do projeto")
    func preferenciasChegamAoMotor() throws {
        let (controller, motor, _) = try controlador(#function)
        controller.start()
        #expect(motor.inicios == 1)
        // Padrão: procura sozinho e baixa sozinho.
        #expect(controller.checksAutomatically)
        #expect(motor.automaticallyChecksForUpdates)
        #expect(motor.automaticallyDownloadsUpdates)
        #expect(controller.installMode == .notify)
    }

    @Test("desligar a busca automática chega ao motor e fica gravado")
    func desligarBuscaAutomatica() throws {
        let (controller, motor, defaults) = try controlador(#function)
        controller.start()
        controller.checksAutomatically = false
        #expect(!motor.automaticallyChecksForUpdates)

        let outroMotor = MotorDeMentira()
        let outro = UpdateController(engine: outroMotor, defaults: defaults)
        outro.start()
        #expect(!outro.checksAutomatically)
        #expect(!outroMotor.automaticallyChecksForUpdates)
    }

    @Test("o modo de instalação fica gravado entre sessões")
    func modoDeInstalacaoGravado() throws {
        let (controller, _, defaults) = try controlador(#function)
        controller.installMode = .silentOnQuit
        let outro = UpdateController(engine: MotorDeMentira(), defaults: defaults)
        #expect(outro.installMode == .silentOnQuit)
    }

    // MARK: - Modo silencioso

    @Test("no modo silencioso não há botão, nem com atualização pronta")
    func modoSilenciosoNaoAcendeBotao() throws {
        let (controller, motor, _) = try controlador(#function)
        controller.installMode = .silentOnQuit
        motor.emite(.ready(releaseDeExemplo))
        #expect(controller.state == .ready(releaseDeExemplo))
        #expect(!controller.showsReadyButton)
    }

    /// O silêncio tem um preço: a pessoa não escolheu a hora da instalação, e
    /// por isso ela merece saber que a versão mudou. Uma vez, discreto.
    @Test("no modo silencioso, a versão nova é anunciada uma única vez")
    func modoSilenciosoAnunciaUmaVez() throws {
        let (primeiro, motor, defaults) = try controlador(
            #function, semente: ["updates.installMode": UpdateInstallMode.silentOnQuit.rawValue]
        )
        primeiro.start()
        // Primeira abertura desta instalação: nada a anunciar.
        #expect(primeiro.state == .idle)
        motor.emite(.ready(releaseDeExemplo))

        // A instalação aconteceu ao fechar: a abertura seguinte é na 0.5.6.
        let motorNovo = MotorDeMentira()
        motorNovo.currentVersion = "0.5.6"
        let segundo = UpdateController(engine: motorNovo, defaults: defaults)
        segundo.start()
        #expect(segundo.state == .justUpdated(version: "0.5.6", changelog: releaseDeExemplo.changelog))
        #expect(segundo.justUpdatedNotice == "Atualizado para 0.5.6 · O que mudou")
        #expect(!segundo.showsReadyButton)

        // E só uma vez: a terceira abertura já não diz nada.
        let terceiro = UpdateController(engine: motorNovo, defaults: defaults)
        terceiro.start()
        #expect(terceiro.state == .idle)
    }

    @Test("no modo de avisar, a abertura seguinte não anuncia nada")
    func modoDeAvisarNaoAnuncia() throws {
        let (primeiro, motor, defaults) = try controlador(#function)
        primeiro.start()
        motor.emite(.ready(releaseDeExemplo))

        let motorNovo = MotorDeMentira()
        motorNovo.currentVersion = "0.5.6"
        let segundo = UpdateController(engine: motorNovo, defaults: defaults)
        segundo.start()
        #expect(segundo.state == .idle)
    }

    @Test("o anúncio da versão nova abre o mesmo painel de mudanças")
    func anuncioAbreOPainel() throws {
        let (primeiro, motor, defaults) = try controlador(
            #function, semente: ["updates.installMode": UpdateInstallMode.silentOnQuit.rawValue]
        )
        primeiro.start()
        motor.emite(.ready(releaseDeExemplo))

        let motorNovo = MotorDeMentira()
        motorNovo.currentVersion = "0.5.6"
        let segundo = UpdateController(engine: motorNovo, defaults: defaults)
        segundo.start()
        segundo.showChangelog()
        #expect(segundo.isShowingChangelog)
        #expect(segundo.changelogBullets
            == ["Convites aceitos não duplicam mais no Google Calendar"])
    }

    // MARK: - Versão em uso

    @Test("a linha de versão vem do bundle, não de um literal")
    func linhaDeVersao() throws {
        let motor = MotorDeMentira()
        motor.currentVersion = "1.2.3"
        motor.currentBuild = "42"
        let (controller, _, _) = try controlador(#function, motor: motor)
        #expect(controller.versionLine == "Versão 1.2.3 (build 42)")
    }
}

@Suite("O idioma das notas de versão")
struct UpdateChangelogLanguageTests {

    private let notas = UpdateChangelog(
        portuguese: ["Convite aceito não duplica", "Dashboard mais rápido"],
        english: ["Accepted invite no longer duplicates", "Faster dashboard"]
    )

    @Test("português do Brasil lê a lista em português")
    func portugues() {
        #expect(notas.bullets(for: .portugueseBrazil) == notas.portuguese)
    }

    /// Alemão e francês leem a lista em inglês de propósito: o appcast carrega
    /// duas listas, não quatro, e inglês é a que essas duas interfaces já
    /// entendem melhor do que português.
    @Test("inglês, alemão e francês leem a lista em inglês", arguments: [
        AppLanguage.english, AppLanguage.german, AppLanguage.french,
    ])
    func inglesParaOResto(language: AppLanguage) {
        #expect(notas.bullets(for: language) == notas.english)
    }

    @Test("faltando a lista do idioma pedido, a outra entra no lugar")
    func recuoEntreIdiomas() {
        let soIngles = UpdateChangelog(portuguese: [], english: ["Only English"])
        #expect(soIngles.bullets(for: .portugueseBrazil) == ["Only English"])

        let soPortugues = UpdateChangelog(portuguese: ["Só português"], english: [])
        #expect(soPortugues.bullets(for: .english) == ["Só português"])
    }

    /// O Sparkle guarda **uma** `<description>` por item: ele escolhe a do
    /// idioma preferido do sistema e descarta as outras. Então a lista que
    /// chega pode não ter idioma declarado — e ela tem de aparecer de todo
    /// jeito, em vez de o painel ficar vazio.
    @Test("a lista sem idioma declarado aparece em qualquer interface")
    func listaSemIdioma() {
        let semIdioma = UpdateChangelog(undetermined: ["Uma linha só"])
        for language in [AppLanguage.portugueseBrazil, .english, .german, .french] {
            #expect(semIdioma.bullets(for: language) == ["Uma linha só"])
        }
    }

    @Test("notas vazias não inventam marcador nenhum")
    func notasVazias() {
        #expect(UpdateChangelog().bullets(for: .portugueseBrazil).isEmpty)
    }
}

@Suite("As notas de versão vindas do HTML do appcast")
struct UpdateChangelogParsingTests {

    @Test("cada item da lista vira um marcador, sem marcação nenhuma")
    func listaHTML() {
        let html = """
            <ul><li>Convite aceito não duplica no Google Calendar</li>\
            <li>Prioridades do dia ficaram <strong>mais rápidas</strong></li></ul>
            """
        #expect(UpdateChangelog.bullets(fromHTML: html) == [
            "Convite aceito não duplica no Google Calendar",
            "Prioridades do dia ficaram mais rápidas",
        ])
    }

    @Test("entidades HTML voltam a ser texto")
    func entidades() {
        let html = "<ul><li>Pastas &amp; etiquetas &lt;novas&gt; &#8212; com &quot;aspas&quot;</li></ul>"
        #expect(UpdateChangelog.bullets(fromHTML: html)
            == ["Pastas & etiquetas <novas> — com \"aspas\""])
    }

    /// Nem todo release vai sair com `<ul>`. Um parágrafo, um `<br>` ou texto
    /// cru continuam dizendo o que mudou, e o painel não pode ficar vazio só
    /// porque o gerador mudou de marcação.
    @Test("sem lista, o que houver é lido linha por linha")
    func semLista() {
        #expect(UpdateChangelog.bullets(fromHTML: "<p>Correção do convite</p><p>Agenda mais rápida</p>")
            == ["Correção do convite", "Agenda mais rápida"])
        #expect(UpdateChangelog.bullets(fromHTML: "Primeira<br>Segunda")
            == ["Primeira", "Segunda"])
        #expect(UpdateChangelog.bullets(fromHTML: "  Uma linha crua  ") == ["Uma linha crua"])
    }

    @Test("HTML vazio ou só com espaços não produz marcador")
    func vazio() {
        #expect(UpdateChangelog.bullets(fromHTML: "").isEmpty)
        #expect(UpdateChangelog.bullets(fromHTML: "<ul><li> </li><li></li></ul>").isEmpty)
        #expect(UpdateChangelog.bullets(fromHTML: "   \n  ").isEmpty)
    }

    @Test("a description única do appcast separa as duas listas pelo lang")
    func listasMarcadasPorIdioma() {
        let html = #"<ul lang="pt-BR"><li>Convite sem cópia</li></ul><ul lang="en"><li>Invite without copy</li><li>Faster</li></ul>"#
        let changelog = UpdateChangelog(appcastHTML: html)
        #expect(changelog.portuguese == ["Convite sem cópia"])
        #expect(changelog.english == ["Invite without copy", "Faster"])
        #expect(changelog.undetermined.isEmpty)
        #expect(changelog.bullets(for: .portugueseBrazil) == ["Convite sem cópia"])
        #expect(changelog.bullets(for: .german) == ["Invite without copy", "Faster"])
    }

    @Test("sem lang, a lista do appcast continua sem idioma declarado")
    func listaSemIdioma() {
        let changelog = UpdateChangelog(appcastHTML: "<ul><li>Uma coisa</li></ul>")
        #expect(changelog == UpdateChangelog(undetermined: ["Uma coisa"]))
    }
}

@Suite("O clique no ícone de atualização")
@MainActor
struct UpdateIconClickTests {

    @Test("sem nada novo, o clique abre o painel e já procura")
    func cliqueSemNovidadeProcura() throws {
        let (controller, motor, _) = try controlador("clique-parado")
        controller.openPanel()
        #expect(controller.isShowingChangelog)
        #expect(motor.buscas == 1)
        #expect(controller.isChecking)
        #expect(controller.readyVersion == nil)
        #expect(controller.currentVersion == "0.5.5")
    }

    @Test("com versão pronta, o clique só abre o changelog, sem procurar de novo")
    func cliqueProntaNaoProcura() throws {
        let (controller, motor, _) = try controlador("clique-pronta")
        motor.emite(.ready(releaseDeExemplo))
        controller.openPanel()
        #expect(controller.isShowingChangelog)
        #expect(motor.buscas == 0)
        #expect(controller.readyVersion == "0.5.6")
    }

    @Test("a busca disparada pelo clique termina em 'versão mais recente'")
    func cliqueTerminaEmAtual() throws {
        let (controller, motor, _) = try controlador("clique-atual")
        controller.openPanel()
        motor.emite(.upToDate(userInitiated: true))
        #expect(controller.manualCheckMessage == L10n.tr("Você está na versão mais recente"))
        controller.dismiss()
        #expect(!controller.isShowingChangelog)
        #expect(controller.state == .idle)
    }
}

