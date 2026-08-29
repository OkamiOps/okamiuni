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
    func fetchBody(accountID: String, messageID: String) async throws -> [String]
}
