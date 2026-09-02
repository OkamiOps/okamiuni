import Foundation
import Testing
import UNICore
@testable import UNIShell

/// O que a faixa do TL;DR escreve depois do resumo quando a triagem existe.
@Suite("A faixa de triagem do leitor")
struct ReaderTriageBandTests {

    private let fuso = TimeZone(identifier: "America/Sao_Paulo")!

    /// Quinta-feira, 4 de setembro de 2026, 15h em São Paulo.
    private var quinta15h: Date {
        var calendario = Calendar(identifier: .gregorian)
        calendario.timeZone = fuso
        return calendario.date(from: DateComponents(
            timeZone: fuso, year: 2026, month: 9, day: 3, hour: 15, minute: 0
        ))!
    }

    @Test("sem triagem, a faixa não escreve nada de novo")
    func semTriagem() {
        #expect(ReaderPane.triageChips(for: nil, timeZone: fuso).isEmpty)
    }

    @Test("precisa resposta aparece; informativo sem prazo não escreve nada")
    func precisaResposta() {
        let pede = MessageTriage(needsReply: true, intent: .request, urgency: .normal)
        #expect(ReaderPane.triageChips(for: pede, timeZone: fuso) == ["Precisa resposta"])

        let calada = MessageTriage(needsReply: false, intent: .informational, urgency: .low)
        #expect(ReaderPane.triageChips(for: calada, timeZone: fuso).isEmpty)
    }

    @Test("o prazo vira 'Prazo: qui 15h', na ordem depois do pedido de resposta")
    func prazo() {
        let triagem = MessageTriage(
            needsReply: true,
            intent: .lead,
            urgency: .high,
            deadline: DetectedDeadline(date: quinta15h, evidence: "quinta às 15h")
        )
        #expect(ReaderPane.triageChips(for: triagem, timeZone: fuso)
            == ["Precisa resposta", "Prazo: qui 15h"])
    }

    @Test("prazo com minuto quebrado escreve o minuto")
    func prazoComMinuto() {
        var calendario = Calendar(identifier: .gregorian)
        calendario.timeZone = fuso
        let data = calendario.date(from: DateComponents(
            timeZone: fuso, year: 2026, month: 9, day: 7, hour: 9, minute: 30
        ))!
        let triagem = MessageTriage(
            needsReply: false,
            intent: .request,
            urgency: .normal,
            deadline: DetectedDeadline(date: data, evidence: "segunda 9h30")
        )
        #expect(ReaderPane.triageChips(for: triagem, timeZone: fuso) == ["Prazo: seg 9h30"])
    }
}
