import Foundation
import Testing
import UNICore
@testable import UNISync

/// A imagem embutida do Gmail, que a `messages.get` **não** entrega.
///
/// Era a dívida da M3-8, e era o defeito que o dono viu: a newsletter que é 100%
/// imagem abria em branco, e o email com uma foto no meio abria com um buraco no
/// lugar dela. O motivo é sempre o mesmo — o Gmail devolve `attachmentId` no
/// lugar do `data`, e a imagem só desce por uma segunda chamada.
///
/// Nenhum caso aqui toca rede: o `StubURLProtocol` responde do roteiro, e uma
/// rota fora do roteiro derruba o teste em vez de sair pela placa de rede.
@Suite("A imagem embutida do Gmail, buscada")
struct GmailInlineAttachmentsTests {

    private static let base = URL(string: "https://gmail.example/gmail/v1/users/me")!

    /// Um PNG minúsculo de verdade, para o `data:` que sai daqui ser uma imagem
    /// e não uma cadeia de bytes qualquer.
    private static let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    )!

    /// A mensagem como o Gmail a entrega: o HTML referencia `cid:foto@uni`, e a
    /// parte da imagem vem **sem** `data` — só com `attachmentId` e `size`.
    private static func mensagemJSON(
        tamanho: Int, attachmentID: String = "ANGjdJ-foto"
    ) -> Data {
        let html = "<p>Ol&aacute;</p><img src=\"cid:foto@uni\" alt=\"produto\">"
        let htmlB64 = Data(html.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        return Data("""
            {
              "id": "m-sheglam", "threadId": "t1", "labelIds": ["INBOX"],
              "snippet": "We value you", "internalDate": "1800000000000",
              "payload": {
                "mimeType": "multipart/related",
                "headers": [
                  {"name": "From", "value": "SHEGLAM <noreply@notify.sheglam.com>"},
                  {"name": "Subject", "value": "We value you"}
                ],
                "parts": [
                  {
                    "mimeType": "text/html",
                    "headers": [{"name": "Content-Type", "value": "text/html; charset=UTF-8"}],
                    "body": {"data": "\(htmlB64)"}
                  },
                  {
                    "mimeType": "image/png",
                    "headers": [{"name": "Content-ID", "value": "<foto@uni>"}],
                    "body": {"attachmentId": "\(attachmentID)", "size": \(tamanho)}
                  }
                ]
              }
            }
            """.utf8)
    }

    private static func anexoJSON(_ dados: Data) -> Data {
        let b64 = dados.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        return Data("{\"size\": \(dados.count), \"data\": \"\(b64)\"}".utf8)
    }

    private static func sessao(
        tamanho: Int, comAnexo: Bool = true
    ) -> URLSession {
        var rotas: [String: [StubURLProtocol.Reply]] = [
            "/gmail/v1/users/me/messages/m-sheglam": [
                .init(body: mensagemJSON(tamanho: tamanho)),
            ],
        ]
        if comAnexo {
            rotas["/gmail/v1/users/me/messages/m-sheglam/attachments/ANGjdJ-foto"] = [
                .init(body: anexoJSON(png)),
            ]
        }
        return StubURLProtocol.session(routes: rotas)
    }

    private static func cliente(_ sessao: URLSession) -> GmailClient {
        GmailClient(session: sessao, accessToken: { "at" }, baseURL: base)
    }

    // MARK: O que a mensagem crua diz

    @Test("O parser anuncia a imagem que só tem attachmentId — com id, tipo e tamanho")
    func anunciaOQueFalta() throws {
        let pendentes = try GmailMessageParser.inlinePorBuscar(
            Self.mensagemJSON(tamanho: 40_000)
        )
        #expect(pendentes.count == 1)
        // O `Content-ID` já normalizado: é a chave com que o sanitizador casa o
        // `cid:` do HTML.
        #expect(pendentes.first?.contentID == "foto@uni")
        #expect(pendentes.first?.attachmentID == "ANGjdJ-foto")
        #expect(pendentes.first?.mime == "image/png")
        #expect(pendentes.first?.tamanho == 40_000)
    }

    @Test("anexo normal do Gmail conserva metadados para baixar sob demanda")
    func normalAttachmentMetadata() throws {
        let raw = Data("""
        {
          "id":"m-arquivo", "threadId":"t", "labelIds":["INBOX"],
          "snippet":"segue", "internalDate":"1800000000000",
          "payload":{"mimeType":"multipart/mixed", "headers":[
            {"name":"From", "value":"Ana <ana@example.com>"},
            {"name":"Subject", "value":"Proposta"}
          ], "parts":[
            {"mimeType":"text/plain", "body":{"data":"U2VndWU"}},
            {"mimeType":"application/pdf", "filename":"../../proposta.pdf",
             "headers":[{"name":"Content-Disposition", "value":"attachment"}],
             "body":{"attachmentId":"arquivo-1", "size":321}}
          ]}
        }
        """.utf8)
        let message = try GmailMessageParser.parse(raw)
        #expect(message.attachments.count == 1)
        #expect(message.attachments.first?.attachmentID == "arquivo-1")
        #expect(message.attachments.first?.filename == "proposta.pdf")
        #expect(message.attachments.first?.mimeType == "application/pdf")
        #expect(message.attachments.first?.byteCount == 321)
        #expect(message.attachments.first?.inlineData == nil)
    }

    @Test("invite.ics no anexo vira calendarICS mesmo sem parte text/calendar")
    func icsAnexadoViraConvite() {
        let ics = "BEGIN:VCALENDAR\nMETHOD:CANCEL\nEND:VCALENDAR"
        let mensagem = GmailMessage(
            id: "x", threadID: "t", labelIDs: [], internalDate: .now,
            from: Contact(name: "A", address: "a@x.com"), to: [], cc: [],
            subject: "Cancelado", snippet: "", body: [], html: nil, calendarICS: nil,
            rfcMessageID: nil, references: [],
            attachments: [
                .init(
                    attachmentID: "att", filename: "invite.ics",
                    mimeType: "application/octet-stream", byteCount: ics.utf8.count,
                    inlineData: Data(ics.utf8)
                )
            ]
        )
        #expect(GmailCalendar.ics(in: mensagem)?.contains("METHOD:CANCEL") == true)
    }

    /// **A prova do defeito, do lado de cá.** Sem ninguém buscar o anexo, o
    /// lugar da foto fica marcado como *por buscar* — e não como o vazio comum
    /// de "não coube". É essa marca que faz o leitor pedir o corpo outra vez.
    @Test("Sem buscar, a foto vira o vazio MARCADO como por buscar")
    func semBuscarFicaMarcada() throws {
        let mensagem = try GmailMessageParser.parse(Self.mensagemJSON(tamanho: 40_000))
        let html = try #require(mensagem.html)
        #expect(html.contains(MimeSanitize.placeholderPendente))
        #expect(InlineImagePlaceholder.temPendente(html))
    }

    // MARK: A busca

    @Test("Com a busca, a foto vira data: de verdade e a marca some")
    func buscaEEmbute() async throws {
        let sessao = Self.sessao(tamanho: Self.png.count)
        let mensagem = try await GmailInlineAttachments.message(
            Self.cliente(sessao), id: "m-sheglam"
        )
        let html = try #require(mensagem.html)

        #expect(html.contains("data:image/png;base64,\(Self.png.base64EncodedString())"))
        // A marca tem de sumir: se ela ficasse, o leitor rebuscaria esta
        // mensagem em toda abertura, para sempre.
        #expect(!InlineImagePlaceholder.temPendente(html))
        #expect(!html.contains("cid:"))

        // Duas viagens e não mais: a mensagem e o anexo. O JSON da mensagem é
        // lido duas vezes (uma para saber o que falta, outra para montar), e é
        // de propósito que ele não é pedido duas vezes ao servidor.
        let pedidos = StubURLProtocol.requests(for: sessao).map(\.path)
        #expect(pedidos == [
            "/gmail/v1/users/me/messages/m-sheglam",
            "/gmail/v1/users/me/messages/m-sheglam/attachments/ANGjdJ-foto",
        ])
    }

    /// O teto da M3-8 vale aqui, e vale **antes** da viagem: uma foto que o
    /// servidor já declarou como grande demais não é baixada para ser jogada
    /// fora ao chegar.
    @Test("A foto acima do teto não é buscada, e não fica marcada como pendente")
    func acimaDoTetoNaoViaja() async throws {
        let sessao = Self.sessao(
            tamanho: MimeSanitize.tetoPorImagem + 1, comAnexo: false
        )
        let mensagem = try await GmailInlineAttachments.message(
            Self.cliente(sessao), id: "m-sheglam"
        )
        let html = try #require(mensagem.html)

        #expect(html.contains(MimeSanitize.placeholder))
        // Sem marca: esta imagem não tem conserto, e rebuscá-la seria uma
        // viagem por abertura da mensagem, para sempre.
        #expect(!InlineImagePlaceholder.temPendente(html))
        #expect(StubURLProtocol.requests(for: sessao).count == 1)
    }

    /// A mensagem sem imagem pendente nenhuma custa **exatamente** o que
    /// custava antes: uma viagem.
    @Test("Sem imagem pendente, nenhuma chamada extra sai")
    func semPendenteNenhumaViagem() async throws {
        let simples = Data("""
            {"id":"m2","threadId":"t","labelIds":[],"snippet":"oi",
             "internalDate":"1800000000000",
             "payload":{"mimeType":"text/plain",
               "headers":[{"name":"From","value":"a@b.com"}],
               "body":{"data":"Qm9tIGRpYQ"}}}
            """.utf8)
        let sessao = StubURLProtocol.session(routes: [
            "/gmail/v1/users/me/messages/m2": [.init(body: simples)],
        ])
        let mensagem = try await GmailInlineAttachments.message(
            Self.cliente(sessao), id: "m2"
        )
        #expect(mensagem.body == ["Bom dia"])
        #expect(StubURLProtocol.requests(for: sessao).count == 1)
    }

    /// Um logotipo que falhou não pode custar a mensagem inteira: o corpo chega
    /// com um buraco, e não com "não foi possível baixar o corpo".
    @Test("O anexo que falha deixa um buraco, não derruba a mensagem")
    func anexoQueFalhaNaoDerruba() async throws {
        let sessao = StubURLProtocol.session(routes: [
            "/gmail/v1/users/me/messages/m-sheglam": [
                .init(body: Self.mensagemJSON(tamanho: Self.png.count)),
            ],
            "/gmail/v1/users/me/messages/m-sheglam/attachments/ANGjdJ-foto": [
                .init(status: 500, body: Data("{}".utf8)),
            ],
        ])
        let mensagem = try await GmailInlineAttachments.message(
            Self.cliente(sessao), id: "m-sheglam"
        )
        let html = try #require(mensagem.html)
        #expect(html.contains("Ol"))
        // E continua **marcada**: um dia ruim de rede não é uma decisão sobre a
        // imagem, e a próxima abertura tenta de novo.
        #expect(InlineImagePlaceholder.temPendente(html))
    }
}
