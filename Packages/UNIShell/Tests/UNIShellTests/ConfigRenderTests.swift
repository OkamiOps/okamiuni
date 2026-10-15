import AppKit
import Foundation
import NIOPosix
import SwiftUI
import Testing
import UNICore
import UNIDesign
import UNISync
@testable import UNIShell

/// Os dez quadros de `Config.dc.html`, renderizados fora da tela no tamanho do
/// desenho (1280×800) e medidos contra os números do CSS.
///
/// Os temas são o mapa que o desenho declara: `claro` é o Vidro, `escuro` é o
/// Vidro Noite, `classico` é o Okami — o mesmo layout, sem vidro.
///
/// Nenhum caso aqui abre janela visível, sintetiza clique ou toca na rede.
@Suite("Os quadros de Configurações", .serialized)
@MainActor
struct ConfigRenderTests {
    /// `width: 1280px; height: 800px` do artboard.
    private let artboard = CGSize(width: 1_280, height: 800)
    private let createdAt = Date(timeIntervalSince1970: 1_800_000_000)

    private static let release = UpdateRelease(
        version: "2.4.2",
        changelog: UpdateChangelog(portuguese: ["Correções"], english: ["Fixes"]),
        releaseURL: URL(string: "https://example.com/v2.4.2")
    )

    // MARK: Visão geral

    @Test("Visão geral põe os problemas antes dos atalhos, no Vidro e no clássico")
    func visaoGeral() async throws {
        for (tema, sufixo) in [(Theme.vidro, "claro"), (Theme.okami, "classico")] {
            let cena = try await scene(failing: true, ready: true)
            let image = try #require(Render.snapshot(
                window(cena, section: .general),
                named: "Config-visao-\(sufixo)",
                size: artboard,
                theme: tema
            ))
            #expect(image.pixelsWide == Int(artboard.width))
            #expect(image.pixelsHigh == Int(artboard.height))

