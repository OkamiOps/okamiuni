import Foundation
import Testing
import UNICore
@testable import UNISync

@Suite("Do servidor para a triagem")
struct TriageProjectionTests {
    @Test("Cada papel de pasta cai na caixa que o Marco 1 desenhou")
    func papelParaCaixa() {
        #expect(TriageProjection.bucket(role: .inbox) == .today)
        #expect(TriageProjection.bucket(role: .later) == .later)
        #expect(TriageProjection.bucket(role: .archive) == .archived)
        #expect(TriageProjection.bucket(role: .trash) == .trash)
        #expect(TriageProjection.bucket(role: .other) == .archived)
    }

    @Test("Enviadas ficam **fora** da triagem, e isso é `nil`, não uma caixa")
    func enviadasForaDaTriagem() {
        // O Marco 2 não mostra Enviadas: a caixa não existe no shell, e
        // enfiá-las em `archived` faria a caixa Arquivado encher do que a
        // pessoa escreveu. O Marco 3 as traz junto com o envio.
        #expect(TriageProjection.bucket(role: .sent) == nil)
    }

    @Test("Os rótulos do Gmail caem nas mesmas caixas, com a mesma precedência")
    func rotulosDoGmail() {
        #expect(TriageProjection.bucket(gmailLabelIDs: ["INBOX", "UNREAD"], laterLabelID: nil) == .today)
        #expect(TriageProjection.bucket(gmailLabelIDs: ["TRASH"], laterLabelID: nil) == .trash)
        #expect(TriageProjection.bucket(gmailLabelIDs: ["SENT"], laterLabelID: nil) == nil)
        // Sem INBOX e sem TRASH: é o "Todos os e-mails", que é o arquivo.
        #expect(TriageProjection.bucket(gmailLabelIDs: ["CATEGORY_PROMOTIONS"], laterLabelID: nil) == .archived)
        #expect(TriageProjection.bucket(gmailLabelIDs: [], laterLabelID: nil) == .archived)
    }

    @Test("A lixeira ganha da caixa de entrada, e `Depois` ganha das duas")
    func precedencia() {
        // Uma mensagem apagada continua carregando INBOX no Gmail por um
        // tempo. Se INBOX vencesse, a mensagem que a pessoa jogou fora voltaria
        // para Hoje — apagar tem de parecer apagar.
        #expect(TriageProjection.bucket(gmailLabelIDs: ["INBOX", "TRASH"], laterLabelID: nil) == .trash)
        // `Depois` é decisão explícita da pessoa, tomada nesta ferramenta.
        // Ela ganha de INBOX, que é só "ainda não triada".
        #expect(TriageProjection.bucket(gmailLabelIDs: ["INBOX", "Label_7"], laterLabelID: "Label_7") == .later)
        // Mas não ganha da lixeira: apagado é apagado.
        #expect(TriageProjection.bucket(gmailLabelIDs: ["Label_7", "TRASH"], laterLabelID: "Label_7") == .trash)
        // E SENT continua fora de tudo.
        #expect(TriageProjection.bucket(gmailLabelIDs: ["SENT", "INBOX"], laterLabelID: nil) == nil)
    }

    @Test("Sem `UNREAD` é lida — o Gmail não tem rótulo `READ`")
    func lidaEhAusenciaDeUnread() {
        // Invertida, a regra faria a caixa inteira abrir não lida e o contador
        // de Hoje mentir em cima do número que a pessoa vê no navegador.
        #expect(TriageProjection.isRead(gmailLabelIDs: ["INBOX"]))
        #expect(TriageProjection.isRead(gmailLabelIDs: []))
        #expect(!TriageProjection.isRead(gmailLabelIDs: ["INBOX", "UNREAD"]))
    }

    @Test("`STARRED` é a bandeira — sinalizar é estado da mensagem")
    func estrelaEhBandeira() {
        // Sem isto, a estrela que a pessoa pôs no navegador sumiria ao abrir o
        // app: perda silenciosa de uma decisão dela.
        #expect(TriageProjection.isFlagged(gmailLabelIDs: ["INBOX", "STARRED"]))
        #expect(!TriageProjection.isFlagged(gmailLabelIDs: ["INBOX"]))
        // As duas bandeiras são independentes: lida e sinalizada convivem.
        #expect(TriageProjection.isRead(gmailLabelIDs: ["STARRED"]))
        #expect(TriageProjection.isFlagged(gmailLabelIDs: ["UNREAD", "STARRED"]))
    }

