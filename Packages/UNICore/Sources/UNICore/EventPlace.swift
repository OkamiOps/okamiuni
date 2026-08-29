import Foundation

/// O que o campo **LOCAL** da janela do compromisso deve mostrar, dado o
/// `LOCATION` que o convite trouxe.
///
/// ## O defeito
///
/// O Google Agenda não escreve um lugar no `LOCATION`: escreve o cartão de
/// entrada da chamada inteiro. A tela do dono mostrava, na linha "LOCAL":
///
/// ```
/// DreamSquad <> Vantion Friday, July 24 · 2:00 – 3:00pm Time zone:
/// America/Argentina/Buenos_Aires Google Meet joining info Video call link:
/// https://meet.google.com/…
/// ```
///
/// Título repetido, horário repetido, fuso, e o link — que a janela já mostra
/// no cartão dele, em cima. Nada disso é um local, e o campo que deveria
/// responder "onde" respondia com a mensagem inteira.
///
/// ## A regra
///
/// Conservadora de propósito, porque o erro caro é o contrário: comer o
/// endereço de uma reunião presencial. Um `LOCATION` só é tratado como despejo
/// quando ele **se denuncia** — traz um link de sala reconhecido (`MeetingLink`)
/// ou uma das frases que só aparecem nesse cartão. Sem denúncia, o texto
/// atravessa intacto: "Av. Paulista, 1000, sala 3" nunca passa por limpeza
/// nenhuma.
///
/// Denunciado, sobra o que for útil: as linhas que não são link, nem frase de
/// cartão, nem o título do próprio evento repetido. Não sobrando nada — o caso
/// do dono, em que o despejo é uma linha só — o campo diz "Sem local definido",
/// que é a verdade.
public enum EventPlace {

    /// O que a janela mostra quando não há local. É o mesmo texto do
    /// `EV_DEFAULT` do protótipo, e continua sendo uma frase só no app inteiro.
    public static let semLocal = "Sem local definido"

    /// As frases que só existem no cartão de entrada da chamada, nunca num
    /// endereço. Curta de propósito, e cresce quando aparecer um caso real —
    /// a mesma disciplina de `MeetingLink.hosts`.
    static let marcasDeDespejo = [
        "joining info",
        "video call link",
        "join by phone",
        "informações de participação",
        "link da videochamada",
        "entrar pelo telefone",
        "time zone:",
        "fuso horário:",
    ]

    /// Este texto se denuncia como despejo de cartão de chamada?
    public static func ehDespejo(_ texto: String) -> Bool {
        if MeetingLink.first(in: texto) != nil { return true }
        let baixo = texto.lowercased()
        return marcasDeDespejo.contains { baixo.contains($0) }
    }

    /// O `LOCATION` virando o que a linha LOCAL mostra. `nil` quando não sobrou
    /// local nenhum — quem chama põe `semLocal` no lugar.
    ///
    /// `summary` entra porque o Google repete o título do evento como primeira
    /// linha do despejo, e um título repetido não é um lugar. Vazio por padrão:
    /// quem não tem título a comparar não perde nada.
    public static func limpa(_ location: String?, summary: String = "") -> String? {
        guard let location else { return nil }
        let inteiro = location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !inteiro.isEmpty else { return nil }
        // **Sem denúncia, sem limpeza.** É esta guarda que faz o endereço
        // físico atravessar byte a byte.
        guard ehDespejo(inteiro) else { return inteiro }

        let tituloBaixo = summary.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let sobra = inteiro
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { linha in
                guard !linha.isEmpty, !ehDespejo(linha) else { return false }
                // Qualquer endereço, e não só o de sala reconhecida: o cartão
                // do Google traz o "responder ao convite" e o mapa, e nenhum
                // dos dois é um lugar.
                guard !linha.lowercased().contains("http") else { return false }
                guard tituloBaixo.isEmpty || linha.lowercased() != tituloBaixo else { return false }
                return true
            }
        return sobra.isEmpty ? nil : sobra.joined(separator: "\n")
    }
}
