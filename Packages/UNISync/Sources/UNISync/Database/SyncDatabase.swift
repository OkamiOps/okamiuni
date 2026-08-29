import Foundation
import GRDB

/// O banco local. **A fonte da verdade da UI.**
///
/// Ele é a razão de o app abrir offline mostrando os últimos 90 dias: a tela
/// nunca espera rede, ela espera o banco — e o banco já está no disco quando o
/// processo sobe. Rede escreve aqui; a UI lê daqui; as duas coisas não se
/// encontram.
public struct SyncDatabase: Sendable {
    public let pool: DatabasePool

    /// Segura o diretório descartável de `temporary()` vivo enquanto este
    /// `SyncDatabase` existir, e o apaga quando a última cópia sai de cena.
    /// `nil` para um banco de verdade — `defaultPath()` não é apagado por
    /// ninguém.
    private let temporaryDirectory: TemporaryDatabaseDirectory?

    /// Abre (criando se preciso) e migra.
    ///
    /// Migrar na abertura, e não sob demanda, é o que garante que nenhum
    /// caminho do app veja o esquema pela metade.
    public init(path: String) throws {
        var config = Configuration()
        // Chaves estrangeiras ligadas: é o que faz remover uma conta levar
        // junto pastas, mensagens, corpos, agenda e estado de sync, em vez de
        // deixar órfãos que a lista mostraria sem dono.
        config.foreignKeysEnabled = true
        temporaryDirectory = nil
        do {
            let opened = try DatabasePool(path: path, configuration: config)
            try Self.migrator.migrate(opened)
            pool = opened
        } catch {
            // Nem "abrir" nem "migrar" são erro de servidor — `.resposta` é
            // para respostas que não fazem sentido vindas de rede; isto aqui
            // nunca viu rede nenhuma. `.banco` é o caso próprio.
            throw SyncError.banco("Não foi possível abrir ou migrar o banco em \(path): \(error)")
        }
    }

    private init(pool: DatabasePool, temporaryDirectory: TemporaryDatabaseDirectory?) throws {
        self.temporaryDirectory = temporaryDirectory
        do {
            try Self.migrator.migrate(pool)
        } catch {
            throw SyncError.banco("Não foi possível migrar o banco: \(error)")
        }
        self.pool = pool
    }

    /// Um banco de teste, descartável, com o mesmo esquema do de verdade.
    ///
    /// **Não é `:memory:` de verdade.** `DatabasePool` fala WAL, e WAL
    /// precisa de um arquivo `-wal` de verdade ao lado do banco — SQLite
    /// recusa ativar WAL sobre `mode=memory` (`SQLite error 1: could not
    /// activate WAL Mode`), mesmo com `cache=shared`. É por isso que o
    /// próprio pacote de testes do GRDB nunca abre um `DatabasePool` em
    /// memória: sempre um arquivo novo num diretório temporário
    /// (`GRDBTestCase.makeDatabasePool`). `DatabaseQueue` teria `:memory:` de
    /// verdade, mas então esta função devolveria um banco que não fala WAL —
    /// divergindo do de produção no que mais importa testar. Daí o nome:
    /// `temporary()`, não `inMemory()` — este banco mora em disco.
    ///
    /// Cada instância ganha seu próprio diretório (nome único por `UUID`, o
    /// que também evita dois testes em paralelo compartilharem arquivo e um
    /// ver a escrita do outro), e o diretório morre com ela: nada de 33
    /// arquivos acumulados em `$TMPDIR` depois de rodar a suíte.
    public static func temporary() throws -> SyncDatabase {
        let diretorio = try TemporaryDatabaseDirectory()
        var config = Configuration()
        config.foreignKeysEnabled = true
        let path = diretorio.url.appendingPathComponent("mail.sqlite").path
        let pool = try DatabasePool(path: path, configuration: config)
        return try SyncDatabase(pool: pool, temporaryDirectory: diretorio)
    }

