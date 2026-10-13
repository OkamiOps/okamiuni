import AppKit
import Foundation
import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

/// Retratos do atualizador, fora da tela.
///
/// Nenhum caso aqui abre janela, sintetiza clique ou toca na rede: o `Render`
/// hospeda a view numa janela a −50.000pt e fotografa o bitmap. O motor é o
/// mesmo de mentira dos testes de estado — ver `MotorDeMentira`.
@Suite("Retratos do atualizador", .serialized)
@MainActor
struct UpdateRenderTests {

    private static let release = UpdateRelease(
        version: "0.5.6",
        changelog: UpdateChangelog(
            portuguese: [
                "Convites aceitos não duplicam mais no Google Calendar",
                "As prioridades do dia ficaram atuais e proativas",
                "Correções no envio por senha de app",
            ],
            english: ["Accepted invites no longer duplicate"]
        ),
        releaseURL: URL(string: "https://github.com/okamiops/okamiuni/releases/tag/v0.5.6")
    )

    private func controlador(
        _ nome: String, pronta: Bool
    ) throws -> UpdateController {
        let defaults = try #require(UserDefaults(suiteName: "render-updates-\(nome)"))
        defaults.removePersistentDomain(forName: "render-updates-\(nome)")
        let motor = MotorDeMentira()
        let controller = UpdateController(engine: motor, defaults: defaults)
        if pronta { motor.emite(.ready(Self.release)) }
        return controller
    }

    /// O controlador na abertura **seguinte** a uma instalação silenciosa.
    private func controladorRecemAtualizado(_ nome: String) throws -> UpdateController {
        let suite = "render-updates-\(nome)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let antigo = MotorDeMentira()
        let primeiro = UpdateController(engine: antigo, defaults: defaults)
        primeiro.installMode = .silentOnQuit
        primeiro.start()
        antigo.emite(.ready(Self.release))

        let novo = MotorDeMentira()
        novo.currentVersion = Self.release.version
        let segundo = UpdateController(engine: novo, defaults: defaults)
        segundo.start()
        return segundo
    }

    // MARK: - O botão do rodapé da lateral

    /// O rodapé da barra, em pontos. O botão da versão nova nasce entre o
    /// cartão da IA e a linha de contas, e é essa faixa que o caso mede — a
    /// imagem inteira mudaria por qualquer outro motivo.
    private static let sidebarSize = CGSize(width: PaneLayout.expandedSidebarWidth, height: 700)
    private static let footerRows = 540..<700

    @Test("o botão da versão nova só aparece com atualização pronta, no claro e no escuro")
    func botaoApareceSoQuandoPronta() async throws {
        for theme in [Theme.tinta, Theme.noite] {
            let store = MailStore(source: InMemoryMailSource.fixtures)
            await store.load()

            let parado = try controlador("parado-\(theme.id)", pronta: false)
            #expect(!parado.showsReadyButton)
            let semBotao = try #require(Render.snapshot(
                FolderSidebar(store: store, onOpenAccounts: {}, updates: parado),
                named: "atualizacao-sem-botao-\(theme.id)",
                size: Self.sidebarSize, theme: theme
            ))

