import Foundation

/// O rascunho de uma resposta rápida, escrito na faixa embutida no leitor.
///
/// Existe para atravessar duas fronteiras sem se perder: a faixa que fecha e
/// reabre, e o "⤢" que promove a resposta para a janela cheia. Por isso ele
/// mora no `MailStore` (`replyDraft(for:)` / `setReplyDraft(_:for:)`) e não em
/// `@State` de uma `View` — estado de `View` morre quando a `View` sai da tela,
/// e perder o que a pessoa escreveu é pior do que não ter o botão.
public struct ReplyDraft: Sendable, Hashable {
    /// Quem recebe. Começa com o remetente da mensagem respondida.
    public var to: [Contact]
    /// Cópia e cópia oculta — as linhas que os botões "Cc" e "Cco" da faixa
    /// abrem, como no protótipo (tela 01, linhas 1157 e 1177).
    public var cc: [Contact]
    public var bcc: [Contact]

    /// O corpo, **texto rico**.
    ///
    /// Era `String` até esta tarefa, e por isso a faixa não podia ter barra de
    /// formatação: uma barra que age sobre a seleção precisa de um corpo que
    /// carregue atributos por trecho. O atributo de verdade é
    /// `BodyStyleAttribute` (ver `RichBody`); os atributos do SwiftUI são
    /// projeção dele.
    public var body: AttributedString

    /// Arquivos reais escolhidos para a resposta. O nome é metadado do arquivo,
    /// não uma chave para uma fixture.
    public var attachments: [OutgoingAttachment]

    /// Quando o rascunho foi guardado pela última vez pelo botão "Salvar".
    /// `nil` = nunca guardado explicitamente (só está em memória enquanto se
    /// digita).
    public var savedAt: Date?

    /// Quando o botão "Enviar" (ou "Enviar e arquivar") foi apertado.
    ///
    /// Separado de `savedAt` de propósito: "Salvar" deixa a faixa aberta para
    /// continuar escrevendo, "Enviar" a fecha na confirmação. Sem os dois
    /// campos, salvar e voltar depois reabriria a faixa como se já tivesse
    /// sido enviada.
    public var sentAt: Date?

    /// O "Enviar e arquivar" arquivou a original. É a metade que o marco
    /// consegue fazer de verdade, e a faixa fechada precisa dizer isso.
    public var archivedOriginal: Bool

    public init(
        to: [Contact] = [],
        cc: [Contact] = [],
        bcc: [Contact] = [],
        body: AttributedString = AttributedString(),
        attachments: [OutgoingAttachment] = [],
        savedAt: Date? = nil,
        sentAt: Date? = nil,
        archivedOriginal: Bool = false
    ) {
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.body = body
        self.attachments = attachments
        self.savedAt = savedAt
        self.sentAt = sentAt
        self.archivedOriginal = archivedOriginal
    }

    /// Conveniência para quem só tem texto puro em mãos — testes e o caminho
    /// de semeadura. O corpo rico nasce sem atributo nenhum, que é o padrão.
    public init(to: [Contact] = [], text: String, savedAt: Date? = nil) {
        self.init(to: to, body: AttributedString(text), savedAt: savedAt)
    }

    /// O corpo em texto puro. É **projeção** do corpo rico, não uma segunda
    /// fonte de verdade: quem escreve escreve em `body`.
    public var text: String { String(body.characters) }

    /// Nada que valha a pena guardar: ninguém no cabeçalho, nada escrito,
    /// nenhum anexo.
    public var isEmpty: Bool {
        to.isEmpty && cc.isEmpty && bcc.isEmpty && attachments.isEmpty && !hasText
    }

    /// Há de fato algo escrito. Um rascunho com só o destinatário semeado não
    /// conta: ninguém escreveu nada ali.
    public var hasText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Um dos "Rascunhos sugeridos" do protótipo (tela 01, linha 1338): o rótulo
/// que aparece no menu e o texto que ele escreve no corpo.
public struct SuggestedDraft: Sendable, Hashable, Identifiable {
    public var id: String { label }
    public let label: String
    public let text: String

    public init(label: String, text: String) {
        self.label = label
        self.text = text
    }
}

/// A aritmética da faixa de resposta rápida: de onde saem as sugestões, o que
/// casa com o que se digita, e o que entra e sai do campo de destinatário.
///
/// Puro de propósito, e fora de qualquer `View`: no Swift 6 uma `View` é
/// `@MainActor` implícito e um `static` dentro dela trapa em runtime quando um
/// teste nonisolated o chama. É a mesma razão de `AgendaSummary` e `PaneLayout`
/// morarem aqui.
public enum QuickReply {
    /// Protótipo: o menu da faixa mostra no máximo cinco linhas.
    ///
    /// Mesmo teto do campo de destinatário, e por delegação: o número estava
    /// escrito duas vezes, e dois tetos que têm de ser iguais divergem no
    /// primeiro ajuste.
    public static var suggestionLimit: Int { ContactDirectory.suggestionLimit }

