import Foundation

/// Guarda determinística contra o falso positivo mais caro do modelo: usar a
/// data de recebimento como se fosse a data de um compromisso. A geração só é
/// aceita quando o texto original contém uma data reconhecível e um horário
/// que coincide com a saída estruturada. O modelo continua decidindo o sentido
/// da mensagem; esta camada só exige evidência para os campos factuais.
public enum MessageAnalysisEventEvidence {
    private static let datePatterns = [
        #"\b(?:hoje|amanh[ãa]|depois\s+de\s+amanh[ãa]|today|tomorrow)\b"#,
        #"\b(?:segunda(?:-feira)?|ter[çc]a(?:-feira)?|quarta(?:-feira)?|quinta(?:-feira)?|sexta(?:-feira)?|s[áa]bado|domingo|monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b"#,
        #"\b\d{1,2}[\/-]\d{1,2}(?:[\/-]\d{2,4})?\b"#,
        #"\b\d{4}-\d{1,2}-\d{1,2}\b"#,
        #"\b(?:dia\s+)?\d{1,2}\s+(?:de\s+)?(?:jan(?:eiro)?|fev(?:ereiro)?|mar[çc]o|abr(?:il)?|mai(?:o)?|jun(?:ho)?|jul(?:ho)?|ago(?:sto)?|set(?:embro)?|out(?:ubro)?|nov(?:embro)?|dez(?:embro)?|january|february|march|april|may|june|july|august|september|october|november|december)\b"#,
        #"\b(?:january|february|march|april|may|june|july|august|september|october|november|december)\s+\d{1,2}\b"#,
        #"\bdia\s+\d{1,2}\b"#,
    ]

    /// A mesma exigência, sem passar pela saída estruturada do motor local:
    /// é ela que o analisador por JSON reaproveita, para que as duas rotas
    /// tenham exatamente uma regra de evidência.
    public static func supports(
        input: MessageAnalysisInput,
        hour: Int,
        minute: Int
    ) -> Bool {
        let source = input.subject + "\n" + input.body
        guard datePatterns.contains(where: { contains($0, in: source) }) else { return false }
        return explicitTimes(in: source).contains {
            $0.hour == hour && $0.minute == minute
        }
    }

    /// A metade **literal** da mesma regra, isolada para quem precisa só
    /// dela: o prazo da triagem não tem hora estruturada para conferir, mas
    /// tem a mesma exigência de que o trecho citado exista, caractere a
    /// caractere, no texto que foi analisado. Assunto conta como texto
    /// analisado: ele vai no prompt junto com o corpo.
    ///
    /// Uma função só, e pública, porque duplicá-la foi o que quase
    /// aconteceu: o compromisso a tinha embutida no validador do JSON e a
    /// triagem precisaria da mesma linha noutro arquivo.
    public static func quotesLiteral(_ evidence: String, in input: MessageAnalysisInput) -> Bool {
        let trecho = evidence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trecho.count >= minimumEvidenceCharacters else { return false }
        return input.body.contains(trecho) || input.subject.contains(trecho)
    }

    /// **Quatro caracteres.** "Não vazio" não era piso nenhum: "5", "h" ou
    /// "de" aparecem em praticamente qualquer email, e uma evidência dessas
    /// passa por acaso — o modelo não teria citado nada e a regra diria que
    /// sim. Quatro é o menor número que exclui a partícula solta e ainda
    /// aceita a citação curta e legítima ("15h30", "sexta", "12/09").
    ///
    /// A citação de três caracteres que se perde ("15h") é aceitável: o preço
    /// de recusá-la é um prazo a menos, e o de aceitá-la é um prazo inventado
    /// no topo do dashboard.
    public static let minimumEvidenceCharacters = 4

    private static func explicitTimes(in source: String) -> [(hour: Int, minute: Int)] {
        var times: [(Int, Int)] = []
        times += captures(
            #"\b([01]?\d|2[0-3])[:h\.]([0-5]\d)\b"#,
            in: source
        ).compactMap { values in
            guard let hour = Int(values[0]), let minute = Int(values[1]) else { return nil }
            return (hour, minute)
        }
        times += captures(#"\b([01]?\d|2[0-3])h\b"#, in: source).compactMap { values in
            guard let hour = Int(values[0]) else { return nil }
            return (hour, 0)
        }
        times += captures(
            #"\b(0?[1-9]|1[0-2])(?::([0-5]\d))?\s*(am|pm)\b"#,
            in: source
        ).compactMap { values in
            guard var hour = Int(values[0]) else { return nil }
            let minute = Int(values[1]) ?? 0
            let period = values[2].lowercased()
            if period == "pm", hour != 12 { hour += 12 }
            if period == "am", hour == 12 { hour = 0 }
            return (hour, minute)
        }
        if contains(#"\b(?:meio-dia|meio\s+dia|noon)\b"#, in: source) {
            times.append((12, 0))
        }
        if contains(#"\b(?:meia-noite|meia\s+noite|midnight)\b"#, in: source) {
            times.append((0, 0))
        }
        return times
    }

    private static func contains(_ pattern: String, in source: String) -> Bool {
        source.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func captures(_ pattern: String, in source: String) -> [[String]] {
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else { return [] }
        let range = NSRange(source.startIndex..., in: source)
        return expression.matches(in: source, range: range).map { match in
            (1..<match.numberOfRanges).map { index in
                let capture = match.range(at: index)
                guard capture.location != NSNotFound,
                      let range = Range(capture, in: source) else { return "" }
                return String(source[range])
            }
        }
    }
}
