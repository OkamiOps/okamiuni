import Foundation
import Testing
import UNICore
@testable import UNISync

/// O espelho da triagem no Gmail, contra o stub de sempre — nenhuma destas
/// afirmações toca rede.
@Suite("O espelho da triagem no Gmail")
struct GmailMirrorTests {
    private let base = "/gmail/v1/users/me"

    private func par(
        routes: [String: [StubURLProtocol.Reply]]
    ) -> (GmailMirror, URLSession) {
        let sessao = StubURLProtocol.session(routes: routes)
        let cliente = GmailClient(
            session: sessao,
            accessToken: { "token" },
            baseURL: URL(string: "https://gmail.example/gmail/v1/users/me")!
        )
        return (GmailMirror(client: cliente), sessao)
    }

    private func alvo(_ id: String) -> MessageCoordinate { .gmail(serverID: id) }

    /// O corpo do POST que foi para um caminho, decodificado.
    private func corpo(
        _ sessao: URLSession, caminho: String, ordem: Int = 0
    ) throws -> [String: Any] {
        let pedidos = StubURLProtocol.requests(for: sessao).filter { $0.path == caminho }
        guard pedidos.indices.contains(ordem),
              let dados = pedidos[ordem].body.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: dados) as? [String: Any]
        else {
            Issue.record("Nenhum POST \(ordem) para \(caminho).")
            return [:]
        }
        return json
    }

    // MARK: - As bandeiras

    @Test("Marcar como lida tira UNREAD; marcar como não lida põe de volta")
    func lida() async throws {
        let (espelho, sessao) = par(routes: [
            "\(base)/messages/batchModify": [.init(status: 204), .init(status: 204)],
        ])

        try await espelho.apply(.setRead(isRead: true, messageIDs: ["x"]), targets: [alvo("m1")])
        try await espelho.apply(.setRead(isRead: false, messageIDs: ["x"]), targets: [alvo("m1")])

        let primeiro = try corpo(sessao, caminho: "\(base)/messages/batchModify", ordem: 0)
        #expect(primeiro["ids"] as? [String] == ["m1"])
        #expect(primeiro["removeLabelIds"] as? [String] == ["UNREAD"])
        #expect((primeiro["addLabelIds"] as? [String])?.isEmpty == true)

        let segundo = try corpo(sessao, caminho: "\(base)/messages/batchModify", ordem: 1)
        #expect(segundo["addLabelIds"] as? [String] == ["UNREAD"])
    }

    @Test("Sinalizar é a estrela do Gmail")
    func estrela() async throws {
        let (espelho, sessao) = par(routes: [
            "\(base)/messages/batchModify": [.init(status: 204)],
        ])
        try await espelho.apply(
            .setFlagged(isFlagged: true, messageIDs: ["x"]), targets: [alvo("m1")]
        )
        let pedido = try corpo(sessao, caminho: "\(base)/messages/batchModify")
        #expect(pedido["addLabelIds"] as? [String] == ["STARRED"])
    }

    // MARK: - As caixas

    @Test("Arquivar tira a INBOX")
    func arquiva() async throws {
        let (espelho, sessao) = par(routes: [
            "\(base)/labels": [.json(#"{"labels":[{"id":"INBOX","name":"INBOX"}]}"#)],
            "\(base)/messages/batchModify": [.init(status: 204)],
        ])
        try await espelho.apply(
            .move(bucket: TriageBucket.archived.rawValue, messageIDs: ["x"]),
            targets: [alvo("m1"), alvo("m2")]
        )
        let pedido = try corpo(sessao, caminho: "\(base)/messages/batchModify")
        #expect(pedido["ids"] as? [String] == ["m1", "m2"])
        #expect(pedido["removeLabelIds"] as? [String] == ["INBOX"])
        #expect((pedido["addLabelIds"] as? [String])?.isEmpty == true)
    }

    @Test("Apagar põe TRASH e tira a INBOX")
    func lixeira() async throws {
        let (espelho, sessao) = par(routes: [
            "\(base)/messages/batchModify": [.init(status: 204)],
        ])
        try await espelho.apply(.delete(messageIDs: ["x"]), targets: [alvo("m1")])
        let pedido = try corpo(sessao, caminho: "\(base)/messages/batchModify")
        #expect(pedido["addLabelIds"] as? [String] == ["TRASH"])
        #expect(pedido["removeLabelIds"] as? [String] == ["INBOX"])
    }

    @Test("Depois cria a label no primeiro uso — e só no primeiro")
    func depoisCriaUmaVezSo() async throws {
        let (espelho, sessao) = par(routes: [
            // A conta ainda não tem `OkamiUNI/Depois`.
            "\(base)/labels": [
                .json(#"{"labels":[{"id":"INBOX","name":"INBOX"}]}"#),
                .json(#"{"id":"Label_7"}"#),
            ],
            "\(base)/messages/batchModify": [.init(status: 204), .init(status: 204)],
        ])

        try await espelho.apply(
            .move(bucket: TriageBucket.later.rawValue, messageIDs: ["x"]), targets: [alvo("m1")]
        )
        try await espelho.apply(
            .move(bucket: TriageBucket.later.rawValue, messageIDs: ["y"]), targets: [alvo("m2")]
        )

        let pedidos = StubURLProtocol.requests(for: sessao)
        // Uma criação, e uma só: a segunda operação usa o id já conhecido.
        let criacoes = pedidos.filter { $0.path == "\(base)/labels" && !$0.body.isEmpty }
        #expect(criacoes.count == 1)
        let criacao = try JSONSerialization.jsonObject(
            with: Data(criacoes[0].body.utf8)
        ) as? [String: Any]
        #expect(criacao?["name"] as? String == TriageProjection.laterLabelName)

        // E as duas mensagens ganharam a label, com a INBOX saindo junto para
        // não aparecerem duas vezes no webmail.
        for ordem in 0...1 {
            let pedido = try corpo(sessao, caminho: "\(base)/messages/batchModify", ordem: ordem)
            #expect(pedido["addLabelIds"] as? [String] == ["Label_7"])
            #expect(pedido["removeLabelIds"] as? [String] == ["INBOX"])
        }
    }

    @Test("Depois reaproveita a label que já existia, sem criar outra")
    func depoisReaproveita() async throws {
        let (espelho, sessao) = par(routes: [
            "\(base)/labels": [
                .json("""
                    {"labels":[{"id":"INBOX","name":"INBOX"},
                    {"id":"Label_3","name":"\(TriageProjection.laterLabelName)"}]}
                    """),
            ],
            "\(base)/messages/batchModify": [.init(status: 204)],
        ])
        try await espelho.apply(
            .move(bucket: TriageBucket.later.rawValue, messageIDs: ["x"]), targets: [alvo("m1")]
        )
        let criacoes = StubURLProtocol.requests(for: sessao)
            .filter { $0.path == "\(base)/labels" && !$0.body.isEmpty }
        #expect(criacoes.isEmpty)
        let pedido = try corpo(sessao, caminho: "\(base)/messages/batchModify")
        #expect(pedido["addLabelIds"] as? [String] == ["Label_3"])
    }

    // MARK: - O apagamento definitivo

    @Test("Apagar definitivamente usa batchDelete")
    func apagaDeVez() async throws {
        let (espelho, sessao) = par(routes: [
            "\(base)/messages/batchDelete": [.init(status: 204)],
        ])
        try await espelho.apply(
            .deletePermanently(messageIDs: ["x"]), targets: [alvo("m1"), alvo("m2")]
        )
        let pedido = try corpo(sessao, caminho: "\(base)/messages/batchDelete")
        #expect(pedido["ids"] as? [String] == ["m1", "m2"])
    }

    @Test("Esvaziar a lixeira pergunta ao servidor o que está nela")
    func esvazia() async throws {
        let (espelho, sessao) = par(routes: [
            "\(base)/messages": [.json(#"{"messages":[{"id":"t1"},{"id":"t2"}]}"#)],
            "\(base)/messages/batchDelete": [.init(status: 204)],
        ])
        // Sem alvo nenhum: as linhas locais já foram apagadas na transação do
        // enfileiramento, e é o servidor que diz o que ainda está na lixeira.
        try await espelho.apply(.emptyTrash, targets: [])

        let listagem = StubURLProtocol.requests(for: sessao).first { $0.path == "\(base)/messages" }
        #expect(listagem?.query.contains("in:trash") == true)
        let pedido = try corpo(sessao, caminho: "\(base)/messages/batchDelete")
        #expect(pedido["ids"] as? [String] == ["t1", "t2"])
    }

    // MARK: - Idempotência

    @Test("Repetir a mesma operação manda o mesmo pedido — nunca uma inversão")
    func idempotente() async throws {
        let (espelho, sessao) = par(routes: [
            "\(base)/messages/batchModify": [.init(status: 204), .init(status: 204)],
        ])
        // O timeout ambíguo, encenado: o executor tenta de novo a mesma
        // operação. O que sai do espelho tem de ser idêntico.
        try await espelho.apply(.setRead(isRead: true, messageIDs: ["x"]), targets: [alvo("m1")])
        try await espelho.apply(.setRead(isRead: true, messageIDs: ["x"]), targets: [alvo("m1")])

        let corpos = StubURLProtocol.requests(for: sessao)
            .filter { $0.path == "\(base)/messages/batchModify" }
            .map(\.body)
        #expect(corpos.count == 2)
        #expect(corpos[0] == corpos[1])
    }
}
