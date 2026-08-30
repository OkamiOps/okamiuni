import Foundation

/// A intenção primária de uma mensagem de e-mail.
///
/// O valor bruto é estável para persistência e para a fronteira com modelos
/// locais. `nil` continua significando que nenhum classificador produziu uma
/// resposta válida; a resolução de uma mensagem, por outro lado, sempre
/// oferece um fallback conservador em `.primary`.
public enum MailCategory: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case primary
    case transactions
    case updates
    case promotions
    case social

    public var id: String { rawValue }

    /// Valida o texto fechado que vem da saída estruturada do modelo.
    ///
    /// Espaços nas pontas e diferenças de caixa são ruído de serialização; uma
    /// categoria fora do conjunto fechado não é convertida silenciosamente em
    /// outra intenção.
    public init?(validatedModelValue value: String?) {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.init(rawValue: normalized)
    }

    /// Resolve uma mensagem sem chamar o modelo.
    ///
    /// A categoria já persistida tem precedência. Na ausência dela, somente
    /// aliases inteiros no assunto e no remetente são usados; o corpo e a
    /// pasta não entram nesta heurística. A pasta é deliberadamente ignorada:
    /// provedores podem colocar uma conversa de cliente em "Newsletter" ou
    /// "Notificações", e repetir esse erro enquanto a IA termina seria pior
    /// do que deixá-la temporariamente em `primary`.
    public static func resolve(message: Message, folderNames: [String] = []) -> MailCategory {
        if let persisted = message.category {
            return persisted
        }

        let sources = [message.subject, message.from.name, message.from.address]
        for source in sources {
            let normalizedSource = normalized(source)
            guard !normalizedSource.isEmpty else { continue }

            for (category, aliases) in aliasTable {
                if aliases.contains(where: { normalizedSource.containsWord($0) }) {
                    return category
                }
            }
        }

        return .primary
    }

    private static let aliasTable: [(MailCategory, [String])] = [
        (
            .transactions,
            [
                "fatura", "faturas", "invoice", "invoices", "recibo", "recibos", "receipt",
                "receipts", "pedido", "pedidos", "order", "orders", "pagamento", "pagamentos",
                "payment", "payments", "compra", "compras", "purchase", "purchases"
            ]
        ),
        (
            .promotions,
            [
                "newsletter", "newsletters", "promoção", "promoções", "promocao", "promocoes",
                "promotion", "promotions", "marketing", "oferta", "ofertas", "offer", "offers",
                "sale", "sales", "desconto", "descontos", "discount", "discounts",
                "frete grátis", "frete gratis", "cupom", "cupons"
            ]
        ),
        (
            .social,
            [
                "social", "rede social", "redes sociais", "community", "comunidade", "linkedin",
                "facebook", "instagram", "twitter", "discord"
            ]
        ),
        (
            .updates,
            [
                "notificação", "notificações", "notificacao", "notificacoes", "notification",
                "notifications", "atualização", "atualizações", "atualizacao", "atualizacoes",
                "update", "updates", "status", "aviso", "avisos", "alert", "alerts"
            ]
        )
    ]

    private static func normalized(_ value: String) -> String {
        value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "pt_BR")
            )
            .lowercased()
            .replacingOccurrences(
                of: #"[^\p{L}\p{N}]+"#,
                with: " ",
                options: .regularExpression
            )
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}

private extension String {
    func containsWord(_ alias: String) -> Bool {
        let normalizedAlias = MailCategory.normalizeAlias(alias)
        guard !normalizedAlias.isEmpty else { return false }
        return " \(self) ".contains(" \(normalizedAlias) ")
    }
}

private extension MailCategory {
    static func normalizeAlias(_ value: String) -> String {
        value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "pt_BR")
            )
            .lowercased()
            .replacingOccurrences(
                of: #"[^\p{L}\p{N}]+"#,
                with: " ",
                options: .regularExpression
            )
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}