    @Test("No IMAP a regra é a inversa — e é a mesma função que responde")
    func bandeirasDoImap() {
        // O IMAP diz o contrário do Gmail: `\Seen` marca lida, onde o Gmail
        // marca `UNREAD` para não lida. Escritas em arquivos diferentes, as
        // duas traduções acabariam invertidas uma em relação à outra sem
        // ninguém perceber.
        #expect(TriageProjection.isRead(imapFlags: ["\\Seen"]))
        #expect(!TriageProjection.isRead(imapFlags: []))
        #expect(!TriageProjection.isRead(imapFlags: ["\\Flagged"]))
        #expect(TriageProjection.isFlagged(imapFlags: ["\\Seen", "\\Flagged"]))
        #expect(!TriageProjection.isFlagged(imapFlags: ["\\Seen"]))
        // `\SEEN`, `\Seen` e `\seen` são a mesma flag no RFC 3501, e servidor
        // que manda em maiúsculas existe.
        #expect(TriageProjection.isRead(imapFlags: ["\\SEEN"]))
        #expect(TriageProjection.isFlagged(imapFlags: ["\\flagged"]))
    }

    @Test("O id do rótulo `Depois` sai da lista de rótulos, quando existir")
    func acharORotuloDepois() {
        let rotulos = [
            GmailLabel(id: "INBOX", name: "INBOX"),
            GmailLabel(id: "Label_7", name: "OkamiUNI/Depois"),
        ]
        #expect(TriageProjection.laterLabelID(in: rotulos) == "Label_7")
        // Instalação nova não tem o rótulo, e isso não é erro: aqui ele só é
        // **lido** se existir. Criá-lo é do Marco 3.
        #expect(TriageProjection.laterLabelID(in: [GmailLabel(id: "INBOX", name: "INBOX")]) == nil)
    }

    @Test("O id de uma mensagem é estável entre execuções")
    func idEstavel() {
        // Determinístico, e não UUID: reabrir o app e recarregar a mesma
        // mensagem tem de encontrar a linha que já existe. Com UUID, cada
        // carga duplicaria a caixa inteira.
        #expect(MessageIdentity.gmail(accountID: "conta-g", serverID: "18f0a1b2c3")
            == MessageIdentity.gmail(accountID: "conta-g", serverID: "18f0a1b2c3"))
        #expect(MessageIdentity.gmail(accountID: "conta-g", serverID: "18f0a1b2c3")
            == "conta-g:g:18f0a1b2c3")
    }

    @Test("Contas diferentes com o mesmo id de servidor não colidem")
    func semColisaoEntreContas() {
        #expect(MessageIdentity.gmail(accountID: "a", serverID: "1")
            != MessageIdentity.gmail(accountID: "b", serverID: "1"))
    }

    @Test("O id do IMAP carrega a pasta e o UIDVALIDITY")
    func idDoImap() {
        #expect(MessageIdentity.imap(accountID: "conta-i", folderID: "conta-i/INBOX", uidValidity: 42, uid: 9_001)
            == "conta-i:i:conta-i/INBOX:42:9001")
        // UIDVALIDITY novo é caixa nova: os UIDs foram reciclados, e casar o
        // UID 1 antigo com o UID 1 novo mostraria a mensagem errada.
        #expect(MessageIdentity.imap(accountID: "c", folderID: "f", uidValidity: 42, uid: 1)
            != MessageIdentity.imap(accountID: "c", folderID: "f", uidValidity: 43, uid: 1))
        // E a mesma mensagem em duas pastas são duas linhas — que é o que o
        // IMAP de fato tem.
        #expect(MessageIdentity.imap(accountID: "c", folderID: "f1", uidValidity: 42, uid: 1)
            != MessageIdentity.imap(accountID: "c", folderID: "f2", uidValidity: 42, uid: 1))
    }
}
