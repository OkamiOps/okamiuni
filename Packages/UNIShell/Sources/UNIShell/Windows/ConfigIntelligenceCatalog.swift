import SwiftUI
import UNICore
import UNIDesign
import UNISync

/// As gavetas da folha "Conectar uma IA", na ordem em que o desenho as põe.
///
/// Elas não são categorias de marketing: cada uma é **uma pergunta diferente
/// sobre onde o texto vai parar**. "Neste Mac" não sai daqui; "Entrar com sua
/// conta" usa uma assinatura que a pessoa já paga; "Chave de API" é um endpoint
/// compatível com OpenAI; "CLI" delega a sessão a um programa já logado nesta
/// máquina; "Agentes" fala um protocolo de agente.
enum ConfigAICategory: String, CaseIterable, Identifiable, Hashable {
    case all
    case mac
    case account
    case apiKey
    case cli
    case agents

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: L10n.tr("Tudo")
        case .mac: L10n.tr("Neste Mac")
        case .account: L10n.tr("Entrar com sua conta")
        case .apiKey: L10n.tr("Chave de API")
        case .cli: L10n.tr("CLI já logado aqui")
        case .agents: L10n.tr("Agentes")
        }
    }

    /// O título da lista da direita quando esta gaveta está aberta — é o que o
    /// desenho escreve em caixa alta acima dos itens.
    var listHeading: String {
        switch self {
        case .all: L10n.tr("TUDO O QUE ESTE APP FALA")
        case .mac: L10n.tr("NESTE MAC · NADA SAI DAQUI")
        case .account: L10n.tr("ENTRAR COM SUA CONTA · SEM CHAVE")
        case .apiKey: L10n.tr("CHAVE DE API · ENDPOINT COMPATÍVEL COM OPENAI")
        case .cli: L10n.tr("CLI JÁ LOGADO AQUI · A SESSÃO É DELE")
        case .agents: L10n.tr("AGENTES · PROTOCOLO DE AGENTE")
        }
    }

    var symbol: String {
        switch self {
        case .all: "line.3.horizontal"
        case .mac: "desktopcomputer"
        case .account: "person.crop.circle"
        case .apiKey: "key"
        case .cli: "terminal"
        case .agents: "cpu"
        }
    }
}

/// Para onde um item da folha leva quando a pessoa clica nele.
///
/// Nada aqui conecta sozinho: a rota diz qual **página** abrir, e é lá que a
/// pessoa cola a chave, autoriza no navegador ou escolhe o modelo.
enum ConfigAIRoute: Hashable {
    /// Apple Intelligence — a única rota que não pede nada a ninguém.
    case appleIntelligence
    /// Um servidor de loopback compatível com OpenAI (Ollama, LM Studio,
    /// LiteLLM local). Leva à página "Neste Mac", que lista os modelos que o
    /// servidor respondeu ter.
    case localServer(preset: String)
    /// O formulário de chave de API, com o endereço do preset já preenchido.
    case apiKey(preset: String)
    /// Login por device auth na assinatura do provedor.
    case login(AssistantProviderOAuthKind)
    /// Um CLI já instalado e logado nesta máquina.
    case cli(AssistantCLIKind)
    /// Os formulários de agente que já existem (ACP e A2A). Eles pedem pasta
    /// autorizada, bookmark e teste de conexão — coisas que esta tela não
    /// reimplementa.
    case agent
}

/// Um item da folha "Conectar uma IA".
///
/// `baseURL` é o endereço **real** do provedor, conferido na documentação
/// oficial dele (a fonte de cada um está no comentário do preset). A pessoa
/// pode trocá-lo no formulário; o preset só evita que ela precise procurar.
struct ConfigAIPreset: Identifiable, Hashable {
    let id: String
    let name: String
    let category: ConfigAICategory
    /// O que a linha mostra em fonte mono, à direita do nome. Normalmente é o
    /// endereço sem o esquema; nos itens que não têm endereço, é uma frase.
    let address: String
    /// O endereço completo, do jeito que vai para o campo "Endereço".
    let baseURL: String?
    let note: String
    let monogram: String
    /// A matiz do monograma. Sem logotipo de marca: o desenho usa um quadrado
    /// com a letra, tingido por matiz, e é o que mantém a lista legível nos 28
    /// temas sem carregar 20 imagens.
    let hue: Double
    let route: ConfigAIRoute