    /// Ver `ContactDirectory.fold`.
    public static func fold(_ text: String) -> String {
        ContactDirectory.fold(text)
    }

    /// Ver `ContactDirectory.matches`.
    ///
    /// Havia aqui uma **segunda** máquina de sugestão, com regras opostas às do
    /// campo de destinatário da janela cheia: ela dobrava acento e a outra não,
    /// ela ignorava a organização e a outra procurava nela, e cada uma estava
    /// travada por um teste que contradizia o da outra. Duas respostas
    /// diferentes para a mesma pergunta, na mesma janela — digitar "Interno"
    /// listava quatro contatos na 03 e nenhum na faixa do leitor.
    ///
    /// `ContactDirectory` é a canônica. O que sobrou aqui é a delegação, para
    /// os call sites da faixa não terem de mudar de nome.
    public static func matches(_ contact: DirectoryContact, query: String) -> Bool {
        ContactDirectory.matches(contact, query: query)
    }

    /// Os contatos que o app conhece, montados a partir do que existe.
    ///
    /// A base são os **remetentes das mensagens** — qualquer nome, qualquer
    /// domínio, qualquer provedor. Nada aqui olha para conta nem para host: uma
    /// lista fixa de domínios seria exatamente o que este projeto não faz.
    /// `catalog` é o caderno de endereços que o app já tenha (no Marco 1, o do
    /// protótipo); quem aparece nos dois soma as duas frequências e fica com o
    /// nome e a organização do caderno, que são os mais completos.
    ///
    /// Ordem: mais escritos primeiro, e empate resolvido por nome e endereço
    /// para a lista não dançar entre duas execuções.
    public static func directory(
        messages: [Message],
        catalog: [DirectoryContact] = []
    ) -> [DirectoryContact] {
        var order: [String] = []
        var byKey: [String: DirectoryContact] = [:]

        func merge(_ entry: DirectoryContact, addingFrequency extra: Int) {
            let key = entry.id
            if let existing = byKey[key] {
                byKey[key] = DirectoryContact(
                    name: entry.name.isEmpty ? existing.name : entry.name,
                    address: existing.address,
                    org: entry.org.isEmpty ? existing.org : entry.org,
                    frequency: existing.frequency + extra
                )
            } else {
                order.append(key)
                byKey[key] = DirectoryContact(
                    name: entry.name, address: entry.address,
                    org: entry.org, frequency: extra
                )
            }
        }

        for message in messages where !message.from.address.isEmpty {
            merge(
                DirectoryContact(
                    name: message.from.name, address: message.from.address,
                    org: "", frequency: 0
                ),
                addingFrequency: 1
            )
        }
        for entry in catalog where !entry.address.isEmpty {
            merge(entry, addingFrequency: entry.frequency)
        }

        return order.compactMap { byKey[$0] }.sorted { left, right in
            if left.frequency != right.frequency { return left.frequency > right.frequency }
            if left.name != right.name { return left.name < right.name }
            return left.address < right.address
        }
    }

    /// As até cinco linhas do menu. Ver `ContactDirectory.suggestions` — é a
    /// mesma decisão, e agora a mesma implementação.
    public static func suggestions(
        matching query: String,
        excluding chosen: [Contact],
        in pool: [DirectoryContact]
    ) -> [DirectoryContact] {
        ContactDirectory.suggestions(matching: query, excluding: chosen, in: pool)
    }

    /// Protótipo: `label: q ? 'Contatos' : 'Mais usados'`.
    public static func menuLabel(query: String) -> String {
        ContactDirectory.menuLabel(query: query)
    }

    /// Ver `ContactDirectory.resolve(typed:in:)` — era o segundo par da mesma
    /// divergência.
    public static func resolve(typed raw: String, in pool: [DirectoryContact]) -> DirectoryContact? {
        ContactDirectory.resolve(typed: raw, in: pool)
    }

    /// Acrescenta sem duplicar. Devolve a lista nova em vez de mutar, para a
    /// regra ser testável fora de qualquer `View`.
    public static func adding(_ contact: Contact, to chips: [Contact]) -> [Contact] {
        guard !chips.contains(where: { $0.id == contact.id }) else { return chips }
        return chips + [contact]
    }

    /// Tira a etiqueta pelo endereço, sem depender do nome.
    public static func removing(_ contact: Contact, from chips: [Contact]) -> [Contact] {
        chips.filter { $0.id != contact.id }
    }

    // MARK: - O que cada botão do rodapé pode fazer

    /// "Enviar" e "Enviar e arquivar" agem com destinatário e conteúdo:
    /// texto, anexo, ou ambos. Um PDF sem texto é uma mensagem válida.
    /// Fora disso o botão fica desabilitado, com o motivo no `help` — botão
    /// mudo é defeito, e um "Enviar" que não faz nada é o pior deles.
    public static func canSend(_ draft: ReplyDraft) -> Bool {
        !draft.to.isEmpty && (draft.hasText || !draft.attachments.isEmpty)
    }

