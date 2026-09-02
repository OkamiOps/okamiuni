import Foundation

/// **O que este email pede de você** — em uma linha, no topo da prévia.
///
/// ## Por que existe
///
/// O dono desta caixa tem TDAH. Resumo é bom, mas resumo ainda é prosa: ele
/// conta o que o email *diz*. A pergunta que custa caro é outra — "isto exige
/// alguma coisa de mim, e até quando?" — e ela estava espalhada em três lugares
/// que ninguém lê junto: a etiqueta na lista, o corpo do texto e o cartão de
/// compromisso do leitor.
///
/// ## De onde sai
///
/// **Só da análise já persistida** (`MessageTriage`), e de nada mais. Sem
/// análise isto é `nil` e a prévia não desenha nada: um "Pede resposta"
/// adivinhado por heurística de texto seria pior do que silêncio, porque
/// treinaria a pessoa a desconfiar da única linha que ela deveria poder ler
/// sem conferir.
///
/// Mora em UNICore, `nonisolated` e sem `View` à vista, pelo motivo de
/// `docs/decisoes-de-engenharia.md`.
public struct PedidoDoEmail: Equatable, Sendable {

    /// "Pede resposta", "Pede confirmação de horário" — o verbo, curto.
    public let chamada: String
    /// "hoje", "amanhã", "até 28/08". `nil` quando a análise não achou prazo.
    public let prazo: String?
    /// Urgência alta ou prazo vencendo hoje — quem desenha usa o acento.
    public let urgente: Bool
    /// O trecho literal que afirma o prazo. É a prova de procedência: sem ela
    /// a data não seria mostrável.
    public let evidencia: String?

    public init(chamada: String, prazo: String?, urgente: Bool, evidencia: String?) {
        self.chamada = chamada
        self.prazo = prazo
        self.urgente = urgente
        self.evidencia = evidencia
    }

    /// O rótulo inteiro, para leitor de tela e para o `help`.
    public var rotulo: String {
        guard let prazo else { return chamada }
        return "\(chamada) · \(prazo)"
    }

    public static func de(
        triagem: MessageTriage?, agora: Date, calendario: Calendar = .current
    ) -> PedidoDoEmail? {
        guard let triagem else { return nil }
        let urgente = triagem.urgency == .high
        // Silêncio é a resposta certa para a newsletter: ela não pede nada, e
        // um selo em toda mensagem vira ruído — que é o defeito que esta peça
        // veio consertar, não repetir.
        guard triagem.needsReply || triagem.deadline != nil || urgente else { return nil }

        let chamada: String
        if triagem.needsReply {
            switch triagem.intent {
            case .scheduling: chamada = "Pede confirmação de horário"
            case .lead: chamada = "Lead esperando retorno"
            default: chamada = "Pede resposta"
            }
        } else if triagem.deadline != nil {
            chamada = "Tem prazo"
        } else {
            chamada = "Marcado como urgente"
        }

        var prazo: String?
        var vencendoHoje = false
        if let limite = triagem.deadline {
            let dias = calendario.dateComponents(
                [.day],
                from: calendario.startOfDay(for: agora),
                to: calendario.startOfDay(for: limite.date)
            ).day ?? 0
            vencendoHoje = dias <= 0
            switch dias {
            case ..<0: prazo = "prazo vencido"
            case 0: prazo = "hoje"
            case 1: prazo = "amanhã"
            default:
                let formatador = DateFormatter()
                formatador.locale = Locale(identifier: "pt_BR")
                formatador.calendar = calendario
                formatador.dateFormat = "dd/MM"
                prazo = "até \(formatador.string(from: limite.date))"
            }
        }

        return PedidoDoEmail(
            chamada: chamada, prazo: prazo, urgente: urgente || vencendoHoje,
            evidencia: triagem.deadline?.evidence
        )
    }
}
