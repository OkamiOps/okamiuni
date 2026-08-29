import Foundation
import Testing
import UNICore
@testable import UNIShell

/// **"Encaminhar convite" encaminha.** Ele escrevia `"Encaminharia o convite
/// para […]"` no `stderr` e acendia a confirmação verde — a janela dizia
/// "Convite encaminhado para 2 pessoas" e ninguém recebia nada.
///
/// Sem protocolo novo: o convite vai como email de texto, pela conta do
/// compromisso, com o mesmo corpo de "Copiar convite". Anexar o `.ics` original
/// fica para quando o app tiver anexos — dívida registrada no relatório.
@Suite("Janela 04 — encaminhar o convite")
@MainActor
struct EventForwardInviteTests {

    private final class PortaFalsa: MailSendPort, @unchecked Sendable {
        private let lock = NSLock()
        private var _enviadas: [OutgoingMessage] = []
        let erro: (any Error)?
        init(erro: (any Error)? = nil) { self.erro = erro }
        var enviadas: [OutgoingMessage] {
            lock.lock()
            defer { lock.unlock() }
            return _enviadas
        }
        func send(_ message: OutgoingMessage) throws {
            if let erro { throw erro }
            lock.lock()
            _enviadas.append(message)
            lock.unlock()
        }
    }

    private struct ErroDeTeste: Error {}

    private func loaded(_ porta: MailSendPort? = nil) async -> MailStore {
        let store = MailStore(source: InMemoryMailSource.fixtures, sendPort: porta)
        await store.load()
        return store
    }

    private let convidado = Contact(name: "Sócio", address: "socio@meusite.com")

    /// O compromisso das fixtures que tem link, participantes e conta: o
    /// "1:1 Marina Duarte", na conta `zoho`.
    private func encontro(_ store: MailStore) throws -> (AgendaItem, EventDetail) {
        let item = try #require(store.agenda.first { $0.id == "e2" })
        return (item, Fixtures.eventDetail(for: item.title))
    }

    // MARK: O que o botão pode fazer