    /// "Salvar" precisa de algo para salvar, e de algo **novo**: rascunho já
    /// carimbado desabilita o botão em vez de recarimbar o mesmo texto.
    public static func canSave(_ draft: ReplyDraft) -> Bool {
        (draft.hasText || !draft.attachments.isEmpty) && draft.savedAt == nil
    }

    /// O rascunho depois do "Enviar". Marco 1 não tem rede: o que fica é o
    /// carimbo, que é o que a faixa fechada mostra. `archiving` registra que a
    /// original foi arquivada de verdade — quem arquiva é o `MailStore`.
    public static func sent(_ draft: ReplyDraft, archiving: Bool, at now: Date) -> ReplyDraft {
        var next = draft
        next.sentAt = now
        next.savedAt = now
        if archiving { next.archivedOriginal = true }
        return next
    }

    /// O rascunho depois do "Salvar": carimbado, e **sem** `sentAt` — salvar
    /// não fecha a faixa nem finge que a resposta saiu.
    public static func saved(_ draft: ReplyDraft, at now: Date) -> ReplyDraft {
        var next = draft
        next.savedAt = now
        return next
    }

    /// O rascunho depois de qualquer edição do corpo: os dois carimbos deixam
    /// de ser verdade no instante em que o texto muda.
    public static func edited(_ draft: ReplyDraft) -> ReplyDraft {
        var next = draft
        next.savedAt = nil
        next.sentAt = nil
        return next
    }

    /// Acrescenta a seleção real sem duplicar a identidade do arquivo. A UI
    /// usa a porta de seleção; esta função mantém a transição testável fora da
    /// `View` e não conhece nenhuma fixture.
    public static func attaching(
        _ draft: ReplyDraft, files: [OutgoingAttachment]
    ) -> ReplyDraft {
        var next = draft
        var ids = Set(next.attachments.map(\.id))
        next.attachments += files.filter { ids.insert($0.id).inserted }
        return next
    }


    // MARK: - Rascunhos sugeridos

    /// O menu "Rascunho sugerido" do protótipo (tela 01, linha 1338).
    ///
    /// A fonte é `message.replyHints`, que é o `sel.replyHints` do protótipo —
    /// e este é o primeiro leitor desse campo. Cada dica vira um rótulo do
    /// menu, exatamente como o protótipo faz
    /// (`replyHints.map(t => ({ value: t, label: t }))`).
    ///
    /// O corpo que a dica escreve é o tratamento mais a própria dica. O
    /// protótipo tem uma tabela `DRAFTS` que traduz cada dica num parágrafo
    /// pronto; esse dado não existe no nosso modelo, e o próprio protótipo cai
    /// no texto da dica quando ele falta (`DRAFTS[t] || t`). Uma tabela dessas
    /// é escopo novo — está registrado no relatório da Task Z.
    ///
    /// Mensagem **sem** dicas não pode ficar com um menu vazio, que é um
    /// controle mudo: aí as sugestões derivam da própria mensagem — o primeiro
    /// nome de quem escreveu e, se o app detectou um compromisso, o rótulo
    /// dele. Nada de lista fixa por domínio, conta ou provedor.
    ///
    /// Puro e fora de `View` para o teste conseguir chamá-lo.
    public static func suggestedDrafts(for message: Message) -> [SuggestedDraft] {
        let greeting = firstName(of: message.from)
        let opening = greeting.isEmpty ? "Olá" : greeting

        if !message.replyHints.isEmpty {
            return message.replyHints.map { hint in
                SuggestedDraft(label: hint, text: "\(opening), \(hint.lowercasedFirstLetter())")
            }
        }

        var drafts: [SuggestedDraft] = []
        if let event = message.detectedEvent {
            drafts.append(
                SuggestedDraft(
                    label: "Confirmar",
                    text: "\(opening), confirmado: \(event.label). Já está na minha agenda."
                )
            )
            drafts.append(
                SuggestedDraft(
                    label: "Remarcar",
                    text: "\(opening), esse horário não fecha aqui. "
                        + "Consegue me mandar duas alternativas?"
                )
            )
        } else {
            drafts.append(
                SuggestedDraft(
                    label: "Confirmar",
                    text: "\(opening), confirmado. Pode seguir."
                )
            )
        }
        drafts.append(
            SuggestedDraft(
                label: "Peço um prazo",
                text: "\(opening), recebi. Vejo isso com calma e te respondo ainda hoje."
            )
        )
        return drafts
    }

    /// "Marina Duarte" → "Marina". Sem nome, devolve vazio — não inventa um
    /// tratamento a partir do endereço.
    static func firstName(of contact: Contact) -> String {
        String(contact.name.split(separator: " ").first ?? "")
    }
}

private extension String {
    /// "Confirmar quinta 15h" → "confirmar quinta 15h", para a dica caber
    /// depois do tratamento. Só a primeira letra: "Renovar 1 ano" não pode
    /// virar "renovar 1 ano" com o resto mexido, e uma sigla no meio fica.
    func lowercasedFirstLetter() -> String {
        guard let first = self.first else { return self }
        return first.lowercased() + dropFirst()
    }
}
