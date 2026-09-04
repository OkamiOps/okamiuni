import Foundation

/// Os idiomas que o aplicativo oferece na preferência `appLanguage`.
///
/// Os valores brutos fazem parte da persistência. Não os renomeie sem uma
/// migração das preferências já gravadas.
public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case portugueseBrazil = "pt-BR"
    case english = "en"
    case german = "de"
    case french = "fr"

    /// A chave compartilhada pela tela de preferências e pela localização.
    public static let defaultsKey = "appLanguage"

    public var id: String { rawValue }

    /// Nome do idioma no próprio idioma, próprio para um seletor de idioma.
    public var nativeName: String {
        switch self {
        case .system: "System"
        case .portugueseBrazil: "Português (Brasil)"
        case .english: "English"
        case .german: "Deutsch"
        case .french: "Français"
        }
    }

    /// Locale usado por formatações que devem acompanhar o idioma escolhido.
    public var locale: Locale {
        switch self {
        case .system: .autoupdatingCurrent
        default: Locale(identifier: rawValue)
        }
    }

    /// A preferência persistida. Leituras posteriores refletem uma mudança
    /// feita pelas preferências; a interface pode pedir relançamento para
    /// reconstruir os textos já materializados.
    public static var selected: Self {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: defaultsKey) else {
                return .portugueseBrazil
            }
            return Self(rawValue: rawValue) ?? .portugueseBrazil
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
        }
    }

    /// Resolve `system` para um idioma que possui recursos no app. Se nenhum
    /// idioma preferido do sistema for suportado, a base é português do Brasil.
    public var resolved: Self {
        guard self == .system else { return self }

        for preferredLanguage in Locale.preferredLanguages {
            if let language = Self.supportedLanguage(matching: preferredLanguage) {
                return language
            }
        }

        return .portugueseBrazil
    }

    private static func supportedLanguage(matching identifier: String) -> Self? {
        let normalized = identifier
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()

        if normalized == portugueseBrazil.rawValue.lowercased() || normalized.hasPrefix("pt-") || normalized == "pt" {
            return .portugueseBrazil
        }
        if normalized == english.rawValue || normalized.hasPrefix("en-") {
            return .english
        }
        if normalized == german.rawValue || normalized.hasPrefix("de-") {
            return .german
        }
        if normalized == french.rawValue || normalized.hasPrefix("fr-") {
            return .french
        }
        return nil
    }
}

/// Uma chave localizável que separa a frase de seus valores interpolados.
///
/// `"Olá, \(name)!"` vira a chave `"Olá, {0}!"` e preserva `name` em
/// `values`. Isso permite que cada `Localizable.strings` reordene argumentos
/// sem perder os valores originais.
public struct LocalizedString: ExpressibleByStringInterpolation {
    public let key: String
    public let values: [Any]

    public init(stringLiteral value: String) {
        key = value
        values = []
    }

    public init(stringInterpolation: StringInterpolation) {
        key = stringInterpolation.key
        values = stringInterpolation.values
    }

    public struct StringInterpolation: StringInterpolationProtocol {
        fileprivate var key = ""
        fileprivate var values: [Any] = []

        public init(literalCapacity: Int, interpolationCount: Int) {
            key.reserveCapacity(literalCapacity + interpolationCount * 3)
            values.reserveCapacity(interpolationCount)
        }

        public mutating func appendLiteral(_ literal: String) {
            key.append(contentsOf: literal)
        }

        public mutating func appendInterpolation<T>(_ value: T) {
            key.append("{\(values.count)}")
            values.append(value)
        }
    }
}

/// Busca uma chave em `Localizable.strings` no idioma escolhido.
public enum L10n {
    /// A preferência armazenada, antes de resolver a escolha do sistema.
    public static var selectedLanguage: AppLanguage { AppLanguage.selected }

    /// O idioma efetivo, com negociação dos idiomas preferidos do sistema.
    public static var language: AppLanguage { selectedLanguage.resolved }

    /// Locale que acompanha o idioma efetivo.
    public static var locale: Locale { language.locale }

    /// Localiza e então substitui os argumentos `{0}`, `{1}`, ... uma vez.
    ///
    /// A substituição é uma única passagem: se um valor contiver `{1}`, ele
    /// permanece texto e nunca dispara outra substituição de argumento.
    public static func tr(_ localizedString: LocalizedString, language: AppLanguage? = nil) -> String {
        let resolvedLanguage = (language ?? selectedLanguage).resolved
        let translated = localizedValue(for: localizedString.key, language: resolvedLanguage)
        return replacingPlaceholders(in: translated, with: localizedString.values)
    }

    private static func localizedValue(for key: String, language: AppLanguage) -> String {
        let localized = bundle(for: language).flatMap { value(for: key, bundle: $0) }
        guard localized == nil, language != .portugueseBrazil else {
            return localized ?? key
        }

        return bundle(for: .portugueseBrazil)
            .flatMap { value(for: key, bundle: $0) } ?? key
    }

    private static func bundle(for language: AppLanguage) -> Bundle? {
        guard let resourceURL = Bundle.module.url(forResource: language.rawValue, withExtension: "lproj"),
              let localizedBundle = Bundle(url: resourceURL) else {
            return nil
        }
        return localizedBundle
    }

    private static func value(for key: String, bundle: Bundle) -> String? {
        let missingValue = "__UNICore_missing_localization__"
        let value = bundle.localizedString(forKey: key, value: missingValue, table: "Localizable")
        return value == missingValue ? nil : value
    }

    private static func replacingPlaceholders(in string: String, with values: [Any]) -> String {
        var result = ""
        var index = string.startIndex

        while index < string.endIndex {
            guard string[index] == "{" else {
                result.append(string[index])
                index = string.index(after: index)
                continue
            }

            let valueStart = string.index(after: index)
            guard let closingBrace = string[valueStart...].firstIndex(of: "}"),
                  let placeholderIndex = Int(string[valueStart..<closingBrace]),
                  values.indices.contains(placeholderIndex) else {
                result.append(string[index])
                index = valueStart
                continue
            }

            result.append(contentsOf: String(describing: values[placeholderIndex]))
            index = string.index(after: closingBrace)
        }

        return result
    }
}