    /// Controle mudo é defeito. Sem conta o convite não tem de quem sair, e o
    /// botão apaga **com o motivo** em vez de aceitar o clique e não mandar.
    @Test("sem conta, ou sem destinatário, o Encaminhar do painel fica apagado")
    func botaoApagado() {
        #expect(EventWindow.canForward(recipients: 2, hasAccount: true))
        #expect(!EventWindow.canForward(recipients: 2, hasAccount: false))
        #expect(!EventWindow.canForward(recipients: 0, hasAccount: true))

        let semConta = EventWindow.forwardHelp(recipients: 2, account: nil, canSend: true)
        #expect(semConta.contains("indisponível"))
        #expect(semConta.contains("conta"))
        let semGente = EventWindow.forwardHelp(recipients: 0, account: "zoho", canSend: true)
        #expect(semGente.contains("indisponível"))
        #expect(EventWindow.forwardHelp(recipients: 1, account: "zoho", canSend: true)
            .contains("fila de saída"))
    }

    // MARK: O assunto e o corpo

    @Test("o assunto é 'Enc: ', o mesmo prefixo do encaminhar do email")
    func assunto() {
        #expect(EventWindow.forwardSubject("1:1 Marina Duarte") == "Enc: 1:1 Marina Duarte")
        // Título vazio não vira "Enc: " pendurado.
        #expect(EventWindow.forwardSubject("") == "Enc: convite")
    }

    @Test("o corpo leva título, horário, local, link e participantes")
    func corpo() async throws {
        let store = await loaded()
        let (item, detail) = try encontro(store)

        let corpo = EventWindow.inviteBody(item, detail: detail, date: Fixtures.today, note: "")

        #expect(corpo.contains("1:1 Marina Duarte"))
        #expect(corpo.contains(item.rangeLabel))
        #expect(corpo.contains("Zoom · sala pessoal"))
        #expect(corpo.contains("https://zoom.us/j/9182736450?pwd=okamiuni"))
        #expect(corpo.contains("marina@clientepremium.com"))
    }

    @Test("o recado do painel vai por cima do convite, e só de espaços não vai")
    func recado() async throws {
        let store = await loaded()
        let (item, detail) = try encontro(store)

        let comRecado = EventWindow.inviteBody(
            item, detail: detail, date: Fixtures.today, note: "Entra no meu lugar?"
        )
        #expect(comRecado.hasPrefix("Entra no meu lugar?\n\n"))

        let soEspaco = EventWindow.inviteBody(
            item, detail: detail, date: Fixtures.today, note: "   "
        )
        #expect(soEspaco.hasPrefix("1:1 Marina Duarte"))
    }

    // MARK: A fila

    @Test("encaminhar o convite põe um email na fila, pela conta do compromisso")
    func enfileira() async throws {
        let porta = PortaFalsa()
        let store = await loaded(porta)
        let (item, detail) = try encontro(store)

        let fechou = EventWindow.forwardInvite(
            item, detail: detail, date: Fixtures.today,
            to: [convidado], note: "", in: store
        )

        #expect(fechou)
        let enviada = try #require(porta.enviadas.first)
        #expect(enviada.to.map(\.address) == ["socio@meusite.com"])
        #expect(enviada.accountID == item.accountID)
        #expect(enviada.from.address == store.account(item.accountID)?.address)
        #expect(enviada.subject == "Enc: 1:1 Marina Duarte")
        #expect(enviada.plainText.contains("https://zoom.us/j/9182736450?pwd=okamiuni"))
        // Encaminhar um convite não é responder a nada.
        #expect(enviada.inReplyTo == nil)
    }

    @Test("sem ninguém escolhido, nada é enfileirado")
    func semDestinatario() async throws {
        let porta = PortaFalsa()
        let store = await loaded(porta)
        let (item, detail) = try encontro(store)

        let fechou = EventWindow.forwardInvite(
            item, detail: detail, date: Fixtures.today, to: [], note: "", in: store
        )

        #expect(!fechou)
        #expect(porta.enviadas.isEmpty)
    }

    /// Compromisso sem conta casada não encaminha — e o painel não fecha
    /// fingindo que encaminhou.
    @Test("compromisso sem conta não encaminha nada")
    func semConta() async throws {
        let porta = PortaFalsa()
        let store = await loaded(porta)
        let (item, detail) = try encontro(store)
        let orfao = AgendaItem(
            id: item.id, title: item.title,
            startMinute: item.startMinute, endMinute: item.endMinute,
            accountID: "conta-que-nao-existe"
        )

        let fechou = EventWindow.forwardInvite(
            orfao, detail: detail, date: Fixtures.today,
            to: [convidado], note: "", in: store
        )

        #expect(!fechou)
        #expect(porta.enviadas.isEmpty)
    }

    /// Sem porta de envio — as fixtures, os ensaios — vale o Marco 1: a linha no
    /// console e a confirmação na janela. Nada aqui promete o que não existe.
    @Test("sem porta de envio, o comportamento do Marco 1 continua igual")
    func semPorta() async throws {
        let store = await loaded()
        let (item, detail) = try encontro(store)

        #expect(EventWindow.forwardInvite(
            item, detail: detail, date: Fixtures.today,
            to: [convidado], note: "", in: store
        ))
    }

    /// Fila que recusa não pode acender a confirmação verde: o painel fica
    /// aberto com quem já foi escolhido, e o erro aparece onde os outros
    /// aparecem.
    @Test("fila que recusa não fecha o painel")
    func filaRecusa() async throws {
        let store = await loaded(PortaFalsa(erro: ErroDeTeste()))
        let (item, detail) = try encontro(store)

        let fechou = EventWindow.forwardInvite(
            item, detail: detail, date: Fixtures.today,
            to: [convidado], note: "", in: store
        )

        #expect(!fechou)
        #expect(store.loadError != nil)
    }
}
