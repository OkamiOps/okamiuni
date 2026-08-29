import Foundation

/// Uma página de `users.history.list` — o que mudou desde um `historyId`.
///
/// **Três listas, e não uma.** O Gmail conta a história em quatro tipos de
/// evento (`messageAdded`, `messageDeleted`, `labelAdded`, `labelRemoved`), e
/// eles pedem três ações diferentes do nosso lado: baixar a mensagem nova,
/// apagar a linha, reler os rótulos de quem já está no banco. Um saco único de
/// ids obrigaria quem aplica a adivinhar qual das três, e a adivinhação erraria
/// justamente no caso que mais dói: apagar uma mensagem que só mudou de rótulo.
///
/// A ordem dentro de cada lista é a do servidor, e ela é preservada de
/// propósito: `GmailIncrementalSync` aplica os apagamentos **por último**, e é
/// isso que faz "chegou e foi apagada no mesmo intervalo" terminar apagada.
public struct GmailHistoryPage: Sendable, Hashable {
    /// Mensagens que entraram na caixa.
    public let added: [String]
    /// Mensagens apagadas **de vez** — não é a lixeira. Ir para a lixeira é
    /// mudança de rótulo (`TRASH`), e chega por `changed`.
    public let deleted: [String]
    /// Mensagens cujos rótulos mudaram: lida/não lida, estrela, lixeira,
    /// arquivamento, as pastas do Fluxo. É a lista que faz a bandeira mudar
    /// dos dois lados.
    public let changed: [String]
    public let nextPageToken: String?
    /// O `historyId` do fim desta página. **É ele que é carimbado**, e não o de
    /// cada evento: carimbar o de um evento do meio faria o próximo ciclo
    /// reprocessar o resto da página — inofensivo, porque a gravação é upsert,
    /// mas trabalho de rede pago em todo ciclo, para sempre.
    public let historyID: String?

    public init(
        added: [String], deleted: [String], changed: [String],
        nextPageToken: String?, historyID: String?
    ) {
        self.added = added
        self.deleted = deleted
        self.changed = changed
        self.nextPageToken = nextPageToken
        self.historyID = historyID
    }

    /// Nada mudou, e não há mais página. É o que uma conta parada devolve, e é
    /// o caso mais comum de todos: o ciclo ocioso não pode custar nada além da
    /// ida e volta.
    public static let vazia = GmailHistoryPage(
        added: [], deleted: [], changed: [], nextPageToken: nil, historyID: nil
    )
}

/// O JSON de `users.history.list` virando `GmailHistoryPage`.
///
/// Num arquivo próprio e puro pela mesma razão que `GmailMessageParser` é: é a
/// parte que mais erra (quatro listas aninhadas, cada uma com a mensagem dentro
/// de um envelope diferente) e a que mais barato se testa.
public enum GmailHistoryParser {
    private struct Wire: Decodable {
        struct Mensagem: Decodable { let id: String }
        struct ComMensagem: Decodable { let message: Mensagem? }
        struct Registro: Decodable {
            let messagesAdded: [ComMensagem]?
            let messagesDeleted: [ComMensagem]?
            let labelsAdded: [ComMensagem]?
            let labelsRemoved: [ComMensagem]?
        }
        let history: [Registro]?
        let nextPageToken: String?
        let historyId: String?
    }

    public static func parse(_ data: Data) throws -> GmailHistoryPage {
        let fio: Wire
        do {
            fio = try JSONDecoder().decode(Wire.self, from: data)
        } catch {
            throw SyncError.resposta("A Gmail API devolveu um histórico num formato que não conhecemos.")
        }

        var adicionadas: [String] = []
        var apagadas: [String] = []
        var mudadas: [String] = []
        // Repetidos saem: um id que apareceu em cinco eventos de rótulo é uma
        // mensagem, e buscá-la cinco vezes é pagar cinco viagens pelo mesmo
        // resultado.
        var vistasAdicionadas: Set<String> = []
        var vistasApagadas: Set<String> = []
        var vistasMudadas: Set<String> = []

        for registro in fio.history ?? [] {
            for item in registro.messagesAdded ?? [] {
                guard let id = item.message?.id, vistasAdicionadas.insert(id).inserted else { continue }
                adicionadas.append(id)
            }
            for item in registro.messagesDeleted ?? [] {
                guard let id = item.message?.id, vistasApagadas.insert(id).inserted else { continue }
                apagadas.append(id)
            }
            for item in (registro.labelsAdded ?? []) + (registro.labelsRemoved ?? []) {
                guard let id = item.message?.id, vistasMudadas.insert(id).inserted else { continue }
                mudadas.append(id)
            }
        }

        return GmailHistoryPage(
            added: adicionadas, deleted: apagadas, changed: mudadas,
            nextPageToken: fio.nextPageToken, historyID: fio.historyId
        )
    }
}