    /// Esta linha responde à busca? O desenho promete "nome, modelo ou
    /// endereço", então os três entram na conta.
    func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return true }
        return [name, address, note, baseURL ?? ""]
            .contains { $0.lowercased().contains(needle) }
    }
}

enum ConfigAICatalog {

    /// Tudo o que o app fala hoje, numa lista só.
    ///
    /// Os endereços foram conferidos na documentação oficial de cada provedor
    /// em 15/10/2026; a fonte está no comentário de cada linha. Trocar um deles
    /// sem reconferir a documentação é como inventá-lo.
    static let all: [ConfigAIPreset] = [

        // MARK: Neste Mac

        ConfigAIPreset(
            id: "apple-intelligence",
            name: L10n.tr("Apple Intelligence"),
            category: .mac,
            address: L10n.tr("no chip deste Mac"),
            baseURL: nil,
            note: L10n.tr("sem conta e sem chave"),
            monogram: "A",
            hue: 268,
            route: .appleIntelligence
        ),
        // Ollama, docs oficiais (docs.ollama.com/openai): a base compatível com
        // OpenAI é `http://localhost:11434/v1/`.
        ConfigAIPreset(
            id: "ollama",
            name: "Ollama",
            category: .mac,
            address: "localhost:11434/v1",
            baseURL: "http://localhost:11434/v1",
            note: L10n.tr("os modelos que você baixou"),
            monogram: "O",
            hue: 150,
            route: .localServer(preset: "ollama")
        ),
        // LM Studio, docs oficiais (lmstudio.ai/docs/app/api/endpoints/openai):
        // `http://localhost:1234/v1`. A porta é configurável no app dele, e por
        // isso o campo continua editável.
        ConfigAIPreset(
            id: "lmstudio",
            name: "LM Studio",
            category: .mac,
            address: "localhost:1234/v1",
            baseURL: "http://localhost:1234/v1",
            note: L10n.tr("o modelo que está carregado"),
            monogram: "L",
            hue: 196,
            route: .localServer(preset: "lmstudio")
        ),
        // LiteLLM rodando na máquina. Era o único preset que este app já tinha
        // (SettingsSections.swift), e continua existindo com o mesmo endereço.
        ConfigAIPreset(
            id: "litellm-local",
            name: L10n.tr("LiteLLM local"),
            category: .mac,
            address: "127.0.0.1:4000/v1",
            baseURL: "http://127.0.0.1:4000/v1",
            note: L10n.tr("seu proxy, seus modelos"),
            monogram: "T",
            hue: 32,
            route: .localServer(preset: "litellm-local")
        ),

        // MARK: Entrar com sua conta

        ConfigAIPreset(
            id: "login-codex",
            name: L10n.tr("ChatGPT"),
            category: .account,
            address: L10n.tr("código no navegador"),
            baseURL: nil,
            note: L10n.tr("a assinatura que você já paga"),
            monogram: "C",
            hue: 165,
            route: .login(.codex)
        ),
        ConfigAIPreset(
            id: "login-xai",
            name: L10n.tr("Grok"),
            category: .account,
            address: L10n.tr("código no navegador"),
            baseURL: nil,
            note: L10n.tr("conexão oficial da xAI"),
            monogram: "G",
            hue: 222,
            route: .login(.xAI)
        ),

        // MARK: Chave de API

        // OpenAI: todos os exemplos oficiais (developers.openai.com/api/docs)
        // usam `https://api.openai.com/v1`.
        ConfigAIPreset(
            id: "openai",
            name: "OpenAI",
            category: .apiKey,
            address: "api.openai.com/v1",
            baseURL: "https://api.openai.com/v1",
            note: "GPT-5.1, o4-mini",
            monogram: "O",
            hue: 165,
            route: .apiKey(preset: "openai")
        ),
        // xAI: docs.x.ai/docs/overview → `https://api.x.ai/v1`.
        ConfigAIPreset(
            id: "xai",
            name: "xAI",
            category: .apiKey,
            address: "api.x.ai/v1",
            baseURL: "https://api.x.ai/v1",
            note: "Grok 4, Grok 4 Fast",
            monogram: "X",
            hue: 222,
            route: .apiKey(preset: "xai")
        ),
        // Anthropic: a camada compatível com OpenAI documentada em
        // platform.claude.com/docs/en/cli-sdks-libraries/libraries/openai-sdk
        // é `https://api.anthropic.com/v1/` — `/v1` e barra final, não um
        // caminho próprio.
        ConfigAIPreset(
            id: "anthropic",
            name: L10n.tr("Anthropic Claude"),
            category: .apiKey,
            address: "api.anthropic.com/v1",
            baseURL: "https://api.anthropic.com/v1",
            note: "Opus 5, Sonnet 5",
            monogram: "A",
            hue: 24,
            route: .apiKey(preset: "anthropic")
        ),
        // MiniMax internacional: platform.minimax.io/docs/guides/text-generation
        // → `https://api.minimax.io/v1`. O endereço da China é outro
        // (`api.minimax.cn/v1`) e a pessoa o digita no campo.
        ConfigAIPreset(
            id: "minimax",
            name: "MiniMax",
            category: .apiKey,
            address: "api.minimax.io/v1",
            baseURL: "https://api.minimax.io/v1",
            note: "MiniMax-M2",
            monogram: "M",
            hue: 300,
            route: .apiKey(preset: "minimax")
        ),
        // Xiaomi MiMo: mimo.mi.com/docs (integração por ferramentas) →
        // `https://api.xiaomimimo.com/v1`. Quem tem Token Plan usa outro host
        // (`token-plan-cn.xiaomimimo.com/v1`), com chave `tp-…`; as duas chaves
        // não valem no host da outra, e é por isso que o campo é editável.
        ConfigAIPreset(
            id: "mimo",
            name: L10n.tr("Xiaomi MiMo"),
            category: .apiKey,
            address: "api.xiaomimimo.com/v1",
            baseURL: "https://api.xiaomimimo.com/v1",
            note: "MiMo",
            monogram: "X",
            hue: 14,
            route: .apiKey(preset: "mimo")
        ),
        // OpenRouter: openrouter.ai/docs/quickstart →
        // `https://openrouter.ai/api/v1` (repare no `/api` antes do `/v1`).
        ConfigAIPreset(
            id: "openrouter",
            name: "OpenRouter",
            category: .apiKey,
            address: "openrouter.ai/api/v1",
            baseURL: "https://openrouter.ai/api/v1",
            note: L10n.tr("mais de 300 modelos"),
            monogram: "R",
            hue: 196,
            route: .apiKey(preset: "openrouter")
        ),
        // DeepSeek: api-docs.deepseek.com publica a base **sem** `/v1`
        // (`https://api.deepseek.com`) e documenta que `…/v1` também é aceito.
        // O preset usa a forma com `/v1` porque é a que o normalizador deste
        // app monta sem ambiguidade; a outra funciona igual.
        ConfigAIPreset(
            id: "deepseek",
            name: "DeepSeek",
            category: .apiKey,
            address: "api.deepseek.com/v1",
            baseURL: "https://api.deepseek.com/v1",
            note: "V3.2, R1",
            monogram: "D",
            hue: 240,
            route: .apiKey(preset: "deepseek")
        ),
        // Moonshot/Kimi global: platform.kimi.ai/docs/guide/start-using-kimi-api
        // → `https://api.moonshot.ai/v1`. O da China é `api.moonshot.cn/v1`,
        // com conta e chave separadas.
        ConfigAIPreset(
            id: "moonshot",
            name: L10n.tr("Moonshot · Kimi"),
            category: .apiKey,
            address: "api.moonshot.ai/v1",
            baseURL: "https://api.moonshot.ai/v1",
            note: "Kimi K2",
            monogram: "K",
            hue: 268,
            route: .apiKey(preset: "moonshot")
        ),
        ConfigAIPreset(
            id: "custom",
            name: L10n.tr("Outro endereço"),
            category: .apiKey,
            address: L10n.tr("você digita o endereço"),
            baseURL: nil,
            note: L10n.tr("qualquer servidor compatível"),
            monogram: "+",
            hue: 210,
            route: .apiKey(preset: "custom")
        ),

        // MARK: CLI já logado aqui

        ConfigAIPreset(
            id: "cli-codex",
            name: AssistantCLIKind.codex.displayName,
            category: .cli,
            address: "codex",
            baseURL: nil,
            note: L10n.tr("a sessão continua sendo dele"),
            monogram: "C",
            hue: 165,
            route: .cli(.codex)
        ),
        ConfigAIPreset(
            id: "cli-claude",
            name: AssistantCLIKind.claude.displayName,
            category: .cli,
            address: "claude",
            baseURL: nil,
            note: L10n.tr("a sessão continua sendo dele"),
            monogram: "C",
            hue: 24,
            route: .cli(.claude)
        ),
        ConfigAIPreset(
            id: "cli-opencode",
            name: AssistantCLIKind.openCode.displayName,
            category: .cli,
            address: "opencode",
            baseURL: nil,
            note: L10n.tr("a sessão continua sendo dele"),
            monogram: "O",
            hue: 120,
            route: .cli(.openCode)
        ),

        // MARK: Agentes

        ConfigAIPreset(
            id: "agent-acp",
            name: L10n.tr("Agente ACP"),
            category: .agents,
            address: L10n.tr("um programa seu, nesta máquina"),
            baseURL: nil,
            note: L10n.tr("pasta autorizada por você"),
            monogram: "P",
            hue: 285,
            route: .agent
        ),
        ConfigAIPreset(
            id: "agent-a2a",
            name: L10n.tr("Agente A2A"),
            category: .agents,
            address: L10n.tr("pelo Agent Card dele"),
            baseURL: nil,
            note: L10n.tr("delegação para outro agente"),
            monogram: "2",
            hue: 320,
            route: .agent
        ),
    ]

