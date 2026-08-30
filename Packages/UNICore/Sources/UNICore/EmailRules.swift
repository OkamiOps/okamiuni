import Foundation
import Observation

/// O campo de uma mensagem que uma regra pode consultar.
///
/// A primeira versão é deliberadamente pequena: uma regra tem uma condição e
/// a condição é um trecho de remetente ou assunto. Isso já cobre o fluxo de
/// filtros mais comum sem inventar uma linguagem de consulta que a tela ainda
/// não consegue explicar.
public enum EmailRuleCondition: Sendable, Hashable, Codable {
    /// Casa no nome de exibição e no endereço do remetente.
    case senderContains(String)
    /// Casa somente no assunto (não na prévia nem no corpo).
    case subjectContains(String)
}

/// O efeito que uma regra pode pedir para uma mensagem.
public enum EmailRuleAction: String, CaseIterable, Identifiable, Sendable, Hashable, Codable {
    case markRead = "marcar_lida"
    case archive = "arquivar"
    case flag = "sinalizar"

    public var id: String { rawValue }

    /// Texto para a futura tela de Regras. O domínio não depende da UI, mas o
    /// rótulo centralizado impede que cada superfície traduza a mesma ação de
    /// uma forma diferente.
    public var label: String {
        switch self {
        case .markRead: "Marcar como lida"
        case .archive: "Arquivar"
        case .flag: "Sinalizar"
        }
    }
}

/// O endereço que recebe uma cópia automática de uma regra.
///
/// Ele é separado de `OutgoingAddress`: o nome de apresentação não participa
/// de uma automação, e aceitar um valor no formato "Nome <email>" aqui faria a
/// configuração parecer mais permissiva do que o transportador realmente é.
/// A validação é deliberadamente pequena, mas barra os caracteres que poderiam
/// injetar cabeçalhos no RFC 5322 e os formatos que não são um endereço só.
public struct EmailRuleForwarding: Sendable, Hashable, Codable {
    public let address: String

    public init?(address: String) {
        guard let normalized = Self.normalizedAddress(address) else { return nil }
        self.address = normalized
    }

    /// Revalida também dados vindos de preferências antigas ou editadas fora da
    /// UI. `Codable` pode materializar uma struct sem passar pelo init acima;
    /// por isso a execução sempre chama esta propriedade antes de enfileirar.
    public var validatedAddress: String? {
        Self.normalizedAddress(address)
    }

    public static func normalizedAddress(_ raw: String) -> String? {
        // A verificação vem antes do trim: aceitar "email\r\n" e removê-lo
        // pareceria inofensivo hoje, mas transforma uma tentativa de injeção
        // de cabeçalho numa configuração válida sem a pessoa perceber.
        guard !raw.unicodeScalars.contains(where: { scalar in
            scalar.value == 0x0A || scalar.value == 0x0D || scalar.value == 0x00
        }) else { return nil }
        let candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty,
              candidate.utf8.count <= 254,
              !candidate.contains(where: { $0.isWhitespace })
        else { return nil }

        let parts = candidate.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2,
              !parts[0].isEmpty,
              !parts[1].isEmpty,
              !parts[0].hasPrefix("."),
              !parts[0].hasSuffix("."),
              !parts[1].hasPrefix("."),
              !parts[1].hasSuffix(".")
        else { return nil }
        return candidate
    }
}

/// Uma regra de e-mail persistível e independente de SwiftUI.
public struct EmailRule: Sendable, Hashable, Identifiable, Codable {
    public let id: String
    public var name: String
    public var enabled: Bool
    public var condition: EmailRuleCondition
    public var actions: [EmailRuleAction]
    /// Nil preserva as regras v1 globais. Regras que encaminham ou movem devem
    /// ser vinculadas à conta dona: endereço e pasta são dados daquela conta,
    /// não da caixa global.
    public var accountID: String?
    /// Uma cópia nova, sem Cc, Cco ou anexos, que sai pela própria conta da
    /// mensagem que casou.
    public var forwarding: EmailRuleForwarding?
    /// O destino real descoberto no provedor. `SwipeMoveDestination` conserva
    /// a diferença essencial entre IMAP (pasta) e Gmail (marcador -INBOX).
    public var moveDestination: SwipeMoveDestination?

