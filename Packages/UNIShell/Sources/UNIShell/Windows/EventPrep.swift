import Foundation
import UNICore

/// "PARA CHEGAR PRONTO" — o bloco de contexto da janela do compromisso.
///
/// ## Só dado real, ou nada
///
/// O protótipo (`ModalAgenda.dc.html`) mostra três linhas: uma promessa que
/// você fez, o último e-mail de quem vai estar lá, e um anexo da conversa. As
/// três são apresentadas como se a IA as tivesse juntado.
///
/// O que entra aqui é a segunda: **os últimos e-mails trocados com os
/// participantes deste compromisso**, lidos do `MailStore`. Isso é verificável
/// — a mensagem existe, tem assunto, tem data, e o "Ler" leva a ela. As outras
/// duas não: "você prometeu a proposta revisada" exige o detector de promessas
/// cruzado com este evento, e "Cronograma_v2.pdf foi anexado na terça" exige
/// casar anexo com compromisso. Nenhum dos dois existe hoje, e fabricar as
/// linhas faria a seção parecer esperta e estar errada.
///
/// Quando não há nenhum e-mail com estas pessoas, o bloco **não aparece**. É o
/// que o brief pede, e é a única versão honesta: um cartão de preparo vazio
/// dizendo "nada a preparar" é ruído com moldura.
enum EventPrep {

    /// Uma linha do bloco.
    struct Line: Identifiable, Equatable {
        /// O id da mensagem — é ele que o "Ler" abre.
        let id: String
        /// "Último e-mail de Marina Costa"
        let who: String
        /// O assunto, que é o que diz do que se trata.
        let what: String
        let date: Date
    }

    /// Quantas linhas o bloco mostra. Três, como o desenho: o bloco é um
    /// lembrete antes da reunião, não a caixa de entrada.
    static let limit = 3

    /// Os últimos e-mails trocados com estas pessoas, do mais recente para o
    /// mais antigo, um por pessoa.
    ///
    /// Um por pessoa, e não os três mais recentes: duas mensagens da mesma
    /// pessoa diriam a mesma coisa duas vezes e empurrariam o terceiro
    /// participante para fora do bloco.
    static func lines(
        guests: [EventPerson],
        messages: [Message],
        me: String,
        limit: Int = limit
    ) -> [Line] {
        let outros = guests
            .map { $0.address.lowercased() }
            .filter { !$0.isEmpty && $0 != me.lowercased() }
        guard !outros.isEmpty else { return [] }
        let procurados = Set(outros)

        var porPessoa: [String: Line] = [:]
        for message in messages {
            let participantes = ([message.from] + message.to).map { $0.address.lowercased() }
            guard let quem = participantes.first(where: { procurados.contains($0) }) else { continue }
            guard !message.subject.isEmpty else { continue }
            if let existente = porPessoa[quem], existente.date >= message.receivedAt { continue }
            // O **nome**, e não o `display`: `display` traz nome e endereço
            // juntos, e a linha do preparo já é longa — ela termina no
            // assunto, que é o que diz do que se trata.
            let contato = ([message.from] + message.to)
                .first { $0.address.lowercased() == quem }
            let nome = contato.map { $0.name.isEmpty ? $0.address : $0.name } ?? quem
            porPessoa[quem] = Line(
                id: message.id,
                who: L10n.tr("Último e-mail de \(nome)"),
                what: message.subject,
                date: message.receivedAt
            )
        }
        return porPessoa.values
            .sorted { $0.date > $1.date }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - A contagem

    /// Quando a contagem aparece: o compromisso começa em até uma hora, ou
    /// está em curso.
    ///
    /// Uma hora, e não "hoje": o bloco da contagem é a maior coisa da janela e
    /// toma o lugar do título. Um compromisso das 17h não precisa dele às 9h
    /// da manhã — ele precisa dele às 16h50.
    static let soonWindow: TimeInterval = 60 * 60

    /// "12 min", "1 h 05", "agora" — e `nil` quando não é hora de contar.
    ///
    /// `nil` também depois do fim: um compromisso que já acabou não tem
    /// contagem nem botão de entrar em destaque.
    static func countdown(start: Date, end: Date, now: Date = Date()) -> String? {
        if now >= start {
            return now < end ? L10n.tr("agora") : nil
        }
        let falta = start.timeIntervalSince(now)
        guard falta <= soonWindow else { return nil }
        let minutos = max(1, Int((falta / 60).rounded(.up)))
        if minutos < 60 { return L10n.tr("\(minutos) min") }
        return L10n.tr("1 h")
    }
}