    /// Quantos itens cada gaveta tem — é o número que o desenho põe à direita
    /// do nome da categoria, e ele vem da lista, não de uma constante escrita à
    /// mão que envelheceria no primeiro provedor novo.
    static func count(_ category: ConfigAICategory) -> Int {
        category == .all ? all.count : all.count { $0.category == category }
    }

    static func items(in category: ConfigAICategory, query: String) -> [ConfigAIPreset] {
        all
            .filter { category == .all || $0.category == category }
            .filter { $0.matches(query) }
    }

    /// A busca varre **todas** as gavetas: quem digita "grok" quer o Grok,
    /// esteja ele na gaveta de conta, na de chave ou na de CLI.
    static func search(_ query: String) -> [ConfigAIPreset] {
        all.filter { $0.matches(query) }
    }

    static func preset(_ id: String) -> ConfigAIPreset? {
        all.first { $0.id == id }
    }
}

// MARK: - O monograma

/// O quadrado com a letra que substitui o logotipo da marca.
///
/// O desenho tinge o quadrado por matiz no Vidro e no Vidro Noite, e usa um
/// cinza plano nos clássicos — que são monocromáticos por definição e onde uma
/// matiz estranha ao tema seria a única cor da tela. A bifurcação é a mesma de
/// `ConfigPalette.field`: `isTranslucent`, nunca o nome do tema.
struct ConfigAIMonogram: View {
    @Environment(\.theme) private var theme
    @Environment(\.configPalette) private var palette

    let letter: String
    let hue: Double
    var side: CGFloat = 34
    var radius: CGFloat = 10
    var fontSize: CGFloat = 13

    var body: some View {
        Text(letter)
            .font(theme.sans.font(size: fontSize, weight: .bold))
            .foregroundStyle(foreground)
            .frame(width: side, height: side)
            .background(background, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    private var background: Color {
        guard theme.isTranslucent else { return palette.field.color }
        return theme.isDark
            ? Color(hue: hue / 360, saturation: 0.32, brightness: 0.30)
            : Color(hue: hue / 360, saturation: 0.18, brightness: 0.95)
    }

    private var foreground: Color {
        guard theme.isTranslucent else { return palette.ink2.color }
        return theme.isDark
            ? Color(hue: hue / 360, saturation: 0.40, brightness: 0.90)
            : Color(hue: hue / 360, saturation: 0.55, brightness: 0.42)
    }
}