    /// Alias semântico útil para código de tela e compatível com o vocabulário
    /// já usado por `Message.isRead`/`Message.isFlagged`.
    public var isEnabled: Bool {
        get { enabled }
        set { enabled = newValue }
    }

    /// Alias de apresentação; o nome persistido continua sendo `name`.
    public var title: String {
        get { name }
        set { name = newValue }
    }

    public init(
        id: String = UUID().uuidString,
        name: String,
        condition: EmailRuleCondition,
        actions: [EmailRuleAction],
        enabled: Bool = true,
        accountID: String? = nil,
        forwarding: EmailRuleForwarding? = nil,
        moveDestination: SwipeMoveDestination? = nil
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.condition = condition
        self.actions = actions
        self.accountID = accountID
        self.forwarding = forwarding
        self.moveDestination = moveDestination
    }

    /// Variante explícita para chamadores que usam a forma de propriedade
    /// `isEnabled`.
    public init(
        id: String = UUID().uuidString,
        name: String,
        condition: EmailRuleCondition,
        actions: [EmailRuleAction],
        isEnabled: Bool,
        accountID: String? = nil,
        forwarding: EmailRuleForwarding? = nil,
        moveDestination: SwipeMoveDestination? = nil
    ) {
        self.init(
            id: id, name: name, condition: condition, actions: actions,
            enabled: isEnabled, accountID: accountID,
            forwarding: forwarding, moveDestination: moveDestination
        )
    }

    /// Há ao menos uma consequência configurada. A UI usa esta pergunta para
    /// aceitar regras somente de encaminhamento/movimento, sem inventar uma
    /// ação local só para satisfazer a validação v1.
    public var hasActions: Bool {
        !actions.isEmpty || forwarding != nil || moveDestination != nil
    }
}

/// Matcher puro das regras.
///
/// Não acessa banco, rede ou `MailStore`: a mesma decisão pode ser testada
/// com uma `Message` de fixture e, depois, usada pelo pipeline que efetivamente
/// gravará as ações.
public enum EmailRuleMatcher {
    /// Uma regra desabilitada nunca casa. Texto vazio também não casa: tratar
    /// `contains("")` como verdadeiro transformaria uma regra ainda em edição
    /// num comando para a caixa inteira.
    public static func matches(_ rule: EmailRule, message: Message) -> Bool {
        guard rule.enabled,
              rule.accountID == nil || rule.accountID == message.accountID
        else { return false }

        switch rule.condition {
        case .senderContains(let value):
            return contains(value, in: "\(message.from.name) \(message.from.address)")
        case .subjectContains(let value):
            return contains(value, in: message.subject)
        }
    }

    /// Todas as regras ativas que casam, mantendo a ordem persistida.
    public static func matchingRules(
        for message: Message, in rules: [EmailRule]
    ) -> [EmailRule] {
        rules.filter { matches($0, message: message) }
    }

    /// Variante sem rótulos para facilitar uso em pipelines existentes.
    public static func matchingRules(
        _ message: Message, rules: [EmailRule]
    ) -> [EmailRule] {
        matchingRules(for: message, in: rules)
    }

    /// Aplica somente a transformação local representada pelas ações.
    ///
    /// Isto não grava no servidor nem no banco. A função existe para manter a
    /// semântica das ações num único lugar e deixar o futuro executor decidir
    /// quando enfileirar `markRead`, `archive` e `flag`.
    public static func apply(
        _ actions: [EmailRuleAction], to message: Message
    ) -> Message {
        actions.reduce(message) { atual, action in
            switch action {
            case .markRead:
                return atual.withRead(true)
            case .archive:
                return atual.withBucket(.archived)
            case .flag:
                return atual.withFlagged(true)
            }
        }
    }

