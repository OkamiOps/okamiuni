import Foundation
import NIOPosix
import SwiftUI
import Testing
import UNICore
import UNIDesign
import UNISync
@testable import UNIShell

/// Retratos focais das áreas que a central de Configurações monta.
///
/// Estes casos exercitam a rota pública de `AccountsWindow` (e não somente as
/// subviews internas): cada seção é criada com as dependências que o app real
/// injeta, mas tudo fica em banco temporário, UserDefaults isolado e cofre de
/// credenciais em memória. O `Render` hospeda a view fora da tela; nenhum
/// evento é enviado ao desktop.
@Suite("As quatro seções de Configurações", .serialized)
@MainActor
struct SettingsSectionsTests {
    private let renderSize = CGSize(width: 1_180, height: 820)
    private let compactRenderSize = CGSize(width: 960, height: 680)
    private let createdAt = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("o rótulo da rota interativa mostra o modelo escolhido, exceto no Foundation Models")
    func assistantRouteLabelCarregaModelo() {
        var remoto = AssistantSettings.default
        remoto.provider = .providerOAuth
        remoto.providerOAuth.kind = .codex
        remoto.providerOAuth.model = "gpt-4"
        let rotuloRemoto = GeneralSettingsView.assistantRouteLabel(for: remoto)
        #expect(rotuloRemoto.contains("gpt-4"))
        #expect(rotuloRemoto == "Codex · ChatGPT · gpt-4")

        var openAI = AssistantSettings.default
        openAI.provider = .openAICompatible
        openAI.openAICompatible.endpoint = "https://api.exemplo.com/v1"
        openAI.openAICompatible.model = "gpt-4o-mini"
        let rotuloOpenAI = GeneralSettingsView.assistantRouteLabel(for: openAI)
        #expect(rotuloOpenAI.contains("gpt-4o-mini"))

        let local = AssistantSettings.default
        let rotuloLocal = GeneralSettingsView.assistantRouteLabel(for: local)
        #expect(rotuloLocal == "Neste Mac")
        #expect(!rotuloLocal.localizedCaseInsensitiveContains("gpt"))
    }