            // O botão "Reconectar" é a única superfície de acento cheio na
            // faixa do primeiro alerta: `padding: 10px 16px` em volta de 13pt
            // de texto, no canto direito do cartão.
            //
            // A tolerância é 0,12 porque o acento do Okami está fora do sRGB
            // (`oklch(72% 0.19 45)`): o token diz (255,117,39) e o bitmap
            // devolve (233,107,36). É a mesma cor, convertida.
            let acaoDoAlerta = CGRect(x: 1_040, y: 140, width: 150, height: 56)
            #expect(
                pixels(image, matching: tema.accent, in: acaoDoAlerta, tolerance: 0.12) > 1_000,
                "Visão geral não desenhou o botão de reconectar no acento do tema"
            )

            // E os quatro azulejos de atalho, embaixo dos alertas.
            let azulejos = CGRect(x: 300, y: 370, width: 890, height: 240)
            #expect(
                pixels(image, matching: tema.glassTile, in: azulejos, tolerance: 0.06) > 20_000,
                "a grade de atalhos não foi desenhada"
            )
        }
    }

    // MARK: Aparência

    @Test("Aparência mostra os três cartões grandes e a fileira dos clássicos")
    func aparencia() async throws {
        let cena = try await scene(failing: false, ready: true)
        let image = try #require(Render.snapshot(
            window(cena, section: .appearance),
            named: "Config-aparencia-claro",
            size: artboard,
            theme: .vidro
        ))
        #expect(image.pixelsWide == Int(artboard.width))

        // O cartão escolhido ganha `0 0 0 2px accent`: o anel é a única fonte
        // do acento naquela faixa de 104pt de altura.
        let cartoes = CGRect(x: 300, y: 110, width: 880, height: 110)
        #expect(
            pixels(image, matching: Theme.vidro.accent, in: cartoes) > 100,
            "o tema em uso não recebeu o anel de seleção"
        )
    }

    // MARK: Conta

    @Test("A página da conta junta sincronização, remetentes e a assinatura")
    func conta() async throws {
        for (tema, sufixo) in [(Theme.vidro, "claro"), (Theme.okami, "classico")] {
            let cena = try await scene(failing: false, ready: false)
            let image = try #require(Render.snapshot(
                window(cena, section: .accounts),
                named: "Config-conta-\(sufixo)",
                size: artboard,
                theme: tema
            ))
            #expect(image.pixelsWide == Int(artboard.width))
            // O cartão da assinatura é a única superfície elevada da direita.
            let direita = CGRect(x: 700, y: 150, width: 540, height: 300)
            #expect(
                pixels(image, matching: tema.glassCard, in: direita) > 2_000,
                "a assinatura não foi desenhada dentro de um e-mail"
            )
        }
    }

    // MARK: Inteligência

    // Os quadros da Inteligência moram em `IntelligenciaRenderTests`: são oito
    // estados (a principal esparsa e cheia, as duas folhas, o código do
    // aparelho, a chave de API, o servidor local fora do ar e a aba de
    // escrita), cada um nos três acabamentos, e eles precisam fechar as portas
    // que tocam disco e rede de loopback. Repetir um deles aqui seria portrait
    // do mesmo painel com menos controle sobre o que ele desenha.

    // MARK: Gestos

    @Test("Gestos desenha as duas prévias de arrasto e as listas por lado")
    func gestos() async throws {
        let cena = try await scene(failing: false, ready: false)
        let image = try #require(Render.snapshot(
            window(cena, section: .gestures),
            named: "Config-gestos-claro",
            size: artboard,
            theme: .vidro
        ))
        #expect(image.pixelsWide == Int(artboard.width))

        // A prévia do arrasto longo é uma faixa de 62pt de altura pintada na
        // cor da **primeira** ação daquele lado. As cores são de significado,
        // não de tema: verde arquiva, âmbar adia, azul traz para hoje.
        let configuracao = cena.swipes.configuration
        for lado in SwipeSide.allCases {
            guard let primeira = configuracao.actions(on: lado).first else { continue }
            let cor = ConfigSwipePalette.color(for: primeira)
            #expect(
                image.pixels(matching: token(cor)) > 1_200,
                "a prévia do lado \(lado.label) não foi pintada na cor de \(primeira.settingsLabel)"
            )
        }
        // E cada ação restante da esquerda ocupa a sua coluna de 86×62.
        for acao in configuracao.actions(on: .trailing).dropFirst() {
            #expect(
                image.pixels(matching: token(ConfigSwipePalette.color(for: acao))) > 1_200,
                "\(acao.settingsLabel) não apareceu na prévia do arrasto curto"
            )
        }
    }

    // MARK: Regras

    @Test("Regras lê como frase e a nova regra mostra o que pegaria")
    func regras() async throws {
        let cena = try await scene(failing: false, ready: false)
        let lista = try #require(Render.snapshot(
            window(cena, section: .rules),
            named: "Config-regras-escuro",
            size: artboard,
            theme: .vidroNoite
        ))
        #expect(lista.pixelsWide == Int(artboard.width))
        // Três das quatro regras estão ligadas: três calhas de acento de
        // 38×22 na coluna da direita.
        #expect(
            lista.pixels(matching: Theme.vidroNoite.accent) > 1_200,
            "os interruptores das regras ativas não apareceram"
        )

        let nova = try #require(Render.snapshot(
            window(cena, section: .rules, newRule: true),
            named: "Config-regra-nova-claro",
            size: artboard,
            theme: .vidro
        ))
        #expect(nova.pixelsWide == Int(artboard.width))
        #expect(
            nova.pixels(matching: Theme.vidro.accent) > 400,
            "a página da regra nova não desenhou o botão de criar"
        )
    }

    // MARK: A cena

    private struct Scene {
        let model: AccountsModel
        let assistant: AssistantSettingsStore
        let rules: EmailRuleStore
        let swipes: SwipeSettingsStore
        let themes: ThemeStore
        let rooms: MeetingRoomSettingsStore
        let mail: MailStore
        let updates: UpdateController?
        let suite: String
        let defaults: UserDefaults
    }

    /// Uma janela com todas as dependências que o app injeta, em banco
    /// temporário, `UserDefaults` isolado e sem rede.
    private func scene(failing: Bool, ready: Bool) async throws -> Scene {
        let suite = "okamiuni.config-render.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        var contas: [Account] = [
            account(id: "gmail", address: "vantion@gmail.com", host: "gmail"),
            account(id: "aitherion", address: "vantion@aitherion.com", host: "aitherion"),
        ]
        contas.append(account(
            id: "okami", address: "contato@okami.dev", host: "okami",
            state: failing ? .erroDeAutenticacao : .ativa
        ))

        let model = try await self.model(with: contas)
        let rules = EmailRuleStore(inMemory: [
            EmailRule(
                id: "newsletters",
                name: "Newsletters fora da caixa",
                condition: .senderContains("newsletter"),
                actions: [.archive, .markRead],
                enabled: true
            ),
            EmailRule(
                id: "notas",
                name: "Notas fiscais",
                condition: .subjectContains("nota fiscal"),
                actions: [.markRead],
                enabled: true
            ),
            EmailRule(
                id: "clientes",
                name: "Clientes Okami",
                condition: .senderContains("okami.dev"),
                actions: [.flag],
                enabled: true,
                accountID: "okami"
            ),
            EmailRule(
                id: "contador",
                name: "Contador",
                condition: .senderContains("contabil@exato.com.br"),
                actions: [],
                enabled: false,
                accountID: "aitherion",
                forwarding: EmailRuleForwarding(address: "financeiro@aitherion.com")
            ),
        ])

        let mail = MailStore(source: InMemoryMailSource.fixtures)
        await mail.load()

        var updates: UpdateController?
        if ready {
            let motor = MotorDeMentira()
            let controller = UpdateController(engine: motor, defaults: defaults)
            controller.start()
            motor.emite(.ready(Self.release))
            updates = controller
        }

        let themes = ThemeStore(defaults: defaults)
        let rooms = MeetingRoomSettingsStore(defaults: defaults)
        rooms.setDefault(.meet, for: "gmail")

        return Scene(
            model: model,
            assistant: AssistantSettingsStore(defaults: defaults, key: "config-render-assistant"),
            rules: rules,
            swipes: SwipeSettingsStore(defaults: defaults),
            themes: themes,
            rooms: rooms,
            mail: mail,
            updates: updates,
            suite: suite,
            defaults: defaults
        )
    }

    private func window(
        _ scene: Scene,
        section: SettingsSection,
        newRule: Bool = false,
        authorizer: ConfigRenderAuthorizer? = nil
    ) -> some View {
        AccountsWindow(
                model: scene.model,
                initialSection: section,
                startsNewRule: newRule,
                assistantSettings: scene.assistant,
                textAssistant: nil,
                providerOAuthAuthorizer: authorizer,
                emailRules: scene.rules,
                themes: scene.themes,
                swipes: scene.swipes,
                mailStore: scene.mail,
            meetingRooms: scene.rooms,
            updates: scene.updates
        )
    }

    private func account(
        id: String,
        address: String,
        host: String,
        state: Account.State = .ativa
    ) -> Account {
        Account(
            id: id,
            address: address,
            displayName: host.capitalized,
            provider: .imap,
            host: host,
            tintLightHex: "#6d63ff",
            tintDarkHex: "#a9a3ff",
            signature: "Vantion Santos\nFundador · Aitherion Labs\naitherion.com · +55 11 99999-0000",
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
        // `start()` é um laço de observação: ele **não** retorna. Esperar por
        // ele aqui travaria o retrato — por isso o observador fica numa tarefa
        // e o caso espera as contas aparecerem.
        let observer = Task { @MainActor in await model.start() }
        defer { observer.cancel() }
        for _ in 0..<150 {
            if model.statuses.count == accounts.count { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.statuses.count == accounts.count, "o banco temporário não publicou as contas")
        return model
    }

    /// A cor desenhada, no formato que o contador de pixels entende.
    private func token(_ color: Color) -> TokenColor {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        return TokenColor(
            red: ns.redComponent, green: ns.greenComponent, blue: ns.blueComponent
        )
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

/// A dublê do autorizador OAuth. Nada aqui abre navegador ou fala com rede.
@MainActor
final class ConfigRenderAuthorizer: AssistantProviderOAuthAuthorizing {
    nonisolated let sessionState = AssistantProviderOAuthSessionState()
    private var sequence: UInt64 = 0
    private let models: [AssistantProviderModel]

    init(status: AssistantProviderOAuthStatus, models: [AssistantProviderModel] = []) {
        self.models = models
        sequence += 1
        sessionState.apply(status, sequence: sequence)
    }

    func refreshStatus(configuration: AssistantProviderOAuthConfiguration) async {}
    func start(configuration: AssistantProviderOAuthConfiguration) async throws {}
    func availableModels(
        configuration: AssistantProviderOAuthConfiguration
    ) async throws -> [AssistantProviderModel] { models }
    func cancelAuthorization() async {}
    func signOut(configuration: AssistantProviderOAuthConfiguration) async {}
}
