import Foundation
import UNICore

/// Uma linha da faixa **HOJE** — `.dg` do mockup `design/07-dashboard.html`.
///
/// Cada linha é curta, clicável, e aponta para uma mensagem de verdade: é isso
/// que ela tem e o briefing em prosa não tinha. Clicar seleciona a mensagem na
/// lista (e a prévia do meio a mostra); não abre nada.
struct DashboardTodayLine: Identifiable, Hashable, Sendable {

    /// A cor do ponto de 5ø, em token — `--warn`, `--accent` ou `--ink4`.
    enum Tone: Hashable, Sendable {
        case warning
        case accent
        case quiet
    }

    let id: String
    let text: String
    let tone: Tone
    /// Qual mensagem a linha seleciona. `nil` na linha do dia vazio, que não
    /// aponta para lugar nenhum.
    let messageID: String?
}

/// A faixa HOJE, montada do recorte de prioridades.
///
/// **Substitui o briefing em prosa**, e por isso não pede nada à IA: ela está
/// pronta quando a tela abre, e sai da triagem que a `DashboardFocus` já fez.
/// A queixa do dono era literal — "o briefing tá uma merda", "não tenho
/// priorização" —, e um parágrafo gerado por modelo não dá priorização: dá
/// parágrafo.
///
/// Puro e fora da `View` de propósito: uma `View` é `@MainActor` implícito e um
/// `static` dentro dela trava num teste `nonisolated`
/// (`docs/decisoes-de-engenharia.md`).
enum DashboardToday {

    /// Quanto de assunto cabe numa linha da faixa antes de ela empurrar as
    /// outras para fora. O mockup escreve "consultoria p/ 40 pessoas".
    static let subjectLimit = 34

    /// As linhas da faixa, na ordem do mockup: resposta, prazo, lead.
    static func lines(_ focus: DashboardFocus, now: Date) -> [DashboardTodayLine] {
        guard !focus.mail.isEmpty else {
            return [emptyLine(triaged: focus.discardedMailCount)]
        }

        var linhas: [DashboardTodayLine] = []

        let respostas = focus.mail.filter { $0.reason == .needsReply }
        if let primeira = respostas.first {
            linhas.append(
                DashboardTodayLine(
                    id: "needsReply",
                    text: respostas.count == 1
                        ? "1 pede resposta"
                        : "\(respostas.count) pedem resposta",
                    tone: .warning,
                    messageID: primeira.id
                )
            )
        }

        for prazo in focus.mail.filter({ $0.reason == .deadline }).prefix(1) {
            linhas.append(
                DashboardTodayLine(
                    id: "deadline",
                    text: deadlineText(prazo.message, now: now),
                    tone: .warning,
                    messageID: prazo.id
                )
            )
        }

        let leads = focus.mail.filter { $0.reason == .lead }
        if let primeiro = leads.first {
            let assunto = shorten(primeiro.message.subject)
            linhas.append(
                DashboardTodayLine(
                    id: "lead",
                    text: leads.count == 1
                        ? "1 lead novo — \(assunto)"
                        : "\(leads.count) leads novos",
                    tone: .accent,
                    messageID: primeiro.id
                )
            )
        }

        // A lista tem gente, mas nenhum dos três motivos fortes: a faixa não
        // pode ficar muda, senão a tela abre com uma tarja vazia por baixo da
        // saudação — que é a "área morta" que esta tela veio matar.
        if linhas.isEmpty, let primeiro = focus.mail.first {
            linhas.append(
                DashboardTodayLine(
                    id: "priorities",
                    text: focus.mail.count == 1
                        ? "1 na lista de prioridades"
                        : "\(focus.mail.count) na lista de prioridades",
                    tone: .quiet,
                    messageID: primeiro.id
                )
            )
        }
        return linhas
    }

    /// `.dg-empty` — "Nada precisa de você — 9 mensagens triadas para a Caixa."
    static func emptyLine(triaged: Int) -> DashboardTodayLine {
        let cauda: String
        switch triaged {
        case 0: cauda = ""
        case 1: cauda = " — 1 mensagem triada para a Caixa."
        default: cauda = " — \(triaged) mensagens triadas para a Caixa."
        }
        return DashboardTodayLine(
            id: "empty", text: "Nada precisa de você\(cauda)", tone: .quiet, messageID: nil
        )
    }

    /// `.dg.rest` — "12 fora da lista · newsletters e avisos", encostado à
    /// direita. `nil` quando a triagem não descartou nada: um "0 fora da
    /// lista" é ruído com cara de número.
    static func restLabel(_ discarded: Int) -> String? {
        guard discarded > 0 else { return nil }
        return discarded == 1
            ? "1 fora da lista · newsletter ou aviso"
            : "\(discarded) fora da lista · newsletters e avisos"
    }

    /// "Prazo: NF de agosto vence 05/09".
    ///
    /// A data só é anexada quando o assunto **não** a traz — a triagem cita o
    /// trecho do texto que a sustenta, e o assunto costuma ser esse trecho.
    /// Escrever "vence 05/09 · 05/09" seria a mesma data duas vezes.
    static func deadlineText(_ message: Message, now: Date) -> String {
        let assunto = shorten(message.subject)
        guard let prazo = message.triage?.deadline?.date else { return "Prazo: \(assunto)" }
        let dia = shortDate(prazo)
        if assunto.contains(dia) { return "Prazo: \(assunto)" }
        return "Prazo: \(assunto) · vence \(dia)"
    }

    /// "05/09". Locale fixo, como `DashboardMetrics.headerDateLabel`.
    static func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.dateFormat = "dd/MM"
        return formatter.string(from: date)
    }

    /// Corta no limite sem partir palavra no meio quando dá.
    static func shorten(_ text: String) -> String {
        let limpo = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard limpo.count > subjectLimit else { return limpo }
        let corte = limpo.prefix(subjectLimit)
        if let espaco = corte.lastIndex(of: " "), corte.distance(from: corte.startIndex, to: espaco) > subjectLimit / 2 {
            return String(corte[corte.startIndex..<espaco]) + "…"
        }
        return String(corte) + "…"
    }
}