    @Test("Geral apresenta o ambiente atual sem iniciar o login de IA")
    func geralRenderizaAmbiente() async throws {
        let model = try await model(with: [account(
            id: "trabalho", address: "marcos@trabalho.example", host: "trabalho"
        )])
        let suite = try isolatedDefaults()
        defer { suite.defaults.removePersistentDomain(forName: suite.name) }
        let settings = AssistantSettingsStore(defaults: suite.defaults, key: "assistant-ui-general")
        _ = try settings.save(.init())
        let authorizer = SettingsProviderOAuthAuthorizer(status: .signedIn)

        let image = try #require(Render.snapshot(
            AccountsWindow(
                model: model,
                initialSection: .general,
                assistantSettings: settings,
                providerOAuthAuthorizer: authorizer,
                themes: ThemeStore(defaults: suite.defaults),
                swipes: SwipeSettingsStore(defaults: suite.defaults)
            ),
            named: "settings-geral-ambiente",
            size: renderSize,
            theme: .tinta
        ))

        #expect(authorizer.modelRequestCount == 0)
        #expect(image.pixelsWide == Int(renderSize.width))
        #expect(image.pixels(matching: Theme.tinta.accentSoft) > 500)
    }

    @Test("Geral permanece legível nos tamanhos menor e maior")
    func geralRenderizaExtremosTipograficos() async throws {
        let model = try await model(with: [account(
            id: "trabalho", address: "marcos@trabalho.example", host: "trabalho"
        )])
        let suite = try isolatedDefaults()
        defer { suite.defaults.removePersistentDomain(forName: suite.name) }
        let themes = ThemeStore(defaults: suite.defaults)
        themes.select(.reboot)

        for preset in [TypographyPreset.compact, .enlarged] {
            themes.selectTypography(preset)
            let image = try #require(Render.snapshot(
                AccountsWindow(
                    model: model,
                    initialSection: .general,
                    themes: themes,
                    swipes: SwipeSettingsStore(defaults: suite.defaults)
                ),
                named: "settings-geral-texto-\(preset.rawValue)-reboot",
                size: compactRenderSize,
                theme: Theme.reboot.applyingTypography(preset)
            ))

            #expect(image.pixelsWide == Int(compactRenderSize.width))
            #expect(image.pixelsHigh == Int(compactRenderSize.height))
            #expect(image.pixels(matching: Theme.reboot.accentSoft) > 500)
        }
    }

    @Test("Agenda apresenta o serviço padrão de cada conta")
    func agendaRenderizaSalas() async throws {
        let model = try await model(with: [account(
            id: "trabalho", address: "marcos@trabalho.example", host: "trabalho"
        )])
        let suite = try isolatedDefaults()
        defer { suite.defaults.removePersistentDomain(forName: suite.name) }
        let rooms = MeetingRoomSettingsStore(defaults: suite.defaults)
        rooms.setDefault(.meet, for: "trabalho")

        let image = try #require(Render.snapshot(
            AccountsWindow(
                model: model,
                initialSection: .agenda,
                themes: ThemeStore(defaults: suite.defaults),
                meetingRooms: rooms
            ),
            named: "settings-agenda-salas",
            size: renderSize,
            theme: .tinta
        ))

        #expect(image.pixelsWide == Int(renderSize.width))
        #expect(image.pixels(matching: Theme.tinta.accentSoft) > 400)
    }

    @Test("Remetentes mostra o endereço principal da conta")
    func remetentesRenderizaAliases() async throws {
        let model = try await model(with: [account(
            id: "trabalho", address: "marcos@okamiops.com", host: "okamiops"
        )])
        let suite = try isolatedDefaults()
        defer { suite.defaults.removePersistentDomain(forName: suite.name) }

        let image = try #require(Render.snapshot(
            AccountsWindow(
                model: model,
                initialSection: .aliases,
                themes: ThemeStore(defaults: suite.defaults),
                swipes: SwipeSettingsStore(defaults: suite.defaults)
            ),
            named: "settings-remetentes",
            size: renderSize,
            theme: .okami
        ))

        #expect(image.pixelsWide == Int(renderSize.width))
        #expect(image.pixelsHigh == Int(renderSize.height))
    }

    @Test("Inteligência renderiza preferências de IA com credencial em memória")
    func inteligenciaRenderiza() async throws {
        let model = try await model(with: [account(
            id: "trabalho", address: "marcos@trabalho.example", host: "trabalho"
        )])
        let suite = try isolatedDefaults()
        defer { suite.defaults.removePersistentDomain(forName: suite.name) }

        let settings = AssistantSettingsStore(defaults: suite.defaults, key: "assistant-ui")
        let configuration = AssistantSettings(
            provider: .openAICompatible,
            openAICompatible: .init(
                endpoint: "https://proxy.example/v1",
                model: "modelo-de-teste",
                credentialID: "settings-ui-key"
            ),
            additionalInstructions: "Responda com clareza."
        )
        _ = try settings.save(configuration)

        let credentials = InMemoryAssistantCredentialStore()
        try credentials.storeAPIKey("chave-somente-em-memoria", for: "settings-ui-key")
        let detachedCredentialLookup = try await Task.detached {
            try credentials.apiKey(for: "settings-ui-key")?.isEmpty == false
        }.value
        #expect(detachedCredentialLookup)
        let themes = ThemeStore(defaults: suite.defaults)
        let swipes = SwipeSettingsStore(defaults: suite.defaults)

        let image = try #require(Render.snapshot(
            AccountsWindow(
                model: model,
                initialSection: .intelligence,
                assistantSettings: settings,
                assistantCredentials: credentials,
                themes: themes,
                swipes: swipes
            ),
            named: "settings-inteligencia-tinta",
            size: renderSize,
            theme: .tinta
        ))

        #expect(image.pixelsWide == Int(renderSize.width))
        #expect(image.pixelsHigh == Int(renderSize.height))
        #expect(settings.snapshot() == configuration)
        #expect(try credentials.apiKey(for: "settings-ui-key") == "chave-somente-em-memoria")
        // O aviso do provedor remoto é uma superfície accentSoft visível; a
        // asserção impede que Geral caia no estado vazio/default sem conteúdo.
        #expect(
            image.pixels(matching: Theme.tinta.accentSoft) > 500,
            "Inteligência não desenhou o conteúdo de IA configurado"
        )
    }

    @Test("Inteligência renderiza LiteLLM sem autenticação sem pedir uma chave")
    func inteligenciaSemAutenticacaoRenderiza() async throws {
        let model = try await model(with: [account(
            id: "trabalho", address: "marcos@trabalho.example", host: "trabalho"
        )])
        let suite = try isolatedDefaults()
        defer { suite.defaults.removePersistentDomain(forName: suite.name) }

        let settings = AssistantSettingsStore(defaults: suite.defaults, key: "assistant-ui-no-auth")
        let configuration = AssistantSettings(
            provider: .openAICompatible,
            openAICompatible: .init(
                endpoint: "https://proxy.example/v1",
                model: "modelo-sem-auth",
                credentialID: "nao-usar",
                authenticationMode: .none
            )
        )
        _ = try settings.save(configuration)
        let themes = ThemeStore(defaults: suite.defaults)
        let swipes = SwipeSettingsStore(defaults: suite.defaults)

        let image = try #require(Render.snapshot(
            AccountsWindow(
                model: model,
                initialSection: .intelligence,
                assistantSettings: settings,
                themes: themes,
                swipes: swipes
            ),
            named: "settings-inteligencia-litellm-sem-auth",
            size: renderSize,
            theme: .tinta
        ))

        #expect(settings.snapshot() == configuration)
        #expect(image.pixelsWide == Int(renderSize.width))
        #expect(
            image.pixels(matching: Theme.tinta.accentSoft) > 500,
            "Inteligência não desenhou a orientação para proxy sem autenticação"
        )
    }

    @Test("Inteligência renderiza CLI OAuth/device sem cofre de API")
    func inteligenciaCLIAuthRenderiza() async throws {
        let model = try await model(with: [account(
            id: "trabalho", address: "marcos@trabalho.example", host: "trabalho"
        )])
        let suite = try isolatedDefaults()
        defer { suite.defaults.removePersistentDomain(forName: suite.name) }

        let settings = AssistantSettingsStore(defaults: suite.defaults, key: "assistant-ui-cli")
        let configuration = AssistantSettings(
            provider: .cli,
            cli: .init(kind: .openCode)
        )
        _ = try settings.save(configuration)
        let themes = ThemeStore(defaults: suite.defaults)
        let swipes = SwipeSettingsStore(defaults: suite.defaults)

        let image = try #require(Render.snapshot(
            AccountsWindow(
                model: model,
                initialSection: .intelligence,
                assistantSettings: settings,
                themes: themes,
                swipes: swipes
            ),
            named: "settings-inteligencia-cli-oauth-device",
            size: renderSize,
            theme: .tinta
        ))

        #expect(settings.snapshot() == configuration)
        #expect(image.pixelsWide == Int(renderSize.width))
        #expect(
            image.pixels(matching: Theme.tinta.accentSoft) > 500,
            "Inteligência não desenhou a orientação para a sessão OAuth/device do CLI"
        )
    }

    @Test("Inteligência renderiza sessão OAuth PKCE autenticada com ação de saída")
    func inteligenciaOAuthPKCERenderiza() async throws {
        let model = try await model(with: [account(
            id: "trabalho", address: "marcos@trabalho.example", host: "trabalho"
        )])
        let suite = try isolatedDefaults()
        defer { suite.defaults.removePersistentDomain(forName: suite.name) }

        let settings = AssistantSettingsStore(defaults: suite.defaults, key: "assistant-ui-pkce")
        let configuration = AssistantSettings(
            provider: .openAICompatible,
            openAICompatible: .init(
                endpoint: "https://proxy.example/v1",
                model: "chatgpt/gpt-5",
                credentialID: "oauth-session",
                authenticationMode: .litellmOAuthPKCE
            )
        )
        _ = try settings.save(configuration)
        let authorizer = SettingsOAuthAuthorizer(status: .signedIn)

        let image = try #require(Render.snapshot(
            AccountsWindow(
                model: model,
                initialSection: .intelligence,
                assistantSettings: settings,
                liteLLMOAuthAuthorizer: authorizer,
                themes: ThemeStore(defaults: suite.defaults),
                swipes: SwipeSettingsStore(defaults: suite.defaults)
            ),
            named: "settings-inteligencia-oauth-pkce-autenticado",
            size: renderSize,
            theme: .tinta
        ))

        #expect(settings.snapshot() == configuration)
        #expect(authorizer.status == .signedIn)
        #expect(image.pixelsWide == Int(renderSize.width))
        #expect(image.pixels(matching: Theme.tinta.accentSoft) > 500)
    }

    @Test("Inteligência renderiza OAuth direto com código de dispositivo oficial")
    func inteligenciaProviderOAuthDeviceCodeRenderiza() async throws {
        let model = try await model(with: [account(
            id: "trabalho", address: "marcos@trabalho.example", host: "trabalho"
        )])
        let suite = try isolatedDefaults()
        defer { suite.defaults.removePersistentDomain(forName: suite.name) }

        let configuration = AssistantSettings(
            provider: .providerOAuth,
            providerOAuth: .init(
                kind: .xAI,
                model: "grok-4-test",
                credentialID: "oauth-grok-settings-ui"
            ),
            additionalInstructions: "Mantenha a resposta objetiva."
        )
        let settings = AssistantSettingsStore(defaults: suite.defaults, key: "assistant-ui-provider-oauth")
        _ = try settings.save(configuration)

        let authorization = AssistantProviderOAuthDeviceAuthorization(
            kind: .xAI,
            verificationURL: try #require(URL(string: "https://auth.x.ai/device")),
            userCode: "KITSUNE-1234",
            expiresAt: createdAt.addingTimeInterval(600),
            pollInterval: 5
        )
        let authorizer = SettingsProviderOAuthAuthorizer(
            status: .awaitingDeviceCode(authorization)
        )

        let image = try #require(Render.snapshot(
            AccountsWindow(
                model: model,
                initialSection: .intelligence,
                assistantSettings: settings,
                providerOAuthAuthorizer: authorizer,
                themes: ThemeStore(defaults: suite.defaults),
                swipes: SwipeSettingsStore(defaults: suite.defaults)
            ),
            named: "settings-inteligencia-oauth-direto-device-code",
            size: renderSize,
            theme: .tinta
        ))

        // O retrato não dispara botões nem abre URL: verifica somente o estado
        // seguro entregue pelo serviço, como aconteceria antes da pessoa clicar
        // em "Abrir página".
        #expect(settings.snapshot() == configuration)
        #expect(authorizer.status == .awaitingDeviceCode(authorization))
        #expect(image.pixelsWide == Int(renderSize.width))
        #expect(
            image.pixels(matching: Theme.tinta.accentSoft) > 500,
            "OAuth direto não desenhou a superfície do código de dispositivo"
        )
    }

    @Test("Inteligência carrega o catálogo OAuth da conta em vez de usar modelo fixo")
    func inteligenciaProviderOAuthCatalogoRenderiza() async throws {
        let model = try await model(with: [account(
            id: "trabalho", address: "marcos@trabalho.example", host: "trabalho"
        )])
        let suite = try isolatedDefaults()
        defer { suite.defaults.removePersistentDomain(forName: suite.name) }

        let configuration = AssistantSettings(
            provider: .providerOAuth,
            providerOAuth: .init(
                kind: .codex,
                model: "modelo-salvo-antigo",
                credentialID: "oauth-codex-settings-ui"
            )
        )
        let settings = AssistantSettingsStore(
            defaults: suite.defaults,
            key: "assistant-ui-provider-oauth-catalog"
        )
        _ = try settings.save(configuration)
        let authorizer = SettingsProviderOAuthAuthorizer(
            status: .signedIn,
            models: [
                .init(id: "gpt-conta-a", displayName: "Conta A"),
                .init(id: "gpt-conta-b", displayName: "Conta B"),
            ]
        )

        let image = try #require(Render.snapshot(
            AccountsWindow(
                model: model,
                initialSection: .intelligence,
                assistantSettings: settings,
                providerOAuthAuthorizer: authorizer,
                themes: ThemeStore(defaults: suite.defaults),
                swipes: SwipeSettingsStore(defaults: suite.defaults)
            ),
            named: "settings-inteligencia-oauth-catalogo-vivo",
            size: renderSize,
            theme: .tinta
        ))

        #expect(authorizer.modelRequestCount > 0)
        #expect(authorizer.requestedKinds == [.codex])
        #expect(image.pixelsWide == Int(renderSize.width))
        #expect(image.pixels(matching: Theme.tinta.accentSoft) > 500)
    }

    @Test("Inteligência mantém provedor, conta e modelo na mesma coluna")
    func inteligenciaOAuthAlinhamentoCompleto() async throws {
        let model = try await model(with: [account(
            id: "trabalho", address: "marcos@trabalho.example", host: "trabalho"
        )])
        let suite = try isolatedDefaults()
        defer { suite.defaults.removePersistentDomain(forName: suite.name) }

        let settings = AssistantSettingsStore(
            defaults: suite.defaults,
            key: "assistant-ui-provider-oauth-alignment"
        )
        _ = try settings.save(AssistantSettings(
            provider: .providerOAuth,
            providerOAuth: .init(
                kind: .codex,
                model: "gpt-5.6-luna",
                credentialID: "oauth-codex-alignment"
            )
        ))
        let authorizer = SettingsProviderOAuthAuthorizer(
            status: .signedIn,
            models: [.init(id: "gpt-5.6-luna", displayName: "GPT-5.6-Luna")]
        )
        let tallSize = CGSize(width: 1_180, height: 1_500)

        let image = try #require(Render.snapshot(
            AccountsWindow(
                model: model,
                initialSection: .intelligence,
                assistantSettings: settings,
                providerOAuthAuthorizer: authorizer,
                themes: ThemeStore(defaults: suite.defaults),
                swipes: SwipeSettingsStore(defaults: suite.defaults)
            ),
            named: "settings-inteligencia-oauth-alinhamento-reboot",
            size: tallSize,
            theme: .reboot
        ))

        #expect(authorizer.modelRequestCount > 0)
        #expect(image.pixelsWide == Int(tallSize.width))
        #expect(image.pixelsHigh == Int(tallSize.height))
        #expect(image.pixels(matching: Theme.reboot.accentSoft) > 500)
    }

    @Test("Inteligência separa preferências humanas do prompt efetivo")
    func inteligenciaRenderizaPreferenciasPersistidas() async throws {
        let model = try await model(with: [account(
            id: "trabalho", address: "marcos@trabalho.example", host: "trabalho"
        )])
        let suite = try isolatedDefaults()
        defer { suite.defaults.removePersistentDomain(forName: suite.name) }

        let configuration = AssistantSettings(
            provider: .foundationModels,
            behavior: .init(
                tone: .direct,
                detail: .concise,
                language: .followConversation,
                format: .executive,
                suggestNextSteps: false,
                questionsInstructions: "Destaque decisões e riscos.",
                writingInstructions: "Não invente prazos."
            ),
            additionalInstructions: "Prefira comunicação objetiva."
        )
        let settings = AssistantSettingsStore(
            defaults: suite.defaults,
            key: "assistant-ui-behavior"
        )
        _ = try settings.save(configuration)

        let image = try #require(Render.snapshot(
            AccountsWindow(
                model: model,
                initialSection: .intelligence,
                assistantSettings: settings,
                themes: ThemeStore(defaults: suite.defaults),
                swipes: SwipeSettingsStore(defaults: suite.defaults)
            ),
            named: "settings-inteligencia-preferencias",
            size: renderSize,
            theme: .tinta
        ))

        #expect(settings.snapshot().behavior == configuration.behavior)
        #expect(image.pixelsWide == Int(renderSize.width))
        #expect(
            image.pixels(matching: Theme.tinta.accentSoft) > 500,
            "Inteligência não desenhou os controles persistidos de comportamento"
        )
    }

    @Test("Gestos mostra o ensaio completo sem estourar a janela compacta")
    func gestosRenderizamEnsaio() async throws {
        let model = try await model(with: [
            account(id: "trabalho", address: "marcos@trabalho.example", host: "trabalho"),
            account(id: "pessoal", address: "marcos@pessoal.example", host: "pessoal")
        ])
        let suite = try isolatedDefaults()
        defer { suite.defaults.removePersistentDomain(forName: suite.name) }
        let swipes = SwipeSettingsStore(defaults: suite.defaults)
        swipes.setActions([.archive, .toggleFlag], on: .leading)
        swipes.setActions([.today, .toggleRead, .trash], on: .trailing)
        let destination = SwipeMoveDestination(
            imapFolder: MailFolder(
                id: "trabalho-projetos",
                accountID: "trabalho",
                serverName: "Projetos",
                displayName: "Projetos",
                role: .other
            ),
            accountLabel: "marcos@trabalho.example"
        )
        let personalDestination = SwipeMoveDestination(
            imapFolder: MailFolder(
                id: "pessoal-referencias",
                accountID: "pessoal",
                serverName: "Referências",
                displayName: "Referências",
                role: .other
            ),
            accountLabel: "marcos@pessoal.example"
        )
        #expect(swipes.setMoveDestination(destination, on: .leading, for: "trabalho"))
        #expect(swipes.setMoveDestination(personalDestination, on: .leading, for: "pessoal"))

        let image = try #require(Render.snapshot(
            AccountsWindow(
                model: model,
                initialSection: .gestures,
                themes: ThemeStore(defaults: suite.defaults),
                swipes: swipes
            ),
            named: "settings-gestos-ensaio",
            size: renderSize,
            theme: .tinta
        ))

        #expect(swipes.configuration.leading == [.archive, .toggleFlag, .moveToDestination])
        #expect(swipes.configuration.trailing == [.today, .toggleRead, .trash])
        #expect(swipes.configuration.destination(on: .leading, for: "trabalho") == destination)
        #expect(swipes.configuration.destination(on: .leading, for: "pessoal") == personalDestination)
        #expect(image.pixelsWide == Int(renderSize.width))
        #expect(
            image.pixels(matching: Theme.tinta.accent) > 900,
            "Gestos não desenhou as ações fortes no ensaio visual"
        )

        let compactImage = try #require(Render.snapshot(
            AccountsWindow(
                model: model,
                initialSection: .gestures,
                themes: ThemeStore(defaults: suite.defaults),
                swipes: swipes
            ),
            named: "settings-gestos-compacta-960x680",
            size: compactRenderSize,
            theme: .tinta
        ))
        #expect(compactImage.pixelsWide == Int(compactRenderSize.width))
        #expect(compactImage.pixelsHigh == Int(compactRenderSize.height))
    }

    @Test("Contas renderiza a lista e o detalhe da conta selecionada")
    func contasRenderiza() async throws {
        let contas = [
            account(
                id: "trabalho", address: "marcos@trabalho.example", host: "trabalho",
                state: .erroDeAutenticacao
            ),
            account(
                id: "pessoal", address: "marcos@pessoal.example", host: "pessoal",
                tintLightHex: "#41845B", tintDarkHex: "#74C58F"
            ),
        ]
        let model = try await model(with: contas)

        let image = try #require(Render.snapshot(
            AccountsWindow(model: model, initialSection: .accounts),
            named: "settings-contas-tinta",
            size: renderSize,
            theme: .tinta
        ))

        #expect(model.statuses.map(\.accountID) == ["trabalho", "pessoal"])
        #expect(model.statuses.first?.state == .erroDeAutenticacao)
        #expect(image.pixelsWide == Int(renderSize.width))

        // A lista de contas e o painel de detalhe ocupam superfícies próprias;
        // contar a seleção/estado accent evita um retrato de janela vazia que
        // ainda teria a mesma largura.
        #expect(
            pixels(image, matching: Theme.tinta.accent,
                   in: CGRect(x: 180, y: 70, width: 225, height: 140)) > 200,
            "Contas não desenhou a seleção/estado da conta"
        )
    }

    @Test("Assinaturas renderiza a assinatura da conta no editor")
    func assinaturasRenderiza() async throws {
        let comAssinatura = account(
            id: "trabalho", address: "marcos@trabalho.example", host: "trabalho",
            signature: "Marcos\nOkamiUNI"
        )
        let model = try await model(with: [comAssinatura])

        let image = try #require(Render.snapshot(
            AccountsWindow(model: model, initialSection: .signatures),
            named: "settings-assinaturas-tinta",
            size: renderSize,
            theme: .tinta
        ))

        #expect(model.statuses.first?.signature == "Marcos\nOkamiUNI")
        #expect(image.pixelsWide == Int(renderSize.width))
        // O editor e seus controles usam surfaces/linhas do tema; uma imagem
        // só com o papel de fundo não representa a seção carregada.
        #expect(
            pixels(image, matching: Theme.tinta.surface,
                   in: CGRect(x: 400, y: 175, width: 620, height: 270)) > 50_000,
            "Assinaturas não desenhou o editor da conta"
        )
    }

    @Test("assinatura HTML abre diretamente na prévia e preserva HTML como fonte")
    func assinaturaHTMLAbreNaPrevia() throws {
        let signature = try EmailSignature(
            plainText: "Marcos Santos · Vantion",
            html: "<table role=\"presentation\" style=\"width:600px\"><tr><td>Marcos Santos</td></tr></table>"
        )
        let textOnly = EmailSignature(legacyText: "Marcos Santos")

        #expect(SignatureSettingsView.initialEditorMode(for: signature) == .preview)
        #expect(SignatureSettingsView.initialCanonicalSource(for: signature) == .html)
        #expect(SignatureSettingsView.initialEditorMode(for: textOnly) == .visual)
        #expect(SignatureSettingsView.initialCanonicalSource(for: textOnly) == .visual)
    }

    @Test("salvar HTML colado normaliza data image em CID sem achatar a tabela")
    func assinaturaHTMLColadaUsaImportadorNoSave() throws {
        let logo = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])
        let prepared = try SignatureSettingsView.importedSignature(
            html: """
            <!doctype html><html><body>
            <table role="presentation" style="width:600px">
              <tr><td><img src="data:image/png;base64,\(logo.base64EncodedString())" alt="Vantion" width="190"></td>
              <td><strong>Marcos Santos</strong></td></tr>
            </table>
            </body></html>
            """,
            resources: []
        )
        let html = try #require(prepared.signature.html)

        #expect(html.contains("<table role=\"presentation\""))
        #expect(html.contains("src=\"cid:"))
        #expect(html.contains("data:image") == false)
        #expect(prepared.signature.inlineResources.count == 1)
        #expect(prepared.signature.inlineResources[0].data == logo)
        #expect(prepared.warnings.isEmpty)
    }

    @Test("Regras renderiza regras persistidas no store em memória")
    func regrasRenderiza() async throws {
        let model = try await model(with: [account(
            id: "trabalho", address: "marcos@trabalho.example", host: "trabalho"
        )])
        let rules = EmailRuleStore(inMemory: [
            EmailRule(
                id: "boletins", name: "Arquivar boletins",
                condition: .senderContains("news@example.com"),
                actions: [.archive]
            ),
            EmailRule(
                id: "reunioes", name: "Sinalizar reuniões",
                condition: .subjectContains("reunião"),
                actions: [.flag, .markRead], enabled: true
            ),
        ])

        let image = try #require(Render.snapshot(
            AccountsWindow(model: model, initialSection: .rules, emailRules: rules),
            named: "settings-regras-tinta",
            size: renderSize,
            theme: .tinta
        ))

        #expect(rules.rules.map(\.id) == ["boletins", "reunioes"])
        #expect(image.pixelsWide == Int(renderSize.width))
        #expect(
            pixels(image, matching: Theme.tinta.surface3,
                   in: CGRect(x: 250, y: 145, width: 235, height: 75)) > 500,
            "Regras não desenhou a lista/editor de regras"
        )
    }

    @Test("Regras mostra encaminhamento e destino real sem esconder os avisos")
    func regrasRenderizaEncaminhamentoEMovimento() throws {
        let folder = MailFolder(
            id: "trabalho-clientes",
            accountID: "trabalho",
            serverName: "Clientes",
            displayName: "Clientes",
            role: .other
        )
        let destination = SwipeMoveDestination(
            imapFolder: folder,
            accountLabel: "marcos@trabalho.example"
        )
        let forwarding = try #require(
            EmailRuleForwarding(address: "arquivo@trabalho.example")
        )
        let rules = EmailRuleStore(inMemory: [
            EmailRule(
                id: "clientes",
                name: "Organizar clientes",
                condition: .senderContains("cliente.example"),
                actions: [.markRead],
                accountID: "trabalho",
                forwarding: forwarding,
                moveDestination: destination
            ),
        ])
        let accounts = [AccountStatus(
            accountID: "trabalho",
            address: "marcos@trabalho.example",
            hostMark: "trabalho",
            state: .ativa,
            messageCount: 0,
            lastSyncedAt: createdAt,
            error: nil,
            progress: nil
        )]
        let size = CGSize(width: 930, height: 760)

        let image = try #require(Render.snapshot(
            RulesSettingsView(
                store: rules,
                accounts: accounts,
                moveDestinations: [destination]
            ),
            named: "settings-regras-encaminhar-mover-reboot",
            size: size,
            theme: .reboot
        ))

        #expect(image.pixelsWide == Int(size.width))
        #expect(image.pixelsHigh == Int(size.height))
        #expect(image.pixels(matching: Theme.reboot.accentSoft) > 500)
    }

    private func account(
        id: String,
        address: String,
        host: String,
        tintLightHex: String = "#CE2968",
        tintDarkHex: String = "#FF78AD",
        signature: String = "",
        state: Account.State = .ativa
    ) -> Account {
        Account(
            id: id,
            address: address,
            displayName: host.capitalized,
            provider: .imap,
            host: host,
            tintLightHex: tintLightHex,
            tintDarkHex: tintDarkHex,
            signature: signature,
            imap: ImapEndpoint(host: "imap.\(host).example", port: 993, security: .tls),
            state: state,
            lastSyncedAt: createdAt
        )
    }

    private func model(with accounts: [Account]) async throws -> AccountsModel {
        let timestamp = createdAt
        let database = try SyncDatabase.temporary()
        try await database.pool.write { connection in
            for (index, account) in accounts.enumerated() {
                try AccountRecord(account, createdAt: timestamp.addingTimeInterval(Double(index)))
                    .insert(connection)
            }
        }

        let director = AccountDirector(
            database: database,
            secrets: InMemorySecretStore(),
            auth: nil,
            session: .shared,
            eventLoopGroup: MultiThreadedEventLoopGroup.singleton,
            imapConnect: { _, _ in throw SyncError.rede("não usado pelo retrato") },
            now: { timestamp }
        )
        let model = AccountsModel(director: director)
        let observer = Task { @MainActor in await model.start() }
        defer { observer.cancel() }

        for _ in 0..<150 {
            if model.statuses.count == accounts.count { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.statuses.count == accounts.count, "o banco temporário não publicou as contas")
        return model
    }

    private func isolatedDefaults() throws -> (name: String, defaults: UserDefaults) {
        let name = "okamiuni.settings-sections.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return (name, defaults)
    }

    private func pixels(
        _ image: NSBitmapImageRep,
        matching token: TokenColor,
        in rect: CGRect,
        tolerance: Double = 0.02
    ) -> Int {
        guard let wanted = token.nsColor.usingColorSpace(.sRGB) else { return 0 }
        let minX = max(0, Int(rect.minX.rounded(.down)))
        let maxX = min(image.pixelsWide, Int(rect.maxX.rounded(.up)))
        let minY = max(0, Int(rect.minY.rounded(.down)))
        let maxY = min(image.pixelsHigh, Int(rect.maxY.rounded(.up)))
        guard minX < maxX, minY < maxY else { return 0 }

        var count = 0
        for y in minY..<maxY {
            for x in minX..<maxX {
                guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      color.alphaComponent > 0.9 else { continue }
                if abs(color.redComponent - wanted.redComponent) < tolerance,
                   abs(color.greenComponent - wanted.greenComponent) < tolerance,
                   abs(color.blueComponent - wanted.blueComponent) < tolerance {
                    count += 1
                }
            }
        }
        return count
    }
}