            let pronto = try controlador("pronto-\(theme.id)", pronta: true)
            #expect(pronto.showsReadyButton)
            let comBotao = try #require(Render.snapshot(
                FolderSidebar(store: store, onOpenAccounts: {}, updates: pronto),
                named: "atualizacao-com-botao-\(theme.id)",
                size: Self.sidebarSize, theme: theme
            ))

            // O ponto do botão é a única coisa do rodapé pintada no acento.
            let acentoComBotao = comBotao.pixels(
                matching: theme.accent, tolerance: 0.02, y: Self.footerRows
            )
            let acentoSemBotao = semBotao.pixels(
                matching: theme.accent, tolerance: 0.02, y: Self.footerRows
            )
            #expect(
                acentoComBotao > acentoSemBotao,
                "\(theme.id): o ponto de acento do botão não apareceu no rodapé"
            )
            #expect(
                comBotao.pixelsDiffering(from: semBotao, inColumns: 0..<comBotao.pixelsWide, rows: Self.footerRows) > 0,
                "\(theme.id): o rodapé ficou idêntico com e sem o botão"
            )
        }
    }

    /// No modo silencioso o botão **não** existe, mesmo com a atualização
    /// pronta no disco. É a promessa que a pessoa aceitou ao escolher o
    /// silêncio, e ela tem de valer no desenho, não só no estado.
    @Test("no modo silencioso o rodapé fica igual ao de sempre")
    func modoSilenciosoNaoDesenhaBotao() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()

        let silencioso = try controlador("silencioso", pronta: false)
        silencioso.installMode = .silentOnQuit
        let semBotao = try #require(Render.snapshot(
            FolderSidebar(store: store, onOpenAccounts: {}, updates: silencioso),
            named: "atualizacao-silenciosa-sem-botao",
            size: Self.sidebarSize, theme: .tinta
        ))

        let comAtualizacao = try controlador("silencioso-pronta", pronta: true)
        comAtualizacao.installMode = .silentOnQuit
        #expect(!comAtualizacao.showsReadyButton)
        let aindaSemBotao = try #require(Render.snapshot(
            FolderSidebar(store: store, onOpenAccounts: {}, updates: comAtualizacao),
            named: "atualizacao-silenciosa-pronta",
            size: Self.sidebarSize, theme: .tinta
        ))

        #expect(aindaSemBotao.pixelsDiffering(from: semBotao) == 0)
    }

    // MARK: - O painel

    private static let panelSize = CGSize(width: UpdatePanel.width, height: 230)

    @Test("o painel desenha versão, mudanças e as duas ações, no claro e no escuro")
    func painelDaAtualizacaoPronta() throws {
        for theme in [Theme.tinta, Theme.noite] {
            let pronto = try controlador("painel-\(theme.id)", pronta: true)
            #expect(pronto.changelogBullets.count == 3)

            let rep = try #require(Render.snapshot(
                UpdatePanel(controller: pronto),
                named: "painel-atualizacao-pronta-\(theme.id)",
                size: Self.panelSize, theme: theme
            ))
            #expect(rep.pixelsWide == Int(UpdatePanel.width))
            // "Instalar e reabrir" é o único acento cheio do painel.
            #expect(
                rep.pixels(matching: theme.accent, tolerance: 0.02) > 400,
                "\(theme.id): o botão primário do painel não foi pintado no acento"
            )
            #expect(
                rep.pixels(matching: theme.surface, tolerance: 0.01) > 10_000,
                "\(theme.id): o painel perdeu a superfície de fundo"
            )
        }
    }

    /// Uma versão **já instalada** não oferece "Instalar e reabrir": não há o
    /// que instalar. O painel é o mesmo, o rodapé não.
    @Test("o painel da versão já instalada não oferece instalar")
    func painelDaVersaoJaInstalada() throws {
        let pronto = try controlador("rodape-pronta", pronta: true)
        let instalado = try controladorRecemAtualizado("rodape-instalada")
        #expect(instalado.state == .justUpdated(version: "0.5.6", changelog: Self.release.changelog))

        let comAcao = try #require(Render.snapshot(
            UpdatePanel(controller: pronto),
            named: "painel-rodape-pronta", size: Self.panelSize, theme: .tinta
        ))
        let semAcao = try #require(Render.snapshot(
            UpdatePanel(controller: instalado),
            named: "painel-rodape-instalada", size: Self.panelSize, theme: .tinta
        ))
        #expect(
            semAcao.pixels(matching: Theme.tinta.accent, tolerance: 0.02)
                < comAcao.pixels(matching: Theme.tinta.accent, tolerance: 0.02),
            "o painel da versão instalada continuou com o botão de acento"
        )
    }

    @Test("o painel sem notas de versão continua desenhando versão e ações")
    func painelSemNotas() throws {
        let defaults = try #require(UserDefaults(suiteName: "render-updates-sem-notas"))
        defaults.removePersistentDomain(forName: "render-updates-sem-notas")
        let motor = MotorDeMentira()
        let controller = UpdateController(engine: motor, defaults: defaults)
        motor.emite(.ready(UpdateRelease(
            version: "0.5.6", changelog: UpdateChangelog(), releaseURL: nil
        )))
        #expect(controller.changelogBullets.isEmpty)

        let rep = try #require(Render.snapshot(
            UpdatePanel(controller: controller),
            named: "painel-sem-notas", size: CGSize(width: UpdatePanel.width, height: 120),
            theme: .tinta
        ))
        #expect(rep.pixels(matching: Theme.tinta.accent, tolerance: 0.02) > 400)
    }

    // MARK: - O cartão de Configurações ▸ Geral

    private static let settingsSize = CGSize(width: 900, height: 900)

    @Test("o cartão de Atualizações desenha em Geral, no claro e no escuro")
    func cartaoEmGeral() throws {
        for theme in [Theme.tinta, Theme.noite] {
            let controller = try controlador("ajustes-\(theme.id)", pronta: false)
            let rep = try #require(Render.snapshot(
                GeneralSettingsView(
                    scope: .general,
                    settingsStore: nil, credentialStore: nil, textAssistant: nil,
                    updates: controller, themes: ThemeStore(), swipes: nil
                ),
                named: "ajustes-atualizacoes-\(theme.id)",
                size: Self.settingsSize, theme: theme
            ))
            #expect(rep.pixelsWide == Int(Self.settingsSize.width))
            #expect(
                rep.pixels(matching: theme.surface2, tolerance: 0.01) > 10_000,
                "\(theme.id): o cartão perdeu a superfície de cartão"
            )
        }
    }

    /// O aviso de assinatura inválida é uma faixa que **tem** de aparecer: ela
    /// é o único lugar onde o app conta que uma atualização foi recusada.
    @Test("o aviso de assinatura inválida muda o cartão de Atualizações")
    func avisoDeAssinaturaNoCartao() throws {
        let limpo = try controlador("ajustes-limpo", pronta: false)
        let semAviso = try #require(Render.snapshot(
            GeneralSettingsView(
                scope: .general,
                settingsStore: nil, credentialStore: nil, textAssistant: nil,
                updates: limpo, themes: ThemeStore(), swipes: nil
            ),
            named: "ajustes-sem-aviso", size: Self.settingsSize, theme: .tinta
        ))

        let defaults = try #require(UserDefaults(suiteName: "render-updates-assinatura"))
        defaults.removePersistentDomain(forName: "render-updates-assinatura")
        let motor = MotorDeMentira()
        let comFalha = UpdateController(engine: motor, defaults: defaults)
        motor.emite(.failed(.invalidSignature, userInitiated: false))
        #expect(comFalha.signatureWarning == UpdateFailure.invalidSignature.message)

        let comAviso = try #require(Render.snapshot(
            GeneralSettingsView(
                scope: .general,
                settingsStore: nil, credentialStore: nil, textAssistant: nil,
                updates: comFalha, themes: ThemeStore(), swipes: nil
            ),
            named: "ajustes-com-aviso", size: Self.settingsSize, theme: .tinta
        ))

        #expect(comAviso.pixelsDiffering(from: semAviso) > 0)
        #expect(
            comAviso.pixels(matching: Theme.tinta.accentSoft, tolerance: 0.02)
                > semAviso.pixels(matching: Theme.tinta.accentSoft, tolerance: 0.02),
            "a faixa do aviso não apareceu no cartão"
        )
    }

    /// Sem atualizador — o caso dos builds de desenvolvimento — o cartão
    /// continua existindo e diz a versão em uso.
    @Test("sem atualizador, o cartão explica por que não há atualização")
    func cartaoSemAtualizador() throws {
        let rep = try #require(Render.snapshot(
            GeneralSettingsView(
                scope: .general,
                settingsStore: nil, credentialStore: nil, textAssistant: nil,
                updates: nil, themes: ThemeStore(), swipes: nil
            ),
            named: "ajustes-sem-atualizador", size: Self.settingsSize, theme: .tinta
        ))
        #expect(rep.pixelsHigh == Int(Self.settingsSize.height))
        #expect(GeneralSettingsView.bundleVersionLine.hasPrefix("Versão "))
    }
}