    /// `Application Support/OkamiUNI/mail.sqlite`, dentro do contêiner do
    /// sandbox — o único lugar em que o app pode escrever sem pedir nada ao
    /// usuário.
    public static func defaultPath() throws -> String {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let pasta = base.appendingPathComponent("OkamiUNI", isDirectory: true)
        try FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true)
        return pasta.appendingPathComponent("mail.sqlite").path
    }

    /// As migrações, versionadas desde a v1. O Marco 3 acrescenta a v2 **ao
    /// lado** desta, nunca editando-a: um banco já migrado não roda a v1 de
    /// novo, e mudar o texto dela deixaria instalações divergentes.
    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE account (
                  id TEXT PRIMARY KEY NOT NULL,
                  address TEXT NOT NULL,
                  displayName TEXT NOT NULL,
                  provider TEXT NOT NULL,
                  host TEXT NOT NULL,
                  tintLightHex TEXT NOT NULL,
                  tintDarkHex TEXT NOT NULL,
                  signature TEXT NOT NULL DEFAULT '',
                  imapHost TEXT,
                  imapPort INTEGER,
                  imapSecurity TEXT,
                  state TEXT NOT NULL,
                  lastSyncedAt DOUBLE,
                  createdAt DOUBLE NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE TABLE folder (
                  id TEXT PRIMARY KEY NOT NULL,
                  accountID TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
                  serverName TEXT NOT NULL,
                  role TEXT NOT NULL,
                  displayName TEXT NOT NULL
                )
                """)
            try db.execute(sql: "CREATE INDEX folder_on_account ON folder(accountID)")
            try db.execute(sql: """
                CREATE TABLE message (
                  id TEXT PRIMARY KEY NOT NULL,
                  accountID TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
                  folderID TEXT NOT NULL REFERENCES folder(id) ON DELETE CASCADE,
                  serverID TEXT,
                  uidValidity INTEGER,
                  fromName TEXT NOT NULL,
                  fromAddress TEXT NOT NULL,
                  toJSON TEXT NOT NULL DEFAULT '[]',
                  ccJSON TEXT NOT NULL DEFAULT '[]',
                  subject TEXT NOT NULL,
                  snippet TEXT NOT NULL,
                  receivedAt DOUBLE NOT NULL,
                  dayOffset INTEGER NOT NULL DEFAULT 0,
                  isRead BOOLEAN NOT NULL DEFAULT 0,
                  isFlagged BOOLEAN NOT NULL DEFAULT 0,
                  bucket TEXT NOT NULL,
                  tagsJSON TEXT NOT NULL DEFAULT '[]',
                  summary TEXT,
                  detectedEventJSON TEXT,
                  replyHintsJSON TEXT NOT NULL DEFAULT '[]'
                )
                """)
            try db.execute(sql: """
                CREATE INDEX message_on_account_received
                ON message(accountID, receivedAt DESC)
                """)
            // A lista "Tudo" e a ValueObservation por trás dela ordenam por
            // data sem filtro de conta — sem este índice, `ORDER BY
            // receivedAt DESC` vira `SCAN + TEMP B-TREE`, refeito a cada
            // disparo da observação.
            try db.execute(sql: "CREATE INDEX message_on_received ON message(receivedAt DESC)")
            // O `WHERE folderID = ?` da Task 13 e a cascata folder→message da
            // remoção de conta — sem índice, os dois viram scan da tabela
            // inteira.
            try db.execute(sql: "CREATE INDEX message_on_folder ON message(folderID)")
            try db.execute(sql: """
                CREATE TABLE message_body (
                  rowid INTEGER PRIMARY KEY,
                  messageID TEXT UNIQUE NOT NULL REFERENCES message(id) ON DELETE CASCADE,
                  paragraphs TEXT NOT NULL,
                  plain TEXT NOT NULL
                )
                """)
            // FTS5 de conteúdo externo sobre `message_body`, com o tokenizer
            // que dobra acento. **A dobra desce para o banco**: o `fold` em
            // memória do Marco 1 percorre o que está carregado, e o corpo das
            // mensagens antigas não está.
            //
            // `remove_diacritics 2` (e não 1) porque o 1 deixa de fora os
            // caracteres compostos por múltiplos code points — "ã" digitado
            // como "a" + U+0303 não casaria.
            //
            // `content_rowid='rowid'` aponta para o `rowid` **declarado**
            // acima (`INTEGER PRIMARY KEY`), não para um rowid implícito: um
            // `VACUUM` só preserva o rowid de uma tabela quando ele é a
            // chave primária de verdade — um rowid implícito seria
            // renumerado, e o índice do FTS passaria a apontar para a linha
            // errada sem nenhum erro visível.
            try db.execute(sql: """
                CREATE VIRTUAL TABLE message_fts USING fts5(
                  plain,
                  content='message_body',
                  content_rowid='rowid',
                  tokenize='unicode61 remove_diacritics 2'
                )
                """)
            // Os três gatilhos que mantêm o índice em dia. Sem o de UPDATE, a
            // troca da prévia pelo corpo cheio (que a carga inicial faz) deixa
            // o índice apontando para o texto velho. Sem o de DELETE, apagar
            // uma conta deixa o índice indexando corpos de mensagens que não
            // existem mais — achável por busca, ilegível ao abrir.
            try db.execute(sql: """
                CREATE TRIGGER message_body_ai AFTER INSERT ON message_body BEGIN
                  INSERT INTO message_fts(rowid, plain) VALUES (new.rowid, new.plain);
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER message_body_ad AFTER DELETE ON message_body BEGIN
                  INSERT INTO message_fts(message_fts, rowid, plain)
                  VALUES ('delete', old.rowid, old.plain);
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER message_body_au AFTER UPDATE ON message_body BEGIN
                  INSERT INTO message_fts(message_fts, rowid, plain)
                  VALUES ('delete', old.rowid, old.plain);
                  INSERT INTO message_fts(rowid, plain) VALUES (new.rowid, new.plain);
                END
                """)
            try db.execute(sql: """
                CREATE TABLE agenda_item (
                  id TEXT PRIMARY KEY NOT NULL,
                  accountID TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
                  title TEXT NOT NULL,
                  startMinute INTEGER NOT NULL,
                  endMinute INTEGER NOT NULL,
                  dayOffset INTEGER NOT NULL DEFAULT 0
                )
                """)
            // Criada já na v1, usada de verdade no Marco 3. Existir desde agora
            // é o que permite a carga inicial guardar o `historyId` do profile
            // e o `UIDVALIDITY` de cada pasta — sem isso o Marco 3 começaria
            // sem ponto de partida e teria de rebaixar tudo.
            try db.execute(sql: """
                CREATE TABLE sync_state (
                  accountID TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
                  folderID TEXT NOT NULL DEFAULT '',
                  historyID TEXT,
                  uidValidity INTEGER,
                  highestUID INTEGER,
                  syncedAt DOUBLE,
                  PRIMARY KEY (accountID, folderID)
                )
                """)
        }
        // A v2 do Marco 3: a fila de saída. **Ao lado** da v1, nunca editando
        // -a — um banco já em v1 não a roda de novo, e mudar o texto dela
        // deixaria instalações divergentes (mesmo alerta do comentário da
        // v1, agora valendo para ela mesma).
        //
        // É esta tabela que resolve o defeito visto pelo dono: sem ela, uma
        // mutação (arquivar, apagar) só existia na memória do `MailStore`, e
        // o próximo retrato que a `ValueObservation` do `DatabaseMailSource`
        // entregasse — vindo do banco, que nunca soube da mutação — desfazia
        // a ação na tela. Com `DatabaseCommandPort` escrevendo a projeção em
        // `message` **e** enfileirando aqui, na mesma transação, o retrato
        // seguinte já nasce certo.
        // NOTA HISTÓRICA: o comentário de `idempotencyKey` dentro do SQL
        // abaixo descreve a **primeira** versão da chave, que era derivada do
        // conteúdo da operação e deduplicava no enfileirar. Ela foi trocada por
        // um `UUID` por operação — a de conteúdo engolia o terceiro passo de um
        // ciclo ler→não-ler→ler e todo `emptyTrash` depois do primeiro. O
        // motivo está em `OutboxRecord.idempotencyKey`. O texto da migração não
        // é editado nem para corrigir um comentário: migração registrada é
        // história, e reescrevê-la é o começo de instalações divergentes.
        migrator.registerMigration("v2") { db in
            try db.execute(sql: """
                CREATE TABLE outbox (
                  id TEXT PRIMARY KEY NOT NULL,
                  accountID TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
                  -- A operação inteira, tipada, como JSON — `MailOperation`
                  -- codifica seu próprio caso (`setRead`, `move`, ...) e os
                  -- ids que ela alcança. Uma coluna, e não uma por campo,
                  -- porque os campos variam por caso: `move` carrega uma
                  -- caixa que os outros não têm.
                  operationJSON TEXT NOT NULL,
                  -- A chave de idempotência: determinística a partir da
                  -- conta, do tipo de operação e dos ids — não de um relógio.
                  -- Duas chamadas com a mesma intenção (mesma conta, mesmo
                  -- tipo, mesmos ids) colidem aqui e a segunda não duplica a
                  -- fila, via `ON CONFLICT(idempotencyKey) DO NOTHING`.
                  idempotencyKey TEXT NOT NULL UNIQUE,
                  attempts INTEGER NOT NULL DEFAULT 0,
                  nextAttemptAt DOUBLE NOT NULL,
                  state TEXT NOT NULL DEFAULT 'pendente',
                  createdAt DOUBLE NOT NULL
                )
                """)
            // O índice do executor: ele varre "as pendentes desta conta, na
            // ordem em que devem ser tentadas" — exatamente esta tripla, na
            // mesma ordem.
            try db.execute(sql: """
                CREATE INDEX outbox_on_account_state_next
                ON outbox(accountID, state, nextAttemptAt)
                """)
        }
        // A v3 da M3-8: o HTML da mensagem, e o convite dela. **Ao lado** das
        // duas anteriores, e só acrescentando colunas — pelo mesmo motivo de
        // sempre, e agora com duas migrações de história para o provar.
        //
        // `ALTER TABLE ADD COLUMN` não recria a tabela, então os três gatilhos
        // do FTS da v1 continuam válidos sem serem tocados — e o FTS continua
        // indexando `plain`, que é texto. Indexar HTML poria `<td>`,
        // `background-color` e o base64 de um logotipo no índice de busca.
        //
        // `html` aceita três valores, e os três significam coisas diferentes:
        // NULL é "esta linha nunca passou pelo decodificador que conhece HTML"
        // (é o estado de toda linha gravada antes desta migração, e é o que faz
        // o leitor rebuscar uma vez ao abrir); `''` é "passou, e a mensagem não
        // tem parte HTML" — só-texto fica só-texto, sem rebusca nenhuma; e o
        // resto é o HTML sanitizado.
        migrator.registerMigration("v3") { db in
            try db.execute(sql: "ALTER TABLE message_body ADD COLUMN html TEXT")
            try db.execute(sql: "ALTER TABLE message_body ADD COLUMN calendarICS TEXT")
        }
        // A v4 da M3-9: a conversa. **Ao lado** das três anteriores, e só
        // acrescentando colunas e índice — pelo mesmo motivo de sempre, agora
        // com três migrações de história para o provar.
        //
        // As três colunas são o mínimo que responde às três perguntas que a
        // conversa faz, e nem uma a mais:
        //
        // - `rfcMessageID` é **a identidade da mensagem entre servidores**. Sem
        //   ela, a resposta que nós mandamos não tem o que pôr em `In-Reply-To`
        //   (a dívida registrada da M3-5) e uma filha não acha a mãe no banco.
        // - `referencesJSON` é a corrente, da raiz para cá. `In-Reply-To` não
        //   ganha coluna própria: quando ele é tudo o que a mensagem trouxe,
        //   ele **é** a corrente de um elo só, e uma segunda coluna com a mesma
        //   informação seria a segunda resposta para a mesma pergunta.
        // - `threadKey` é a chave derivada, **guardada e indexada**. Derivar na
        //   leitura significaria uma consulta por linha da lista, a cada
        //   retrato; e a derivação olha a mensagem-mãe, que é justamente uma
        //   consulta.
        //
        // O índice é `(accountID, threadKey)` porque é assim que a pergunta é
        // feita — "as mensagens desta conversa, nesta conta" —, e
        // `(accountID, rfcMessageID)` porque a derivação procura a mãe por aí,
        // uma vez por mensagem nova.
        //
        // **O preenchimento das linhas antigas.** Elas não têm cabeçalho
        // nenhum (ninguém os gravou até aqui), então a chave delas é o fallback
        // do assunto normalizado — a regra 3 de `ThreadKey`. A normalização é
        // texto com dobra de acento e laço de prefixos, que SQL não faz sem
        // inventar uma segunda implementação da regra; então ela roda em Swift,
        // aqui, uma vez na vida da instalação. Assunto vazio cai no próprio id,
        // que é único: conversa de uma mensagem só, nunca todas juntas.
        //
        // A partir daí a chave melhora sozinha: o sync grava `rfcMessageID` de
        // toda mensagem nova, e o `UPDATE` do `DatabaseBodyFetcher` reescreve a
        // chave da mensagem antiga na primeira vez que alguém a abre.
        migrator.registerMigration("v4") { db in
            try db.execute(sql: "ALTER TABLE message ADD COLUMN rfcMessageID TEXT")
            try db.execute(
                sql: "ALTER TABLE message ADD COLUMN referencesJSON TEXT NOT NULL DEFAULT '[]'"
            )
            try db.execute(sql: "ALTER TABLE message ADD COLUMN threadKey TEXT")
            try db.execute(sql: """
                CREATE INDEX message_on_thread ON message(accountID, threadKey)
                """)
            try db.execute(sql: """
                CREATE INDEX message_on_rfc_message_id ON message(accountID, rfcMessageID)
                """)

            let linhas = try Row.fetchAll(db, sql: "SELECT id, accountID, subject FROM message")
            for linha in linhas {
                let id: String = linha["id"]
                let accountID: String = linha["accountID"]
                let subject: String = linha["subject"]
                let chave = ThreadKey.derive(
                    accountID: accountID, messageID: nil, inReplyTo: nil,
                    references: [], subject: subject, fallback: id
                )
                try db.execute(
                    sql: "UPDATE message SET threadKey = ? WHERE id = ?",
                    arguments: [chave, id]
                )
            }
        }
        // A v5 da M3-11: **os compromissos que a pessoa criou**. Ao lado das
        // quatro anteriores, e sem tocar em nenhuma — pelo mesmo motivo de
        // sempre, agora com quatro migrações de história para o provar.
        //
        // "Coloco o item no calendário e ao fechar e abrir o OkamiUNI a agenda
        // some." Sumia: `MailStore.addToAgenda` só acrescentava à lista em
        // memória, e o retrato seguinte — do banco ou das fixtures — substituía
        // a lista inteira.
        //
        // ## Por que uma tabela nova, e não a `agenda_item` da v1
        //
        // Três razões, e a primeira decide sozinha.
        //
        // 1. `agenda_item.accountID` tem `REFERENCES account(id)`, e as chaves
        //    estrangeiras estão ligadas. **Sem conta conectada não haveria onde
        //    gravar**: a mensagem de exemplo tem `accountID` de fixture, que não
        //    existe em `account`, e o `INSERT` seria recusado. O compromisso que
        //    a pessoa cria sem conta é dela do mesmo jeito, e a tabela nova não
        //    tem essa chave — a conta fica guardada como texto, que é o que ela
        //    é para este fim: de onde o compromisso veio.
        // 2. `agenda_item` é a agenda **que a fonte dá** — no Marco 4, a do
        //    EventKit. Misturar as duas obrigaria toda leitura de lá a separar o
        //    que é servidor do que é nosso.
        // 3. Ela não tem coluna para `UID`, `SEQUENCE`, local, gente, link nem
        //    descrição, e acrescentá-las a uma tabela que é de outra coisa é o
        //    começo de uma tabela que não é de nada.
        //
        // ## `day` é texto, e não um `dayOffset` inteiro
        //
        // `AgendaItem.dayOffset` é **relativo** ao "hoje" da tela, e com conta
        // conectada esse hoje é o relógio da máquina. Gravado cru, um
        // compromisso de amanhã seria "amanhã" outra vez amanhã, e no outro dia,
        // e no outro — o compromisso fugindo um dia por abertura. `day` guarda
        // o dia civil ("2026-08-30"), que não anda e não tem fuso; a tradução
        // nos dois sentidos é `CivilDay`, e só ela.
        //
        // ## Uma coluna por campo, e JSON só onde há lista
        //
        // Título, horário, `UID`, `SEQUENCE`, local, link, descrição, nota,
        // repetição e alerta são valores, e viram colunas. Organizador,
        // participantes, pauta e a trilha "o que gerou este compromisso" são
        // listas ou registros compostos, e viram JSON — uma tabela filha para
        // cada uma seria quatro `JOIN`s para desenhar uma janela que sempre lê
        // tudo junto.
        migrator.registerMigration("v5") { db in
            try db.execute(sql: """
                CREATE TABLE created_agenda_item (
                  id TEXT PRIMARY KEY NOT NULL,
                  -- Texto, sem `REFERENCES`: ver a nota acima. É de onde o
                  -- compromisso veio, e ele sobrevive à conta sair.
                  accountID TEXT NOT NULL,
                  title TEXT NOT NULL,
                  -- O dia civil, "AAAA-MM-DD". Nunca um deslocamento, nunca um
                  -- instante.
                  day TEXT NOT NULL,
                  startMinute INTEGER NOT NULL,
                  endMinute INTEGER NOT NULL,
                  -- A identidade do evento no iCalendar, igual em toda cópia
                  -- dele. É o que faz "✓ Na agenda" sobreviver ao reinício em
                  -- vez de o cartão oferecer de novo o que já está lá.
                  calendarUID TEXT,
                  calendarSequence INTEGER,
                  -- O detalhe da janela 04. NULL no compromisso que não trouxe
                  -- nenhum, e aí a janela cai em `Fixtures.eventDetail(for:)`
                  -- como sempre caiu.
                  place TEXT,
                  link TEXT,
                  descricao TEXT,
                  note TEXT,
                  recurrence TEXT,
                  notice TEXT,
                  organizerJSON TEXT,
                  peopleJSON TEXT,
                  agendaJSON TEXT,
                  threadJSON TEXT
                )
                """)
            // A pergunta que a checagem de duplicata faz, e a única consulta
            // desta tabela além de "traga tudo".
            try db.execute(sql: """
                CREATE INDEX created_agenda_on_uid
                ON created_agenda_item(accountID, calendarUID)
                """)
        }
        // A v6 da M3-12: **os remetentes de quem as imagens carregam
        // sozinhas.** Ao lado das cinco anteriores, sem tocar em nenhuma.
        //
        // "Toda hora tenho que clicar em Carregar, mesmo em remetente
        // confiável." O bloqueio por padrão fica — ele é a defesa contra o
        // pixel de rastreio, e é o padrão certo. O que faltava era a memória de
        // um "sempre" dito uma vez.
        //
        // ## O endereço inteiro é a chave, e não o domínio
        //
        // Ver `UNICore.SenderTrust` para o argumento completo. Em duas linhas:
        // o rótulo do botão diz o endereço, e é ele que a pessoa aprovou; e sem
        // DKIM/SPF conferidos, um domínio liberado é herdado por qualquer
        // `From` forjado daquele domínio.
        //
        // ## Sem `REFERENCES account(id)`
        //
        // Pelo mesmo motivo da v5: confiar num remetente é uma decisão sobre
        // **ele**, não sobre uma caixa. Ela vale em qualquer conta e sobrevive
        // à conta sair — e com a chave estrangeira ligada, uma confiança dada
        // sem conta conectada (as fixtures) nem poderia ser gravada.
        //
        // Duas colunas e mais nada. `createdAt` não é enfeite: é o que permite
        // um dia mostrar "confiado em março" ou expirar o que ninguém mais usa,
        // sem migração nova.
        migrator.registerMigration("v6") { db in
            try db.execute(sql: """
                CREATE TABLE trusted_sender (
                  -- O endereço normalizado (minúsculas, sem espaço nas pontas).
                  -- Chave primária: confiar duas vezes no mesmo remetente é a
                  -- mesma linha, não duas.
                  address TEXT PRIMARY KEY NOT NULL,
                  createdAt DOUBLE NOT NULL
                )
                """)
        }
        return migrator
    }
}

/// Um diretório de trabalho descartável, apagado quando a última cópia do
/// `SyncDatabase` que o segura sai de cena.
///
/// Classe, e não struct, de propósito: é o `deinit` que dá a `temporary()`
/// seu apagamento automático — um `SyncDatabase` é um `struct`, que não tem
/// `deinit` próprio, então quem carrega o "apague-me ao sumir" tem de ser um
/// tipo de referência escondido dentro dele.
private final class TemporaryDatabaseDirectory: @unchecked Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("okamiuni-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