@MainActor
private final class SettingsOAuthAuthorizer: LiteLLMOAuthAuthorizing {
    nonisolated let sessionState = LiteLLMOAuthSessionState()

    var status: LiteLLMOAuthStatus { sessionState.status }

    init(status: LiteLLMOAuthStatus) {
        sessionState.apply(status)
    }

    func refreshStatus(endpoint: URL, credentialID: String) async {}

    func start(endpoint: URL, credentialID: String) async throws {
        sessionState.apply(.signedIn)
    }

    func signOut(endpoint: URL, credentialID: String) async {
        sessionState.apply(.signedOut)
    }
}

@MainActor
private final class SettingsProviderOAuthAuthorizer: AssistantProviderOAuthAuthorizing {
    nonisolated let sessionState = AssistantProviderOAuthSessionState()
    private let models: [AssistantProviderModel]
    private(set) var modelRequestCount = 0
    private(set) var requestedKinds: [AssistantProviderOAuthKind] = []

    var status: AssistantProviderOAuthStatus { sessionState.status }

    init(
        status: AssistantProviderOAuthStatus,
        models: [AssistantProviderModel] = []
    ) {
        self.models = models
        sessionState.apply(status)
    }

    func refreshStatus(configuration: AssistantProviderOAuthConfiguration) async {}

    func start(configuration: AssistantProviderOAuthConfiguration) async throws {}

    func availableModels(
        configuration: AssistantProviderOAuthConfiguration
    ) async throws -> [AssistantProviderModel] {
        modelRequestCount += 1
        requestedKinds.append(configuration.kind)
        return models
    }

    func cancelAuthorization() async {
        sessionState.apply(.signedOut)
    }

    func signOut(configuration: AssistantProviderOAuthConfiguration) async {
        sessionState.apply(.signedOut)
    }
}
