import Foundation
import Testing
import UNICore
import UNISync
@testable import UNIShell

@Suite("O ensaio de contas")
struct AccountsRehearsalTests {
    @Test("Só liga com a bandeira")
    func bandeira() {
        #expect(AccountsRehearsal.parse(["--ensaiar-contas"]) != nil)
        #expect(AccountsRehearsal.parse([]) == nil)
        #expect(AccountsRehearsal.parse(["--ensaiar-arraste"]) == nil)
        // A bandeira não pode ser prefixo de outra: `--ensaiar-contas-nao`
        // não liga isto.
        #expect(AccountsRehearsal.parse(["--ensaiar-contas-nao"]) == nil)
    }

    @Test("O servidor IMAP do ensaio sobe em loopback, numa porta que o sistema escolhe")
    func servidorLocal() throws {
        // Nenhum ensaio toca rede externa: a porta é 0 (o sistema escolhe) e o
        // host é 127.0.0.1. É isto que faz `--ensaiar-contas` rodar num
        // notebook desligado da internet.
        let servidor = RehearsalImapServer()
        let porta = try servidor.start()
        defer { servidor.stop() }
        #expect(porta > 0)
    }

    @Test("A varredura leva os bancos do ensaio e não toca no resto")
    func varreduraDosBancos() throws {
        // O `deinit` que apagaria o banco descartável nunca roda: quem encerra
        // o ensaio é `NSApp.terminate`, que derruba o processo sem desmontar
        // nada. Eram vinte diretórios acumulados no contêiner quando isto foi
        // notado — instrumento que suja a máquina de quem o roda tem um defeito,
        // mesmo medindo certo.
        //
        // A varredura recebe o diretório em vez de assumir o `tmp` do processo:
        // varrer o `tmp` de dentro de um teste apagaria os bancos temporários de
        // qualquer suíte rodando ao lado.
        let raiz = FileManager.default.temporaryDirectory
            .appendingPathComponent("varredura-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: raiz, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: raiz) }

        let doEnsaio = raiz.appendingPathComponent("okamiuni-\(UUID().uuidString)", isDirectory: true)
        let alheio = raiz.appendingPathComponent("nao-e-nosso", isDirectory: true)
        try FileManager.default.createDirectory(at: doEnsaio, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: alheio, withIntermediateDirectories: true)

        #expect(AccountsRehearsal.limpaBancosDoEnsaio(em: raiz) == 1)
        #expect(!FileManager.default.fileExists(atPath: doEnsaio.path))
        #expect(FileManager.default.fileExists(atPath: alheio.path))
    }

    @Test("Os quadros do ensaio vão para o contêiner, e não para o disco do usuário")
    func caminhoDosQuadros() {
        let caminho = RehearsalStage.framePath("contas-01-vazio")
        #expect(caminho.hasSuffix("ensaio-contas-01-vazio.png"))
        #expect(caminho.hasPrefix(NSTemporaryDirectory()))
    }

    @Test("O servidor do ensaio responde o roteiro fixo — e só ele")
    func roteiroFixo() throws {
        // A prova de que o roteiro existe e é o mesmo em qualquer máquina, sem
        // subir socket nenhum. O que sai daqui é o que o `ImapSession` lê.
        let respostas = RehearsalImapServer.respostas(para: "a1 LOGIN \"x\" \"y\"")
        #expect(respostas == ["a1 OK LOGIN completed"])

        // Verbo de duas palavras: `UID SEARCH` não pode cair no balde do
        // `UID FETCH` — foi o que a Task 10 aprendeu no servidor dos testes.
        #expect(RehearsalImapServer.respostas(para: "a2 UID SEARCH SINCE 1-Jan-2026")
            == ["* SEARCH 9001 9002", "a2 OK UID SEARCH completed"])

        // Fora do roteiro é `BAD`, e não silêncio: um comando que o ensaio não
        // previu tem de aparecer como erro, não como conexão pendurada.
        #expect(RehearsalImapServer.respostas(para: "a3 APPEND INBOX {3}")
            == ["a3 BAD comando fora do roteiro do ensaio"])
    }

    @Test("A porta insegura do IMAP é só para o loopback")
    func portaInsegura() {
        // O ensaio fala em claro contra 127.0.0.1 porque o servidor falso não
        // tem certificado. A porta que permite isso recusa qualquer outro host
        // — a promessa "credencial nunca sai em claro desta máquina" continua
        // de pé, agora por guarda explícita em vez de por `internal`.
        #expect(ImapEndpoint.ehLoopback("127.0.0.1"))
        #expect(ImapEndpoint.ehLoopback("::1"))
        #expect(ImapEndpoint.ehLoopback("localhost"))
        #expect(!ImapEndpoint.ehLoopback("imap.gmail.com"))
        // Nem por sufixo: `evil-localhost.com` não é a máquina de ninguém.
        #expect(!ImapEndpoint.ehLoopback("evil-localhost.com"))
        #expect(!ImapEndpoint.ehLoopback("127.0.0.1.evil.com"))
    }
}
