import Foundation
import UNICore

/// O adaptador entre o que o `MailStore` entrega e o que `DayPlan.make`
/// espera. Puro, com teste próprio — as duas conversões abaixo são as duas
/// costuras onde a Tarefa 1 e o store de verdade divergem, e cada uma tem o
/// porquê escrito.
enum DashboardPlanInput {

    /// O plano do dia, montado do jeito que a tela 08 o monta.
    ///
    /// Um lugar só: a gaveta precisa saber quem é o herói (o primeiro chip
    /// diz o nome dele) e uma segunda montagem daria um herói diferente do
    /// que a tela está mostrando.
    @MainActor
    static func plan(
        store: MailStore, drafts: [String: ReadyDraft],
        filter: DayPlan.Filter, today: Date, nowMinute: Int
    ) -> DayPlan {
        let selecionada = store.selectedAccountID
        let disparos = store.messages.filter { message in
            message.bucket == .today
                && message.effectiveBulkMarks.isBulk
                && (selecionada == nil || message.accountID == selecionada)
        }
        return DayPlan.make(
            focus: planFocus(store.dashboardFocus(nowMinute: nowMinute), broadcasts: disparos),
            drafts: validatedDrafts(drafts) { store.message($0) },
            rules: store.senderRules,
            agenda: store.agenda,
            filter: filter,
            now: today,
            nowMinute: nowMinute
        )
    }

    /// Valida cada rascunho contra a mensagem **cheia** e devolve uma cópia
    /// cujo hash casa com o recorte sem corpo que o `DashboardFocus` carrega.
    ///
    /// O porquê: `ReadyDraft.contentHash` cobre assunto + trecho + **corpo**
    /// (contrato da coluna `content_hash` da v20, Tarefa 1, decisão 2), mas o
    /// focus guarda cada linha por `withoutHeavyPayload()` — sem corpo. Um
    /// rascunho válido pareceria vencido para o `DayPlan`, e a tela nunca
    /// escreveria "Resposta pronta". A validação de verdade acontece aqui,
    /// contra a mensagem com corpo; a cópia reescreve o hash para o recorte
    /// que o plano vê. Rascunho vencido continua caindo fora — é a primeira
    /// guarda.
    static func validatedDrafts(
        _ drafts: [String: ReadyDraft],
        fullMessage: (String) -> Message?
    ) -> [String: ReadyDraft] {
        drafts.compactMapValues { draft in
            guard let cheia = fullMessage(draft.messageID),
                  draft.matches(cheia)
            else { return nil }
            return ReadyDraft(
                messageID: draft.messageID,
                text: draft.text,
                contentHash: ReadyDraft.contentHash(for: cheia.withoutHeavyPayload()),
                modelVersion: draft.modelVersion,
                usedAgenda: draft.usedAgenda
            )
        }
    }

    /// Acrescenta ao focus os disparos que o ranking descartou.
    ///
    /// O porquê: `DashboardFocus.snapshot` zera o score de todo disparo e o
    /// manda para `discardedMailCount` — mas o `DayPlan` precisa **vê-los
    /// chegar** para decidir o destino de cada um (disparo com prazo vai para
    /// "Vence", como a Abacus; sem prazo vira `removed`, com o porquê, como a
    /// Carol e a Resend — ruling 3 da Tarefa 1). Os acrescentados saem das
    /// contagens de descarte para ninguém somar dos dois lados.
    static func planFocus(
        _ focus: DashboardFocus, broadcasts: [Message]
    ) -> DashboardFocus {
        let presentes = Set(focus.mail.map(\.id))
        let novos = broadcasts
            .filter { !presentes.contains($0.id) }
            .sorted { $0.receivedAt > $1.receivedAt }
            .prefix(20)
            .map { DashboardFocus.MailItem(message: $0.withoutHeavyPayload(), reason: .broadcast) }
        guard !novos.isEmpty else { return focus }
        return DashboardFocus(
            mail: focus.mail + novos,
            meetings: focus.meetings,
            pending: focus.pending,
            omittedMailCount: focus.omittedMailCount,
            omittedMeetingCount: focus.omittedMeetingCount,
            nextUpLabel: focus.nextUpLabel,
            discardedMailCount: max(0, focus.discardedMailCount - novos.count),
            discardedBroadcastCount: max(0, focus.discardedBroadcastCount - novos.count)
        )
    }
}
