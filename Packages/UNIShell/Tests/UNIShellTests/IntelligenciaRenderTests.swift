import AppKit
import Foundation
import NIOPosix
import SwiftUI
import Testing
import UNICore
import UNIDesign
import UNISync
@testable import UNIShell

/// Os sete quadros de `IA-Config2.dc.html`, cada um no Vidro, no Vidro Noite e
/// num clássico — 21 retratos, renderizados fora da tela no tamanho do desenho
/// (1280×800).
///
/// Os temas são o mapa que o desenho declara: `claro` é o Vidro, `escuro` é o
/// Vidro Noite, `classico` é o Okami — o mesmo layout, sem vidro.
///
/// Nenhum caso aqui abre janela visível, sintetiza clique, varre o disco por
/// CLIs ou pergunta a um servidor local: as duas portas que tocam o mundo
/// entram por `ConfigIntelligenceProbes`, e é isso que faz "servidor fora do
/// ar" ser um estado desenhado de propósito em vez de um acidente de ambiente.
@Suite("Os quadros da Inteligência", .serialized)
@MainActor
struct IntelligenciaRenderTests {
    private let artboard = CGSize(width: 1_280, height: 800)
    private let createdAt = Date(timeIntervalSince1970: 1_800_000_000)

    /// Os três acabamentos, com o sufixo que o nome do PNG usa.
    private var temas: [(theme: Theme, sufixo: String)] {
        [(.vidro, "claro"), (.vidroNoite, "escuro"), (.okami, "classico")]
    }

    // MARK: 1 — a principal com uma conexão só

    /// Dado esparso: Apple Intelligence e nada mais. Nenhum CLI instalado,
    /// nenhum endpoint gravado, nenhuma sessão de assinatura.
    ///
    /// É o quadro que pega "caixa dentro de caixa" e cartão vazio: com uma
    /// linha só, o cartão de "Conectadas" tem de continuar lendo como lista, e
    /// a faixa de CLIs tem de **desaparecer** em vez de virar um azulejo vazio.
    @Test("a principal com uma conexão só não deixa cartão vazio na tela")
    func principalEsparsa() async throws {
        for (tema, sufixo) in temas {
            let cena = try await scene()
            var settings = AssistantSettings.default
            settings.provider = .foundationModels
            _ = try cena.assistant.save(settings)

            let image = try #require(Render.snapshot(
                window(cena),
                named: "IA2-principal-1conexao-\(sufixo)",
                size: artboard,
                theme: tema
            ))
            #expect(image.pixelsWide == Int(artboard.width))
            #expect(image.pixelsHigh == Int(artboard.height))

