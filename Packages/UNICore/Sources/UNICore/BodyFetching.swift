import Foundation

/// De onde vem o corpo de uma mensagem que o banco **não tem**.
///
/// A carga inicial baixa o corpo cheio de 50 mensagens por pasta — o resto
/// desce por demanda, e "por demanda" era uma frase na spec sem nenhum código
/// atrás dela. O resultado, no banco do dono: 39 das 83 mensagens abrem no
/// leitor sem uma linha de texto, mudas, sem nada na tela dizendo por quê.
///
/// Mora no `UNICore`, ao lado de `MailCommandPort` e pela mesma razão: quem
/// chama é o `MailStore`, e o `MailStore` não pode depender de GRDB nem de NIO
/// para pedir um corpo. O `UNISync` conforma do lado de fora.
///
/// **Assíncrono, ao contrário de `MailCommandPort`.** As seis mutações são
/// escrita local numa transação SQLite; esta aqui é rede — uma conexão IMAP ou
/// uma chamada à Gmail API. É por isso que ela é a única porta do app cuja
/// espera a interface precisa **mostrar**.
/// O que a busca por demanda traz de volta.
///
/// **Três campos e não um** desde a M3-8: o corpo que a porta baixa é o mesmo,
/// mas o decodificador parou de jogar o HTML e o convite fora no caminho. Um
/// tipo, e não uma tupla, porque ele atravessa três pacotes — e uma tupla de
/// três `String?` é a próxima troca de posição silenciosa entre `html` e
/// `calendarICS`.
public struct FetchedBody: Sendable, Equatable {
    /// Os parágrafos de sempre. Lista vazia é resposta legítima.
    public var paragraphs: [String]
    /// O HTML sanitizado, ou `""` quando a mensagem não tem parte HTML. Nunca
    /// `nil` vindo de uma busca de verdade — ver `Message.bodyHTML`.
    public var html: String
    /// O `text/calendar` cru, quando houver.
    public var calendarICS: String?

    public init(paragraphs: [String], html: String = "", calendarICS: String? = nil) {
        self.paragraphs = paragraphs
        self.html = html
        self.calendarICS = calendarICS
    }
}

public protocol BodyFetching: Sendable {
    /// Busca o corpo desta mensagem no servidor, **grava no banco**, e devolve
    /// os parágrafos.
    ///
    /// Gravar é parte do contrato, e não um efeito colateral de quem
    /// implementa: sem isso, sair da mensagem e voltar pagaria a viagem de
    /// novo, e a busca no corpo continuaria sem achar o que a pessoa acabou de
    /// ler. O retorno existe para quem chamou poder mostrar agora, sem esperar
    /// o retrato seguinte.
    ///
    /// Lista vazia é resposta legítima — mensagem sem parte de texto nenhuma —
    /// e não é erro. Quem chama distingue as duas coisas pelo `throw`.
    func fetchBody(accountID: String, messageID: String) async throws -> FetchedBody
}
