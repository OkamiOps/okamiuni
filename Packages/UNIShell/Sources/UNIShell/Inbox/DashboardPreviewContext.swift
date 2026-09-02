import Foundation
import UNICore

/// Uma linha do bloco **Contexto** da prévia — `.cx` do mockup.
struct DashboardContextLine: Identifiable, Hashable, Sendable {
    let id: String
    let text: String
}

/// O que o app **já sabe** sobre a pessoa do outro lado do email selecionado.
///
/// Três fontes, todas locais e todas de dados que já existem: o compromisso de
/// hoje que cita a pessoa, a pendência que cita a pessoa, e a conversa
/// anterior com o mesmo endereço. Nada é inventado e nada é pedido a modelo
/// nenhum — o que não existe simplesmente não aparece, e o bloco encolhe.
///
/// **O que faltou.** O app não guarda participantes de compromisso (o
/// `AgendaItem` tem título, horário e conta, e mais nada), então o casamento
/// com a agenda é pelo nome dentro do título — que é como o "1:1 Marina
/// Duarte" do mockup se deixa achar. Pendência é texto solto (`PendingItem`
/// não aponta para mensagem nem para contato), então vale a mesma regra.
///
/// Puro e fora da `View`, pelo motivo de sempre.
enum DashboardPreviewContext {

    static func lines(
        for message: Message,
        agenda: [AgendaItem],
        pending: [PendingItem],
        messages: [Message]
    ) -> [DashboardContextLine] {
        var linhas: [DashboardContextLine] = []
        let nomes = searchTerms(for: message)

        if let compromisso = agenda.first(where: { item in
            item.dayOffset == 0 && !item.isCancelled && mentions(item.title, nomes)
        }) {
            linhas.append(
                DashboardContextLine(
                    id: "agenda-\(compromisso.id)",
                    text: "\(compromisso.title) hoje às \(clock(compromisso.startMinute)) · agenda"
                )
            )
        }

        if let pendencia = pending.first(where: { mentions($0.text, nomes) }) {
            linhas.append(
                DashboardContextLine(
                    id: "pendencia-\(pendencia.id)", text: "Pendência: \(pendencia.text)"
                )
            )
        }

        if let anterior = lastConversation(with: message, in: messages) {
            linhas.append(
                DashboardContextLine(
                    id: "conversa-\(anterior.id)",
                    text: "Última conversa: \(anterior.subject) · "
                        + DashboardToday.shortDate(anterior.receivedAt)
                )
            )
        }
        return linhas
    }

    /// A conversa anterior com o **mesmo endereço**, fora da mensagem em foco
    /// e fora da lixeira. Endereço, e não nome: dois "Contabilidade" de contas
    /// diferentes não são a mesma pessoa.
    static func lastConversation(with message: Message, in messages: [Message]) -> Message? {
        let endereco = message.from.address.lowercased()
        guard !endereco.isEmpty else { return nil }
        return messages
            .filter { outro in
                outro.id != message.id
                    && outro.from.address.lowercased() == endereco
                    && outro.bucket != .trash
                    && outro.bucket != .junk
                    && outro.receivedAt < message.receivedAt
            }
            .max { $0.receivedAt < $1.receivedAt }
    }

    /// Como procurar a pessoa num texto livre: o nome inteiro e o primeiro
    /// nome. Pedaço de duas letras não vale — "Di" acharia "Diretoria".
    static func searchTerms(for message: Message) -> [String] {
        var termos: [String] = []
        let nome = message.from.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if nome.count >= 3, !nome.contains("@") {
            termos.append(nome.lowercased())
            if let primeiro = nome.split(whereSeparator: \.isWhitespace).first,
               primeiro.count >= 3 {
                termos.append(primeiro.lowercased())
            }
        }
        return termos
    }

    static func mentions(_ text: String, _ terms: [String]) -> Bool {
        guard !terms.isEmpty else { return false }
        let alvo = text.lowercased()
        return terms.contains { alvo.contains($0) }
    }

    /// "11:00" a partir de minutos desde a meia-noite.
    static func clock(_ minute: Int) -> String {
        String(format: "%02d:%02d", minute / 60, minute % 60)
    }
}