    private static func contains(_ value: String, in text: String) -> Bool {
        let needle = ContactDirectory.fold(value.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !needle.isEmpty else { return false }
        return ContactDirectory.fold(text).contains(needle)
    }
}

/// Store das regras com envelope versionado em `UserDefaults`.
///
/// O envelope é importante: decodificar diretamente uma lista faria uma
/// alteração futura de schema parecer corrupção e apagaria silenciosamente
/// regras existentes. Versões futuras desconhecidas são tratadas como estado
/// vazio até haver uma migração explícita; os bytes originais permanecem no
/// `UserDefaults` enquanto nenhuma operação de escrita for solicitada.
@MainActor
@Observable
public final class EmailRuleStore {
    /// A v2 acrescenta campos opcionais à regra. O decoder sintetizado de
    /// `EmailRule` lê v1 sem eles, e a guarda abaixo continua aceitando o
    /// envelope v1 para que salvar uma regra antiga seja a única migração.
    public static let currentVersion = 2
    public static let storageKey = "okamiuni.emailRules"

    private struct Envelope: Codable {
        let version: Int
        let rules: [EmailRule]
    }

    public private(set) var rules: [EmailRule]

    /// `nil` no modo em memória; com um `UserDefaults` injetado a mesma API
    /// cobre persistência real e suites isoladas de teste.
    private let defaults: UserDefaults?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.rules = Self.read(from: defaults)
    }

    /// Inicializador sem efeitos no disco, útil para matcher/fluxo de UI em
    /// testes e previews.
    public init(inMemory rules: [EmailRule] = []) {
        self.defaults = nil
        self.rules = Self.unique(rules)
    }

    /// Substitui a lista inteira e grava inclusive uma lista vazia: vazio é
    /// uma escolha válida, não ausência acidental da preferência.
    public func replace(_ rules: [EmailRule]) {
        self.rules = Self.unique(rules)
        persist()
    }

    /// Insere uma regra nova ou atualiza a regra de mesmo id, sem mudar sua
    /// posição na lista.
    public func upsert(_ rule: EmailRule) {
        if let index = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[index] = rule
        } else {
            rules.append(rule)
        }
        persist()
    }

    /// Remove uma regra; remover um id ausente é idempotente.
    public func remove(id: String) {
        rules.removeAll { $0.id == id }
        persist()
    }

    /// Liga/desliga uma regra sem reconstruir a entidade no chamador.
    public func setEnabled(_ enabled: Bool, for id: String) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[index].enabled = enabled
        persist()
    }

    /// Restaura o estado sem regras e remove o envelope persistido.
    public func resetToDefault() {
        rules = []
        defaults?.removeObject(forKey: Self.storageKey)
    }

    /// Retorna a regra atual pelo identificador persistido.
    public func rule(id: String) -> EmailRule? {
        rules.first { $0.id == id }
    }

    /// Atalha a consulta para o futuro executor sem acoplar o store a
    /// `MailStore`.
    public func matchingRules(for message: Message) -> [EmailRule] {
        EmailRuleMatcher.matchingRules(for: message, in: rules)
    }

    private func persist() {
        guard let defaults else { return }
        let envelope = Envelope(version: Self.currentVersion, rules: rules)
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private static func read(from defaults: UserDefaults) -> [EmailRule] {
        guard let data = defaults.data(forKey: storageKey) else { return [] }

        if let envelope = try? JSONDecoder().decode(Envelope.self, from: data) {
            guard envelope.version <= currentVersion else { return [] }
            return unique(envelope.rules)
        }

        // Migração de uma eventual primeira versão que gravou a lista sem
        // envelope. Ela só é lida; a próxima escrita já sobe para a versão 1.
        if let legacy = try? JSONDecoder().decode([EmailRule].self, from: data) {
            return unique(legacy)
        }

        // Dados inválidos não podem derrubar a abertura da janela. Não gravar
        // aqui preserva a possibilidade de uma migração futura recuperar os
        // bytes que não conhecemos.
        return []
    }

    private static func unique(_ rules: [EmailRule]) -> [EmailRule] {
        var seen = Set<String>()
        return rules.filter { seen.insert($0.id).inserted }
    }
}
