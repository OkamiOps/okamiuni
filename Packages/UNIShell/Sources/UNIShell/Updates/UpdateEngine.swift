import Foundation
import UNICore

/// Uma versão nova, pronta para instalar.
///
/// `Codable` por uma razão só: ela é gravada nas preferências quando fica
/// pronta, para a abertura **seguinte** poder dizer "atualizado para 0.5.6" com
/// o changelog na mão. Sem isso, o modo silencioso instalaria a versão nova e a
/// pessoa não teria como saber o que mudou — o appcast já não está por perto
/// quando o app reabre.
public struct UpdateRelease: Codable, Sendable, Equatable {
    /// A versão que a pessoa lê — `CFBundleShortVersionString` do item, não o
    /// número de build.
    public let version: String
    public let changelog: UpdateChangelog
    /// A página do release no GitHub, quando o appcast a declara em
    /// `<sparkle:fullReleaseNotesLink>`.
    public let releaseURL: URL?

    public init(version: String, changelog: UpdateChangelog, releaseURL: URL?) {
        self.version = version
        self.changelog = changelog
        self.releaseURL = releaseURL
    }
}

/// O que pode dar errado, nas categorias que mudam o que o app faz.
///
/// Não é o `NSError` do Sparkle: o motor traduz os códigos dele para estes
/// quatro casos, porque é a **categoria** que decide o comportamento — se o
/// erro cala a boca numa busca de fundo, se o aviso fica gravado, se a frase
/// pede para mover o app. O texto do sistema não serve para nenhuma das três
/// decisões e nunca está traduzido para os quatro idiomas do app.
public enum UpdateFailure: Sendable, Equatable {
    /// Sem rede, feed fora do ar, XML que não baixou. Silenciosa na busca de
    /// fundo: ninguém pediu nada, e um alerta a cada seis horas num avião é
    /// ruído.
    case network
    /// A assinatura EdDSA não bateu. **Nunca instala**, e o aviso fica.
    case invalidSignature
    /// O app está onde não se pode escrever — baixado na pasta Downloads,
    /// aberto de dentro de um .dmg, ou em quarentena/translocado.
    case notWritable
    /// Qualquer outra, com a frase que o Sparkle deu. Cai aqui o que não
    /// sabemos categorizar — e dizer o texto cru é melhor do que dizer nada.
    case other(String)

    public var message: String {
        switch self {
        case .network:
            L10n.tr("Não foi possível verificar agora. Tente de novo mais tarde.")
        case .invalidSignature:
            L10n.tr("A atualização não passou na verificação de assinatura e não foi instalada.")
        case .notWritable:
            L10n.tr("Mova o OkamiUNI para Aplicativos para atualizar.")
        case let .other(detail):
            detail
        }
    }

    /// Erro que a busca de fundo engole.
    ///
    /// Só a rede. Assinatura inválida e lugar sem permissão aparecem **mesmo**
    /// sem ninguém pedir: a primeira é a única hipótese de alguém ter trocado
    /// o arquivo no caminho, e a segunda é a razão pela qual o app nunca
    /// atualizaria sozinho se ninguém dissesse nada.
    public var isSilentWhenScheduled: Bool {
        self == .network
    }
}

/// O que o motor descobriu. Um caso por mudança de estado que a tela mostra.
public enum UpdateEngineEvent: Sendable, Equatable {
    case checkStarted(userInitiated: Bool)
    case upToDate(userInitiated: Bool)
    /// `nil` quando o servidor não declarou o tamanho — e aí a barra é
    /// indeterminada, em vez de mentir uma porcentagem.
    case downloading(progress: Double?)
    case ready(UpdateRelease)
    case failed(UpdateFailure, userInitiated: Bool)
}

/// O atualizador, visto por quem desenha a tela.
///
/// Existe como protocolo para o Sparkle **não** entrar no `UNIShell`. O motor
/// de verdade mora no alvo do app (ver `App/Updates/SparkleUpdateEngine.swift`)
/// porque ele depende de um framework com XPC Services assinados; aqui ficam o
/// estado e a interface, que é o que precisa de teste. O `UpdateControllerTests`
/// roda contra um motor de mentira, sem rede e sem Keychain.
@MainActor
public protocol UpdateEngine: AnyObject {
    /// Quem recebe o que o motor descobriu. O `UpdateController` se registra
    /// aqui no `init`; é closure, e não delegate, porque há um ouvinte só.
    var onEvent: (@MainActor (UpdateEngineEvent) -> Void)? { get set }

    /// Procurar sozinho, de seis em seis horas. Vem das preferências.
    var automaticallyChecksForUpdates: Bool { get set }

    /// Baixar sozinho ao encontrar. Ligado nos dois modos: é o que faz
    /// "Instalar e reabrir" ser instantâneo em vez de um download que começa
    /// quando a pessoa já decidiu reabrir o app.
    var automaticallyDownloadsUpdates: Bool { get set }

    /// A versão em uso, do bundle.
    var currentVersion: String { get }
    var currentBuild: String { get }

    /// Liga o atualizador e faz a primeira busca de fundo.
    func start()

    /// "Procurar agora". O resultado aparece na nossa interface, não numa
    /// janela do Sparkle.
    func checkNow()

    /// Instala e reabre agora, pelo caminho normal de encerramento do app.
    func installImmediately()

    /// Deixa a instalação para o fechamento do app.
    func deferInstallationToQuit()
}