            // Os dois quadrados de 34pt dos papéis são a única superfície de
            // `accentSoft` na faixa de cima do conteúdo: 2 × 34² = 2.312pt.
            let papeis = CGRect(x: 300, y: 150, width: 820, height: 120)
            #expect(
                pixels(image, matching: tema.accentSoft, in: papeis, tolerance: 0.04) > 600,
                "\(sufixo): o cartão “Quem faz o quê” não desenhou os dois papéis"
            )
        }
    }

    // MARK: 2 — a principal com várias conexões

    @Test("a principal com várias conexões mostra papel, estado e o convite")
    func principalCheia() async throws {
        for (tema, sufixo) in temas {
            let cena = try await scene()
            var settings = AssistantSettings.default
            settings.provider = .providerOAuth
            settings.providerOAuth.kind = .codex
            settings.providerOAuth.model = "gpt-5.1"
            settings.openAICompatible.endpoint = "https://api.minimax.io/v1"
            settings.openAICompatible.model = "MiniMax-M2"
            _ = try cena.assistant.save(settings)

            let image = try #require(Render.snapshot(
                window(
                    cena,
                    authorizer: ConfigRenderAuthorizer(status: .signedIn, models: [
                        AssistantProviderModel(id: "gpt-5.1"),
                        AssistantProviderModel(id: "gpt-5.1-mini"),
                        AssistantProviderModel(id: "o4-mini"),
                    ]),
                    probes: povoadas
                ),
                named: "IA2-principal-varias-\(sufixo)",
                size: artboard,
                theme: tema
            ))
            #expect(image.pixelsWide == Int(artboard.width))

            // Os dois quadrados de 34pt dos papéis são `accentSoft`.
            let conteudo = CGRect(x: 300, y: 130, width: 820, height: 560)
            #expect(
                pixels(image, matching: tema.accentSoft, in: conteudo, tolerance: 0.04) > 600,
                "\(sufixo): o cartão “Quem faz o quê” não desenhou os dois papéis"
            )
            // E o verde de "Conectada" nos pontos de estado da coluna direita.
            #expect(
                pixels(image, matching: tema.success, in: conteudo, tolerance: 0.06) > 60,
                "\(sufixo): nenhuma conexão se disse conectada"
            )
        }
    }

    // MARK: 3 e 4 — a folha de conectar

    @Test("a folha de conectar abre com as cinco gavetas e a busca vazia")
    func folhaBuscaVazia() async throws {
        for (tema, sufixo) in temas {
            let cena = try await scene()
            let image = try #require(Render.snapshot(
                window(cena, sheet: .choose),
                named: "IA2-conectar-vazia-\(sufixo)",
                size: artboard,
                theme: tema
            ))
            #expect(image.pixelsWide == Int(artboard.width))

            // A folha tem 840×566 e nasce centrada: a superfície dela é a única
            // `modalSheet` da imagem, e cobre quase meio milhão de pontos.
            #expect(
                image.pixels(matching: tema.modalSheet, tolerance: 0.03) > 100_000,
                "\(sufixo): a folha não foi desenhada sobre a janela"
            )
            // O véu cobre **a navegação também** — é o que o desenho pede, e é
            // por isso que a folha mora na janela e não no painel.
            let navegacao = CGRect(x: 20, y: 300, width: 180, height: 200)
            #expect(
                pixels(image, matching: tema.modalScrim, in: navegacao, tolerance: 0.08) > 0
                    || pixels(image, matching: tema.glassTile, in: navegacao, tolerance: 0.03) < 20_000,
                "\(sufixo): o véu não chegou à navegação"
            )
        }
    }

    @Test("a busca “grok” acha o Grok em todas as gavetas")
    func folhaBuscaGrok() async throws {
        // A busca varre o catálogo inteiro: o Grok está na gaveta de conta e o
        // xAI na de chave, e os dois respondem.
        let achados = ConfigAICatalog.search("grok")
        #expect(achados.contains { $0.id == "login-xai" })
        #expect(!achados.contains { $0.id == "minimax" })

        for (tema, sufixo) in temas {
            let cena = try await scene()
            let image = try #require(Render.snapshot(
                window(cena, sheet: .choose, busca: "grok"),
                named: "IA2-conectar-grok-\(sufixo)",
                size: artboard,
                theme: tema
            ))
            #expect(image.pixelsWide == Int(artboard.width))
            #expect(
                image.pixels(matching: tema.modalSheet, tolerance: 0.03) > 100_000,
                "\(sufixo): a folha com busca não foi desenhada"
            )
        }
    }

    // MARK: 5 — o Grok com código

    @Test("a folha do Grok mostra o código do aparelho e nenhuma chave")
    func grokComCodigo() async throws {
        let autorizacao = AssistantProviderOAuthDeviceAuthorization(
            kind: .xAI,
            verificationURL: try #require(URL(string: "https://grok.com/device")),
            userCode: "KHDJ7F2Q",
            // A partir de agora, não da data fixa da cena: a contagem na tela
            // é `expira − agora`, e um instante de 2027 daria "132651:59".
            expiresAt: Date().addingTimeInterval(278),
            pollInterval: 5
        )

        for (tema, sufixo) in temas {
            let cena = try await scene()
            var settings = AssistantSettings.default
            settings.provider = .providerOAuth
            settings.providerOAuth.kind = .xAI
            settings.providerOAuth.model = "grok-4"
            _ = try cena.assistant.save(settings)

            let image = try #require(Render.snapshot(
                window(
                    cena,
                    sheet: .login(.xAI),
                    authorizer: ConfigRenderAuthorizer(status: .awaitingDeviceCode(autorizacao))
                ),
                named: "IA2-grok-codigo-\(sufixo)",
                size: artboard,
                theme: tema
            ))
            #expect(image.pixelsWide == Int(artboard.width))

            // A caixa do código é `accentSoft` com aresta de acento, e é a
            // única superfície de acento suave no meio da folha de 524pt.
            let caixa = CGRect(x: 380, y: 250, width: 520, height: 300)
            #expect(
                pixels(image, matching: tema.accentSoft, in: caixa, tolerance: 0.05) > 2_000,
                "\(sufixo): a caixa do código do aparelho não foi desenhada"
            )
        }
    }

    /// A palavra está proibida na tela, e o lugar de provar isso é aqui — numa
    /// asserção que falha se alguém a reintroduzir em qualquer catálogo.
    @Test("“experimental” não aparece em nenhum texto da Inteligência")
    func semExperimental() {
        var textos: [String] = []
        for preset in ConfigAICatalog.all {
            textos += [preset.name, preset.address, preset.note, preset.baseURL ?? ""]
        }
        for categoria in ConfigAICategory.allCases {
            textos += [categoria.label, categoria.listHeading]
        }
        for papel in ConfigAIRole.allCases {
            textos += [papel.title, papel.subtitle, papel.verb]
        }
        for texto in textos {
            #expect(
                !texto.lowercased().contains("experimental"),
                "“experimental” voltou para a tela em “\(texto)”"
            )
        }
    }

    // MARK: 6 — a chave de API (MiniMax)

    @Test("o formulário de chave nasce com o endereço oficial do provedor")
    func minimax() async throws {
        let preset = try #require(ConfigAICatalog.preset("minimax"))
        #expect(preset.baseURL == "https://api.minimax.io/v1")

        for (tema, sufixo) in temas {
            let cena = try await scene()
            var settings = AssistantSettings.default
            settings.openAICompatible.endpoint = "https://api.minimax.io/v1"
            settings.openAICompatible.model = "MiniMax-M2"
            settings.provider = .openAICompatible
            _ = try cena.assistant.save(settings)

            let image = try #require(Render.snapshot(
                window(cena, page: .apiKey(presetID: "minimax")),
                named: "IA2-minimax-\(sufixo)",
                size: artboard,
                theme: tema
            ))
            #expect(image.pixelsWide == Int(artboard.width))

            // O cartão do formulário é a única superfície elevada da página, e
            // as cinco linhas lhe dão altura de sobra.
            let cartao = CGRect(x: 300, y: 130, width: 700, height: 320)
            #expect(
                pixels(image, matching: tema.glassCard, in: cartao, tolerance: 0.04) > 20_000,
                "\(sufixo): o cartão do formulário não foi desenhado"
            )
            // E o botão "Testar e salvar" é o acento cheio embaixo dele.
            let botoes = CGRect(x: 300, y: 430, width: 700, height: 120)
            #expect(
                pixels(image, matching: tema.accent, in: botoes, tolerance: 0.12) > 600,
                "\(sufixo): o botão de testar e salvar não foi desenhado"
            )
        }
    }

    // MARK: 7 — Neste Mac, com o servidor fora do ar

    @Test("Neste Mac com o servidor fora do ar diz isso, e oferece a volta")
    func localForaDoAr() async throws {
        for (tema, sufixo) in temas {
            let cena = try await scene()
            let image = try #require(Render.snapshot(
                window(cena, page: .local),
                named: "IA2-local-fora-do-ar-\(sufixo)",
                size: artboard,
                theme: tema
            ))
            #expect(image.pixelsWide == Int(artboard.width))

            // O cartão da Apple Intelligence tem o quadrado de 40pt em
            // `accentSoft` e a etiqueta "Sem configuração" na mesma cor.
            let apple = CGRect(x: 300, y: 130, width: 820, height: 100)
            #expect(
                pixels(image, matching: tema.accentSoft, in: apple, tolerance: 0.04) > 1_200,
                "\(sufixo): o cartão da Apple Intelligence não foi desenhado"
            )
            // Nenhum modelo pode aparecer: o servidor não respondeu, e a página
            // não pode inventar uma lista. O anel de seleção do rádio é
            // `accent`, e ele não existe neste quadro.
            let servidor = CGRect(x: 300, y: 240, width: 820, height: 220)
            #expect(
                pixels(image, matching: tema.accent, in: servidor, tolerance: 0.06) < 400,
                "\(sufixo): a página listou modelo de um servidor que não respondeu"
            )
        }
    }

    // MARK: 8 — a aba "Como ela escreve"

    /// A aba que o desenho põe ao lado de "Conexões". A lógica é a de antes —
    /// tom, tamanho, formato, idioma e as três instruções —, e o que este
    /// quadro prova é que ela sobreviveu à mudança de lugar.
    @Test("a aba “Como ela escreve” mantém as preferências de escrita")
    func comoElaEscreve() async throws {
        for (tema, sufixo) in temas {
            let cena = try await scene()
            var settings = AssistantSettings.default
            settings.behavior.tone = .direct
            settings.behavior.writingInstructions =
                "Assine como Vantion. Nunca prometa prazo que não está no e-mail."
            _ = try cena.assistant.save(settings)

            let image = try #require(Render.snapshot(
                window(cena, tab: .writing),
                named: "IA2-como-escreve-\(sufixo)",
                size: artboard,
                theme: tema
            ))
            #expect(image.pixelsWide == Int(artboard.width))

            // O cartão das cinco linhas é a única superfície elevada da aba.
            let cartao = CGRect(x: 300, y: 130, width: 820, height: 300)
            #expect(
                pixels(image, matching: tema.glassCard, in: cartao, tolerance: 0.04) > 30_000,
                "\(sufixo): o cartão das preferências de escrita não foi desenhado"
            )
        }
    }

    // MARK: 9 — a janela de verdade, com os semáforos

    /// `Render` não desenha os botões nativos da janela; `JanelaReal` desenha.
    ///
    /// A Inteligência agora desenha o **próprio** cabeçalho, e é essa a razão
    /// deste caso: os semáforos moram na navegação, e um cabeçalho novo no
    /// painel ao lado não pode empurrá-los nem ser empurrado por eles.
    @Test("a Inteligência numa janela titulada não mexe nos semáforos")
    func janelaComSemaforos() async throws {
        let cena = try await scene()
        let foto = try #require(JanelaReal.fotografar(
            window(cena),
            size: artboard,
            theme: .vidroNoite,
            named: "IA2-janela-real-escuro"
        ))
        #expect(foto.bitmap.pixelsWide == Int(artboard.width))
        // As três bolinhas são do sistema e caem no vão que a navegação
        // reserva, no alto à esquerda — longe do cabeçalho do painel, que
        // começa depois dos 264pt da coluna.
        #expect(foto.semaforos.count == 3)
        #expect(foto.grupo.minX > 0)
        #expect(foto.grupo.maxX < ConfigMetrics.navWidth)
    }

    // MARK: A cena

    private struct Scene {
        let model: AccountsModel
        let assistant: AssistantSettingsStore
        let credentials: InMemoryAssistantCredentialStore
        let themes: ThemeStore
        let mail: MailStore
        let suite: String
        let defaults: UserDefaults
    }

    /// Nada instalado e nada no ar — e é de propósito: é o chão de que os
    /// retratos partem, para o quadro não mudar conforme a máquina.
    private let probes = ConfigIntelligenceProbes.silent

    /// Os três CLIs encontrados e logados, para o quadro cheio.
    private var povoadas: ConfigIntelligenceProbes {
        let instalados = [
            AssistantCLIInstallation(kind: .codex, executablePath: "/opt/homebrew/bin/codex"),
            AssistantCLIInstallation(kind: .claude, executablePath: "/opt/homebrew/bin/claude"),
            AssistantCLIInstallation(kind: .openCode, executablePath: "/opt/homebrew/bin/opencode"),
        ]
        let logados: [AssistantCLIKind: AssistantCLIAuthenticationState] = [
            .codex: .authenticated, .claude: .authenticated, .openCode: .authenticated,
        ]
        return ConfigIntelligenceProbes(
            cliScan: { instalados },
            cliAuthentication: { _ in logados },
            localServer: { _ in .notRunning },
            seededCLIs: instalados,
            seededAuthentication: logados
        )
    }

    private func scene() async throws -> Scene {
        let suite = "okamiuni.ia2-render.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let contas: [Account] = [
            account(id: "gmail", address: "vantion@gmail.com", host: "gmail"),
            account(id: "aitherion", address: "vantion@aitherion.com", host: "aitherion"),
            account(id: "okami", address: "contato@okami.dev", host: "okami"),
        ]
        let model = try await self.model(with: contas)
        let mail = MailStore(source: InMemoryMailSource.fixtures)
        await mail.load()

        return Scene(
            model: model,
            assistant: AssistantSettingsStore(defaults: defaults, key: "ia2-render-assistant"),
            credentials: InMemoryAssistantCredentialStore(),
            themes: ThemeStore(defaults: defaults),
            mail: mail,
            suite: suite,
            defaults: defaults
        )
    }

    private func window(
        _ scene: Scene,
        sheet: ConfigIntelligenceSheet? = nil,
        page: ConfigIntelligencePage = .main,
        tab: ConfigIntelligenceTab = .connections,
        busca: String = "",
        authorizer: ConfigRenderAuthorizer? = nil,
        probes: ConfigIntelligenceProbes? = nil
    ) -> some View {
        AccountsWindow(
            model: scene.model,
            initialSection: .intelligence,
            initialIntelligenceSheet: sheet,
            initialIntelligencePage: page,
            initialIntelligenceTab: tab,
            initialIntelligenceSearch: busca,
            intelligenceProbes: probes ?? self.probes,
            assistantSettings: scene.assistant,
            assistantCredentials: scene.credentials,
            textAssistant: nil,
            providerOAuthAuthorizer: authorizer,
            themes: scene.themes,
            mailStore: scene.mail
        )
    }

    private func account(id: String, address: String, host: String) -> Account {
        Account(
            id: id,
            address: address,
            displayName: host.capitalized,
            provider: .imap,
            host: host,
            tintLightHex: "#6d63ff",
            tintDarkHex: "#a9a3ff",
            signature: "Vantion Santos",
            imap: ImapEndpoint(host: "imap.\(host).example", port: 993, security: .tls),
            state: .ativa,
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

    private func pixels(
        _ image: NSBitmapImageRep,
        matching token: TokenColor,
        in rect: CGRect,
        tolerance: Double = 0.03
    ) -> Int {
        guard let wanted = token.nsColor.usingColorSpace(.sRGB) else { return 0 }
        let minX = max(0, Int(rect.minX))
        let maxX = min(image.pixelsWide, Int(rect.maxX))
        let minY = max(0, Int(rect.minY))
        let maxY = min(image.pixelsHigh, Int(rect.maxY))
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
