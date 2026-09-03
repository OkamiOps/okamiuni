import Foundation
import Testing
import UNICore
import UNISync
@testable import UNIShell

/// As decisões puras do dashboard 08 — rótulos, relógio, fatiamento da
/// proposta e a coluna do dia. As **medidas** contra o HTML do mockup moram
/// em `Dashboard08ParityTests`; aqui é o que não é número de CSS.
///
/// Suíte **nonisolated** de propósito: se um dia alguém mover estas contas
/// para dentro de uma `View` (que é `@MainActor` implícito), o caso quebra na
/// hora — a lição registrada em `docs/decisoes-de-engenharia.md`.
@Suite("Dashboard 08 · decisões puras")
struct DashboardMetricsTests {

    // MARK: - O relógio da tela

    @Test("o rótulo diz quando é a próxima atualização, no ciclo de 5 min")
    func updateLabelFollowsTheClock() {
        #expect(
            DashboardMetrics.updateLabel(nowMinute: 601, isBusy: false)
                == "Atualizado agora · próximo em 4 min"
        )
        #expect(
            DashboardMetrics.updateLabel(nowMinute: 604, isBusy: false)
                == "Atualizado agora · próximo em 1 min"
        )
        #expect(
            DashboardMetrics.updateLabel(nowMinute: 600, isBusy: false)
                == "Atualizado agora · próximo em 5 min"
        )
    }

    @Test("com a barra fina trabalhando, o rótulo vira Atualizando…")
    func updateLabelWhileBusy() {
        #expect(DashboardMetrics.updateLabel(nowMinute: 601, isBusy: true) == "Atualizando…")
    }

    // MARK: - Rótulos

    @Test("o botão do herói promete o envio só com rascunho pronto")
    func heroButtonLabel() {
        #expect(DashboardMetrics.heroButtonLabel(hasReadyDraft: true) == "Enviar a resposta")
        #expect(DashboardMetrics.heroButtonLabel(hasReadyDraft: false) == "Ver")
    }

    @Test("a confirmação de uma linha nomeia o destinatário")
    func sendConfirmation() {
        #expect(
            DashboardMetrics.sendConfirmationLabel(address: "jack@whitmore.dev")
                == "Enviar para jack@whitmore.dev?"
        )
    }

    @Test("\"Sexta 9h\" sai da data proposta pelo plano")
    func laterActionLabel() {
        // 2026-09-04 é uma sexta.
        var partes = DateComponents()
        partes.year = 2026; partes.month = 9; partes.day = 4; partes.hour = 9
        let sexta = Calendar.current.date(from: partes)!
        #expect(DashboardMetrics.laterActionLabel(until: sexta) == "Sexta 9h")
    }

    @Test("o rodapé nomeia quem saiu, com o porquê na primeira e o resto somado")
    func removedFooter() {
        let frase = DashboardMetrics.removedFooterLabel(
            [
                (name: "Carol da Zoho", why: "campanha, não lead"),
                (name: "Resend", why: "disparo"),
            ],
            extraCount: 11
        )
        #expect(
            frase == "Tirei da lista hoje: Carol da Zoho (campanha, não lead), "
                + "Resend e mais 11 disparos."
        )
        // Nada removido e nada de fora: rodapé nenhum.
        #expect(DashboardMetrics.removedFooterLabel([], extraCount: 0) == nil)
        // Um disparo só concorda em número.
        #expect(
            DashboardMetrics.removedFooterLabel([(name: "Resend", why: "")], extraCount: 1)
                == "Tirei da lista hoje: Resend e mais 1 disparo."
        )
    }

    @Test("o título do bloco junta os nomes com \"e\" no fim")
    func replyBlockTitle() {
        #expect(
            DashboardMetrics.replyBlockTitle(names: ["Jack", "Jayden", "Maria"])
                == "Responder Jack, Jayden e Maria"
        )
        #expect(DashboardMetrics.replyBlockTitle(names: ["Jack"]) == "Responder Jack")
        #expect(DashboardMetrics.replyBlockTitle(names: []) == "Responder emails")
    }

    @Test("o subtítulo do bloco escreve a contagem por extenso")
    func replyBlockSub() {
        #expect(
            DashboardMetrics.replyBlockSub(count: 3, minutes: 20)
                == "20 min · as três já prontas"
        )
        #expect(
            DashboardMetrics.replyBlockSub(count: 1, minutes: 20)
                == "20 min · a resposta já pronta"
        )
    }

    @Test("\"Ler o email inteiro\" conta as linhas de verdade, sem as vazias")
    func bodyLineCount() {
        #expect(DashboardMetrics.bodyLineCount("a\nb\n\nc") == 3)
        #expect(DashboardMetrics.readWholeLabel(lineCount: 4) == "Ler o email inteiro · 4 linhas")
        #expect(DashboardMetrics.readWholeLabel(lineCount: 1) == "Ler o email inteiro · 1 linha")
    }

    // MARK: - A frase da proposta, fatiada

    @Test("\"Resposta pronta.\" sai em negrito e a prévia corrida")
    func proposalSegmentsForDraft() {
        let segments = DashboardMetrics.proposalSegments(
            text: "Resposta pronta. “Sim, libero até sexta.”",
            isReadyDraft: true
        )
        #expect(segments == [
            .strong("Resposta pronta."),
            .plain("“Sim, libero até sexta.”"),
        ])
    }

    @Test("a pergunta final da sugestão sai em itálico")
    func proposalSegmentsForSuggestion() {
        let segments = DashboardMetrics.proposalSegments(
            text: "Pede para atualizar seu perfil. Sem prazo. Deixar para sexta de manhã?",
            isReadyDraft: false
        )
        #expect(segments == [
            .plain("Pede para atualizar seu perfil. Sem prazo."),
            .note("Deixar para sexta de manhã?"),
        ])
    }

    @Test("o rascunho que olhou a agenda ganha a nota em itálico")
    func proposalSegmentsWithAgenda() {
        let segments = DashboardMetrics.proposalSegments(
            text: "Resposta pronta. “Terça ou quinta.”",
            isReadyDraft: true, usedAgenda: true
        )
        #expect(segments.last == .note("Olhei sua agenda antes de propor."))
    }

    @Test("texto que é só a pergunta vira uma nota inteira")
    func proposalSegmentsAllQuestion() {
        let segments = DashboardMetrics.proposalSegments(
            text: "Arquivar e não trazer mais?", isReadyDraft: false
        )
        #expect(segments == [.note("Arquivar e não trazer mais?")])
    }

    // MARK: - A coluna do dia

    private func agendaItem(
        id: String, title: String, start: Int, end: Int, day: Int = 0,
        cancelled: Bool = false
    ) -> AgendaItem {
        AgendaItem(
            id: id, title: title, startMinute: start, endMinute: end,
            accountID: "gmail", dayOffset: day, isCancelled: cancelled
        )
    }

    @Test("a coluna do dia intercala eventos, Agora, bloco e prazos pela hora")
    func dayEntriesFollowTheClock() {
        let entries = DashboardDay.entries(
            agenda: [
                agendaItem(id: "odette", title: "Termin de Odette", start: 570, end: 600),
                agendaItem(id: "aitherion", title: "Aitherion", start: 699, end: 759),
                agendaItem(id: "amanha", title: "De amanhã", start: 500, end: 560, day: 1),
                agendaItem(
                    id: "cancelado", title: "Cancelado", start: 620, end: 650, cancelled: true
                ),
            ],
            deadlines: [
                .init(
                    messageID: "jayden", senderName: "Jayden",
                    minuteToday: 1_080, dayLabel: nil, sub: "confirmar até hoje às 18h"
                ),
                .init(
                    messageID: "abacus", senderName: "Abacus AI",
                    minuteToday: nil, dayLabel: "Sáb", sub: "6.000 créditos expiram sábado"
                ),
            ],
            plan: DayPlan.ReplyBlock(
                day: 0, startMinute: 780, minutes: 20,
                messageIDs: ["jack", "jayden", "maria"]
            ),
            planNames: ["Jack", "Jayden", "Maria"],
            nowMinute: 600
        )
        #expect(entries == [
            .event(id: "odette", hour: "09:30", title: "Termin de Odette", sub: "30min · gmail"),
            .now,
            .event(id: "aitherion", hour: "11:39", title: "Aitherion", sub: "1h · gmail"),
            .plan(
                hour: "13:00",
                title: "Responder Jack, Jayden e Maria",
                sub: "20 min · as três já prontas"
            ),
            .deadline(
                id: "jayden", hour: "18:00", title: "Prazo de Jayden",
                sub: "confirmar até hoje às 18h"
            ),
            .deadline(
                id: "abacus", hour: "Sáb", title: "Prazo de Abacus AI",
                sub: "6.000 créditos expiram sábado"
            ),
        ])
    }

    @Test("o primeiro nome sai do contato, e do endereço quando não há nome")
    func firstName() {
        #expect(DashboardDay.firstName(
            of: Contact(name: "Jack Whitmore", address: "jack@whitmore.dev")
        ) == "Jack")
        #expect(DashboardDay.firstName(
            of: Contact(name: "", address: "maria@exemplo.com")
        ) == "maria")
    }
}
