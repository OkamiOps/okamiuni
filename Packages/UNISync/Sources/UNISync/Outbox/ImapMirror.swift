import Foundation
import UNICore
import os

/// O espelho da triagem no IMAP — a coluna "IMAP" da tabela da spec.
///
/// | Caixa | O que vai para o servidor |
/// |---|---|
/// | Hoje | move para a INBOX |
/// | Depois | move para a pasta `OkamiUNI/Depois` (criada no primeiro uso) |
/// | Arquivado | move para a pasta de papel `archive` |
/// | Lixeira | move para a pasta de papel `trash` |
/// | Sinalizada | `\Flagged` |
/// | Lida | `\Seen` |
///
/// Ator pelas mesmas duas razões do `GmailMirror`: as pastas do servidor são
/// lidas **uma vez** por sessão (um `LIST` por operação seria uma ida e volta
/// jogada fora a cada mensagem lida), e a criação de `OkamiUNI/Depois` acontece
/// uma vez só.
public actor ImapMirror: MailMirror {
    /// Como conseguir uma sessão autenticada. Closure, e não uma sessão
    /// pronta, porque a fila vive muito mais que uma conexão: o app fica aberto
    /// o dia todo, a rede cai, o servidor derruba conexões ociosas. Guardar uma
    /// sessão fixa faria a primeira queda parar a fila da conta para sempre.
    private let conectar: @Sendable () async throws -> ImapSession
    /// Como conseguir uma sessão SMTP autenticada, quando a conta tem por onde
    /// enviar. Closure pela mesma razão da de leitura — e **opcional** porque
    /// uma conta sem servidor de envio derivável existe, e o resto do espelho
    /// (a triagem inteira) continua funcionando nela.
    private let conectarSmtp: (@Sendable () async throws -> SmtpSession)?
    private let now: @Sendable () -> Date
    private var sessao: ImapSession?
    private var pastas: [ImapFolder]?
    /// As pastas que **esta sessão** já mandou criar.
    ///
    /// Era um `Bool` para a `OkamiUNI/Depois` e virou conjunto quando o arquivo
    /// e a lixeira ganharam o mesmo tratamento: sem ele, arquivar cinquenta
    /// mensagens numa conta sem pasta de arquivo mandaria cinquenta `CREATE`
    /// para o servidor — todos menos o primeiro respondidos com
    /// `NO [ALREADYEXISTS]`, que o `create` engole em silêncio. Uma ida e volta
    /// por mensagem para não fazer nada.
    private var criadas: Set<String> = []
    private let log = Logger(subsystem: "com.okamiops.okamiuni", category: "ImapMirror")

    public init(
        connect: @Sendable @escaping () async throws -> ImapSession,
        smtp: (@Sendable () async throws -> SmtpSession)? = nil,
        now: @Sendable @escaping () -> Date = Date.init
    ) {
        conectar = connect
        conectarSmtp = smtp
        self.now = now
    }

    /// A conveniência de quem já tem uma sessão viva — os testes, e quem
    /// espelha dentro de uma sincronização em curso.
    public init(
        session: ImapSession,
        smtp: (@Sendable () async throws -> SmtpSession)? = nil,
        now: @Sendable @escaping () -> Date = Date.init
    ) {
        conectar = { session }
        conectarSmtp = smtp
        self.now = now
        sessao = session
    }

    /// A sessão de agora, conectando na primeira vez.
    private func sessaoAtiva() async throws -> ImapSession {
        if let sessao { return sessao }
        let nova = try await conectar()
        sessao = nova
        // Pastas são da conexão: uma sessão nova relê a lista, e é assim que
        // uma pasta criada noutro cliente aparece sem reiniciar o app.
        pastas = nil
        return nova
    }

    /// Descarta a conexão morta para a próxima tentativa reconectar. O executor
    /// já agenda o recuo; o que ele não pode fazer é adivinhar que a sessão
    /// guardada aqui virou entulho.
    private func derruba() {
        sessao = nil
        pastas = nil
        // A memória do que já foi criado é **da conexão**: a sessão nova relê a
        // lista, e uma pasta que só existia na cabeça deste ator (criada por um
        // `CREATE` que talvez nem tenha chegado, já que a conexão caiu) não pode
        // impedir a tentativa seguinte de a criar de novo.
        criadas = []
    }

    @discardableResult
    public func apply(
        _ operation: MailOperation, targets: [MessageCoordinate]
    ) async throws -> MessageCoordinate? {
        do {
            return try await aplica(operation, targets: targets)
        } catch let erro as SyncError {
            if case .rede = erro { derruba() }
            if case .tls = erro { derruba() }
            throw erro
        }
    }

    private func aplica(
        _ operation: MailOperation, targets: [MessageCoordinate]
    ) async throws -> MessageCoordinate? {
        let session = try await sessaoAtiva()
        switch operation {
        case .setRead(let isRead, _):
            try await bandeira("\\Seen", ligada: isRead, targets: targets)

        case .setFlagged(let isFlagged, _):
            try await bandeira("\\Flagged", ligada: isFlagged, targets: targets)

        case .move(let bruto, _):
            guard let bucket = TriageBucket(rawValue: bruto) else {
                throw SyncError.resposta("Caixa de triagem desconhecida na fila: \(bruto).")
            }
            try await mover(targets, para: try await destino(de: bucket))

        case .placeInFolder(_, let serverName, let bruto, _):
            guard bruto == FolderPlacement.move.rawValue else {
                throw SyncError.resposta("O IMAP move mensagens entre pastas; esta operação pediu um marcador.")
            }
            try await mover(targets, para: serverName)

        case .moveGmailLabel:
            throw SyncError.resposta("Uma operação de marcador Gmail chegou a uma conta IMAP.")

        case .delete:
            try await mover(targets, para: try await destino(de: .trash))

        case .deletePermanently:
            for (pasta, uids) in agrupa(targets) {
                _ = try await session.select(ImapFolder(name: pasta, specialUse: nil))
                try await session.store(uids: uids, flags: ["\\Deleted"], add: true)
                try await session.expunge()
            }

        case .emptyTrash:
            let lixeira = try await destino(de: .trash)
            _ = try await session.select(ImapFolder(name: lixeira, specialUse: nil))
            try await session.markAllDeleted()
            try await session.expunge()

        case .send(let mensagem):
            return try await envia(mensagem)
        }
        // Só o envio grava mensagem nova; o resto mexe em pasta e bandeira do
        // que já estava lá.
        return nil
    }

    // MARK: O envio

    /// SMTP para entregar, IMAP para guardar a cópia.
    ///
    /// A ordem das três coisas é o que faz a operação ser repetível:
    ///
    /// 1. **Pergunta antes.** Se o `Message-ID` já está em Enviadas, a
    ///    tentativa anterior chegou até o fim — não manda de novo. É a mesma
    ///    pergunta que torna o `mover` idempotente, feita pela mesma razão: um
    ///    tempo esgotado ambíguo não sabe se passou, e reenviar entrega a
    ///    mesma mensagem duas vezes na caixa de quem recebe.
    /// 2. **Entrega.** Uma sessão SMTP por envio, e ela morre no fim: o
    ///    servidor de submissão derruba conexão ociosa, e guardar uma faria a
    ///    primeira queda parar o envio da conta.
    /// 3. **Guarda a cópia**, e falhar aqui **não** desfaz o envio — a
    ///    mensagem já saiu, e dizer que o envio falhou faria a pessoa mandá-la
    ///    de novo. A falha vai para o log; a cópia aparece no próximo ciclo se
    ///    o servidor a tiver por conta própria (vários põem), ou não aparece.
    private func envia(_ mensagem: OutgoingMessage) async throws -> MessageCoordinate? {
        guard let conectarSmtp else {
            throw SyncError.resposta(
                "A conta não tem servidor de envio, e enviar precisa de um."
            )
        }
        // A pasta é lida **antes** de qualquer coisa sair, e uma falha aqui
        // aborta o envio de propósito: sem conseguir olhar Enviadas não há como
        // saber se a tentativa anterior passou, e mandar às cegas é escolher a
        // duplicata. A fila tenta de novo com o recuo dela.
        let enviadas = try await nome(de: .sent, em: lista())
        if let enviadas, try await jaEstaEnviada(mensagem.messageID, em: enviadas) { return nil }

        // `includeBcc: false`: no SMTP a cópia oculta viaja no `RCPT TO`, e um
        // cabeçalho `Bcc` no texto a mostraria para todo mundo que recebeu.
        let raw = OutgoingMime.compose(mensagem, date: now(), includeBcc: false)
        let smtp = try await conectarSmtp()
        do {
            try await smtp.send(
                from: mensagem.from.address, recipients: mensagem.recipients, raw: raw
            )
        } catch {
            await smtp.quit()
            throw error
        }
        await smtp.quit()

        guard let enviadas else {
            log.notice("A conta não tem pasta de Enviadas: a cópia da mensagem não foi guardada.")
            return nil
        }
        do {
            let session = try await sessaoAtiva()
            guard try await session.capabilities().contains("LITERAL+") else {
                log.notice("O servidor não anuncia LITERAL+: a cópia em Enviadas não foi gravada.")
                return nil
            }
            // O `APPENDUID` é onde a cópia ficou — e é ele que faz a linha
            // gravada aqui ter o mesmo id que a próxima leitura da pasta daria
            // à mesma mensagem. Servidor sem `UIDPLUS` não o manda, e aí não há
            // coordenada honesta a devolver: a cópia aparece no ciclo seguinte,
            // pela leitura normal da pasta.
            guard let carimbo = try await session.append(mailbox: enviadas, raw: raw) else {
                log.notice("O servidor não devolveu APPENDUID: a cópia em Enviadas aparece no próximo ciclo.")
                return nil
            }
            return .imap(
                folderName: enviadas, uidValidity: carimbo.uidValidity, uid: carimbo.uid
            )
        } catch {
            // Registrado e seguido: a mensagem **já saiu**, e transformar isto
            // em falha faria a fila tentar de novo um envio que já aconteceu.
            log.error("A cópia em Enviadas não foi gravada: \(error)")
            return nil
        }
    }

    /// O `Message-ID` já está na pasta de Enviadas?
    private func jaEstaEnviada(_ messageID: String, em pasta: String) async throws -> Bool {
        let session = try await sessaoAtiva()
        _ = try await session.select(ImapFolder(name: pasta, specialUse: nil))
        return try await !session.uids(messageID: "<\(messageID)>").isEmpty
    }

    // MARK: As bandeiras

    /// `UID STORE` por pasta. Os alvos de uma operação podem estar espalhados
    /// (marcar como lida uma seleção que atravessa caixas é o caso normal), e o
    /// IMAP só opera na pasta selecionada — daí o agrupamento, que também é o
    /// que faz N mensagens virarem **um** `STORE` por pasta em vez de N.
    private func bandeira(_ flag: String, ligada: Bool, targets: [MessageCoordinate]) async throws {
        let session = try await sessaoAtiva()
        for (pasta, uids) in agrupa(targets) {
            _ = try await session.select(ImapFolder(name: pasta, specialUse: nil))
            try await session.store(uids: uids, flags: [flag], add: ligada)
        }
    }

    // MARK: O mover, e a idempotência dele

    /// Mover no IMAP é `COPY` + `STORE \Deleted` + `EXPUNGE` — três comandos, e
    /// portanto três lugares onde a conexão pode cair no meio.
    ///
    /// **`COPY` é a única operação deste espelho que não é idempotente sozinha:**
    /// copiar duas vezes deixa duas cópias no destino. Um retry depois de um
    /// timeout ambíguo não sabe se a primeira cópia passou — então ele
    /// **pergunta**, e o que ele pergunta cobre os três pontos de queda:
    ///
    /// 1. O UID ainda está na origem? Se não está, `COPY`, `STORE` e `EXPUNGE`
    ///    já aconteceram: a operação está feita, e não há nada a fazer.
    /// 2. Está na origem: pega o `Message-ID` dela — a identidade que
    ///    atravessa a cópia — e pergunta ao **destino** se ele já a tem. Se
    ///    tem, a cópia passou e o que caiu foi o `STORE`/`EXPUNGE`: pula o
    ///    `COPY` e termina a limpeza.
    /// 3. Não tem: copia, marca e expurga, na ordem.
    ///
    /// Sem o passo 2 — e é exatamente esta a mutação que o teste do invariante
    /// mata — o retry copia de novo e a pessoa vê a mesma mensagem duas vezes
    /// na pasta de destino, no webmail dela, sem nada no app que explique por
    /// quê.
    private func mover(_ targets: [MessageCoordinate], para destino: String) async throws {
        for (pasta, uids) in agrupa(targets) {
            // Mover para onde a mensagem já está é trabalho nenhum — e é o que
            // acontece quando o servidor já foi atualizado por outro cliente.
            guard pasta != destino else { continue }
            for uid in uids {
                try await moveUm(uid: uid, de: pasta, para: destino)
            }
        }
    }

    /// O mover de uma mensagem, com o `[TRYCREATE]` do RFC 2180 pago.
    ///
    /// **A caixa de destino pode não existir no meio da operação**, e o
    /// protocolo tem uma resposta própria para isso: o `NO [TRYCREATE]` de um
    /// `COPY` (ou o `NO [NONEXISTENT]` de um `SELECT`) quer dizer "crie a caixa
    /// e tente de novo" — literalmente. Antes disto o `NO` virava
    /// `SyncError.servidor`, o executor o classificava como falha e a operação
    /// parava a fila da conta por causa de uma pasta ausente.
    ///
    /// A retentativa refaz o mover **do começo**, e não do ponto em que parou:
    /// ela reseleciona a origem, reconfere que o UID ainda está lá e repergunta
    /// ao destino. É de graça — a pasta recém-criada está vazia, então a
    /// pergunta responde "copie" na hora — e é o que mantém a idempotência
    /// documentada em `mover(_:para:)` valendo também por este caminho.
    ///
    /// **Uma vez, e não em laço.** Se o `CREATE` passou e o `COPY` seguinte
    /// ainda diz que a caixa não existe, o problema não é a caixa faltando: é o
    /// servidor, e insistir seria girar contra ele.
    private func moveUm(uid: Int64, de origem: String, para destino: String) async throws {
        do {
            try await tentaMover(uid: uid, de: origem, para: destino)
        } catch SyncError.servidor(_, let mensagem)
        where ImapWire.pedeCriacaoDaCaixa(mensagem) {
            log.notice("A caixa de destino não existe; criando e tentando o move de novo.")
            try await cria(destino)
            try await tentaMover(uid: uid, de: origem, para: destino)
        }
    }

    /// Cria a pasta uma vez por sessão e reabre a lista para as próximas
    /// operações a acharem pelo caminho normal.
    private func cria(_ mailbox: String) async throws {
        guard !criadas.contains(mailbox) else { return }
        try await sessaoAtiva().create(mailbox: mailbox)
        criadas.insert(mailbox)
        pastas = nil
    }

    private func tentaMover(uid: Int64, de origem: String, para destino: String) async throws {
        let session = try await sessaoAtiva()
        _ = try await session.select(ImapFolder(name: origem, specialUse: nil))
        guard try await !session.existingUIDs([uid]).isEmpty else { return }

        var precisaCopiar = true
        if let messageID = try await session.messageID(uid: uid) {
            _ = try await session.select(ImapFolder(name: destino, specialUse: nil))
            precisaCopiar = try await session.uids(messageID: messageID).isEmpty
            _ = try await session.select(ImapFolder(name: origem, specialUse: nil))
        }
        if precisaCopiar {
            try await session.copy(uids: [uid], to: destino)
        }
        try await session.store(uids: [uid], flags: ["\\Deleted"], add: true)
        try await session.expunge()
    }

    // MARK: As pastas

    /// Alvos agrupados por pasta, com os UIDs de cada uma. Os alvos que não são
    /// IMAP (não existem numa conta IMAP, mas o tipo permite) simplesmente não
    /// entram.
    private func agrupa(_ targets: [MessageCoordinate]) -> [(String, [Int64])] {
        var mapa: [String: [Int64]] = [:]
        var ordem: [String] = []
        for alvo in targets {
            guard case .imap(let pasta, _, let uid) = alvo else { continue }
            if mapa[pasta] == nil { ordem.append(pasta) }
            mapa[pasta, default: []].append(uid)
        }
        return ordem.map { ($0, mapa[$0] ?? []) }
    }

    /// A pasta que corresponde a uma caixa da triagem.
    ///
    /// A tradução é a **inversa** da `TriageProjection.bucket(role:)`, e é por
    /// isso que ela é escrita em termos de `FolderRole` e não de nomes: quem
    /// decide que "Alle Nachrichten" é o arquivo é `FolderRoles`, num lugar só.
    /// - Note: **Nenhuma caixa de triagem falha mais por pasta ausente.** As
    ///   três que precisam de uma pasta de verdade (Depois, Arquivado, Lixeira)
    ///   criam a que falta, pela mesma regra e com o mesmo cuidado: o nome
    ///   criado é um que `FolderRoles` reconhece de volta, para a pasta feita
    ///   por nós ser achada pelo `LIST` da próxima vez em vez de uma segunda
    ///   ser criada ao lado. Era este o defeito da conta do dono — cinco
    ///   operações paradas atrás de "a conta não tem pasta de arquivo".
    private func destino(de bucket: TriageBucket) async throws -> String {
        let disponiveis = try await lista()
        switch bucket {
        case .today:
            return nome(de: .inbox, em: disponiveis) ?? "INBOX"
        case .later:
            if let existente = nome(de: .later, em: disponiveis) { return existente }
            try await cria(MirrorNames.later)
            return MirrorNames.later
        case .archived:
            if let pasta = nome(de: .archive, em: disponiveis) { return pasta }
            try await cria(MirrorNames.archive)
            return MirrorNames.archive
        case .trash:
            if let pasta = nome(de: .trash, em: disponiveis) { return pasta }
            try await cria(MirrorNames.trash)
            return MirrorNames.trash
        case .all:
            throw SyncError.resposta("\"Tudo\" é uma visão, não uma pasta — não há para onde mover.")
        case .sent:
            // Enviadas é pasta de verdade no servidor, e mesmo assim não é
            // destino: o que põe uma mensagem lá é enviá-la. Ver a mesma
            // recusa no `GmailMirror`.
            throw SyncError.resposta("Enviadas guarda o que saiu — não há como mover uma mensagem para lá.")
        }
    }

    private func nome(de papel: FolderRole, em pastas: [ImapFolder]) -> String? {
        pastas.first { $0.role == papel }?.name
    }

    private func lista() async throws -> [ImapFolder] {
        if let pastas { return pastas }
        let novas = try await sessaoAtiva().folders()
        pastas = novas
        return novas
    }
}
