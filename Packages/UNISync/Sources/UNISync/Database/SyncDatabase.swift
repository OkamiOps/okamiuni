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
        do {
            pool = try DatabasePool(path: path, configuration: config)
        } catch {
            throw SyncError.resposta("Não foi possível abrir o banco em \(path): \(error)")
        }
        try Self.migrator.migrate(pool)
    }

    private init(pool: DatabasePool) throws {
        self.pool = pool
        try Self.migrator.migrate(pool)
    }

    /// Um banco de teste, descartável, com o mesmo esquema do de verdade.
    ///
    /// **Não é `:memory:` de verdade.** `DatabasePool` fala WAL, e WAL
    /// precisa de um arquivo `-wal` de verdade ao lado do banco — SQLite
    /// recusa ativar WAL sobre `mode=memory` (`SQLite error 1: could not
    /// activate WAL Mode`), mesmo com `cache=shared`. É por isso que o
    /// próprio pacote de testes do GRDB nunca abre um `DatabasePool` em
    /// memória: sempre um arquivo novo num diretório temporário
    /// (`GRDBTestCase.makeDatabasePool`). Um nome próprio por instância, aqui
    /// via `UUID`, é o que evita dois testes em paralelo compartilharem o
    /// mesmo arquivo e um ver a escrita do outro. `DatabaseQueue` teria
    /// `:memory:` de verdade, mas então esta função devolveria um banco que
    /// não fala WAL — divergindo do de produção no que mais importa testar.
    public static func inMemory() throws -> SyncDatabase {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("okamiuni-\(UUID().uuidString).sqlite")
            .path
        let pool = try DatabasePool(path: path, configuration: config)
        return try SyncDatabase(pool: pool)
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
                  bucket TEXT NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE INDEX message_on_account_received
                ON message(accountID, receivedAt DESC)
                """)
            try db.execute(sql: """
                CREATE TABLE message_body (
                  messageID TEXT PRIMARY KEY NOT NULL REFERENCES message(id) ON DELETE CASCADE,
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
            // o índice apontando para o texto velho.
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
        return migrator
    }
}
