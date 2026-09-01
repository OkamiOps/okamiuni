import Foundation

/// O link de entrar na reunião, achado dentro de um texto qualquer.
///
/// **Por que não "a primeira URL".** Um convite de verdade traz meia dúzia de
/// endereços: o mapa do local, o "responder a este convite", a política de
/// privacidade do organizador, o rodapé da empresa. Pegar o primeiro poria
/// qualquer um deles onde a pessoa espera o botão de entrar na chamada — e ela
/// clicaria em cima da hora.
///
/// Então a regra é a inversa: só passa o que é reconhecidamente uma sala. A
/// lista é curta de propósito e cresce quando aparecer um caso real; um
/// endereço não reconhecido não vira link nenhum, e a janela de detalhe
/// simplesmente não desenha o cartão — que é honesto.
public enum MeetingLink {

    /// Os hospedeiros de sala que este projeto reconhece.
    public static let hosts = [
        "meet.google.com",
        "zoom.us",
        "webex.com",
        "teams.microsoft.com",
        "teams.live.com",
        "whereby.com",
        "meet.jit.si",
        "meeting.zoho.com",
        "meet.zoho.com",
    ]

    /// O primeiro link de reunião do texto, ou `nil`.
    ///
    /// Sem `NSRegularExpression`: a varredura é por palavra, e a palavra é
    /// separada por espaço, quebra de linha ou os sinais que costumam cercar
    /// um endereço num texto de convite (`<`, `>`, aspas, parênteses).
    public static func first(in texto: String) -> String? {
        let separadores = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "<>\"'()[],;"))
        for pedaco in texto.components(separatedBy: separadores) {
            let candidato = podaPontuacaoFinal(pedaco)
            let minusculo = candidato.lowercased()
            guard minusculo.hasPrefix("https://") || minusculo.hasPrefix("http://") else { continue }
            guard let host = URL(string: candidato)?.host()?.lowercased() else { continue }
            // Sufixo, e não `contains`: `zoom.us.exemplo.com` não é o Zoom, e
            // `contains` deixaria passar.
            if hosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
                return candidato
            }
        }
        return nil
    }

    /// O endereço **pronto para abrir**, ou `nil`.
    ///
    /// Existe para o botão "Entrar" e para o cartão do link fazerem a mesma
    /// pergunta uma vez só: dois lugares decidindo por conta própria o que é
    /// clicável divergiriam no primeiro caso torto, e um deles viraria controle
    /// mudo — o botão que aparece e não abre nada.
    ///
    /// Só `http`/`https`, e só com hospedeiro: um `mailto:` ou um "Sala 3" não
    /// se abre no navegador, e prometer que sim é a mesma mudez de outra cor.
    public static func destino(_ texto: String?) -> URL? {
        guard let texto else { return nil }
        let limpo = texto.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !limpo.isEmpty, let url = URL(string: limpo) else { return nil }
        guard let esquema = url.scheme?.lowercased(), esquema == "http" || esquema == "https" else {
            return nil
        }
        guard let host = url.host(), !host.isEmpty else { return nil }
        return url
    }

    /// O valor de um campo explícito de sala, já limpo para persistência.
    ///
    /// Aqui não usamos a allowlist de `first(in:)`: quando a pessoa cola uma
    /// sala num campo chamado “Link da reunião”, ela já declarou a intenção. A
    /// allowlist continua valendo ao vasculhar texto livre, onde um mapa ou
    /// rodapé não pode virar “Entrar” por acidente.
    public static func normalizado(_ texto: String) -> String? {
        destino(texto)?.absoluteString
    }

    /// O ponto final da frase não faz parte do endereço. `)` e `>` já caíram
    /// como separadores; sobra a pontuação colada no fim.
    private static func podaPontuacaoFinal(_ texto: String) -> String {
        var podado = texto
        while let ultimo = podado.last, ".,;:!?".contains(ultimo) {
            podado.removeLast()
        }
        return podado
    }
}
