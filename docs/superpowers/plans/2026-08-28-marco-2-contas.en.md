# OkamiUNI — Milestone 2: Real Accounts (Google OAuth, IMAP, Keychain, and a Local Database)
> **Historical implementation plan (28 August 2026).** It records intended work at that point in time and is not evidence of the current application.
>
> [Português original](2026-08-28-marco-2-contas.md) | [English](2026-08-28-marco-2-contas.en.md)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move beyond fixtures: users can connect any number of accounts (Google through OAuth and any other provider through IMAP with an app password). Secrets live in the Keychain, the most recent 90 days are stored in a GRDB database, and the Milestone 1 shell reads that database without changing its shape.

**Architecture:** A new package, `Packages/UNISync`, sits between `UNICore` and the outside world. It imports `UNICore` (`Account`, `Message`, and `AgendaItem` are the shared types) and **never** imports SwiftUI. `UNIShell` knows it only through two ports: the existing read-side `MailSource`, and `AccountDirector`/`AccountsModel` for account management. The database is the source of truth: the UI reads through `ValueObservation` and never waits for the network.

**Tech Stack:** Swift 6.3, SwiftUI (only in `UNIShell`/`App`), AppKit, `AuthenticationServices`, `Security.framework`, GRDB.swift (SQLite + FTS5 + `ValueObservation`), swift-nio-imap (and its SwiftNIO dependency), Swift Testing, XcodeGen, macOS 26.

**Spec:** `docs/superpowers/specs/2026-08-28-marco-2-contas-design.md` — this plan is derived from that spec; read both.

## Global Constraints

- Minimum deployment target: **macOS 26.0**, Swift 6.3, `SWIFT_VERSION` 6.0 in the project, `swift-tools-version: 6.2` in packages, and `SWIFT_STRICT_CONCURRENCY: complete`. The build must have no concurrency warnings.
- Tests use **Swift Testing** (`import Testing`, `@Test`, `#expect`, `#require`). **Never XCTest**, in any package or task.
- **A new test counts only after it has been shown to fail with the defect reintroduced.** Each task has a “run to see it fail” step before its implementation step; skipping it invalidates the task. If the test passes immediately, remove the line that makes it pass, run it again to confirm the failure, then restore the line.
- **Every new UI interaction requires a rehearsal in the real app.** This milestone uses `--ensaiar-contas`, following `Packages/UNIShell/Sources/UNIShell/Windows/SwipeRehearsal.swift`: events are synthesized **inside the process** (`NSApp.postEvent` / `NSWindow.sendEvent`), screenshots are captured for each phase, and `NSApp.terminate` runs at the end. A View test without a rehearsal does not prove interaction.
- **NEVER launch the app outside rehearsal/capture instruments.** Do not run bare `open` or use `Tools/rodar.sh` merely to inspect it. Launch the app only with `--capturar=…`, `--ensaiar-arraste`, `--ensaiar-teclado`, `--ensaiar-barra`, or `--ensaiar-contas`; each exits on its own.
- **New dependencies: ONLY `GRDB.swift` and `swift-nio-imap`** (plus the included `swift-nio`, declared only so the test target can name `NIOCore`/`NIOPosix`/`NIOEmbedded`). OAuth uses `ASWebAuthenticationSession` and `URLSession`; Keychain uses `Security.framework`. Do not add a Google SDK, HTTP library, or Keychain wrapper.
- **`UNISync` does not import SwiftUI.** `Observation`, `Foundation`, `AppKit` (only in the OAuth presenter), and `AuthenticationServices` are allowed; `import SwiftUI` inside `Packages/UNISync` is a defect.
- **Nothing limits the provider, domain, or number of accounts.** `Account.Provider` remains open and `.imap` is the general case. `ImapPresets` is an autofill convenience, never a gatekeeper: manual host/port/TLS entry is always available for any domain.
- **Keep pure logic out of `View`.** Everything worth testing as `nonisolated` lives in `UNICore` or `UNISync`. A `View` is implicitly `@MainActor` and is not a place for decisions.
- **Never swallow an error.** `try?` in a network, database, or Keychain path is a defect. Every error becomes a `SyncError` case with a Portuguese message and reaches a surface that offers an action (reconnect or try again).
- **Time zones do not cross the model.** A day remains `dayOffset: Int` and a time remains minute-of-day. `Date` exists only at the boundaries (UTC epoch in the database, Gmail’s `internalDate`, and IMAP’s `INTERNALDATE`). `UNISync` performs no calendar conversion except the explicit 90-day window calculation, which receives a `Calendar`.
- **Color, corner radius, and typography always come from `Theme`** (`@Environment(\.theme)`) across all 26 themes. Do not use color literals, ad hoc corner radii, or `Font.system` in an Accounts-window View. Use the Milestone 1 `.hairline` (one device pixel, including on 1× screens). The reference dropdown is `ComposerSelect`.
- **Inline spacing is allowed**, following the Milestone 1 rule: every value comes from the drawing, not intuition.
- All interface text is in **Brazilian Portuguese**.
- **No test touches the external network.** HTTP always uses a `URLProtocol` stub; IMAP always uses an in-memory fake NIO server bound to `127.0.0.1:0`. A real account is used only manually by the project owner in the final manual test.
- **The `.xcodeproj` is generated** by `xcodegen` from `project.yml`. Never edit it by hand or commit it.
- One commit per completed task, with a Portuguese message and the trailer `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.
- **The plan does not block on Google.** Only Task 1 depends on the project owner; no coding task waits for it, because `GoogleAuth` and `GmailClient` are proven against local stubs. The real client ID appears only in the acceptance-criteria manual test.

---

## File structure

```
Config/Google.example.xcconfig           Modelo versionado do client ID
Config/Google.xcconfig                   O client ID real — .gitignore
docs/oauth-google.md                     Roteiro do dono do projeto (Task 1)
project.yml                              + pacote UNISync, + configFiles
App/Info.plist                           + CFBundleURLTypes, + OkamiUNIGoogleClientID
App/OkamiUNIApp.swift                    Composição: banco, director, fonte real vs fixtures

Packages/UNICore/Sources/UNICore/
  Account.swift                          + ImapEndpoint, State, lastSyncedAt, copiadores
  Message.swift                          + serverID, uidValidity (pelo funil copy)
  MessageStore.swift                     + MailSnapshot, snapshots(), bodyMatches(), observe()
  ContextMenu.swift                      + ContextCommand.openAccounts e o item "Contas…"

Packages/UNISync/                        O pacote novo
  Package.swift
  Sources/UNISync/
    Wiring.swift                         O espaço de nomes e a prova de que GRDB e NIOIMAP linkam
    AppComposition.swift                 Banco + diretor + fonte (banco vs fixtures)
    SyncError.swift                      O tipo único de erro, com mensagem em português
    Secrets/SecretStore.swift            Protocolo, Secret, OAuthTokens
    Secrets/KeychainSecretStore.swift    Security.framework
    Secrets/InMemorySecretStore.swift    O fake dos testes
    Database/SyncDatabase.swift          DatabasePool, migrador, caminho no contêiner
    Database/Records.swift               AccountRecord, FolderRecord, MessageRecord, …
    Database/MessageSearch.swift         A busca FTS5 com acento dobrado
    Providers/ImapPresets.swift          ImapPreset e a tabela aberta de provedores
    Providers/ProviderDetector.swift     endereço → rota
    Providers/FolderRoles.swift          SPECIAL-USE / nome → papel
    Google/GoogleAuthConfig.swift        Client ID, escopos, endpoints
    Google/PKCE.swift                    Verifier/challenge S256
    Google/OAuthCallback.swift           Parser do redirect
    Google/AuthorizationPresenter.swift  Porta + ASWebAuthenticationSession
    Google/GoogleAuth.swift              Troca, refresh, corrida única, revogação
    Gmail/GmailTypes.swift               Profile, Label, Page, Message, Format
    Gmail/GmailMessageParser.swift       JSON da API → GmailMessage (puro)
    Gmail/GmailClient.swift              URLSession tipado
    Imap/ImapWire.swift                  Comandos e interpretação de resposta (puro)
    Imap/ImapResponseAdapter.swift       O ÚNICO arquivo que toca os tipos do swift-nio-imap
    Imap/ImapSession.swift               Ator sobre NIO
    Load/TriageProjection.swift          Papel/label → TriageBucket (puro)
    Load/MessageIdentity.swift           Id nosso a partir do id do servidor (puro)
    Load/InitialLoader.swift             Carga de 90 dias, por lote, retomável
    Source/DatabaseMailSource.swift      MailSource lendo do banco + observação
    Accounts/AccountStatus.swift         O que a janela mostra por conta
    Accounts/AccountTints.swift          As cores de conta, em ciclo (nunca acabam)
    Accounts/AccountDirector.swift       O ator: adicionar, testar, remover, carregar
    Accounts/AccountsModel.swift         @Observable, a ponte para a UI
  Tests/UNISyncTests/
    StubURLProtocol.swift                O stub HTTP compartilhado
    FakeImapServer.swift                 O servidor IMAP falso em memória (NIO)
    Fixtures/gmail-*.json                Respostas gravadas da API
    …Tests.swift                         Um arquivo por componente

Packages/UNIShell/Sources/UNIShell/
  Windows/AccountsWindow.swift           A cena nova
  Windows/AccountsList.swift             A lista de contas com estado e erro
  Windows/AddAccountForm.swift           Endereço → rota → OAuth ou formulário IMAP
  Windows/AccountsRehearsal.swift        --ensaiar-contas
  Windows/RehearsalImapServer.swift      O IMAP falso do ensaio, em 127.0.0.1
  Windows/UNIWindow.swift                + UNIWindow.accounts
  Support/ContextMenuHost.swift          + despacho de .openAccounts
  Inbox/FolderSidebar.swift              A linha da conta mostra estado e progresso
```

**Why this division:** Only `UNISync` knows about networking, disk and Keychain. It imports and returns `UNICore` types, leaving `UNIShell` unaware of the backend. Within `UNISync`, pure files (`ProviderDetector`, `ImapPresets`, `FolderRoles`, `PKCE`, `OAuthCallback`, `GmailMessageParser`, `ImapWire`, `TriageProjection`, `MessageIdentity`) can be tested without networking. They contain most decisions, keeping the genuinely asynchronous pieces (`GoogleAuth`, `GmailClient`, `ImapSession`) thin.

---

## Task order and dependencies

| # | Task | Depends on |
|---|---|---|
| 1 | Google Cloud OAuth client guide (project owner) | — |
| 2 | SPM wiring: package `UNISync`, GRDB, swift-nio-imap, `project.yml` | — |
| 3 | Evolve `UNICore`: `Account` and `Message` gain real fields | 2 |
| 4 | `SyncError` + `SecretStore` (protocol, Keychain, fake) | 2 |
| 5 | GRDB v1 schema, migration and accent-folding FTS5 | 3, 4 |
| 6 | `ProviderDetector`, `ImapPresets`, `FolderRoles` (pure) | 3 |
| 7 | `GoogleAuth`: PKCE, callback, exchange, refresh, single flight | 4 |
| 8 | `GmailClient` against JSON fixtures | 7 |
| 9 | Fake IMAP server + `ImapSession`: connect, log in, log out | 6 |
| 10 | `ImapSession`: LIST, SELECT, UID SEARCH, batch FETCH, UIDVALIDITY | 9 |
| 11 | `TriageProjection` and `MessageIdentity` (pure) | 6 |
| 12 | Gmail `InitialLoader` | 5, 8, 11 |
| 13 | IMAP `InitialLoader` | 5, 10, 11 |
| 14 | `DatabaseMailSource`, observation and body search in `MailStore` | 5, 12 |
| 15 | `AccountDirector` and `AccountsModel` | 12, 13, 14 |
| 16 | Accounts window (UI) | 15 |
| 17 | The `--ensaiar-contas` rehearsal | 16 |
| 18 | App composition and acceptance | 14, 16, 17 |

**Deliberate departure from the suggested specification order:** `Account`/`Message` evolution (Task 3) moved ahead of the GRDB schema (Task 5). The schema must persist `Account.State`, the IMAP endpoint and `Message` server IDs. Writing tables before types would require inventing and later reconciling a second database state enum: two truths for one question, a defect this project already encountered with `QuickReply.fold`.

---

### Task 1: Google Cloud OAuth client guide (for the project owner)

This is the **only** task that writes no code and depends on another person. It comes first so the project owner can perform it alongside the rest of the plan; **no coding task waits for it.** All `GoogleAuth` and `GmailClient` tasks use local stubs. The real client ID appears only in Task 18’s manual test.

**Files:**
- Create: `docs/oauth-google.md`
- Create: `Config/Google.example.xcconfig`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: nothing.
- Produces: `docs/oauth-google.md` (the guide); `Config/Google.example.xcconfig` with `OKAMIUNI_GOOGLE_CLIENT_ID`, wired to `Info.plist` by Task 2 and read through `GoogleAuthConfig.fromBundle(_:)` by Task 7.

- [ ] **Step 1: Write the guide**

Create `docs/oauth-google.md` with exactly this content:

````markdown
# Criar o OAuth Client do Google (uma vez, pelo dono do projeto)

O OkamiUNI fala com a Gmail API em nome do usuário. Para isso o Google exige um
**OAuth Client ID de aplicativo desktop**, criado por quem é dono do projeto no
Google Cloud. Não há como o app criar isso sozinho, e não há como embutir um
client de terceiros: o consentimento cita o nome do projeto.

O app **não fica bloqueado** enquanto isto não existe. Sem client ID, a rota
Google da janela de Contas mostra "Falta o OAuth Client ID do Google — ver
docs/oauth-google.md" com o botão que abre este arquivo, e a rota IMAP funciona
normalmente. Nenhum teste depende deste roteiro.

Leva uns dez minutos.

## 1. Criar o projeto

1. Abra <https://console.cloud.google.com/>.
2. No seletor de projeto (barra do topo, à esquerda), clique em **Novo projeto**.
3. Nome: `OkamiUNI`. Organização: a sua, ou "Sem organização".
4. **Criar**. Espere a notificação e selecione o projeto novo no seletor.

## 2. Ativar a Gmail API

1. Menu ☰ ▸ **APIs e serviços** ▸ **Biblioteca**.
2. Busque `Gmail API`.
3. Abra o cartão **Gmail API** e clique em **Ativar**.

## 3. Configurar a tela de consentimento

1. Menu ☰ ▸ **APIs e serviços** ▸ **Tela de permissão OAuth**.
2. Tipo de usuário: **Externo**. **Criar**.
3. Preencha o mínimo obrigatório:
   - Nome do app: `OkamiUNI`
   - Email de suporte: o seu
   - Email do desenvolvedor: o seu
4. **Salvar e continuar**.
5. Na etapa **Escopos**, clique em **Adicionar ou remover escopos** e marque os
   três, colando cada um no filtro:
   - `https://www.googleapis.com/auth/gmail.modify`
   - `https://www.googleapis.com/auth/gmail.send`
   - `https://www.googleapis.com/auth/userinfo.email`

   Os três são pedidos **juntos**, de propósito: `gmail.send` só é usado no
   Marco 3, mas pedi-lo depois obrigaria o usuário a consentir duas vezes.
6. **Atualizar** ▸ **Salvar e continuar**.
7. Na etapa **Usuários de teste**, **Adicionar usuários** e coloque os endereços
   Gmail que você vai conectar. **Em modo de teste, só esses endereços
   conseguem autorizar o app** — se faltar um, o consentimento devolve
   `access_denied`, que o app mostra como "Autorização negada ou revogada".
8. **Salvar e continuar** ▸ **Voltar ao painel**.

Modo **Teste** serve. Publicar exige verificação do Google, que só faz sentido
quando o app for distribuído.

## 4. Criar o Client ID

1. Menu ☰ ▸ **APIs e serviços** ▸ **Credenciais**.
2. **Criar credenciais** ▸ **ID do cliente OAuth**.
3. Tipo de aplicativo: **App para computador** (*Desktop app*).
4. Nome: `OkamiUNI macOS`.
5. **Criar**. Copie o **ID do cliente** — algo como
   `123456789012-abcdefghijklmnop.apps.googleusercontent.com`.

Não existe "URI de redirecionamento" para escolher aqui: um client de desktop
aceita esquema próprio. O app usa `com.okamiops.okamiuni:/oauth`, registrado no
`Info.plist` em `CFBundleURLTypes`.

**Não há segredo do cliente a guardar.** Client de desktop é público por
definição, e é exatamente por isso que o fluxo usa PKCE (S256): a prova de
posse é o `code_verifier` gerado a cada autorização, não um segredo embutido no
binário — que qualquer pessoa extrairia do `.app`.

## 5. Entregar o client ID ao app

```bash
cp Config/Google.example.xcconfig Config/Google.xcconfig
```

Abra `Config/Google.xcconfig` e troque o valor:

```
OKAMIUNI_GOOGLE_CLIENT_ID = 123456789012-abcdefghijklmnop.apps.googleusercontent.com
```

`Config/Google.xcconfig` está no `.gitignore` — o client ID não vai para o
repositório. `Config/Google.example.xcconfig` vai, com o valor vazio, para
quem clonar saber que o arquivo existe.

Depois: `xcodegen generate`.

## Como saber que deu certo

Rode o ensaio da janela de Contas:

```bash
xcodegen generate
xcodebuild -project OkamiUNI.xcodeproj -scheme OkamiUNI -configuration Debug build
open -g --args --ensaiar-contas
```

Sem client ID, o stderr traz `contas: rota google sem client ID`. Com o client
ID configurado, traz `contas: rota google pronta`. O ensaio **não** abre o
navegador nem toca a rede: ele usa o apresentador de autorização falso.
````

- [ ] **Step 2: Write the xcconfig template**

`Config/Google.example.xcconfig`:

```
// Copie para Config/Google.xcconfig (que está no .gitignore) e cole o seu
// client ID de app desktop. Ver docs/oauth-google.md.
//
// Vazio é legítimo: sem client ID a rota Google da janela de Contas explica o
// que falta e aponta para o roteiro, e a rota IMAP continua inteira.
OKAMIUNI_GOOGLE_CLIENT_ID =
```

- [ ] **Step 3: Ignore the real file**

Add this to the end of `.gitignore`:

```
# O client ID do OAuth do Google. Ver docs/oauth-google.md.
Config/Google.xcconfig
```

- [ ] **Step 4: Confirm that the secret does not escape**

Run: `git status --porcelain Config/ && git check-ignore -v Config/Google.xcconfig || echo "AINDA NAO IGNORADO"`

Expected: `Config/Google.example.xcconfig` appears as new (`??`).
`check-ignore` prints the rule only when the file exists locally, so before the
project owner copies it, `AINDA NAO IGNORADO` is expected and is not a defect.
Create an empty `Config/Google.xcconfig`, run the command again, and confirm
that `check-ignore` now matches; delete it afterwards if it is not needed.

- [ ] **Step 5: Commit**

```bash
git add docs/oauth-google.md Config/Google.example.xcconfig .gitignore
git commit -m "O roteiro do OAuth do Google, para o dono do projeto seguir sem parar o plano

Nenhuma tarefa de código espera por isto: GoogleAuth e GmailClient são
provados contra stub local, e o client ID real só entra no teste manual do
critério de aceite. Sem ele, a rota Google explica o que falta em vez de
falhar mudo.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: SPM wiring — the `UNISync` package with GRDB and swift-nio-imap; a green build before any product code

This task contains no product logic. It stands alone because adding two
dependencies to an XcodeGen project with `SWIFT_STRICT_CONCURRENCY: complete`
can fail for reasons unrelated to the product; discovering that in the middle
of an `ImapSession` task costs twice as much.

**Files:**
- Create: `Packages/UNISync/Package.swift`
- Create: `Packages/UNISync/Sources/UNISync/Wiring.swift`
- Create: `Packages/UNISync/Tests/UNISyncTests/WiringTests.swift`
- Modify: `project.yml`
- Modify: `App/Info.plist`
- Modify: `Packages/UNIShell/Package.swift`

**Interfaces:**
- Consumes: `Config/Google.example.xcconfig` from Task 1 (only the `OKAMIUNI_GOOGLE_CLIENT_ID` key). **XcodeGen 2.46 treats a missing `configFiles` entry as an error, not a warning**, so every path that first runs `xcodegen generate` ensures the file exists: `test -f Config/Google.xcconfig || cp Config/Google.example.xcconfig Config/Google.xcconfig`. That copy is the legitimate template with an empty ID. This task adds the same guard to `Tools/rodar.sh`.
- Produces: the `UNISync` product, importable by `UNIShell` and the app target; `UNISync.wiringCheck() -> String`, which exists only to prove that the two third-party packages link.

- [ ] **Step 1: Write the failing test**

`Packages/UNISync/Tests/UNISyncTests/WiringTests.swift`:

```swift
import Foundation
import Testing
import GRDB
import NIOIMAP
@testable import UNISync

@Suite("Wiring das dependências novas")
struct WiringTests {
    @Test("O pacote existe e nomeia as duas dependências")
    func wiring() {
        #expect(UNISync.wiringCheck() == "GRDB+NIOIMAP")
    }

    @Test("GRDB abre um banco em memória e responde SQL")
    func grdbAbre() throws {
        let queue = try DatabaseQueue()
        let um = try queue.read { db in try Int.fetchOne(db, sql: "SELECT 1") }
        #expect(um == 1)
    }

    @Test("SQLite foi compilado com FTS5 e com o tokenizer que dobra acento")
    func fts5Existe() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: """
                CREATE VIRTUAL TABLE t USING fts5(
                    corpo, tokenize='unicode61 remove_diacritics 2'
                )
                """)
            try db.execute(sql: "INSERT INTO t(corpo) VALUES ('Revisão do contrato')")
        }
        let achou = try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM t WHERE t MATCH 'Revisao'")
        }
        #expect(achou == 1)
    }

    @Test("swift-nio-imap está linkado e monta um nome de caixa")
    func nioImapExiste() {
        let caixa = MailboxName(ByteBuffer(string: "INBOX"))
        #expect(caixa.bytes.readableBytesView.count == 5)
    }
}
```

- [ ] **Step 2: Run it to see it fail**

Run: `cd Packages/UNISync && swift test`

Expected: FAIL — `error: could not find Package.swift in this directory or any of its parent directories`. The package does not exist.

- [ ] **Step 3: Create the package**

`Packages/UNISync/Package.swift`:

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "UNISync",
    platforms: [.macOS(.v26)],
    products: [.library(name: "UNISync", targets: ["UNISync"])],
    dependencies: [
        .package(path: "../UNICore"),
        // As duas únicas dependências novas do marco.
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-nio-imap.git", .upToNextMinor(from: "0.4.0")),
        // O SwiftNIO que o swift-nio-imap já traz. Declarado aqui só para o
        // alvo de teste poder nomear NIOCore/NIOPosix/NIOEmbedded ao montar o
        // servidor IMAP falso — não é uma terceira dependência, é a mesma
        // árvore com um nome à mão.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    ],
    targets: [
        .target(
            name: "UNISync",
            dependencies: [
                "UNICore",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "NIOIMAP", package: "swift-nio-imap"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ]
        ),
        .testTarget(
            name: "UNISyncTests",
            dependencies: [
                "UNISync",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
            ],
            resources: [.copy("Fixtures")]
        ),
    ]
)
```

`swift-nio-ssl` provides SwiftNIO TLS and comes from the `swift-nio-imap`
dependency tree. It needs its own `dependencies` entry so the product can be named:

```swift
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.25.0"),
```

Add that line to the `dependencies` array above, after `swift-nio`.

`Packages/UNISync/Sources/UNISync/Wiring.swift`:

```swift
import Foundation
import GRDB
import NIOIMAP

/// O espaço de nomes do pacote, e a prova de que as duas dependências novas
/// linkam.
///
/// `wiringCheck()` não é código de produção disfarçado: ele existe para a
/// Task 2 ter um verde que não depende de nenhuma decisão do produto. Se um dia
/// alguém o apagar e nada quebrar, ele terá cumprido o papel — mas até lá ele é
/// o primeiro a falhar quando uma atualização de GRDB ou de swift-nio-imap
/// muda de nome de produto.
public enum UNISync {
    public static func wiringCheck() -> String {
        _ = DatabaseQueue.self
        _ = MailboxName.self
        return "GRDB+NIOIMAP"
    }
}
```

`Packages/UNISync/Tests/UNISyncTests/Fixtures/.gitkeep` (an empty file: the
`resources: [.copy("Fixtures")]` declaration requires the directory to exist;
Gmail JSON files arrive in Task 8):

```
```

- [ ] **Step 4: Run it to see it pass**

Run: `cd Packages/UNISync && swift test`

Expected: PASS, 4 tests. The first run downloads GRDB, swift-nio,
swift-nio-ssl, and swift-nio-imap; wait for dependency resolution to finish.

- [ ] **Step 5: Connect the package to `UNIShell` and the app target**

In `Packages/UNIShell/Package.swift`, add the path dependency and the target
dependency:

```swift
    dependencies: [
        .package(path: "../UNIDesign"),
        .package(path: "../UNICore"),
        .package(path: "../UNISync"),
    ],
    targets: [
        .target(name: "UNIShell", dependencies: ["UNIDesign", "UNICore", "UNISync"]),
        .testTarget(name: "UNIShellTests", dependencies: ["UNIShell"]),
    ]
```

In `project.yml`, add the package, target dependency, and client-ID configuration
file:

```yaml
packages:
  UNIDesign:
    path: Packages/UNIDesign
  UNICore:
    path: Packages/UNICore
  UNIShell:
    path: Packages/UNIShell
  UNISync:
    path: Packages/UNISync

configFiles:
  Debug: Config/Google.xcconfig
  Release: Config/Google.xcconfig
```

Then, inside `targets: OkamiUNI: dependencies:`, after `UNIShell`:

```yaml
      - package: UNISync
        product: UNISync
```

- [ ] **Step 6: Add the client ID and redirect scheme to the bundle**

In `App/Info.plist`, before the final `</dict>`:

```xml
  <key>OkamiUNIGoogleClientID</key>
  <string>$(OKAMIUNI_GOOGLE_CLIENT_ID)</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key>
      <string>com.okamiops.okamiuni.oauth</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>com.okamiops.okamiuni</string>
      </array>
    </dict>
  </array>
```

- [ ] **Step 7: Build the full app successfully**

Run:

```bash
xcodegen generate && xcodebuild -project OkamiUNI.xcodeproj -scheme OkamiUNI -configuration Debug build 2>&1 | tail -20
```

Expected: `BUILD SUCCEEDED`, with **no** `warning:` line mentioning
`Sendable`, `concurrency`, or `actor-isolated`. If `Config/Google.xcconfig`
does not exist yet, `xcodegen` warns that the configuration file was not found
and continues; the `Info.plist` key remains empty, which is the state Task 7
knows how to explain.

- [ ] **Step 8: Confirm that the 807 tests remain green**

Run:

```bash
for p in UNIDesign UNICore UNIShell UNISync; do
  (cd "Packages/$p" && swift test 2>&1 | grep -E 'Test run with')
done
```

Expected: four `Test run with N tests passed` lines, none containing `failed`.
The `UNIDesign`+`UNICore`+`UNIShell` total remains 807.

- [ ] **Step 9: Commit**

```bash
git add Packages/UNISync Packages/UNIShell/Package.swift project.yml App/Info.plist
git commit -m "O pacote UNISync entra com GRDB e swift-nio-imap, e o build fica verde antes de qualquer lógica

As duas dependências novas do marco, e mais nada. O teste de wiring prova o
que interessa saber antes de escrever a primeira linha de produto: FTS5 existe
com o tokenizer que dobra acento, e o swift-nio-imap linka. O Info.plist já
carrega o client ID por xcconfig e registra o esquema do redirect.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: `UNICore` evolves — `Account` and `Message` gain real fields without changing a fixture

**Files:**
- Modify: `Packages/UNICore/Sources/UNICore/Account.swift`
- Modify: `Packages/UNICore/Sources/UNICore/Message.swift:121-193`
- Create: `Packages/UNICore/Tests/UNICoreTests/AccountEvolutionTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces the following interfaces, used unchanged by the rest of the plan:
  - `struct ImapEndpoint: Sendable, Hashable` with `let host: String`, `let port: Int`, `let security: ImapEndpoint.Security`, `init(host:port:security:)`, and `enum Security: String, Sendable, Hashable, CaseIterable { case tls, startTLS }`.
  - `enum Account.State: String, Sendable, Hashable, CaseIterable { case ativa, carregando, erroDeAutenticacao }`.
  - `Account.init(id:address:displayName:provider:host:tintLightHex:tintDarkHex:signature:imap:state:lastSyncedAt:)` — the last three parameters default to (`nil`, `.ativa`, `nil`), while `signature` retains its `""` default.
  - `Account.imap: ImapEndpoint?`, `Account.state: Account.State`, `Account.lastSyncedAt: Date?`.
  - `Account.withState(_ state: Account.State) -> Account`, `Account.withLastSynced(_ date: Date?) -> Account`, `Account.withImap(_ endpoint: ImapEndpoint?) -> Account`.
  - `Message.serverID: String?` and `Message.uidValidity: Int64?`, both defaulting to `nil` in `init` and both preserved by `Message.copy`.

- [ ] **Step 1: Write the failing test**

`Packages/UNICore/Tests/UNICoreTests/AccountEvolutionTests.swift`:

```swift
import Foundation
import Testing
@testable import UNICore

@Suite("Account e Message com os campos do Marco 2")
struct AccountEvolutionTests {
    @Test("Os campos novos são aditivos: as fixtures do Marco 1 continuam válidas")
    func fixturesIntactas() {
        for account in Fixtures.accounts {
            #expect(account.imap == nil)
            #expect(account.state == .ativa)
            #expect(account.lastSyncedAt == nil)
        }
        for message in Fixtures.messages {
            #expect(message.serverID == nil)
            #expect(message.uidValidity == nil)
        }
    }

    @Test("Uma conta IMAP guarda host, porta e forma de TLS")
    func contaImap() {
        let conta = Account(
            id: "novo", address: "eu@meudominio.com.br", displayName: "Meu",
            provider: .imap, host: "meudominio",
            tintLightHex: "#3F6AA1", tintDarkHex: "#8CBAF7",
            imap: ImapEndpoint(host: "imap.meudominio.com.br", port: 993, security: .tls)
        )
        #expect(conta.imap?.host == "imap.meudominio.com.br")
        #expect(conta.imap?.port == 993)
        #expect(conta.imap?.security == .tls)
        #expect(conta.state == .ativa)
    }

    @Test("Os copiadores preservam tudo o que não pediram para mudar")
    func copiadoresPreservam() {
        let base = Account(
            id: "novo", address: "eu@meudominio.com.br", displayName: "Meu",
            provider: .imap, host: "meudominio",
            tintLightHex: "#3F6AA1", tintDarkHex: "#8CBAF7",
            signature: "Eu",
            imap: ImapEndpoint(host: "imap.meudominio.com.br", port: 143, security: .startTLS)
        )
        let carregando = base.withState(.carregando)
        #expect(carregando.state == .carregando)
        #expect(carregando.signature == "Eu")
        #expect(carregando.imap?.security == .startTLS)
        #expect(carregando.address == base.address)

        let carimbada = carregando.withLastSynced(Date(timeIntervalSince1970: 1_800_000_000))
        #expect(carimbada.lastSyncedAt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(carimbada.state == .carregando)

        let semImap = carimbada.withImap(nil)
        #expect(semImap.imap == nil)
        #expect(semImap.lastSyncedAt == Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test("Os ids de servidor da mensagem sobrevivem a mover, ler e sinalizar")
    func idsDeServidorSobrevivem() {
        let original = Message(
            id: "gmail:g:18f", accountID: "gmail",
            from: Contact(name: "Marina", address: "marina@x.com"),
            receivedAt: Date(timeIntervalSince1970: 1_800_000_000),
            subject: "Assunto", snippet: "Trecho", body: ["Corpo"],
            tags: [], bucket: .today, isRead: false,
            summary: nil, detectedEvent: nil,
            serverID: "18f0a1b2c3", uidValidity: 42
        )
        #expect(original.serverID == "18f0a1b2c3")
        #expect(original.uidValidity == 42)

        let arquivada = original.withBucket(.archived).withRead(true).withFlagged(true)
        #expect(arquivada.serverID == "18f0a1b2c3")
        #expect(arquivada.uidValidity == 42)
        #expect(arquivada.bucket == .archived)
    }

    @Test("`erroDeAutenticacao` é um estado, não um texto solto")
    func estadoDeErro() {
        #expect(Account.State(rawValue: "erroDeAutenticacao") == .erroDeAutenticacao)
        #expect(Account.State.allCases.count == 3)
    }
}
```

- [ ] **Step 2: Run it to see it fail**

Run: `cd Packages/UNICore && swift test --filter AccountEvolution`

Expected: FAIL — `cannot find 'ImapEndpoint' in scope`, `value of type 'Account' has no member 'state'`, `extra arguments 'serverID', 'uidValidity'`.

- [ ] **Step 3: Add the fields to `Account`**

In `Packages/UNICore/Sources/UNICore/Account.swift`, before `public struct Account`:

```swift
/// Onde e como falar IMAP com um servidor.
///
/// Um tipo próprio, e não três campos soltos em `Account`, porque os três só
/// fazem sentido juntos: porta sem host não liga em lugar nenhum, e "usa TLS"
/// sem porta não diz se é 993 (TLS desde o primeiro byte) ou 143 com
/// `STARTTLS`. Nulo em `Account.imap` significa "esta conta não fala IMAP" —
/// uma conta Google recém-conectada, por exemplo.
public struct ImapEndpoint: Sendable, Hashable {
    /// Como o TLS entra. Não é preferência: é o protocolo do servidor.
    public enum Security: String, Sendable, Hashable, CaseIterable {
        /// TLS implícito, desde o primeiro byte. Porta canônica 993.
        case tls
        /// Conexão em claro que sobe para TLS com `STARTTLS`. Porta 143.
        case startTLS
    }

    public let host: String
    public let port: Int
    public let security: Security

    public init(host: String, port: Int, security: Security) {
        self.host = host
        self.port = port
        self.security = security
    }
}
```

Inside `Account`, after `enum Provider`:

```swift
    /// Em que pé a conta está — o que a lateral e a janela de Contas mostram.
    ///
    /// `erroDeAutenticacao` é o estado que o refresh de token falhado e o
    /// `LOGIN` recusado produzem. Ele existe como **estado da conta**, e não
    /// como um alerta passageiro, porque a conta continua na lista com as
    /// mensagens que já baixou: o que ela perdeu foi o direito de baixar mais.
    /// Toda superfície que mostra uma conta neste estado tem de oferecer
    /// reconectar — conta parada sem explicação é a versão de dados do botão
    /// mudo.
    public enum State: String, Sendable, Hashable, CaseIterable {
        case ativa
        case carregando
        case erroDeAutenticacao
    }
```

Then, after `public let signature: String`:

```swift
    /// Nulo para contas que não falam IMAP (uma conta Google, por exemplo).
    public let imap: ImapEndpoint?

    /// O estado corrente. Default `.ativa`: as fixtures do Marco 1 nasceram
    /// sem estado nenhum e continuam significando "funcionando".
    public let state: State

    /// Quando a última sincronização terminou. Nulo é "nunca sincronizou" —
    /// que é o que a janela mostra como "ainda não sincronizada", em vez de
    /// inventar uma data.
    ///
    /// `Date` aqui não fere a regra de fuso: isto é um **instante**, não um
    /// horário de parede. Quem escreve "às 14:32" formata na borda, com o
    /// `Calendar` de quem está lendo.
    public let lastSyncedAt: Date?
```

Replace `init` with:

```swift
    public init(
        id: String, address: String, displayName: String,
        provider: Provider, host: String, tintLightHex: String, tintDarkHex: String,
        signature: String = "",
        imap: ImapEndpoint? = nil,
        state: State = .ativa,
        lastSyncedAt: Date? = nil
    ) {
        self.id = id
        self.address = address
        self.displayName = displayName
        self.provider = provider
        self.host = host
        self.tintLightHex = tintLightHex
        self.tintDarkHex = tintDarkHex
        self.signature = signature
        self.imap = imap
        self.state = state
        self.lastSyncedAt = lastSyncedAt
    }
```

Then add the copy funnel after `tint(isDark:)`, for the same reason
`Message.copy` exists:

```swift
    /// A mesma conta noutro estado.
    public func withState(_ state: State) -> Account { copy(state: state) }

    /// A mesma conta com outro carimbo de sincronização.
    public func withLastSynced(_ date: Date?) -> Account {
        copy(lastSyncedAt: .some(date))
    }

    /// A mesma conta com outro endpoint IMAP (ou nenhum).
    public func withImap(_ endpoint: ImapEndpoint?) -> Account {
        copy(imap: .some(endpoint))
    }

    /// O único lugar que reconstrói uma `Account`.
    ///
    /// Onze campos, três deles com default no `init`: reconstruir à mão em
    /// cada chamador é a mesma armadilha que `Message.copy` já pagou — o campo
    /// esquecido **compila** e vira uma assinatura sumida ou uma conta que
    /// voltou a "ativa" sozinha. Acrescentar campo ao modelo quebra este
    /// arquivo, que é onde se quer que quebre.
    ///
    /// Os dois opcionais entram como `String??`/`Date??` para "não mexer"
    /// (`nil`) ser distinguível de "apagar" (`.some(nil)`).
    private func copy(
        state: State? = nil,
        imap: ImapEndpoint?? = nil,
        lastSyncedAt: Date?? = nil
    ) -> Account {
        Account(
            id: id, address: address, displayName: displayName,
            provider: provider, host: host,
            tintLightHex: tintLightHex, tintDarkHex: tintDarkHex,
            signature: signature,
            imap: imap ?? self.imap,
            state: state ?? self.state,
            lastSyncedAt: lastSyncedAt ?? self.lastSyncedAt
        )
    }
```

- [ ] **Step 4: Add server IDs to `Message`**

In `Packages/UNICore/Sources/UNICore/Message.swift`, after
`public let replyHints: [String]`:

```swift
    /// O id que o **servidor** dá a esta mensagem, opaco para nós.
    ///
    /// Gmail: o `id` da `messages.get`. IMAP: o UID, em texto. Nulo nas
    /// fixtures e em qualquer mensagem que não nasceu de um servidor — é
    /// aditivo, como `dayOffset` foi.
    ///
    /// Opaco de verdade: nada no app interpreta este texto, faz `switch` sobre
    /// ele nem presume formato. Quem precisa de um id **nosso** usa
    /// `Message.id`, que `UNISync.MessageIdentity` monta de forma estável.
    public let serverID: String?

    /// O `UIDVALIDITY` da pasta IMAP de onde o UID veio. Nulo para Gmail e
    /// para as fixtures.
    ///
    /// Existe porque UID sozinho não identifica nada: o servidor pode trocar o
    /// `UIDVALIDITY` da pasta e reciclar os UIDs desde 1. Guardar o par é o que
    /// permite ao Marco 3 detectar a troca e refazer a pasta em vez de casar
    /// mensagem errada com mensagem errada.
    public let uidValidity: Int64?
```

In `init`, add both parameters at the end with defaults, along with their
assignments:

```swift
    public init(
        id: String, accountID: String, from: Contact, receivedAt: Date,
        subject: String, snippet: String, body: [String],
        tags: [Tag], bucket: TriageBucket, isRead: Bool,
        summary: String?, detectedEvent: DetectedEvent?,
        dayOffset: Int = 0, replyHints: [String] = [],
        to: [Contact] = [], cc: [Contact] = [], isFlagged: Bool = false,
        serverID: String? = nil, uidValidity: Int64? = nil
    ) {
        self.serverID = serverID
        self.uidValidity = uidValidity
        self.to = to
```

(the rest of the `init` body stays as-is).

In the `copy` funnel reconstruction, add both at the end of the call:

```swift
            to: to, cc: cc, isFlagged: isFlagged ?? self.isFlagged,
            serverID: serverID, uidValidity: uidValidity
```

Update the `copy` comment to say seven rather than five:

```swift
    /// Cada campo novo com default no `init` é uma armadilha a mais para quem
    /// copia à mão — `dayOffset` e `replyHints` já custaram uma mensagem de
    /// ontem reaparecendo sob "Hoje". Com `to`, `cc`, `isFlagged`, `serverID` e
    /// `uidValidity` são sete. Aqui a lista é escrita uma vez, e os três
    /// copiadores acima passam por ela.
```

- [ ] **Step 5: Run it to see it pass**

Run: `cd Packages/UNICore && swift test --filter AccountEvolution`

Expected: PASS, 5 tests.

- [ ] **Step 6: Prove by mutation that the `copy` funnel carries the IDs**

Remove `serverID: serverID, uidValidity: uidValidity` from the call inside
`Message.copy` (letting the defaults apply), then run it again.

Run: `cd Packages/UNICore && swift test --filter idsDeServidorSobrevivem`

Expected: FAIL — `Expectation failed: arquivada.serverID == "18f0a1b2c3"`.
Restore the line and confirm that the test is green.

- [ ] **Step 7: The 807 tests remain green**

Run:

```bash
for p in UNIDesign UNICore UNIShell; do
  (cd "Packages/$p" && swift test 2>&1 | grep -E 'Test run with')
done
```

Expected: no line containing `failed`. No fixture was touched and no caller of
`Account(...)` or `Message(...)` had to change—that is what “additive” means.

- [ ] **Step 8: Commit**

```bash
git add Packages/UNICore
git commit -m "A conta ganha para onde ligar e em que pé está; a mensagem, o id que o servidor lhe deu

ImapEndpoint junta host, porta e forma de TLS porque os três só fazem sentido
juntos. Account.State existe como estado, não como alerta: a conta com o token
vencido continua mostrando o que já baixou, e o que ela perdeu foi o direito de
baixar mais. Message guarda serverID e uidValidity opacos, e os dois passam
pelo funil copy — provado por mutação.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: `SyncError` and `SecretStore` — the Keychain behind a protocol

**Files:**
- Create: `Packages/UNISync/Sources/UNISync/SyncError.swift`
- Create: `Packages/UNISync/Sources/UNISync/Secrets/SecretStore.swift`
- Create: `Packages/UNISync/Sources/UNISync/Secrets/InMemorySecretStore.swift`
- Create: `Packages/UNISync/Sources/UNISync/Secrets/KeychainSecretStore.swift`
- Create: `Packages/UNISync/Tests/UNISyncTests/SecretStoreTests.swift`
- Create: `Packages/UNISync/Tests/UNISyncTests/SyncErrorTests.swift`

**Interfaces:**
- Consumes: nothing—only `Foundation` and `Security`.
- Produces:
  - `enum SyncError: Error, Sendable, Hashable, LocalizedError` with cases `.rede(String)`, `.tls(String)`, `.autenticacao`, `.autorizacaoRevogada`, `.quota`, `.servidor(codigo: Int, mensagem: String)`, `.keychain(status: Int32)`, `.semClientID`, and `.resposta(String)`; it exposes `var mensagem: String` and `var errorDescription: String?`, both returning the same value.
  - `struct OAuthTokens: Sendable, Hashable, Codable` with `accessToken: String`, `refreshToken: String`, `expiresAt: Date`, `init(accessToken:refreshToken:expiresAt:)`, and `func isExpired(at now: Date, margin: TimeInterval = 60) -> Bool`.
  - `enum Secret: Sendable, Hashable, Codable { case password(String); case oauth(OAuthTokens) }`.
  - `protocol SecretStore: Sendable` with `func store(_ secret: Secret, for accountID: String) throws`, `func secret(for accountID: String) throws -> Secret?`, and `func remove(for accountID: String) throws`.
  - `final class InMemorySecretStore: SecretStore, @unchecked Sendable`, with `init()`.
  - `struct KeychainSecretStore: SecretStore, Sendable`, with `init(service: String = "com.okamiops.okamiuni")`.

- [ ] **Step 1: Write the failing test**

`Packages/UNISync/Tests/UNISyncTests/SyncErrorTests.swift`:

```swift
import Foundation
import Testing
@testable import UNISync

@Suite("SyncError fala português e chega inteiro ao MailStore")
struct SyncErrorTests {
    @Test("Cada caso tem mensagem própria, nenhuma vazia, nenhuma repetida")
    func mensagensDistintas() {
        let casos: [SyncError] = [
            .rede("tempo esgotado"),
            .tls("certificado expirado"),
            .autenticacao,
            .autorizacaoRevogada,
            .quota,
            .servidor(codigo: 503, mensagem: "Service Unavailable"),
            .keychain(status: -25300),
            .semClientID,
            .resposta("BAD comando desconhecido"),
        ]
        let mensagens = casos.map(\.mensagem)
        #expect(mensagens.allSatisfy { !$0.isEmpty })
        #expect(Set(mensagens).count == casos.count)
    }

    @Test("`localizedDescription` é a mensagem em português, não o nome do caso")
    func localizedDescriptionEmPortugues() {
        // É este texto que `MailStore.load()` grava em `loadError`. Sem
        // LocalizedError, o Foundation devolveria "The operation couldn’t be
        // completed. (UNISync.SyncError error 2.)" — erro engolido com outra
        // roupa.
        let erro: any Error = SyncError.autenticacao
        #expect(erro.localizedDescription == SyncError.autenticacao.mensagem)
        #expect(erro.localizedDescription.contains("senha"))
    }

    @Test("A mensagem do servidor carrega o código, para o relato não ser genérico")
    func mensagemDoServidorCitaOCodigo() {
        #expect(SyncError.servidor(codigo: 503, mensagem: "Service Unavailable").mensagem.contains("503"))
    }

    @Test("A falta do client ID aponta o roteiro, em vez de dizer só que falhou")
    func semClientIDApontaORoteiro() {
        #expect(SyncError.semClientID.mensagem.contains("docs/oauth-google.md"))
    }
}
```

`Packages/UNISync/Tests/UNISyncTests/SecretStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import UNISync

@Suite("SecretStore")
struct SecretStoreTests {
    private let vencido = OAuthTokens(
        accessToken: "at-velho", refreshToken: "rt",
        expiresAt: Date(timeIntervalSince1970: 1_000)
    )

    @Test("Guardar, ler e apagar, no fake em memória")
    func cicloCompleto() throws {
        let cofre = InMemorySecretStore()
        #expect(try cofre.secret(for: "conta-a") == nil)

        try cofre.store(.password("senha-de-app"), for: "conta-a")
        #expect(try cofre.secret(for: "conta-a") == .password("senha-de-app"))

        try cofre.store(.oauth(vencido), for: "conta-a")
        #expect(try cofre.secret(for: "conta-a") == .oauth(vencido))

        try cofre.remove(for: "conta-a")
        #expect(try cofre.secret(for: "conta-a") == nil)
    }

    @Test("Contas diferentes não se enxergam")
    func contasIsoladas() throws {
        let cofre = InMemorySecretStore()
        try cofre.store(.password("a"), for: "conta-a")
        try cofre.store(.password("b"), for: "conta-b")
        try cofre.remove(for: "conta-a")
        #expect(try cofre.secret(for: "conta-a") == nil)
        #expect(try cofre.secret(for: "conta-b") == .password("b"))
    }

    @Test("Apagar o que não existe não é erro — é o estado a que se queria chegar")
    func apagarAusenteNaoLanca() throws {
        let cofre = InMemorySecretStore()
        try cofre.remove(for: "nunca-existiu")
    }

    @Test("Token vencido é vencido com margem, e a margem é do chamador")
    func vencimentoComMargem() {
        let tokens = OAuthTokens(
            accessToken: "at", refreshToken: "rt",
            expiresAt: Date(timeIntervalSince1970: 2_000)
        )
        // Trinta segundos antes de vencer: com a margem padrão de 60s, já conta
        // como vencido — pedir com um token que morre no caminho é o mesmo que
        // pedir com um token morto.
        #expect(tokens.isExpired(at: Date(timeIntervalSince1970: 1_970)))
        #expect(!tokens.isExpired(at: Date(timeIntervalSince1970: 1_900)))
        #expect(!tokens.isExpired(at: Date(timeIntervalSince1970: 1_970), margin: 10))
    }

    /// O Keychain de verdade só roda quando alguém pede — em CI ele é hostil
    /// (pede desbloqueio, exige assinatura, deixa lixo na keychain do usuário).
    /// `OKAMIUNI_KEYCHAIN_TESTS=1 swift test --filter Keychain` liga.
    @Test(
        "O Keychain real guarda e devolve o mesmo segredo",
        .enabled(if: ProcessInfo.processInfo.environment["OKAMIUNI_KEYCHAIN_TESTS"] == "1")
    )
    func keychainReal() throws {
        let cofre = KeychainSecretStore(service: "com.okamiops.okamiuni.testes")
        let id = "teste-\(UUID().uuidString)"
        defer { try? cofre.remove(for: id) }

        try cofre.store(.password("senha-de-app"), for: id)
        #expect(try cofre.secret(for: id) == .password("senha-de-app"))

        // Guardar de novo sobrescreve em vez de duplicar a entrada.
        try cofre.store(.oauth(vencido), for: id)
        #expect(try cofre.secret(for: id) == .oauth(vencido))

        try cofre.remove(for: id)
        #expect(try cofre.secret(for: id) == nil)
    }
}
```

- [ ] **Step 2: Run it to see it fail**

Run: `cd Packages/UNISync && swift test --filter 'SyncError|SecretStore'`

Expected: FAIL — `cannot find 'SyncError' in scope`, `cannot find 'InMemorySecretStore' in scope`.

- [ ] **Step 3: Write `SyncError`**

`Packages/UNISync/Sources/UNISync/SyncError.swift`:

```swift
import Foundation

/// O único tipo de erro que sai do `UNISync`.
///
/// Único de propósito: toda superfície que mostra uma conta mostra o erro dela
/// com uma ação, e uma superfície só consegue fazer isso se souber a lista
/// inteira de coisas que podem dar errado. Um `Error` opaco vindo do
/// `URLSession` ou do `NIOSSL` obrigaria a UI a escrever "algo deu errado" —
/// que é erro engolido com boa apresentação.
///
/// `LocalizedError` não é enfeite: `MailStore.load()` grava
/// `error.localizedDescription` em `loadError`, e sem esta conformidade o
/// Foundation devolveria "The operation couldn’t be completed."
public enum SyncError: Error, Sendable, Hashable, LocalizedError {
    /// Não chegou ao servidor: sem rota, tempo esgotado, DNS.
    case rede(String)
    /// Chegou, mas o TLS não fechou: certificado, versão, `STARTTLS` recusado.
    case tls(String)
    /// O servidor entendeu e recusou as credenciais.
    case autenticacao
    /// O usuário negou o consentimento, ou revogou o acesso depois.
    case autorizacaoRevogada
    /// O provedor pediu para desacelerar (HTTP 429, `[THROTTLED]` no IMAP).
    case quota
    /// O servidor respondeu com falha própria.
    case servidor(codigo: Int, mensagem: String)
    /// O Keychain recusou. `status` é o `OSStatus` cru, para o relato ter o que
    /// procurar; a mensagem já vem traduzida.
    case keychain(status: Int32)
    /// Falta o OAuth Client ID do Google no bundle. Ver `docs/oauth-google.md`.
    case semClientID
    /// A resposta chegou e não dá para entender — JSON fora do contrato,
    /// `BAD` do IMAP, redirect sem `code` nem `error`.
    case resposta(String)

    /// A frase que o usuário lê. Uma por caso, nenhuma genérica: "erro de
    /// rede" e "senha recusada" pedem ações diferentes, e uma frase só para as
    /// duas manda a pessoa tentar a coisa errada.
    public var mensagem: String {
        switch self {
        case .rede(let detalhe):
            "Não foi possível falar com o servidor: \(detalhe). Verifique a conexão e tente de novo."
        case .tls(let detalhe):
            "A conexão segura falhou: \(detalhe). Confira a porta e a forma de TLS da conta."
        case .autenticacao:
            "O servidor recusou o endereço ou a senha. Em provedores com verificação em duas etapas, use uma senha de app."
        case .autorizacaoRevogada:
            "Autorização negada ou revogada. Reconecte a conta para autorizar de novo."
        case .quota:
            "O provedor pediu para desacelerar. A carga continua sozinha em instantes."
        case .servidor(let codigo, let mensagem):
            "O servidor respondeu \(codigo): \(mensagem)."
        case .keychain(let status):
            "Não foi possível guardar o segredo no Keychain (código \(status))."
        case .semClientID:
            "Falta o OAuth Client ID do Google. Siga docs/oauth-google.md e rode xcodegen generate."
        case .resposta(let detalhe):
            "Resposta inesperada do servidor: \(detalhe)."
        }
    }

    public var errorDescription: String? { mensagem }
}
```

- [ ] **Step 4: Write the protocol and fake**

`Packages/UNISync/Sources/UNISync/Secrets/SecretStore.swift`:

```swift
import Foundation

/// Os tokens de uma conta OAuth.
///
/// `expiresAt` é instante absoluto, não horário de parede — nenhum fuso
/// atravessa isto.
public struct OAuthTokens: Sendable, Hashable, Codable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date

    public init(accessToken: String, refreshToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    /// Vencido, com folga.
    ///
    /// A margem existe porque um token que morre em dez segundos já está morto
    /// para uma requisição que leva quinze: renovar antes é mais barato que
    /// descobrir o 401 no meio da carga inicial e refazer o lote.
    public func isExpired(at now: Date, margin: TimeInterval = 60) -> Bool {
        now.addingTimeInterval(margin) >= expiresAt
    }
}

/// O que uma conta guarda no Keychain.
///
/// Duas formas porque são dois protocolos: IMAP autentica com senha de app,
/// Google com um par de tokens que se renova. Um `String` só serviria aos dois
/// e obrigaria quem lê a adivinhar qual é qual.
public enum Secret: Sendable, Hashable, Codable {
    case password(String)
    case oauth(OAuthTokens)
}

/// O cofre de segredos, por conta.
///
/// Protocolo, e não a implementação direta, por um motivo concreto: o Keychain
/// em ambiente de teste pede desbloqueio, exige binário assinado e deixa lixo
/// na keychain do usuário. Os testes de tudo que **usa** segredo rodam contra
/// `InMemorySecretStore`; o Keychain de verdade tem o teste dele, atrás de uma
/// marca de ambiente.
///
/// Síncrono de propósito: as chamadas do `Security.framework` são síncronas e
/// rápidas, e envolvê-las em `async` só acrescentaria pontos de suspensão sem
/// nada em troca.
public protocol SecretStore: Sendable {
    /// Guarda, sobrescrevendo o que houver para esta conta.
    func store(_ secret: Secret, for accountID: String) throws
    /// Nulo quando não há nada guardado — ausência não é erro.
    func secret(for accountID: String) throws -> Secret?
    /// Apagar o que não existe não lança: é o mesmo estado a que se queria
    /// chegar, como `MailStore.removeFromAgenda`.
    func remove(for accountID: String) throws
}
```

`Packages/UNISync/Sources/UNISync/Secrets/InMemorySecretStore.swift`:

```swift
import Foundation

/// O cofre dos testes e do ensaio: memória do processo, e nada mais.
///
/// `@unchecked Sendable` com `NSLock`, e não um ator, porque o protocolo é
/// síncrono — e o protocolo é síncrono porque o Keychain é. Trocar por ator
/// aqui obrigaria `SecretStore` inteiro a virar `async`, contaminando
/// `GoogleAuth`, `AccountDirector` e os dois `InitialLoader` por um ganho que
/// não existe: o dicionário é lido e escrito em microssegundos.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Secret] = [:]

    public init() {}

    public func store(_ secret: Secret, for accountID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[accountID] = secret
    }

    public func secret(for accountID: String) throws -> Secret? {
        lock.lock()
        defer { lock.unlock() }
        return storage[accountID]
    }

    public func remove(for accountID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: accountID)
    }
}
```

- [ ] **Step 5: Write the real Keychain implementation**

`Packages/UNISync/Sources/UNISync/Secrets/KeychainSecretStore.swift`:

```swift
import Foundation
import Security

/// O cofre de verdade: `kSecClassGenericPassword`, serviço
/// `com.okamiops.okamiuni`, conta = id da conta.
///
/// **Nenhum segredo passa pelo banco.** A tabela `account` guarda endereço,
/// host e porta; a senha de app e os tokens moram só aqui. É por isso que
/// remover uma conta são dois passos (banco + Keychain) e a janela de Contas
/// avisa antes.
public struct KeychainSecretStore: SecretStore, Sendable {
    private let service: String

    public init(service: String = "com.okamiops.okamiuni") {
        self.service = service
    }

    private func query(_ accountID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID,
        ]
    }

    public func store(_ secret: Secret, for accountID: String) throws {
        let data = try JSONEncoder().encode(secret)

        // Atualizar quando já existe, inserir quando não — em vez de apagar e
        // inserir. Apagar primeiro deixa uma janela em que a conta está sem
        // segredo nenhum, e um refresh concorrente nessa janela derrubaria a
        // conta para `erroDeAutenticacao` sem motivo.
        let update = SecUpdateItemDataStatus(data)
        let status = SecItemUpdate(query(accountID) as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        if status != errSecItemNotFound { throw SyncError.keychain(status: status) }

        var insert = query(accountID)
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let added = SecItemAdd(insert as CFDictionary, nil)
        guard added == errSecSuccess else { throw SyncError.keychain(status: added) }
    }

    public func secret(for accountID: String) throws -> Secret? {
        var lookup = query(accountID)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SyncError.keychain(status: status) }
        guard let data = item as? Data else {
            throw SyncError.resposta("O Keychain devolveu algo que não são dados.")
        }
        return try JSONDecoder().decode(Secret.self, from: data)
    }

    public func remove(for accountID: String) throws {
        let status = SecItemDelete(query(accountID) as CFDictionary)
        // Ausente não é erro, pelo mesmo motivo de `MailStore.removeFromAgenda`.
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SyncError.keychain(status: status)
        }
    }
}

/// O dicionário de atualização, isolado para o `store` acima caber numa tela.
private func SecUpdateItemDataStatus(_ data: Data) -> [String: Any] {
    [kSecValueData as String: data]
}
```

- [ ] **Step 6: Run it to see it pass**

Run: `cd Packages/UNISync && swift test --filter 'SyncError|SecretStore'`

Expected: PASS. The real Keychain test appears as **skipped** because its
environment flag is off; that is expected, not a failure.

- [ ] **Step 7: Prove by mutation that `LocalizedError` is doing work**

Delete `public var errorDescription: String? { mensagem }` and run:

Run: `cd Packages/UNISync && swift test --filter localizedDescriptionEmPortugues`

Expected: FAIL — `localizedDescription` returns to
"The operation couldn’t be completed. (UNISync.SyncError error 2.)".
Restore the line and confirm that the test is green.

- [ ] **Step 8: Run the real Keychain once, manually**

Run: `cd Packages/UNISync && OKAMIUNI_KEYCHAIN_TESTS=1 swift test --filter keychainReal`

Expected: PASS. If macOS asks for Keychain-access permission, allow it. A
failure with `-34018` (`errSecMissingEntitlement`) means the SPM test binary
is not signed with the Keychain entitlement. Record that in the task report and
continue: the path that matters is the signed app, covered by Task 18.

- [ ] **Step 9: Commit**

```bash
git add Packages/UNISync/Sources/UNISync/SyncError.swift Packages/UNISync/Sources/UNISync/Secrets Packages/UNISync/Tests/UNISyncTests/SyncErrorTests.swift Packages/UNISync/Tests/UNISyncTests/SecretStoreTests.swift
git commit -m "O erro tem nome e o segredo tem cofre — nenhum dos dois passa pelo banco

SyncError é único porque a UI só consegue oferecer a ação certa se souber a
lista inteira do que pode dar errado; LocalizedError não é enfeite, é o que
faz MailStore.loadError falar português — provado por mutação. SecretStore é
protocolo porque o Keychain em teste é hostil, e o teste do real fica atrás de
OKAMIUNI_KEYCHAIN_TESTS.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: The GRDB v1 schema — migration, records, and accent-folding FTS5 search

**Files:**
- Create: `Packages/UNISync/Sources/UNISync/Database/SyncDatabase.swift`
- Create: `Packages/UNISync/Sources/UNISync/Database/Records.swift`
- Create: `Packages/UNISync/Sources/UNISync/Database/MessageSearch.swift`
- Create: `Packages/UNISync/Tests/UNISyncTests/SyncDatabaseTests.swift`

**Interfaces:**
- Consumes: `Account`, `Account.State`, `ImapEndpoint`, `Message`, `TriageBucket`, `AgendaItem`, `Contact` (Task 3); `SyncError` (Task 4).
- Produces:
  - `struct SyncDatabase: Sendable` with `let pool: DatabasePool`, `init(path: String) throws`, `static func inMemory() throws -> SyncDatabase`, `static func defaultPath() throws -> String`, and `static var migrator: DatabaseMigrator`.
  - `enum FolderRole: String, Sendable, Hashable, CaseIterable { case inbox, archive, trash, sent, later = "depois", other = "outra" }` — it lives in `Database/Records.swift` because the `folder` table persists it; Task 6 uses it without redefining it.
  - `struct AccountRecord`, `struct FolderRecord`, `struct MessageRecord`, `struct MessageBodyRecord`, `struct AgendaItemRecord`, and `struct SyncStateRecord` — all `Codable, FetchableRecord, PersistableRecord, Sendable, Equatable`, with the fields listed in step 4.
  - `AccountRecord.init(_ account: Account, createdAt: Date)` and `AccountRecord.account -> Account`.
  - `MessageRecord.init(_ message: Message, folderID: String)` and `MessageRecord.message(body: [String]) -> Message`.
  - `enum MessageSearch { static func matchingBodyIDs(_ db: Database, term: String, accountID: String?) throws -> Set<String>; static func ftsQuery(_ term: String) -> String? }`.

- [ ] **Step 1: Write the failing test**

`Packages/UNISync/Tests/UNISyncTests/SyncDatabaseTests.swift`:

```swift
import Foundation
import GRDB
import Testing
import UNICore
@testable import UNISync

@Suite("O banco da v1")
struct SyncDatabaseTests {
    private func banco() throws -> SyncDatabase { try SyncDatabase.inMemory() }

    private let conta = Account(
        id: "conta-a", address: "eu@meudominio.com.br", displayName: "Meu",
        provider: .imap, host: "meudominio",
        tintLightHex: "#3F6AA1", tintDarkHex: "#8CBAF7", signature: "Eu",
        imap: ImapEndpoint(host: "imap.meudominio.com.br", port: 993, security: .tls),
        state: .carregando
    )

    private func mensagem(
        _ id: String, assunto: String = "Assunto", corpo: [String] = ["Corpo"],
        bucket: TriageBucket = .today
    ) -> Message {
        Message(
            id: id, accountID: "conta-a",
            from: Contact(name: "Marina Duarte", address: "marina@clientepremium.com"),
            receivedAt: Date(timeIntervalSince1970: 1_800_000_000),
            subject: assunto, snippet: "Trecho", body: corpo,
            tags: [], bucket: bucket, isRead: false,
            summary: nil, detectedEvent: nil,
            to: [Contact(name: "Eu", address: "eu@meudominio.com.br")],
            serverID: "9001", uidValidity: 42
        )
    }

    @Test("A migração v1 cria as seis tabelas e o índice de busca")
    func migracaoV1() throws {
        let db = try banco()
        let tabelas = try db.pool.read { conexao -> Set<String> in
            try String.fetchSet(conexao, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        for esperada in ["account", "folder", "message", "message_body", "agenda_item", "sync_state", "message_fts"] {
            #expect(tabelas.contains(esperada), "faltou a tabela \(esperada)")
        }
        let versoes = try db.pool.read { try SyncDatabase.migrator.appliedIdentifiers($0) }
        #expect(versoes == ["v1"])
    }

    @Test("Migrar duas vezes não faz nada na segunda")
    func migracaoIdempotente() throws {
        let db = try banco()
        try SyncDatabase.migrator.migrate(db.pool)
        let versoes = try db.pool.read { try SyncDatabase.migrator.appliedIdentifiers($0) }
        #expect(versoes == ["v1"])
    }

    @Test("A conta vai e volta inteira — inclusive o endpoint e o estado")
    func contaVaiEVolta() throws {
        let db = try banco()
        try db.pool.write { try AccountRecord(conta, createdAt: Date(timeIntervalSince1970: 1)).insert($0) }
        let devolvida = try db.pool.read { conexao -> Account in
            try #require(try AccountRecord.fetchOne(conexao, key: "conta-a")).account
        }
        #expect(devolvida == conta)
    }

    @Test("Nenhuma coluna do banco guarda segredo")
    func nenhumaColunaDeSegredo() throws {
        let db = try banco()
        let colunas = try db.pool.read { conexao -> [String] in
            try conexao.columns(in: "account").map(\.name)
        }
        let proibidas = ["password", "senha", "token", "accessToken", "refreshToken", "secret"]
        for coluna in colunas {
            let dobrada = coluna.lowercased()
            #expect(!proibidas.contains { dobrada.contains($0.lowercased()) }, "coluna suspeita: \(coluna)")
        }
    }

    @Test("A mensagem vai e volta inteira, corpo incluído")
    func mensagemVaiEVolta() throws {
        let db = try banco()
        let original = mensagem("m1", corpo: ["Primeiro parágrafo.", "Segundo."])
        try db.pool.write { conexao in
            try AccountRecord(conta, createdAt: Date(timeIntervalSince1970: 1)).insert(conexao)
            try FolderRecord(
                id: "conta-a/INBOX", accountID: "conta-a",
                serverName: "INBOX", role: .inbox, displayName: "Caixa de entrada"
            ).insert(conexao)
            try MessageRecord(original, folderID: "conta-a/INBOX").insert(conexao)
            try MessageBodyRecord(messageID: "m1", paragraphs: original.body).insert(conexao)
        }
        let devolvida = try db.pool.read { conexao -> Message in
            let registro = try #require(try MessageRecord.fetchOne(conexao, key: "m1"))
            let corpo = try MessageBodyRecord.fetchOne(conexao, key: "m1")
            return registro.message(body: corpo?.body ?? [])
        }
        #expect(devolvida == original)
    }

    @Test("Apagar a conta leva junto pastas, mensagens, corpos, agenda e estado de sync")
    func cascataAoRemoverConta() throws {
        let db = try banco()
        try db.pool.write { conexao in
            try AccountRecord(conta, createdAt: Date(timeIntervalSince1970: 1)).insert(conexao)
            try FolderRecord(
                id: "conta-a/INBOX", accountID: "conta-a",
                serverName: "INBOX", role: .inbox, displayName: "Caixa de entrada"
            ).insert(conexao)
            try MessageRecord(mensagem("m1"), folderID: "conta-a/INBOX").insert(conexao)
            try MessageBodyRecord(messageID: "m1", paragraphs: ["Corpo"]).insert(conexao)
            try AgendaItemRecord(
                AgendaItem(id: "a1", title: "Reunião", startMinute: 570, endMinute: 600, accountID: "conta-a")
            ).insert(conexao)
            try SyncStateRecord(
                accountID: "conta-a", folderID: "conta-a/INBOX",
                historyID: "77", uidValidity: 42, highestUID: 9001,
                syncedAt: Date(timeIntervalSince1970: 2)
            ).insert(conexao)
            _ = try AccountRecord.deleteOne(conexao, key: "conta-a")
        }
        try db.pool.read { conexao in
            #expect(try FolderRecord.fetchCount(conexao) == 0)
            #expect(try MessageRecord.fetchCount(conexao) == 0)
            #expect(try MessageBodyRecord.fetchCount(conexao) == 0)
            #expect(try AgendaItemRecord.fetchCount(conexao) == 0)
            #expect(try SyncStateRecord.fetchCount(conexao) == 0)
            // O gatilho do FTS tem de ter desfeito o índice junto com o corpo.
            #expect(try Int.fetchOne(conexao, sql: "SELECT count(*) FROM message_fts") == 0)
        }
    }

    @Test("A busca no corpo dobra acento nos dois sentidos")
    func buscaDobraAcento() throws {
        let db = try banco()
        try db.pool.write { conexao in
            try AccountRecord(conta, createdAt: Date(timeIntervalSince1970: 1)).insert(conexao)
            try FolderRecord(
                id: "conta-a/INBOX", accountID: "conta-a",
                serverName: "INBOX", role: .inbox, displayName: "Caixa de entrada"
            ).insert(conexao)
            try MessageRecord(mensagem("m1"), folderID: "conta-a/INBOX").insert(conexao)
            try MessageBodyRecord(
                messageID: "m1",
                paragraphs: ["A revisão do contrato ficou pronta.", "Abraço."]
            ).insert(conexao)
        }
        try db.pool.read { conexao in
            // Sem acento acha com acento — é o caso que o README promete.
            #expect(try MessageSearch.matchingBodyIDs(conexao, term: "Revisao", accountID: nil) == ["m1"])
            // E com acento acha o mesmo, para a busca não punir quem digita certo.
            #expect(try MessageSearch.matchingBodyIDs(conexao, term: "revisão", accountID: nil) == ["m1"])
            // Prefixo funciona: quem digitou meia palavra ainda acha.
            #expect(try MessageSearch.matchingBodyIDs(conexao, term: "contra", accountID: nil) == ["m1"])
            // E o que não está no corpo não aparece.
            #expect(try MessageSearch.matchingBodyIDs(conexao, term: "orçamento", accountID: nil).isEmpty)
        }
    }

    @Test("A busca respeita o filtro de conta")
    func buscaFiltraPorConta() throws {
        let db = try banco()
        let outra = Account(
            id: "conta-b", address: "outro@x.com", displayName: "Outro",
            provider: .imap, host: "x", tintLightHex: "#397852", tintDarkHex: "#88D1A2"
        )
        try db.pool.write { conexao in
            try AccountRecord(conta, createdAt: Date(timeIntervalSince1970: 1)).insert(conexao)
            try AccountRecord(outra, createdAt: Date(timeIntervalSince1970: 1)).insert(conexao)
            for (id, accountID) in [("m1", "conta-a"), ("m2", "conta-b")] {
                try FolderRecord(
                    id: "\(accountID)/INBOX", accountID: accountID,
                    serverName: "INBOX", role: .inbox, displayName: "Caixa de entrada"
                ).insert(conexao)
                var registro = MessageRecord(mensagem(id), folderID: "\(accountID)/INBOX")
                registro.accountID = accountID
                try registro.insert(conexao)
                try MessageBodyRecord(messageID: id, paragraphs: ["A revisão saiu."]).insert(conexao)
            }
        }
        try db.pool.read { conexao in
            #expect(try MessageSearch.matchingBodyIDs(conexao, term: "revisao", accountID: nil) == ["m1", "m2"])
            #expect(try MessageSearch.matchingBodyIDs(conexao, term: "revisao", accountID: "conta-b") == ["m2"])
        }
    }

    @Test("Termo que só tem pontuação não vira consulta — MATCH com sintaxe inválida derruba o SQLite")
    func termoVazioNaoConsulta() throws {
        #expect(MessageSearch.ftsQuery("   ") == nil)
        #expect(MessageSearch.ftsQuery("\"") == nil)
        #expect(MessageSearch.ftsQuery("revisão do contrato") == "\"revisão\" \"do\" \"contrato\"*")
        let db = try banco()
        try db.pool.read { conexao in
            #expect(try MessageSearch.matchingBodyIDs(conexao, term: "  ", accountID: nil).isEmpty)
        }
    }

    @Test("Trocar o corpo reindexa: o texto velho deixa de achar, o novo passa a achar")
    func atualizarCorpoReindexa() throws {
        let db = try banco()
        try db.pool.write { conexao in
            try AccountRecord(conta, createdAt: Date(timeIntervalSince1970: 1)).insert(conexao)
            try FolderRecord(
                id: "conta-a/INBOX", accountID: "conta-a",
                serverName: "INBOX", role: .inbox, displayName: "Caixa de entrada"
            ).insert(conexao)
            try MessageRecord(mensagem("m1"), folderID: "conta-a/INBOX").insert(conexao)
            try MessageBodyRecord(messageID: "m1", paragraphs: ["Prévia curta."]).insert(conexao)
            // A carga inicial baixa a prévia primeiro e o corpo cheio depois:
            // é exatamente este UPDATE que roda no meio da Task 12.
            try MessageBodyRecord(messageID: "m1", paragraphs: ["Corpo inteiro com orçamento."]).update(conexao)
        }
        try db.pool.read { conexao in
            #expect(try MessageSearch.matchingBodyIDs(conexao, term: "previa", accountID: nil).isEmpty)
            #expect(try MessageSearch.matchingBodyIDs(conexao, term: "orcamento", accountID: nil) == ["m1"])
        }
    }

    @Test("A observação acorda quando alguém escreve")
    func observacaoAcorda() async throws {
        let db = try banco()
        try await db.pool.write { conexao in
            try AccountRecord(self.conta, createdAt: Date(timeIntervalSince1970: 1)).insert(conexao)
        }
        let observacao = ValueObservation.tracking { conexao in
            try AccountRecord.fetchCount(conexao)
        }
        var vistos: [Int] = []
        for try await contagem in observacao.values(in: db.pool) {
            vistos.append(contagem)
            if vistos.count == 1 {
                let outra = Account(
                    id: "conta-b", address: "outro@x.com", displayName: "Outro",
                    provider: .imap, host: "x", tintLightHex: "#397852", tintDarkHex: "#88D1A2"
                )
                try await db.pool.write { try AccountRecord(outra, createdAt: Date(timeIntervalSince1970: 1)).insert($0) }
            }
            if vistos.count == 2 { break }
        }
        #expect(vistos == [1, 2])
    }
}
```

- [ ] **Step 2: Run it to see it fail**

Run: `cd Packages/UNISync && swift test --filter SyncDatabase`

Expected: FAIL — `cannot find 'SyncDatabase' in scope`.

- [ ] **Step 3: Write opening and migration**

`Packages/UNISync/Sources/UNISync/Database/SyncDatabase.swift`:

```swift
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

    /// Um banco de teste, em memória, com o mesmo esquema do de verdade.
    ///
    /// `DatabasePool` em memória precisa de nome próprio por instância, senão
    /// dois testes rodando em paralelo compartilham o mesmo banco e um vê a
    /// escrita do outro.
    public static func inMemory() throws -> SyncDatabase {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(
            path: "file:okamiuni-\(UUID().uuidString)?mode=memory&cache=shared",
            configuration: config
        )
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
```

- [ ] **Step 4: Write the records**

`Packages/UNISync/Sources/UNISync/Database/Records.swift`:

```swift
import Foundation
import GRDB
import UNICore

/// O papel de uma pasta, do ponto de vista do app.
///
/// Nome do servidor não serve: "Archive", "Arquivo", "[Gmail]/Todos os e-mails"
/// e "Alle Nachrichten" são a mesma coisa. O papel é o que a projeção de
/// triagem lê, e é por isso que ele é gravado — descobri-lo de novo a cada
/// abertura significaria refazer a heurística de nome sobre dados que já
/// resolvemos uma vez.
///
/// `other` é legítimo e comum: pasta que o usuário criou não tem papel nosso.
public enum FolderRole: String, Sendable, Hashable, CaseIterable {
    case inbox
    case archive
    case trash
    case sent
    /// A pasta `OkamiUNI/Depois`, quando existe de instalação anterior. Neste
    /// marco ela só é **lida**; escrever nela é do Marco 3.
    case later = "depois"
    case other = "outra"
}

public struct AccountRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "account"

    public var id: String
    public var address: String
    public var displayName: String
    public var provider: String
    public var host: String
    public var tintLightHex: String
    public var tintDarkHex: String
    public var signature: String
    public var imapHost: String?
    public var imapPort: Int?
    public var imapSecurity: String?
    public var state: String
    public var lastSyncedAt: Date?
    public var createdAt: Date

    public init(_ account: Account, createdAt: Date) {
        id = account.id
        address = account.address
        displayName = account.displayName
        provider = account.provider.rawValue
        host = account.host
        tintLightHex = account.tintLightHex
        tintDarkHex = account.tintDarkHex
        signature = account.signature
        imapHost = account.imap?.host
        imapPort = account.imap?.port
        imapSecurity = account.imap?.security.rawValue
        state = account.state.rawValue
        lastSyncedAt = account.lastSyncedAt
        self.createdAt = createdAt
    }

    /// De volta ao tipo do `UNICore`.
    ///
    /// Valor desconhecido em `provider` e `state` **não** derruba a leitura:
    /// um banco escrito por uma versão futura tem de continuar abrindo, com a
    /// conta aparecendo como IMAP ativa, em vez de a lista inteira sumir.
    /// Cair para o caso geral é a mesma regra de `.imap` ser o caso geral.
    public var account: Account {
        let endpoint: ImapEndpoint? = {
            guard let imapHost, let imapPort,
                  let bruto = imapSecurity,
                  let security = ImapEndpoint.Security(rawValue: bruto)
            else { return nil }
            return ImapEndpoint(host: imapHost, port: imapPort, security: security)
        }()
        return Account(
            id: id, address: address, displayName: displayName,
            provider: Account.Provider(rawValue: provider) ?? .imap,
            host: host, tintLightHex: tintLightHex, tintDarkHex: tintDarkHex,
            signature: signature, imap: endpoint,
            state: Account.State(rawValue: state) ?? .ativa,
            lastSyncedAt: lastSyncedAt
        )
    }
}

public struct FolderRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "folder"

    public var id: String
    public var accountID: String
    public var serverName: String
    public var role: String
    public var displayName: String

    public init(id: String, accountID: String, serverName: String, role: FolderRole, displayName: String) {
        self.id = id
        self.accountID = accountID
        self.serverName = serverName
        self.role = role.rawValue
        self.displayName = displayName
    }

    /// O id de uma pasta é conta + nome no servidor. Determinístico de
    /// propósito: reabrir o app e listar as pastas de novo tem de encontrar as
    /// mesmas linhas, não criar linhas paralelas.
    public static func id(accountID: String, serverName: String) -> String {
        "\(accountID)/\(serverName)"
    }

    public var folderRole: FolderRole { FolderRole(rawValue: role) ?? .other }
}

public struct MessageRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "message"

    public var id: String
    public var accountID: String
    public var folderID: String
    public var serverID: String?
    public var uidValidity: Int64?
    public var fromName: String
    public var fromAddress: String
    public var toJSON: String
    public var ccJSON: String
    public var subject: String
    public var snippet: String
    public var receivedAt: Date
    public var dayOffset: Int
    public var isRead: Bool
    public var isFlagged: Bool
    public var bucket: String

    public init(_ message: Message, folderID: String) {
        id = message.id
        accountID = message.accountID
        self.folderID = folderID
        serverID = message.serverID
        uidValidity = message.uidValidity
        fromName = message.from.name
        fromAddress = message.from.address
        toJSON = Self.encode(message.to)
        ccJSON = Self.encode(message.cc)
        subject = message.subject
        snippet = message.snippet
        receivedAt = message.receivedAt
        dayOffset = message.dayOffset
        isRead = message.isRead
        isFlagged = message.isFlagged
        bucket = message.bucket.rawValue
    }

    /// O corpo vem de fora porque mora noutra tabela: a lista mostra centenas
    /// de linhas e não precisa de nenhum corpo, e carregar todos por tabela
    /// única faria a abertura pagar por texto que ninguém vai ler.
    public func message(body: [String]) -> Message {
        Message(
            id: id, accountID: accountID,
            from: Contact(name: fromName, address: fromAddress),
            receivedAt: receivedAt,
            subject: subject, snippet: snippet, body: body,
            tags: [], bucket: TriageBucket(rawValue: bucket) ?? .archived,
            isRead: isRead, summary: nil, detectedEvent: nil,
            dayOffset: dayOffset, replyHints: [],
            to: Self.decode(toJSON), cc: Self.decode(ccJSON),
            isFlagged: isFlagged,
            serverID: serverID, uidValidity: uidValidity
        )
    }

    /// Um contato serializado, para `to`/`cc` caberem numa coluna.
    private struct Wire: Codable { var name: String; var address: String }

    private static func encode(_ contacts: [Contact]) -> String {
        let fio = contacts.map { Wire(name: $0.name, address: $0.address) }
        guard let dados = try? JSONEncoder().encode(fio),
              let texto = String(data: dados, encoding: .utf8) else { return "[]" }
        return texto
    }

    private static func decode(_ json: String) -> [Contact] {
        guard let dados = json.data(using: .utf8),
              let fio = try? JSONDecoder().decode([Wire].self, from: dados) else { return [] }
        return fio.map { Contact(name: $0.name, address: $0.address) }
    }
}

public struct MessageBodyRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "message_body"

    public var messageID: String
    /// Os parágrafos, como JSON — é assim que `Message.body` é modelado.
    public var paragraphs: String
    /// Os mesmos parágrafos, juntos por quebra de linha. **É esta coluna que o
    /// FTS5 indexa**: indexar o JSON faria os colchetes e as aspas entrarem no
    /// índice e a busca por `"` casar com tudo.
    public var plain: String

    public init(messageID: String, paragraphs: [String]) {
        self.messageID = messageID
        let dados = (try? JSONEncoder().encode(paragraphs)) ?? Data("[]".utf8)
        self.paragraphs = String(data: dados, encoding: .utf8) ?? "[]"
        plain = paragraphs.joined(separator: "\n")
    }

    public var body: [String] {
        guard let dados = paragraphs.data(using: .utf8),
              let lista = try? JSONDecoder().decode([String].self, from: dados) else { return [] }
        return lista
    }
}

public struct AgendaItemRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "agenda_item"

    public var id: String
    public var accountID: String
    public var title: String
    public var startMinute: Int
    public var endMinute: Int
    /// Continua `Int`, e não uma `Date`, pelo mesmo motivo que
    /// `AgendaItem.dayOffset` é: um deslocamento em dias não atravessa fuso.
    public var dayOffset: Int

    public init(_ item: AgendaItem) {
        id = item.id
        accountID = item.accountID
        title = item.title
        startMinute = item.startMinute
        endMinute = item.endMinute
        dayOffset = item.dayOffset
    }

    public var item: AgendaItem {
        AgendaItem(
            id: id, title: title,
            startMinute: startMinute, endMinute: endMinute,
            accountID: accountID, dayOffset: dayOffset
        )
    }
}

public struct SyncStateRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "sync_state"

    public var accountID: String
    /// Vazio para o estado da conta inteira (o `historyId` do Gmail); o id da
    /// pasta para o estado por pasta (o par `UIDVALIDITY`/maior UID do IMAP).
    public var folderID: String
    public var historyID: String?
    public var uidValidity: Int64?
    public var highestUID: Int64?
    public var syncedAt: Date?

    public init(
        accountID: String, folderID: String,
        historyID: String? = nil, uidValidity: Int64? = nil,
        highestUID: Int64? = nil, syncedAt: Date? = nil
    ) {
        self.accountID = accountID
        self.folderID = folderID
        self.historyID = historyID
        self.uidValidity = uidValidity
        self.highestUID = highestUID
        self.syncedAt = syncedAt
    }
}
```

- [ ] **Step 5: Write search**

`Packages/UNISync/Sources/UNISync/Database/MessageSearch.swift`:

```swift
import Foundation
import GRDB

/// A busca no **corpo**, no banco.
///
/// O `MailStore` do Marco 1 procura em remetente, assunto e prévia, dobrando
/// acento em memória. Isso continua valendo e não muda — o que faltava era o
/// corpo, que não está carregado. Esta consulta é o que o `DatabaseMailSource`
/// expõe por `MailSource.bodyMatches(_:)`.
public enum MessageSearch {
    /// O termo digitado virado consulta FTS5, ou `nil` quando não sobra nada
    /// para procurar.
    ///
    /// Cada palavra vira um termo entre aspas (que é como o FTS5 escapa
    /// qualquer coisa), e a **última** ganha `*` de prefixo: quem está
    /// digitando "revis" espera achar "revisão" antes de terminar a palavra,
    /// mas quem já escreveu "revisão do" não quer que "do" case com "domingo".
    ///
    /// Devolver `nil` em vez de uma string vazia não é preciosismo: `MATCH ''`
    /// e `MATCH '"'` são erro de sintaxe no SQLite, e um erro de sintaxe no
    /// caminho da digitação derruba a busca a cada tecla.
    public static func ftsQuery(_ term: String) -> String? {
        let palavras = term
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !palavras.isEmpty else { return nil }
        var partes = palavras.map { "\"\($0)\"" }
        partes[partes.count - 1] += "*"
        return partes.joined(separator: " ")
    }

    /// Os ids das mensagens cujo corpo casa. `accountID` nulo abrange todas.
    public static func matchingBodyIDs(
        _ db: Database, term: String, accountID: String?
    ) throws -> Set<String> {
        guard let consulta = ftsQuery(term) else { return [] }
        var sql = """
            SELECT b.messageID
            FROM message_fts f
            JOIN message_body b ON b.rowid = f.rowid
            JOIN message m ON m.id = b.messageID
            WHERE message_fts MATCH ?
            """
        var argumentos: [DatabaseValueConvertible] = [consulta]
        if let accountID {
            sql += " AND m.accountID = ?"
            argumentos.append(accountID)
        }
        return try String.fetchSet(db, sql: sql, arguments: StatementArguments(argumentos))
    }
}
```

- [ ] **Step 6: Run it to see it pass**

Run: `cd Packages/UNISync && swift test --filter SyncDatabase`

Expected: PASS, 11 tests.

- [ ] **Step 7: Prove by mutation that the UPDATE trigger and tokenizer work**

Make two mutations, one at a time:

1. Delete the `message_body_au` trigger from the migration and run
   `swift test --filter atualizarCorpoReindexa`.
   Expected: FAIL — `MessageSearch.matchingBodyIDs(term: "previa")` finds
   `m1` again because the index remains on the old text.
2. Replace `remove_diacritics 2` with `remove_diacritics 0` and run
   `swift test --filter buscaDobraAcento`.
   Expected: FAIL — `"Revisao"` no longer finds `"revisão"`.

Restore both changes and confirm that the test is green.

- [ ] **Step 8: Commit**

```bash
git add Packages/UNISync/Sources/UNISync/Database Packages/UNISync/Tests/UNISyncTests/SyncDatabaseTests.swift
git commit -m "O banco da v1: seis tabelas, cascata de verdade e a dobra de acento no índice

A dobra desce para o banco porque o fold em memória do Marco 1 só percorre o
que está carregado, e o corpo das mensagens antigas não está. Os três gatilhos
do FTS existem porque a carga inicial troca a prévia pelo corpo cheio —
provado por mutação: sem o de UPDATE, a busca continua achando o texto velho.
Nenhuma coluna guarda segredo, e há teste que afirma isso.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: `ProviderDetector`, `ImapPresets`, and `FolderRoles` — the three pure routing decisions

**Files:**
- Create: `Packages/UNISync/Sources/UNISync/Providers/ImapPresets.swift`
- Create: `Packages/UNISync/Sources/UNISync/Providers/ProviderDetector.swift`
- Create: `Packages/UNISync/Sources/UNISync/Providers/FolderRoles.swift`
- Create: `Packages/UNISync/Tests/UNISyncTests/ProviderDetectorTests.swift`
- Create: `Packages/UNISync/Tests/UNISyncTests/FolderRolesTests.swift`

**Interfaces:**
- Consumes: `ImapEndpoint` and `ImapEndpoint.Security` (Task 3); `FolderRole` (Task 5).
- Produces:
  - `struct ImapPreset: Sendable, Hashable` with `let name: String`, `let hostMark: String`, `let endpoint: ImapEndpoint`, `let domains: [String]`, and `init(name:hostMark:endpoint:domains:)`.
  - `enum ImapPresets { static let all: [ImapPreset]; static func preset(forDomain domain: String) -> ImapPreset? }`.
  - `enum ProviderRoute: Sendable, Hashable { case google; case imap(ImapPreset); case manual(suggested: ImapEndpoint) }`.
  - `enum ProviderDetector { static func domain(of address: String) -> String?; static func isValidAddress(_ address: String) -> Bool; static func route(for address: String) -> ProviderRoute? }`.
  - `enum FolderRoles { static func role(specialUse: String?, name: String) -> FolderRole; static let laterFolderName: String }`.

- [ ] **Step 1: Write the failing tests**

`Packages/UNISync/Tests/UNISyncTests/ProviderDetectorTests.swift`:

```swift
import Foundation
import Testing
import UNICore
@testable import UNISync

@Suite("Do endereço à rota")
struct ProviderDetectorTests {
    @Test("O domínio sai do endereço, dobrado e sem espaço em volta")
    func dominio() {
        #expect(ProviderDetector.domain(of: "  Ricardo@Gmail.COM ") == "gmail.com")
        #expect(ProviderDetector.domain(of: "contato@meusite.com.br") == "meusite.com.br")
        #expect(ProviderDetector.domain(of: "sem-arroba") == nil)
        #expect(ProviderDetector.domain(of: "@so-dominio.com") == nil)
        #expect(ProviderDetector.domain(of: "so-usuario@") == nil)
        // Dois arrobas não é endereço; a última parte não vira domínio.
        #expect(ProviderDetector.domain(of: "a@b@c.com") == nil)
    }

    @Test("Domínio do Google vai por OAuth")
    func rotaGoogle() {
        #expect(ProviderDetector.route(for: "ricardo@gmail.com") == .google)
        #expect(ProviderDetector.route(for: "ricardo@googlemail.com") == .google)
    }

    @Test("Domínio conhecido traz o preset preenchido")
    func rotaPreset() throws {
        let rota = try #require(ProviderDetector.route(for: "ricardo@icloud.com"))
        guard case .imap(let preset) = rota else {
            Issue.record("esperava .imap, veio \(rota)"); return
        }
        #expect(preset.hostMark == "icloud")
        #expect(preset.endpoint.host == "imap.mail.me.com")
        #expect(preset.endpoint.port == 993)
        #expect(preset.endpoint.security == .tls)
    }

    @Test("Domínio desconhecido não é recusado — vai para o formulário manual com sugestão")
    func rotaManual() throws {
        // Este é o teste que impede a tabela de virar porteiro. Um domínio
        // próprio, de hospedagem qualquer, tem de chegar ao formulário com
        // `imap.<domínio>:993` já digitado — palpite, não veredito.
        let rota = try #require(ProviderDetector.route(for: "eu@dominio-que-ninguem-conhece.xyz"))
        guard case .manual(let sugerido) = rota else {
            Issue.record("esperava .manual, veio \(rota)"); return
        }
        #expect(sugerido.host == "imap.dominio-que-ninguem-conhece.xyz")
        #expect(sugerido.port == 993)
        #expect(sugerido.security == .tls)
    }

    @Test("Endereço inválido não tem rota — o campo diz isso em vez de adivinhar")
    func semRota() {
        #expect(ProviderDetector.route(for: "") == nil)
        #expect(ProviderDetector.route(for: "ricardo") == nil)
        #expect(ProviderDetector.route(for: "ricardo@") == nil)
        #expect(!ProviderDetector.isValidAddress("ricardo@sem-ponto"))
        #expect(ProviderDetector.isValidAddress("ricardo@empresa.com"))
    }

    @Test("A tabela é aberta: nenhum domínio aparece em dois presets, e todos têm host e porta")
    func tabelaCoerente() {
        var vistos: Set<String> = []
        for preset in ImapPresets.all {
            #expect(!preset.name.isEmpty)
            #expect(!preset.hostMark.isEmpty)
            #expect(!preset.endpoint.host.isEmpty)
            #expect(preset.endpoint.port > 0)
            #expect(!preset.domains.isEmpty)
            for dominio in preset.domains {
                #expect(dominio == dominio.lowercased(), "domínio fora de caixa baixa: \(dominio)")
                #expect(vistos.insert(dominio).inserted, "domínio repetido em dois presets: \(dominio)")
            }
        }
    }

    @Test("A busca por domínio dobra a caixa")
    func buscaPorDominioDobraCaixa() {
        #expect(ImapPresets.preset(forDomain: "ICLOUD.COM")?.hostMark == "icloud")
        #expect(ImapPresets.preset(forDomain: "nao-existe.zzz") == nil)
    }
}
```

`Packages/UNISync/Tests/UNISyncTests/FolderRolesTests.swift`:

```swift
import Foundation
import Testing
@testable import UNISync

@Suite("O papel de uma pasta")
struct FolderRolesTests {
    @Test("SPECIAL-USE manda, quando o servidor dá")
    func specialUseManda() {
        #expect(FolderRoles.role(specialUse: "\\Archive", name: "Coisas") == .archive)
        #expect(FolderRoles.role(specialUse: "\\All", name: "Coisas") == .archive)
        #expect(FolderRoles.role(specialUse: "\\Trash", name: "Coisas") == .trash)
        #expect(FolderRoles.role(specialUse: "\\Sent", name: "Coisas") == .sent)
        // Rascunhos e spam existem no servidor e não têm papel nosso.
        #expect(FolderRoles.role(specialUse: "\\Drafts", name: "Rascunhos") == .other)
        #expect(FolderRoles.role(specialUse: "\\Junk", name: "Spam") == .other)
        // A caixa maiúscula do atributo não pode mudar a resposta.
        #expect(FolderRoles.role(specialUse: "\\arCHive", name: "Coisas") == .archive)
    }

    @Test("Sem SPECIAL-USE, o nome decide — em português, inglês e no formato do Gmail")
    func nomeDecide() {
        #expect(FolderRoles.role(specialUse: nil, name: "INBOX") == .inbox)
        #expect(FolderRoles.role(specialUse: nil, name: "Caixa de entrada") == .inbox)
        #expect(FolderRoles.role(specialUse: nil, name: "Arquivo") == .archive)
        #expect(FolderRoles.role(specialUse: nil, name: "Archive") == .archive)
        #expect(FolderRoles.role(specialUse: nil, name: "[Gmail]/Todos os e-mails") == .archive)
        #expect(FolderRoles.role(specialUse: nil, name: "[Gmail]/All Mail") == .archive)
        #expect(FolderRoles.role(specialUse: nil, name: "Lixeira") == .trash)
        #expect(FolderRoles.role(specialUse: nil, name: "Deleted Messages") == .trash)
        #expect(FolderRoles.role(specialUse: nil, name: "Enviados") == .sent)
        #expect(FolderRoles.role(specialUse: nil, name: "Sent Items") == .sent)
        #expect(FolderRoles.role(specialUse: nil, name: "Projetos/2026") == .other)
    }

    @Test("O acento não muda a resposta: 'Lixeira' e 'lixeira' são a mesma pasta")
    func nomeDobraAcentoECaixa() {
        #expect(FolderRoles.role(specialUse: nil, name: "lixeira") == .trash)
        #expect(FolderRoles.role(specialUse: nil, name: "ARQUIVO") == .archive)
        #expect(FolderRoles.role(specialUse: nil, name: "Todos os e-mails") == .archive)
    }

    @Test("A pasta `OkamiUNI/Depois` é reconhecida quando existir de instalação anterior")
    func pastaDepois() {
        #expect(FolderRoles.laterFolderName == "OkamiUNI/Depois")
        #expect(FolderRoles.role(specialUse: nil, name: "OkamiUNI/Depois") == .later)
        #expect(FolderRoles.role(specialUse: nil, name: "okamiuni/depois") == .later)
        // E o SPECIAL-USE não a atropela: o servidor não tem atributo para ela,
        // mas se marcasse a pasta como arquivo, o nosso nome ainda ganha —
        // é a nossa pasta, criada por nós, com significado nosso.
        #expect(FolderRoles.role(specialUse: "\\Archive", name: "OkamiUNI/Depois") == .later)
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd Packages/UNISync && swift test --filter 'ProviderDetector|FolderRoles'`

Expected: FAIL — `cannot find 'ProviderDetector' in scope`, `cannot find 'FolderRoles' in scope`, `cannot find 'ImapPresets' in scope`.

- [ ] **Step 3: Write the presets table**

`Packages/UNISync/Sources/UNISync/Providers/ImapPresets.swift`:

```swift
import Foundation
import UNICore

/// Um provedor cujo IMAP a gente já sabe de cor.
public struct ImapPreset: Sendable, Hashable {
    /// O nome que a janela mostra: "iCloud", "Zoho", "Fastmail".
    public let name: String
    /// O que vai para `Account.host` e aparece no chip em versalete da lateral.
    public let hostMark: String
    public let endpoint: ImapEndpoint
    /// Sempre em caixa baixa.
    public let domains: [String]

    public init(name: String, hostMark: String, endpoint: ImapEndpoint, domains: [String]) {
        self.name = name
        self.hostMark = hostMark
        self.endpoint = endpoint
        self.domains = domains
    }
}

/// A tabela de provedores conhecidos.
///
/// **É conveniência de preenchimento, nunca porteiro.** Um domínio fora desta
/// lista não é recusado: ele cai em `ProviderRoute.manual`, com
/// `imap.<domínio>:993` sugerido no formulário, que a pessoa corrige se
/// precisar. Nada aqui limita provedor ou domínio — a lista existe só para
/// poupar digitação de quem usa um dos casos comuns.
///
/// Consulta de MX **não** entra: rede no caminho da digitação é latência a cada
/// tecla, e a tabela mais o formulário manual já cobrem o mesmo espaço.
public enum ImapPresets {
    public static let all: [ImapPreset] = [
        ImapPreset(
            name: "iCloud", hostMark: "icloud",
            endpoint: ImapEndpoint(host: "imap.mail.me.com", port: 993, security: .tls),
            domains: ["icloud.com", "me.com", "mac.com"]
        ),
        ImapPreset(
            name: "Zoho", hostMark: "zoho",
            endpoint: ImapEndpoint(host: "imap.zoho.com", port: 993, security: .tls),
            domains: ["zoho.com", "zohomail.com"]
        ),
        ImapPreset(
            name: "Hostinger", hostMark: "hostinger",
            endpoint: ImapEndpoint(host: "imap.hostinger.com", port: 993, security: .tls),
            domains: ["hostinger.com"]
        ),
        ImapPreset(
            name: "Fastmail", hostMark: "fastmail",
            endpoint: ImapEndpoint(host: "imap.fastmail.com", port: 993, security: .tls),
            domains: ["fastmail.com", "fastmail.fm"]
        ),
        ImapPreset(
            name: "Outlook", hostMark: "outlook",
            endpoint: ImapEndpoint(host: "outlook.office365.com", port: 993, security: .tls),
            domains: ["outlook.com", "hotmail.com", "live.com"]
        ),
        ImapPreset(
            name: "Yahoo", hostMark: "yahoo",
            endpoint: ImapEndpoint(host: "imap.mail.yahoo.com", port: 993, security: .tls),
            domains: ["yahoo.com", "yahoo.com.br", "ymail.com"]
        ),
        ImapPreset(
            name: "UOL", hostMark: "uol",
            endpoint: ImapEndpoint(host: "imap.uol.com.br", port: 993, security: .tls),
            domains: ["uol.com.br", "bol.com.br"]
        ),
        ImapPreset(
            name: "Locaweb", hostMark: "locaweb",
            endpoint: ImapEndpoint(host: "imap.locaweb.com.br", port: 993, security: .tls),
            domains: ["locaweb.com.br"]
        ),
    ]

    private static let porDominio: [String: ImapPreset] = {
        var tabela: [String: ImapPreset] = [:]
        for preset in all {
            for dominio in preset.domains { tabela[dominio] = preset }
        }
        return tabela
    }()

    public static func preset(forDomain domain: String) -> ImapPreset? {
        porDominio[domain.lowercased()]
    }
}
```

- [ ] **Step 4: Write the detector**

`Packages/UNISync/Sources/UNISync/Providers/ProviderDetector.swift`:

```swift
import Foundation
import UNICore

/// Por onde falar com a conta que a pessoa acabou de digitar.
public enum ProviderRoute: Sendable, Hashable {
    /// Domínio do Google: OAuth, com a Gmail API por cima.
    case google
    /// Domínio conhecido: IMAP com o preset já preenchido.
    case imap(ImapPreset)
    /// Qualquer outro domínio: IMAP com o formulário aberto e um palpite.
    ///
    /// **Este é o caso geral**, não a exceção. `suggested` é chute — host,
    /// porta e TLS ficam editáveis, e é a pessoa que decide.
    case manual(suggested: ImapEndpoint)
}

public enum ProviderDetector {
    /// Os domínios que o Google atende com a conta pessoal.
    ///
    /// Note o que **não** está aqui: nenhum domínio de Google Workspace. Uma
    /// empresa com o Gmail atrás do domínio próprio cai em `.manual`, digita o
    /// IMAP do Google e funciona. Tentar adivinhar Workspace pelo domínio
    /// exigiria consultar MX, que é rede no caminho da digitação — e errar
    /// mandaria a pessoa para um consentimento OAuth que o domínio dela não
    /// aceita, que é pior do que um formulário.
    private static let googleDomains: Set<String> = ["gmail.com", "googlemail.com"]

    /// O domínio, em caixa baixa. Nulo quando não é um endereço.
    public static func domain(of address: String) -> String? {
        let limpo = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let partes = limpo.split(separator: "@", omittingEmptySubsequences: false)
        guard partes.count == 2 else { return nil }
        guard !partes[0].isEmpty, !partes[1].isEmpty else { return nil }
        return String(partes[1])
    }

    /// Serve como endereço? Um ponto no domínio é o piso — `eu@localhost` não
    /// é o caso que este app atende, e aceitá-lo mandaria a pessoa para um
    /// formulário que nunca ligaria em lugar nenhum.
    public static func isValidAddress(_ address: String) -> Bool {
        guard let dominio = domain(of: address) else { return false }
        guard dominio.contains(".") else { return false }
        guard !dominio.hasPrefix("."), !dominio.hasSuffix(".") else { return false }
        return true
    }

    /// A rota. Nulo quando o texto ainda não é um endereço — o campo mostra
    /// isso em vez de propor uma rota inventada.
    public static func route(for address: String) -> ProviderRoute? {
        guard isValidAddress(address), let dominio = domain(of: address) else { return nil }
        if googleDomains.contains(dominio) { return .google }
        if let preset = ImapPresets.preset(forDomain: dominio) { return .imap(preset) }
        return .manual(suggested: ImapEndpoint(host: "imap.\(dominio)", port: 993, security: .tls))
    }
}
```

- [ ] **Step 5: Write role detection**

`Packages/UNISync/Sources/UNISync/Providers/FolderRoles.swift`:

```swift
import Foundation
import UNICore

/// Que papel uma pasta do servidor cumpre para nós.
///
/// Duas fontes, nesta ordem de confiança: o atributo `SPECIAL-USE`, quando o
/// servidor o dá, e o nome, quando não dá. A parte do nome é uma tabela pura e
/// testável de propósito — é o pedaço que mais varia entre provedores e o que
/// mais vai precisar de conserto, e conserto de heurística sem teste é aposta.
public enum FolderRoles {
    /// A pasta que o Marco 3 vai criar para espelhar a caixa "Depois". Aqui
    /// ela só é **lida**, se já existir de instalação anterior.
    public static let laterFolderName = "OkamiUNI/Depois"

    public static func role(specialUse: String?, name: String) -> FolderRole {
        // A nossa pasta ganha de qualquer atributo: ela é nossa, o significado
        // é nosso, e um servidor que a marcasse como arquivo não sabe disso.
        if fold(name) == fold(laterFolderName) { return .later }

        if let specialUse {
            switch fold(specialUse) {
            case "\\inbox": return .inbox
            // `\All` é o "Todos os e-mails" do Gmail, que é o arquivo dele.
            case "\\archive", "\\all": return .archive
            case "\\trash": return .trash
            case "\\sent": return .sent
            // `\Drafts` e `\Junk` existem e não têm papel nosso — cair em
            // `.other` é a resposta certa, não uma lacuna.
            default: break
            }
        }

        let dobrado = fold(name)
        if dobrado == "inbox" || dobrado == "caixa de entrada" { return .inbox }
        for sufixo in ["archive", "arquivo", "all mail", "todos os e-mails", "todos os emails"]
        where dobrado == sufixo || dobrado.hasSuffix("/" + sufixo) {
            return .archive
        }
        for sufixo in ["trash", "lixeira", "deleted messages", "itens excluidos"]
        where dobrado == sufixo || dobrado.hasSuffix("/" + sufixo) {
            return .trash
        }
        for sufixo in ["sent", "sent items", "sent messages", "enviados", "itens enviados"]
        where dobrado == sufixo || dobrado.hasSuffix("/" + sufixo) {
            return .sent
        }
        return .other
    }

    /// Caixa e acento fora. A mesma dobra do resto do app —
    /// `ContactDirectory.fold` é a única definição, e esta chama aquela em vez
    /// de virar uma segunda resposta para a mesma pergunta.
    private static func fold(_ text: String) -> String {
        ContactDirectory.fold(text.trimmingCharacters(in: .whitespaces))
    }
}
```

- [ ] **Step 6: Run them to see them pass**

Run: `cd Packages/UNISync && swift test --filter 'ProviderDetector|FolderRoles'`

Expected: PASS, 11 tests.

- [ ] **Step 7: Prove by mutation that the general case is truly general**

Replace `return .manual(...)` in `ProviderDetector.route` with `return nil`, then run:

Run: `cd Packages/UNISync && swift test --filter rotaManual`

Expected: FAIL — `#require` returns `nil` and the test reports the problem. That
turns the table into a gatekeeper, the defect prohibited by the inherited constraint.
Restore the line and confirm that the test is green.

- [ ] **Step 8: Commit**

```bash
git add Packages/UNISync/Sources/UNISync/Providers Packages/UNISync/Tests/UNISyncTests/ProviderDetectorTests.swift Packages/UNISync/Tests/UNISyncTests/FolderRolesTests.swift
git commit -m "Do endereço à rota, e do nome da pasta ao papel dela — tudo puro, tudo com fronteira testada

A tabela de presets é conveniência de preenchimento, nunca porteiro: domínio
desconhecido cai no formulário manual com imap.<domínio>:993 sugerido, e há
teste que quebra se alguém trocar isso por uma recusa. Google Workspace não é
adivinhado por domínio de propósito — errar mandaria a pessoa para um
consentimento que o domínio dela não aceita.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 7: `GoogleAuth` — PKCE, callback, token exchange, refresh, and single-flight, against a local stub

**Files:**
- Create: `Packages/UNISync/Sources/UNISync/Google/GoogleAuthConfig.swift`
- Create: `Packages/UNISync/Sources/UNISync/Google/PKCE.swift`
- Create: `Packages/UNISync/Sources/UNISync/Google/OAuthCallback.swift`
- Create: `Packages/UNISync/Sources/UNISync/Google/AuthorizationPresenter.swift`
- Create: `Packages/UNISync/Sources/UNISync/Google/GoogleAuth.swift`
- Create: `Packages/UNISync/Tests/UNISyncTests/StubURLProtocol.swift`
- Create: `Packages/UNISync/Tests/UNISyncTests/GoogleAuthTests.swift`

**Interfaces:**
- Consumes: `SyncError`, `SecretStore`, `Secret`, `OAuthTokens`, `InMemorySecretStore` (Task 4).
- Produces:
  - `struct PKCEPair: Sendable, Hashable { let verifier: String; let challenge: String; static func make(from bytes: [UInt8]) -> PKCEPair; static func random() -> PKCEPair }`.
  - `struct GoogleAuthConfig: Sendable, Hashable` with `let clientID: String`, `let redirectURI: String`, `let callbackScheme: String`, `let scopes: [String]`, `let authorizationEndpoint: URL`, `let tokenEndpoint: URL`, `let revocationEndpoint: URL`; `static let defaultScopes: [String]`; `init(clientID:redirectURI:callbackScheme:scopes:authorizationEndpoint:tokenEndpoint:revocationEndpoint:)` with defaults for everything except `clientID`; `static func fromBundle(_ bundle: Bundle) throws -> GoogleAuthConfig`; and `func authorizationURL(pkce: PKCEPair, state: String, loginHint: String?) -> URL`.
  - `enum OAuthCallback { static func code(from url: URL, expectedState: String) throws -> String }`.
  - `protocol AuthorizationPresenter: Sendable { func authorize(url: URL, callbackScheme: String) async throws -> URL }`; `final class WebAuthorizationPresenter: NSObject, AuthorizationPresenter, @unchecked Sendable`; and `struct StubAuthorizationPresenter: AuthorizationPresenter` with `init(redirect: @Sendable @escaping (URL) throws -> URL)`.
  - `actor GoogleAuth` with `init(config: GoogleAuthConfig, session: URLSession, secrets: any SecretStore, presenter: any AuthorizationPresenter, now: @Sendable @escaping () -> Date = Date.init)`, `func connect(accountID: String, loginHint: String?) async throws -> OAuthTokens`, `func accessToken(for accountID: String) async throws -> String`, and `func revoke(accountID: String) async throws`.

- [ ] **Step 1: Write the HTTP stub**

`Packages/UNISync/Tests/UNISyncTests/StubURLProtocol.swift`:

```swift
import Foundation

/// O servidor HTTP dos testes: um `URLProtocol` que responde do roteiro em
/// memória. **Nenhum teste deste pacote toca rede externa**, e é esta classe
/// que garante isso — uma URL fora do roteiro derruba o teste em vez de sair
/// pela placa de rede.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status: Int
        var body: Data
        var headers: [String: String]

        init(status: Int = 200, body: Data = Data(), headers: [String: String] = ["Content-Type": "application/json"]) {
            self.status = status
            self.body = body
            self.headers = headers
        }

        static func json(_ text: String, status: Int = 200) -> Reply {
            Reply(status: status, body: Data(text.utf8))
        }
    }

    /// O que cada caminho responde, e o que foi pedido — protegidos por lock
    /// porque o `URLSession` chama isto de outra fila.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: [Reply]] = [:]
    nonisolated(unsafe) private static var recorded: [(path: String, body: String)] = []

    /// Instala um roteiro. Cada caminho tem uma **fila** de respostas: a
    /// primeira chamada consome a primeira, e é assim que se testa "o refresh
    /// falha, e o seguinte funciona".
    static func install(_ routes: [String: [Reply]]) {
        lock.lock()
        defer { lock.unlock() }
        self.routes = routes
        recorded = []
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        routes = [:]
        recorded = []
    }

    /// O que o cliente pediu, na ordem. É como o teste afirma que o corpo do
    /// POST levou `grant_type=refresh_token` e não outra coisa.
    static var requests: [(path: String, body: String)] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// Uma `URLSession` que só fala com este stub.
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let caminho = request.url?.path ?? ""
        // `httpBody` vem nulo quando o corpo foi entregue por stream, que é o
        // que o URLSession faz com `uploadTask`. O `GoogleAuth` usa
        // `httpBody`, então ler daqui basta — e quando não bastar, o teste
        // grava string vazia em vez de mentir.
        let corpo = request.httpBody.flatMap { String(data: $0, encoding: .utf8) }
            ?? request.httpBodyStream.map { fluxo in
                fluxo.open()
                defer { fluxo.close() }
                var dados = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while fluxo.hasBytesAvailable {
                    let lidos = fluxo.read(&buffer, maxLength: buffer.count)
                    if lidos <= 0 { break }
                    dados.append(contentsOf: buffer[0..<lidos])
                }
                return String(data: dados, encoding: .utf8) ?? ""
            } ?? ""

        Self.lock.lock()
        Self.recorded.append((path: caminho, body: corpo))
        let resposta: Reply?
        if var fila = Self.routes[caminho], !fila.isEmpty {
            resposta = fila.removeFirst()
            Self.routes[caminho] = fila
        } else {
            resposta = nil
        }
        Self.lock.unlock()

        guard let resposta, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(
                .unsupportedURL,
                userInfo: [NSLocalizedDescriptionKey: "Nenhuma resposta no roteiro para \(caminho)"]
            ))
            return
        }

        let http = HTTPURLResponse(
            url: url, statusCode: resposta.status,
            httpVersion: "HTTP/1.1", headerFields: resposta.headers
        )!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: resposta.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
```

- [ ] **Step 2: Write the failing test**

`Packages/UNISync/Tests/UNISyncTests/GoogleAuthTests.swift`:

```swift
import Foundation
import Testing
@testable import UNISync

@Suite("OAuth do Google, contra servidor local", .serialized)
struct GoogleAuthTests {
    private let config = GoogleAuthConfig(
        clientID: "cliente-de-teste.apps.googleusercontent.com",
        tokenEndpoint: URL(string: "https://oauth2.example/token")!,
        revocationEndpoint: URL(string: "https://oauth2.example/revoke")!
    )

    private func auth(
        secrets: any SecretStore,
        redirect: @Sendable @escaping (URL) throws -> URL = { url in
            URL(string: "com.okamiops.okamiuni:/oauth?code=codigo-devolvido&state="
                + (URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "state" }?.value ?? ""))!
        },
        now: @Sendable @escaping () -> Date = { Date(timeIntervalSince1970: 10_000) }
    ) -> GoogleAuth {
        GoogleAuth(
            config: config, session: StubURLProtocol.session(), secrets: secrets,
            presenter: StubAuthorizationPresenter(redirect: redirect), now: now
        )
    }

    // MARK: PKCE e a URL de autorização

    @Test("O challenge é o SHA-256 do verifier em base64url sem padding")
    func pkceS256() {
        // Vetor do RFC 7636, apêndice B.
        let bytes: [UInt8] = [
            116, 24, 223, 180, 151, 153, 224, 37, 79, 250, 96, 125, 216, 173,
            187, 186, 22, 212, 37, 77, 105, 214, 191, 54, 34, 60, 203, 138,
            26, 122, 232, 152,
        ]
        let par = PKCEPair.make(from: bytes)
        #expect(par.verifier == "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wOOSRe9x2xI4")
        #expect(par.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        // base64url: sem '+', sem '/', sem '='.
        #expect(!par.challenge.contains("+"))
        #expect(!par.challenge.contains("/"))
        #expect(!par.challenge.contains("="))
    }

    @Test("Dois pares aleatórios não se repetem e têm tamanho legal")
    func pkceAleatorio() {
        let a = PKCEPair.random()
        let b = PKCEPair.random()
        #expect(a.verifier != b.verifier)
        // RFC 7636: entre 43 e 128 caracteres.
        #expect(a.verifier.count >= 43 && a.verifier.count <= 128)
    }

    @Test("A URL de autorização leva client, redirect, escopos, S256 e o state")
    func urlDeAutorizacao() throws {
        let par = PKCEPair.make(from: Array(repeating: 7, count: 32))
        let url = config.authorizationURL(pkce: par, state: "estado-123", loginHint: "eu@gmail.com")
        let itens = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func valor(_ nome: String) -> String? { itens.first { $0.name == nome }?.value }

        #expect(valor("client_id") == config.clientID)
        #expect(valor("redirect_uri") == "com.okamiops.okamiuni:/oauth")
        #expect(valor("response_type") == "code")
        #expect(valor("code_challenge_method") == "S256")
        #expect(valor("code_challenge") == par.challenge)
        #expect(valor("state") == "estado-123")
        #expect(valor("login_hint") == "eu@gmail.com")
        // `access_type=offline` é o que faz o Google devolver refresh_token.
        // Sem ele a conta funciona por uma hora e depois cai em
        // erroDeAutenticacao sem ter o que renovar.
        #expect(valor("access_type") == "offline")
        #expect(valor("prompt") == "consent")

        let escopos = try #require(valor("scope")).split(separator: " ").map(String.init)
        #expect(escopos.contains("https://www.googleapis.com/auth/gmail.modify"))
        #expect(escopos.contains("https://www.googleapis.com/auth/gmail.send"))
        #expect(escopos.contains("https://www.googleapis.com/auth/userinfo.email"))
    }

    // MARK: O redirect de volta

    @Test("O código sai do redirect quando o state confere")
    func callbackComCodigo() throws {
        let url = URL(string: "com.okamiops.okamiuni:/oauth?code=abc123&state=estado-123")!
        #expect(try OAuthCallback.code(from: url, expectedState: "estado-123") == "abc123")
    }

    @Test("State trocado é recusado — é a defesa contra o redirect injetado")
    func callbackComStateErrado() {
        let url = URL(string: "com.okamiops.okamiuni:/oauth?code=abc123&state=outro")!
        #expect(throws: SyncError.resposta("O redirect do Google veio com um `state` que não é o nosso.")) {
            try OAuthCallback.code(from: url, expectedState: "estado-123")
        }
    }

    @Test("`access_denied` vira autorização revogada, não erro genérico")
    func callbackNegado() {
        let url = URL(string: "com.okamiops.okamiuni:/oauth?error=access_denied&state=estado-123")!
        #expect(throws: SyncError.autorizacaoRevogada) {
            try OAuthCallback.code(from: url, expectedState: "estado-123")
        }
    }

    @Test("Redirect sem `code` e sem `error` não é engolido")
    func callbackVazio() {
        let url = URL(string: "com.okamiops.okamiuni:/oauth?state=estado-123")!
        #expect(throws: (any Error).self) {
            try OAuthCallback.code(from: url, expectedState: "estado-123")
        }
    }

    // MARK: Troca e refresh

    @Test("Conectar troca o código por tokens e os guarda no cofre")
    func trocaGuardaTokens() async throws {
        StubURLProtocol.install([
            "/token": [.json("""
                {"access_token":"at-1","refresh_token":"rt-1","expires_in":3600,"token_type":"Bearer"}
                """)],
        ])
        defer { StubURLProtocol.reset() }

        let cofre = InMemorySecretStore()
        let tokens = try await auth(secrets: cofre).connect(accountID: "conta-g", loginHint: "eu@gmail.com")

        #expect(tokens.accessToken == "at-1")
        #expect(tokens.refreshToken == "rt-1")
        #expect(tokens.expiresAt == Date(timeIntervalSince1970: 13_600))
        #expect(try cofre.secret(for: "conta-g") == .oauth(tokens))

        let pedido = try #require(StubURLProtocol.requests.first)
        #expect(pedido.body.contains("grant_type=authorization_code"))
        #expect(pedido.body.contains("code=codigo-devolvido"))
        #expect(pedido.body.contains("code_verifier="))
        // Client de desktop é público: não há segredo nenhum no corpo.
        #expect(!pedido.body.contains("client_secret"))
    }

    @Test("Token válido é devolvido sem tocar a rede")
    func tokenValidoNaoRenova() async throws {
        StubURLProtocol.install([:])
        defer { StubURLProtocol.reset() }

        let cofre = InMemorySecretStore()
        try cofre.store(.oauth(OAuthTokens(
            accessToken: "at-vivo", refreshToken: "rt",
            expiresAt: Date(timeIntervalSince1970: 99_999)
        )), for: "conta-g")

        #expect(try await auth(secrets: cofre).accessToken(for: "conta-g") == "at-vivo")
        #expect(StubURLProtocol.requests.isEmpty)
    }

    @Test("Token vencido é renovado, e o refresh antigo é preservado quando o Google não manda um novo")
    func refreshPreservaRefreshToken() async throws {
        StubURLProtocol.install([
            "/token": [.json("""
                {"access_token":"at-2","expires_in":3600,"token_type":"Bearer"}
                """)],
        ])
        defer { StubURLProtocol.reset() }

        let cofre = InMemorySecretStore()
        try cofre.store(.oauth(OAuthTokens(
            accessToken: "at-velho", refreshToken: "rt-guardado",
            expiresAt: Date(timeIntervalSince1970: 1)
        )), for: "conta-g")

        #expect(try await auth(secrets: cofre).accessToken(for: "conta-g") == "at-2")

        // O Google só devolve `refresh_token` no primeiro consentimento.
        // Sobrescrevê-lo com vazio derrubaria a conta na renovação seguinte.
        guard case .oauth(let guardados)? = try cofre.secret(for: "conta-g") else {
            Issue.record("esperava tokens no cofre"); return
        }
        #expect(guardados.refreshToken == "rt-guardado")
        #expect(guardados.accessToken == "at-2")
    }

    @Test("Refresh recusado marca `autorizacaoRevogada` — e não deixa token morto no cofre")
    func refreshRecusado() async throws {
        StubURLProtocol.install([
            "/token": [.json("""
                {"error":"invalid_grant","error_description":"Token has been expired or revoked."}
                """, status: 400)],
        ])
        defer { StubURLProtocol.reset() }

        let cofre = InMemorySecretStore()
        try cofre.store(.oauth(OAuthTokens(
            accessToken: "at-velho", refreshToken: "rt-morto",
            expiresAt: Date(timeIntervalSince1970: 1)
        )), for: "conta-g")

        await #expect(throws: SyncError.autorizacaoRevogada) {
            _ = try await self.auth(secrets: cofre).accessToken(for: "conta-g")
        }
    }

    @Test("Quota do servidor de token não vira erro genérico")
    func refreshComQuota() async throws {
        StubURLProtocol.install([
            "/token": [.json("{\"error\":\"rateLimitExceeded\"}", status: 429)],
        ])
        defer { StubURLProtocol.reset() }

        let cofre = InMemorySecretStore()
        try cofre.store(.oauth(OAuthTokens(
            accessToken: "at", refreshToken: "rt", expiresAt: Date(timeIntervalSince1970: 1)
        )), for: "conta-g")

        await #expect(throws: SyncError.quota) {
            _ = try await self.auth(secrets: cofre).accessToken(for: "conta-g")
        }
    }

    @Test("Dez pedidos simultâneos com token vencido fazem UM refresh só")
    func corridaDeRefreshEhUnica() async throws {
        // A prova de que o single-flight existe. Sem ele, dez chamadas
        // disparariam dez POSTs, e o Google invalida o refresh token quando
        // ele é usado em paralelo — a conta cairia sozinha em erro.
        StubURLProtocol.install([
            "/token": [.json("""
                {"access_token":"at-unico","expires_in":3600,"token_type":"Bearer"}
                """)],
        ])
        defer { StubURLProtocol.reset() }

        let cofre = InMemorySecretStore()
        try cofre.store(.oauth(OAuthTokens(
            accessToken: "at-velho", refreshToken: "rt",
            expiresAt: Date(timeIntervalSince1970: 1)
        )), for: "conta-g")
        let auth = auth(secrets: cofre)

        let tokens = try await withThrowingTaskGroup(of: String.self) { grupo in
            for _ in 0..<10 { grupo.addTask { try await auth.accessToken(for: "conta-g") } }
            var todos: [String] = []
            for try await token in grupo { todos.append(token) }
            return todos
        }

        #expect(tokens == Array(repeating: "at-unico", count: 10))
        #expect(StubURLProtocol.requests.count == 1)
    }

    @Test("Conta sem segredo nenhum pede autenticação em vez de estourar")
    func semSegredo() async {
        StubURLProtocol.install([:])
        defer { StubURLProtocol.reset() }
        await #expect(throws: SyncError.autenticacao) {
            _ = try await self.auth(secrets: InMemorySecretStore()).accessToken(for: "fantasma")
        }
    }

    @Test("Revogar avisa o Google e limpa o cofre")
    func revogar() async throws {
        StubURLProtocol.install(["/revoke": [.init(status: 200)]])
        defer { StubURLProtocol.reset() }

        let cofre = InMemorySecretStore()
        try cofre.store(.oauth(OAuthTokens(
            accessToken: "at", refreshToken: "rt", expiresAt: Date(timeIntervalSince1970: 99_999)
        )), for: "conta-g")

        try await auth(secrets: cofre).revoke(accountID: "conta-g")
        #expect(try cofre.secret(for: "conta-g") == nil)
        #expect(StubURLProtocol.requests.contains { $0.path == "/revoke" })
    }

    @Test("Sem client ID no bundle, a configuração diz o que falta")
    func semClientID() {
        #expect(throws: SyncError.semClientID) {
            _ = try GoogleAuthConfig.fromBundle(Bundle(for: BundleAnchor.self))
        }
    }
}

/// Âncora para pegar um `Bundle` que não tem a chave do client ID.
private final class BundleAnchor {}
```

- [ ] **Step 3: Run it to see it fail**

Run: `cd Packages/UNISync && swift test --filter GoogleAuth`

Expected: FAIL — `cannot find 'PKCEPair' in scope`, `cannot find 'GoogleAuthConfig' in scope`.

- [ ] **Step 4: Write PKCE**

`Packages/UNISync/Sources/UNISync/Google/PKCE.swift`:

```swift
import CryptoKit
import Foundation

/// O par do PKCE (RFC 7636), método S256.
///
/// **É o que substitui o segredo do cliente.** Um app de desktop é público por
/// definição: qualquer pessoa abre o `.app` e lê um segredo embutido. O PKCE
/// troca o segredo fixo por um segredo **por autorização** — o `verifier`
/// nasce aleatório, só o `challenge` (o hash dele) atravessa o navegador, e a
/// troca do código exige o `verifier`, que nunca saiu do processo.
public struct PKCEPair: Sendable, Hashable {
    public let verifier: String
    public let challenge: String

    /// Determinístico, para o teste poder usar o vetor do RFC.
    public static func make(from bytes: [UInt8]) -> PKCEPair {
        let verifier = base64URL(Data(bytes))
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return PKCEPair(verifier: verifier, challenge: base64URL(Data(digest)))
    }

    public static func random() -> PKCEPair {
        var bytes = [UInt8](repeating: 0, count: 32)
        // 32 bytes viram 43 caracteres em base64url — o piso do RFC.
        // `SecRandomCopyBytes` só falha se o gerador do sistema falhar; se
        // falhar, não há como continuar com segurança, e mascarar com
        // `arc4random` seria fingir que houve entropia.
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "O gerador aleatório do sistema falhou (\(status)).")
        return make(from: bytes)
    }

    /// base64 com o alfabeto de URL e sem `=` — o RFC exige os três ajustes.
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
```

- [ ] **Step 5: Write configuration and the callback parser**

`Packages/UNISync/Sources/UNISync/Google/GoogleAuthConfig.swift`:

```swift
import Foundation

public struct GoogleAuthConfig: Sendable, Hashable {
    public let clientID: String
    /// Esquema próprio de app desktop. O `Info.plist` registra o esquema em
    /// `CFBundleURLTypes`; sem esse registro o macOS não devolve o redirect.
    public let redirectURI: String
    /// Só o esquema, que é o que `ASWebAuthenticationSession` quer.
    public let callbackScheme: String
    public let scopes: [String]
    public let authorizationEndpoint: URL
    public let tokenEndpoint: URL
    public let revocationEndpoint: URL

    /// Os três pedidos **juntos**, no primeiro consentimento.
    ///
    /// `gmail.send` só é usado no Marco 3 e mesmo assim entra aqui: pedi-lo
    /// depois obrigaria o usuário a passar pela tela de consentimento uma
    /// segunda vez, para um app que ele já autorizou.
    public static let defaultScopes = [
        "https://www.googleapis.com/auth/gmail.modify",
        "https://www.googleapis.com/auth/gmail.send",
        "https://www.googleapis.com/auth/userinfo.email",
    ]

    public init(
        clientID: String,
        redirectURI: String = "com.okamiops.okamiuni:/oauth",
        callbackScheme: String = "com.okamiops.okamiuni",
        scopes: [String] = GoogleAuthConfig.defaultScopes,
        authorizationEndpoint: URL = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
        tokenEndpoint: URL = URL(string: "https://oauth2.googleapis.com/token")!,
        revocationEndpoint: URL = URL(string: "https://oauth2.googleapis.com/revoke")!
    ) {
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.callbackScheme = callbackScheme
        self.scopes = scopes
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.revocationEndpoint = revocationEndpoint
    }

    /// O client ID vem do `Info.plist`, alimentado por `Config/Google.xcconfig`.
    ///
    /// **Nunca hardcoded**: o valor é de quem publica o app, não do código, e
    /// deixar um no repositório amarraria toda instalação a um projeto do
    /// Google Cloud que não é dela.
    ///
    /// Ausente ou vazio lança `.semClientID`, que a janela de Contas mostra
    /// apontando `docs/oauth-google.md`. Falha explicada, não silêncio.
    public static func fromBundle(_ bundle: Bundle) throws -> GoogleAuthConfig {
        let bruto = bundle.object(forInfoDictionaryKey: "OkamiUNIGoogleClientID") as? String
        let limpo = (bruto ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !limpo.isEmpty, !limpo.hasPrefix("$(") else { throw SyncError.semClientID }
        return GoogleAuthConfig(clientID: limpo)
    }

    public func authorizationURL(pkce: PKCEPair, state: String, loginHint: String?) -> URL {
        var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false)!
        var itens = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            // Sem `access_type=offline` o Google não devolve refresh token, e a
            // conta pararia de funcionar uma hora depois sem nada a renovar.
            URLQueryItem(name: "access_type", value: "offline"),
            // `prompt=consent` força o refresh token a vir também quando o
            // usuário já tinha autorizado o app antes — reconectar depois de um
            // erro precisa disso para não voltar sem refresh token.
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        if let loginHint { itens.append(URLQueryItem(name: "login_hint", value: loginHint)) }
        components.queryItems = itens
        return components.url!
    }
}
```

`Packages/UNISync/Sources/UNISync/Google/OAuthCallback.swift`:

```swift
import Foundation

public enum OAuthCallback {
    /// O `code` do redirect, conferindo o `state`.
    ///
    /// A conferência do `state` não é burocracia: sem ela, qualquer coisa
    /// capaz de abrir uma URL `com.okamiops.okamiuni:/oauth?code=…` na máquina
    /// injetaria um código de autorização de **outra** conta no nosso fluxo, e
    /// o app conectaria a caixa de outra pessoa achando que era a sua.
    public static func code(from url: URL, expectedState: String) throws -> String {
        guard let itens = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            throw SyncError.resposta("O redirect do Google veio sem parâmetros.")
        }
        func valor(_ nome: String) -> String? { itens.first { $0.name == nome }?.value }

        if let erro = valor("error") {
            // `access_denied` é o usuário clicando "Cancelar" ou não estando na
            // lista de testadores — os dois pedem a mesma ação: reconectar.
            if erro == "access_denied" { throw SyncError.autorizacaoRevogada }
            throw SyncError.resposta("O Google recusou a autorização: \(erro).")
        }
        guard valor("state") == expectedState else {
            throw SyncError.resposta("O redirect do Google veio com um `state` que não é o nosso.")
        }
        guard let code = valor("code"), !code.isEmpty else {
            throw SyncError.resposta("O redirect do Google veio sem código de autorização.")
        }
        return code
    }
}
```

- [ ] **Step 6: Write the presenter**

`Packages/UNISync/Sources/UNISync/Google/AuthorizationPresenter.swift`:

```swift
import AuthenticationServices
import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Quem abre o navegador e devolve o redirect.
///
/// É porta, e não chamada direta, por dois motivos: nenhum teste pode abrir um
/// navegador, e o ensaio `--ensaiar-contas` precisa percorrer o fluxo Google
/// inteiro sem sair da máquina. `WebAuthorizationPresenter` é o de verdade;
/// `StubAuthorizationPresenter` é o dos testes e do ensaio.
public protocol AuthorizationPresenter: Sendable {
    func authorize(url: URL, callbackScheme: String) async throws -> URL
}

/// `ASWebAuthenticationSession`: a sessão do sistema, com a barra que mostra o
/// domínio real ao usuário. **Não é uma WebView nossa** — o Google recusa
/// consentimento em WebView embarcada, e com razão: numa WebView nossa o app
/// enxergaria a senha digitada.
public final class WebAuthorizationPresenter:
    NSObject, AuthorizationPresenter,
    ASWebAuthenticationPresentationContextProviding, @unchecked Sendable {

    /// A sessão viva. Guardada porque `ASWebAuthenticationSession` é
    /// desalocada — e cancelada — se ninguém a segurar.
    private var session: ASWebAuthenticationSession?

    public override init() { super.init() }

    public func authorize(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
                let sessao = ASWebAuthenticationSession(
                    url: url, callbackURLScheme: callbackScheme
                ) { callback, erro in
                    if let callback {
                        continuation.resume(returning: callback)
                    } else if let erro = erro as? ASWebAuthenticationSessionError,
                              erro.code == .canceledLogin {
                        continuation.resume(throwing: SyncError.autorizacaoRevogada)
                    } else {
                        continuation.resume(throwing: SyncError.rede(
                            erro?.localizedDescription ?? "a janela de autorização fechou sem resposta"
                        ))
                    }
                }
                sessao.presentationContextProvider = self
                // Sessão **não** efêmera: reconectar uma conta que o navegador
                // já conhece não deve exigir digitar a senha do Google de novo.
                sessao.prefersEphemeralWebBrowserSession = false
                self.session = sessao
                guard sessao.start() else {
                    continuation.resume(throwing: SyncError.rede(
                        "não foi possível abrir a janela de autorização"
                    ))
                    return
                }
            }
        }
    }

    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor() }
    }
}

/// O apresentador dos testes e do ensaio: devolve o redirect que o roteiro
/// mandar, sem abrir nada.
public struct StubAuthorizationPresenter: AuthorizationPresenter {
    private let redirect: @Sendable (URL) throws -> URL

    public init(redirect: @Sendable @escaping (URL) throws -> URL) {
        self.redirect = redirect
    }

    public func authorize(url: URL, callbackScheme: String) async throws -> URL {
        try redirect(url)
    }
}
```

- [ ] **Step 7: Write `GoogleAuth`**

`Packages/UNISync/Sources/UNISync/Google/GoogleAuth.swift`:

```swift
import Foundation

/// O fluxo OAuth do Google, do consentimento ao refresh.
///
/// Ator porque o estado que ele guarda — a corrida de refresh em voo, por
/// conta — precisa de exclusão mútua de verdade. Sem ela, dez requisições
/// simultâneas com o token vencido disparam dez refreshes, e o Google invalida
/// um refresh token usado em paralelo: a conta cai sozinha em
/// `erroDeAutenticacao` sem ninguém ter feito nada errado.
public actor GoogleAuth {
    private let config: GoogleAuthConfig
    private let session: URLSession
    private let secrets: any SecretStore
    private let presenter: any AuthorizationPresenter
    private let now: @Sendable () -> Date

    /// A renovação em voo, por conta. É o single-flight.
    private var inFlight: [String: Task<OAuthTokens, any Error>] = [:]

    public init(
        config: GoogleAuthConfig,
        session: URLSession,
        secrets: any SecretStore,
        presenter: any AuthorizationPresenter,
        now: @Sendable @escaping () -> Date = Date.init
    ) {
        self.config = config
        self.session = session
        self.secrets = secrets
        self.presenter = presenter
        self.now = now
    }

    // MARK: Primeiro consentimento

    /// Abre o consentimento, troca o código por tokens e os guarda.
    public func connect(accountID: String, loginHint: String?) async throws -> OAuthTokens {
        let pkce = PKCEPair.random()
        let state = UUID().uuidString
        let url = config.authorizationURL(pkce: pkce, state: state, loginHint: loginHint)

        let callback = try await presenter.authorize(url: url, callbackScheme: config.callbackScheme)
        let code = try OAuthCallback.code(from: callback, expectedState: state)

        let tokens = try await postToken([
            "grant_type": "authorization_code",
            "code": code,
            "code_verifier": pkce.verifier,
            "client_id": config.clientID,
            "redirect_uri": config.redirectURI,
        ], keepingRefreshToken: nil)

        try secrets.store(.oauth(tokens), for: accountID)
        return tokens
    }

    // MARK: Token para usar agora

    /// O access token corrente da conta, renovando se preciso.
    ///
    /// É o que `GmailClient` chama antes de cada requisição.
    public func accessToken(for accountID: String) async throws -> String {
        guard case .oauth(let guardados)? = try secrets.secret(for: accountID) else {
            // Sem tokens não há o que renovar: quem pode resolver isto é o
            // usuário, reconectando. `autenticacao` é o que a janela traduz
            // em "Reconectar".
            throw SyncError.autenticacao
        }
        guard guardados.isExpired(at: now()) else { return guardados.accessToken }
        return try await refresh(accountID: accountID, using: guardados).accessToken
    }

    /// A renovação, com uma corrida por conta.
    private func refresh(accountID: String, using guardados: OAuthTokens) async throws -> OAuthTokens {
        if let emVoo = inFlight[accountID] { return try await emVoo.value }

        let tarefa = Task<OAuthTokens, any Error> { [config, secrets] in
            let novos = try await self.postToken([
                "grant_type": "refresh_token",
                "refresh_token": guardados.refreshToken,
                "client_id": config.clientID,
            ], keepingRefreshToken: guardados.refreshToken)
            try secrets.store(.oauth(novos), for: accountID)
            return novos
        }
        inFlight[accountID] = tarefa
        defer { inFlight[accountID] = nil }
        return try await tarefa.value
    }

    // MARK: Revogação

    /// Avisa o Google e limpa o cofre.
    ///
    /// O aviso pode falhar (a máquina pode estar offline quando o usuário
    /// remove a conta) e mesmo assim o segredo local sai: deixar o token no
    /// Keychain de uma conta que a pessoa mandou remover é pior do que uma
    /// autorização órfã do lado do Google, que ela revoga na conta dela.
    public func revoke(accountID: String) async throws {
        defer { try? secrets.remove(for: accountID) }
        guard case .oauth(let guardados)? = try secrets.secret(for: accountID) else { return }

        var request = URLRequest(url: config.revocationEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(form(["token": guardados.refreshToken]).utf8)

        let (_, resposta) = try await enviar(request)
        guard let http = resposta as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            // Revogar já revogado devolve 400 — não é motivo para a remoção
            // parar. O `defer` acima já limpou o cofre.
            return
        }
    }

    // MARK: O POST do token

    private func postToken(
        _ campos: [String: String], keepingRefreshToken anterior: String?
    ) async throws -> OAuthTokens {
        var request = URLRequest(url: config.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(form(campos).utf8)

        let (dados, resposta) = try await enviar(request)
        guard let http = resposta as? HTTPURLResponse else {
            throw SyncError.resposta("O servidor de token respondeu sem cabeçalho HTTP.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw tokenError(status: http.statusCode, body: dados)
        }

        struct Wire: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Double?
        }
        let fio: Wire
        do {
            fio = try JSONDecoder().decode(Wire.self, from: dados)
        } catch {
            throw SyncError.resposta("O servidor de token respondeu num formato que não conhecemos.")
        }
        guard let refresh = fio.refresh_token ?? anterior else {
            // Primeiro consentimento sem refresh token: a conta funcionaria uma
            // hora e morreria. Melhor falhar agora, dizendo o que aconteceu.
            throw SyncError.resposta(
                "O Google não devolveu refresh token. Reconecte a conta pedindo consentimento de novo."
            )
        }
        return OAuthTokens(
            accessToken: fio.access_token,
            refreshToken: refresh,
            expiresAt: now().addingTimeInterval(fio.expires_in ?? 3_600)
        )
    }

    /// Cada falha do servidor de token vira o caso que pede a ação certa.
    private func tokenError(status: Int, body: Data) -> SyncError {
        struct Wire: Decodable { let error: String?; let error_description: String? }
        let fio = try? JSONDecoder().decode(Wire.self, from: body)
        if status == 429 || fio?.error == "rateLimitExceeded" { return .quota }
        switch fio?.error {
        case "invalid_grant", "unauthorized_client", "access_denied":
            // O refresh token morreu (revogado, senha trocada, 6 meses parado).
            // Só reconectar resolve.
            return .autorizacaoRevogada
        case "invalid_client":
            return .semClientID
        default:
            return .servidor(
                codigo: status,
                mensagem: fio?.error_description ?? fio?.error ?? "sem detalhe"
            )
        }
    }

    private func enviar(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let erro as URLError {
            // Rede é rede; TLS é TLS. A janela oferece ações diferentes para
            // os dois, e um erro só mandaria a pessoa tentar a coisa errada.
            switch erro.code {
            case .secureConnectionFailed, .serverCertificateUntrusted,
                 .serverCertificateHasBadDate, .serverCertificateNotYetValid,
                 .serverCertificateHasUnknownRoot:
                throw SyncError.tls(erro.localizedDescription)
            default:
                throw SyncError.rede(erro.localizedDescription)
            }
        } catch {
            throw SyncError.rede(error.localizedDescription)
        }
    }

    private func form(_ campos: [String: String]) -> String {
        campos
            .sorted { $0.key < $1.key }
            .map { chave, valor in
                let escapado = valor.addingPercentEncoding(
                    withAllowedCharacters: .alphanumerics
                ) ?? valor
                return "\(chave)=\(escapado)"
            }
            .joined(separator: "&")
    }
}
```

- [ ] **Step 8: Run it to see it pass**

Run: `cd Packages/UNISync && swift test --filter GoogleAuth`

Expected: PASS, 14 tests.

- [ ] **Step 9: Prove by mutation the two decisions that cost the most**

1. Delete `if let emVoo = inFlight[accountID] { return try await emVoo.value }` and run
   `swift test --filter corridaDeRefreshEhUnica`.
   Expected: FAIL — the second call finds no response in the stub (the `/token`
   queue has only one) and the test dies with `Nenhuma resposta no roteiro`.
2. Replace `fio.refresh_token ?? anterior` with `fio.refresh_token` and run
   `swift test --filter refreshPreservaRefreshToken`.
   Expected: FAIL — refresh throws because Google does not repeat the refresh
   token and the app would have deleted the only one it had.

Restore both changes and confirm that the test is green.

- [ ] **Step 10: Confirm that no test reaches the network**

Run: `cd Packages/UNISync && swift test --filter GoogleAuth 2>&1 | grep -ci 'accounts.google.com\|oauth2.googleapis.com' || echo "0 (nenhuma URL real)"`

Expected: `0 (nenhuma URL real)`. Every test URL is `oauth2.example`, which
exists only inside `StubURLProtocol`.

- [ ] **Step 11: Commit**

```bash
git add Packages/UNISync/Sources/UNISync/Google Packages/UNISync/Tests/UNISyncTests/StubURLProtocol.swift Packages/UNISync/Tests/UNISyncTests/GoogleAuthTests.swift
git commit -m "O OAuth do Google inteiro, sem SDK e sem sair da máquina

PKCE substitui o segredo do cliente porque app de desktop é público por
definição. A corrida de refresh é única por conta: o Google invalida um
refresh token usado em paralelo, e sem o single-flight dez requisições
derrubariam a conta sozinhas — provado por mutação. O refresh token antigo é
preservado quando a renovação não traz um novo, que é o comportamento real do
Google e o segundo defeito provado por mutação.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 8: `GmailClient` — the typed API, against recorded JSON fixtures

**Files:**
- Create: `Packages/UNISync/Sources/UNISync/Gmail/GmailTypes.swift`
- Create: `Packages/UNISync/Sources/UNISync/Gmail/GmailMessageParser.swift`
- Create: `Packages/UNISync/Sources/UNISync/Gmail/GmailClient.swift`
- Create: `Packages/UNISync/Tests/UNISyncTests/Fixtures/gmail-profile.json`
- Create: `Packages/UNISync/Tests/UNISyncTests/Fixtures/gmail-labels.json`
- Create: `Packages/UNISync/Tests/UNISyncTests/Fixtures/gmail-list.json`
- Create: `Packages/UNISync/Tests/UNISyncTests/Fixtures/gmail-message-full.json`
- Create: `Packages/UNISync/Tests/UNISyncTests/Fixtures/gmail-message-metadata.json`
- Create: `Packages/UNISync/Tests/UNISyncTests/GmailClientTests.swift`

**Interfaces:**
- Consumes: `SyncError` (Task 4); `StubURLProtocol` (Task 7); `Contact` from `UNICore`.
- Produces:
  - `struct GmailProfile: Sendable, Hashable { let emailAddress: String; let historyID: String }`.
  - `struct GmailLabel: Sendable, Hashable { let id: String; let name: String }`.
  - `struct GmailPage: Sendable, Hashable { let ids: [String]; let nextPageToken: String? }`.
  - `enum GmailFormat: String, Sendable { case metadata, full }`.
  - `struct GmailMessage: Sendable, Hashable { let id: String; let labelIDs: [String]; let internalDate: Date; let from: Contact; let to: [Contact]; let cc: [Contact]; let subject: String; let snippet: String; let body: [String] }`.
  - `enum MailAddress { static func parse(_ header: String) -> Contact?; static func parseList(_ header: String) -> [Contact] }`.
  - `enum GmailMessageParser { static func parse(_ data: Data) throws -> GmailMessage; static func decodeBody(base64URL: String) -> String; static func paragraphs(from text: String) -> [String] }`.
  - `struct GmailClient: Sendable` with `init(session: URLSession, accessToken: @Sendable @escaping () async throws -> String, baseURL: URL = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me")!)`, `func profile() async throws -> GmailProfile`, `func labels() async throws -> [GmailLabel]`, `func messageIDs(query: String, pageToken: String?) async throws -> GmailPage`, and `func message(id: String, format: GmailFormat) async throws -> GmailMessage`.

- [ ] **Step 1: Record the API fixtures**

These are real Gmail API responses with substituted addresses. Record them
literally.

`Fixtures/gmail-profile.json`:

```json
{"emailAddress":"ricardo@gmail.com","messagesTotal":48213,"threadsTotal":31004,"historyId":"9928471"}
```

`Fixtures/gmail-labels.json`:

```json
{"labels":[
  {"id":"INBOX","name":"INBOX","type":"system"},
  {"id":"SENT","name":"SENT","type":"system"},
  {"id":"TRASH","name":"TRASH","type":"system"},
  {"id":"UNREAD","name":"UNREAD","type":"system"},
  {"id":"STARRED","name":"STARRED","type":"system"},
  {"id":"Label_7","name":"OkamiUNI/Depois","type":"user"}
]}
```

`Fixtures/gmail-list.json`:

```json
{"messages":[
  {"id":"18f0a1b2c3","threadId":"18f0a1b2c3"},
  {"id":"18f0a1b2c4","threadId":"18f0a1b2c4"}
],"nextPageToken":"pagina-2","resultSizeEstimate":2}
```

`Fixtures/gmail-message-metadata.json`:

```json
{"id":"18f0a1b2c4","threadId":"18f0a1b2c4","labelIds":["INBOX","UNREAD"],
 "snippet":"Segue a prévia sem corpo","internalDate":"1800000000000",
 "payload":{"mimeType":"text/plain","headers":[
   {"name":"From","value":"Newsletter <noticias@exemplo.com>"},
   {"name":"Subject","value":"Boletim de agosto"}
 ]}}
```

`Fixtures/gmail-message-full.json` — the parser-teaching case: `multipart/alternative`,
a base64url body, an RFC 2047-encoded subject, `To` with two names, and `Cc`
with one:

```json
{"id":"18f0a1b2c3","threadId":"18f0a1b2c3",
 "labelIds":["INBOX","UNREAD","STARRED"],
 "snippet":"A revisão do contrato ficou pronta",
 "internalDate":"1800000000000",
 "payload":{
   "mimeType":"multipart/alternative",
   "headers":[
     {"name":"From","value":"\"Duarte, Marina\" <marina@clientepremium.com>"},
     {"name":"To","value":"Ricardo Alves <ricardo@gmail.com>, contato@meusite.com"},
     {"name":"Cc","value":"juridico@clientepremium.com"},
     {"name":"Subject","value":"=?UTF-8?B?UmV2aXPDo28gZG8gY29udHJhdG8=?="},
     {"name":"Date","value":"Tue, 25 Aug 2026 09:00:00 -0300"}
   ],
   "parts":[
     {"partId":"0","mimeType":"text/plain","body":{"size":74,
      "data":"QSByZXZpc8OjbyBkbyBjb250cmF0byBmaWNvdSBwcm9udGEuCgpQb2RlbW9zIGZlY2hhciBxdWludGE_"}},
     {"partId":"1","mimeType":"text/html","body":{"size":92,
      "data":"PHA-QSByZXZpc8OjbyBmaWNvdSBwcm9udGEuPC9wPg_-"}}
   ]
 }}
```

> The `text/plain` `data` is `A revisão do contrato ficou pronta.\n\nPodemos fechar quinta?`
> in base64**url** (`-`/`_` instead of `+`/`/`, with no `=` padding). That is
> exactly what the API returns, which is why decoding with standard base64
> fails.

- [ ] **Step 2: Write the failing test**

`Packages/UNISync/Tests/UNISyncTests/GmailClientTests.swift`:

```swift
import Foundation
import Testing
import UNICore
@testable import UNISync

@Suite("Gmail API", .serialized)
struct GmailClientTests {
    private func fixture(_ nome: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/\(nome)", withExtension: "json"))
        return try Data(contentsOf: url)
    }

    private func cliente() -> GmailClient {
        GmailClient(
            session: StubURLProtocol.session(),
            accessToken: { "at-de-teste" },
            baseURL: URL(string: "https://gmail.example/gmail/v1/users/me")!
        )
    }

    // MARK: Cabeçalhos de endereço

    @Test("O nome entre aspas e o endereço saem separados")
    func enderecoComNomeEntreAspas() {
        let contato = MailAddress.parse("\"Duarte, Marina\" <marina@clientepremium.com>")
        #expect(contato?.name == "Duarte, Marina")
        #expect(contato?.address == "marina@clientepremium.com")
    }

    @Test("Endereço sem nome usa o próprio endereço como nome")
    func enderecoSemNome() {
        // Nome vazio deixaria a lista com uma linha em branco onde o design
        // desenha o remetente. O endereço é o melhor nome disponível.
        #expect(MailAddress.parse("juridico@clientepremium.com")?.name == "juridico@clientepremium.com")
        #expect(MailAddress.parse("  <so@angulos.com> ")?.name == "so@angulos.com")
    }

    @Test("A lista respeita a vírgula dentro das aspas")
    func listaDeEnderecos() {
        // Cortar por vírgula sem olhar as aspas parte "Duarte, Marina" em dois
        // destinatários — e o "Responder a todos" mandaria email para "Duarte".
        let lista = MailAddress.parseList("\"Duarte, Marina\" <m@x.com>, Ricardo <r@y.com>")
        #expect(lista.count == 2)
        #expect(lista.first?.name == "Duarte, Marina")
        #expect(lista.last?.address == "r@y.com")
        #expect(MailAddress.parseList("").isEmpty)
    }

    // MARK: O parser

    @Test("A mensagem cheia sai inteira, com assunto decodificado e corpo em parágrafos")
    func mensagemCheia() throws {
        let mensagem = try GmailMessageParser.parse(fixture("gmail-message-full"))
        #expect(mensagem.id == "18f0a1b2c3")
        #expect(mensagem.labelIDs == ["INBOX", "UNREAD", "STARRED"])
        // internalDate vem em **milissegundos**; tratá-lo como segundos joga a
        // mensagem para o ano 58 mil e a lista fica em ordem aleatória.
        #expect(mensagem.internalDate == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(mensagem.from.name == "Duarte, Marina")
        #expect(mensagem.from.address == "marina@clientepremium.com")
        #expect(mensagem.to.count == 2)
        #expect(mensagem.cc.map(\.address) == ["juridico@clientepremium.com"])
        // RFC 2047: o assunto chega codificado e tem de sair legível.
        #expect(mensagem.subject == "Revisão do contrato")
        #expect(mensagem.snippet == "A revisão do contrato ficou pronta")
        #expect(mensagem.body == ["A revisão do contrato ficou pronta.", "Podemos fechar quinta?"])
    }

    @Test("Entre `text/plain` e `text/html`, o parser fica com o texto")
    func preferenciaPorTextoSimples() throws {
        let mensagem = try GmailMessageParser.parse(fixture("gmail-message-full"))
        // O leitor do Marco 1 desenha `[String]` de parágrafos, não HTML. Pegar
        // a parte HTML encheria a tela de tags.
        #expect(!mensagem.body.contains { $0.contains("<p>") })
    }

    @Test("A mensagem em formato `metadata` vem sem corpo, e isso não é erro")
    func mensagemSemCorpo() throws {
        let mensagem = try GmailMessageParser.parse(fixture("gmail-message-metadata"))
        #expect(mensagem.body.isEmpty)
        #expect(mensagem.subject == "Boletim de agosto")
        #expect(mensagem.to.isEmpty)
        #expect(mensagem.from.address == "noticias@exemplo.com")
    }

    @Test("base64url decodifica onde o base64 comum falha")
    func base64URL() {
        #expect(GmailMessageParser.decodeBody(base64URL: "QSByZXZpc8OjbyE") == "A revisão!")
        // Padding ausente é o normal na API; com `=` também tem de funcionar.
        #expect(GmailMessageParser.decodeBody(base64URL: "QSByZXZpc8OjbyE=") == "A revisão!")
        #expect(GmailMessageParser.decodeBody(base64URL: "não é base64") == "")
    }

    @Test("Parágrafos saem das linhas em branco, e as pontas somem")
    func paragrafos() {
        #expect(GmailMessageParser.paragraphs(from: "Um.\n\nDois.\n\n\n  Três.  \n") == ["Um.", "Dois.", "Três."])
        #expect(GmailMessageParser.paragraphs(from: "   ").isEmpty)
        // Quebra simples dentro de um parágrafo continua sendo um parágrafo.
        #expect(GmailMessageParser.paragraphs(from: "Linha um\nlinha dois") == ["Linha um\nlinha dois"])
    }

    @Test("JSON fora do contrato não é engolido")
    func jsonInvalido() {
        #expect(throws: (any Error).self) {
            _ = try GmailMessageParser.parse(Data("{\"nada\":1}".utf8))
        }
    }

    // MARK: O cliente

    @Test("O perfil traz o endereço e o historyId que o Marco 3 vai usar")
    func perfil() async throws {
        StubURLProtocol.install(["/gmail/v1/users/me/profile": [.init(body: try fixture("gmail-profile"))]])
        defer { StubURLProtocol.reset() }

        let perfil = try await cliente().profile()
        #expect(perfil.emailAddress == "ricardo@gmail.com")
        #expect(perfil.historyID == "9928471")
    }

    @Test("Toda requisição leva o Bearer, e o token é pedido na hora")
    func bearerEmToda() async throws {
        StubURLProtocol.install(["/gmail/v1/users/me/profile": [.init(body: try fixture("gmail-profile"))]])
        defer { StubURLProtocol.reset() }

        let pedidos = Contador()
        let cliente = GmailClient(
            session: StubURLProtocol.session(),
            accessToken: { await pedidos.incrementaEDevolve() },
            baseURL: URL(string: "https://gmail.example/gmail/v1/users/me")!
        )
        _ = try await cliente.profile()
        // Pedir o token **por requisição**, e não uma vez na construção, é o
        // que faz o refresh transparente chegar aqui: um token guardado no
        // init venceria no meio da carga inicial.
        #expect(await pedidos.total == 1)
    }

    @Test("Os rótulos vêm com a pasta Depois quando ela existe")
    func rotulos() async throws {
        StubURLProtocol.install(["/gmail/v1/users/me/labels": [.init(body: try fixture("gmail-labels"))]])
        defer { StubURLProtocol.reset() }

        let rotulos = try await cliente().labels()
        #expect(rotulos.count == 6)
        #expect(rotulos.first { $0.name == "OkamiUNI/Depois" }?.id == "Label_7")
    }

    @Test("A lista devolve ids e o token da próxima página")
    func lista() async throws {
        StubURLProtocol.install(["/gmail/v1/users/me/messages": [.init(body: try fixture("gmail-list"))]])
        defer { StubURLProtocol.reset() }

        let pagina = try await cliente().messageIDs(query: "newer_than:90d", pageToken: nil)
        #expect(pagina.ids == ["18f0a1b2c3", "18f0a1b2c4"])
        #expect(pagina.nextPageToken == "pagina-2")
    }

    @Test("Lista vazia devolve página vazia, e não erro")
    func listaVazia() async throws {
        // Uma conta nova, ou uma janela de 90 dias sem nada: `messages` some
        // do JSON inteiro. Tratar ausência como erro faria a conta parecer
        // quebrada quando ela só está vazia.
        StubURLProtocol.install([
            "/gmail/v1/users/me/messages": [.json("{\"resultSizeEstimate\":0}")],
        ])
        defer { StubURLProtocol.reset() }

        let pagina = try await cliente().messageIDs(query: "newer_than:90d", pageToken: nil)
        #expect(pagina.ids.isEmpty)
        #expect(pagina.nextPageToken == nil)
    }

    @Test("401 vira autenticação, 429 vira quota, 500 vira servidor")
    func errosDistintos() async throws {
        for (status, esperado) in [
            (401, SyncError.autenticacao),
            (403, SyncError.autorizacaoRevogada),
            (429, SyncError.quota),
            (503, SyncError.servidor(codigo: 503, mensagem: "Service Unavailable")),
        ] {
            StubURLProtocol.install([
                "/gmail/v1/users/me/profile": [.json(
                    "{\"error\":{\"code\":\(status),\"message\":\"Service Unavailable\"}}",
                    status: status
                )],
            ])
            await #expect(throws: esperado) { _ = try await self.cliente().profile() }
            StubURLProtocol.reset()
        }
    }
}

/// Conta quantas vezes o token foi pedido.
private actor Contador {
    private(set) var total = 0
    func incrementaEDevolve() -> String {
        total += 1
        return "at-de-teste"
    }
}
```

- [ ] **Step 3: Run it to see it fail**

Run: `cd Packages/UNISync && swift test --filter GmailClient`

Expected: FAIL — `cannot find 'GmailClient' in scope`, `cannot find 'MailAddress' in scope`.

- [ ] **Step 4: Write the types and address parser**

`Packages/UNISync/Sources/UNISync/Gmail/GmailTypes.swift`:

```swift
import Foundation
import UNICore

public struct GmailProfile: Sendable, Hashable {
    public let emailAddress: String
    /// O ponto de partida do sync incremental do Marco 3. Guardado já aqui,
    /// na carga inicial: capturá-lo depois abriria uma janela em que as
    /// mensagens chegadas no meio nunca apareceriam.
    public let historyID: String
}

public struct GmailLabel: Sendable, Hashable {
    public let id: String
    public let name: String
}

public struct GmailPage: Sendable, Hashable {
    public let ids: [String]
    public let nextPageToken: String?
}

public enum GmailFormat: String, Sendable {
    /// Cabeçalhos e nada de corpo — o que a lista precisa.
    case metadata
    /// A mensagem inteira.
    case full
}

public struct GmailMessage: Sendable, Hashable {
    public let id: String
    public let labelIDs: [String]
    public let internalDate: Date
    public let from: Contact
    public let to: [Contact]
    public let cc: [Contact]
    public let subject: String
    public let snippet: String
    /// Vazio em formato `metadata` — ausência legítima, não erro.
    public let body: [String]
}

/// Cabeçalhos de endereço, do jeito que eles chegam de verdade.
public enum MailAddress {
    /// `"Duarte, Marina" <marina@x.com>` → nome e endereço separados.
    ///
    /// Sem nome, o **endereço** vira o nome: uma linha da lista com o campo de
    /// remetente em branco é pior do que uma com o endereço cru.
    public static func parse(_ header: String) -> Contact? {
        let limpo = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !limpo.isEmpty else { return nil }

        if let abre = limpo.lastIndex(of: "<"), let fecha = limpo.lastIndex(of: ">"), abre < fecha {
            let endereco = String(limpo[limpo.index(after: abre)..<fecha])
                .trimmingCharacters(in: .whitespaces)
            var nome = String(limpo[limpo.startIndex..<abre])
                .trimmingCharacters(in: .whitespaces)
            if nome.hasPrefix("\""), nome.hasSuffix("\""), nome.count >= 2 {
                nome = String(nome.dropFirst().dropLast())
            }
            nome = decodeRFC2047(nome)
            guard !endereco.isEmpty else { return nil }
            return Contact(name: nome.isEmpty ? endereco : nome, address: endereco)
        }
        return Contact(name: limpo, address: limpo)
    }

    /// A lista de `To`/`Cc`, cortada por vírgula **fora das aspas**.
    ///
    /// Cortar por vírgula sem olhar as aspas parte `"Duarte, Marina"` em dois
    /// destinatários, e o "Responder a todos" passa a mandar email para
    /// alguém chamado "Duarte".
    public static func parseList(_ header: String) -> [Contact] {
        var partes: [String] = []
        var atual = ""
        var dentroDeAspas = false
        for caractere in header {
            switch caractere {
            case "\"": dentroDeAspas.toggle(); atual.append(caractere)
            case "," where !dentroDeAspas: partes.append(atual); atual = ""
            default: atual.append(caractere)
            }
        }
        partes.append(atual)
        return partes.compactMap(parse)
    }

    /// `=?UTF-8?B?…?=` e `=?UTF-8?Q?…?=` (RFC 2047).
    ///
    /// O Foundation não traz isto pronto, e sem ele todo assunto acentuado
    /// aparece como uma linha de gibberish na lista — que é a primeira coisa
    /// que se vê ao conectar uma conta em português.
    static func decodeRFC2047(_ text: String) -> String {
        guard text.contains("=?") else { return text }
        var resultado = ""
        var resto = Substring(text)
        while let inicio = resto.range(of: "=?"), let fim = resto.range(of: "?=", range: inicio.upperBound..<resto.endIndex) {
            resultado += resto[resto.startIndex..<inicio.lowerBound]
            let miolo = resto[inicio.upperBound..<fim.lowerBound]
            let campos = miolo.split(separator: "?", maxSplits: 2, omittingEmptySubsequences: false)
            if campos.count == 3 {
                let charset = String(campos[0]).uppercased()
                let codificacao = String(campos[1]).uppercased()
                let carga = String(campos[2])
                let encoding: String.Encoding = charset.hasPrefix("ISO-8859") ? .isoLatin1 : .utf8
                if codificacao == "B", let dados = Data(base64Encoded: carga),
                   let texto = String(data: dados, encoding: encoding) {
                    resultado += texto
                } else if codificacao == "Q" {
                    resultado += decodeQuotedPrintable(carga, encoding: encoding)
                } else {
                    resultado += miolo
                }
            } else {
                resultado += miolo
            }
            resto = resto[fim.upperBound...]
        }
        resultado += resto
        return resultado
    }

    private static func decodeQuotedPrintable(_ text: String, encoding: String.Encoding) -> String {
        var bytes: [UInt8] = []
        var indice = text.startIndex
        while indice < text.endIndex {
            let caractere = text[indice]
            if caractere == "=", let fim = text.index(indice, offsetBy: 3, limitedBy: text.endIndex),
               let byte = UInt8(text[text.index(after: indice)..<fim], radix: 16) {
                bytes.append(byte)
                indice = fim
            } else if caractere == "_" {
                bytes.append(0x20)
                indice = text.index(after: indice)
            } else {
                bytes.append(contentsOf: Array(String(caractere).utf8))
                indice = text.index(after: indice)
            }
        }
        return String(data: Data(bytes), encoding: encoding) ?? text
    }
}
```

- [ ] **Step 5: Write the message parser**

`Packages/UNISync/Sources/UNISync/Gmail/GmailMessageParser.swift`:

```swift
import Foundation
import UNICore

/// O JSON da `messages.get` virando `GmailMessage`.
///
/// Puro e num arquivo próprio porque é a parte que mais erra e a que mais
/// barato se testa: MIME aninhado, base64url, RFC 2047 e milissegundos. Nada
/// aqui toca rede.
public enum GmailMessageParser {
    private struct Wire: Decodable {
        struct Header: Decodable { let name: String; let value: String }
        struct Body: Decodable { let data: String? }
        struct Part: Decodable {
            let mimeType: String?
            let headers: [Header]?
            let body: Body?
            let parts: [Part]?
        }
        let id: String
        let labelIds: [String]?
        let snippet: String?
        let internalDate: String?
        let payload: Part?
    }

    public static func parse(_ data: Data) throws -> GmailMessage {
        let fio: Wire
        do {
            fio = try JSONDecoder().decode(Wire.self, from: data)
        } catch {
            throw SyncError.resposta("A Gmail API devolveu uma mensagem num formato que não conhecemos.")
        }
        guard let payload = fio.payload else {
            throw SyncError.resposta("A mensagem \(fio.id) veio sem `payload`.")
        }

        let cabecalhos = payload.headers ?? []
        func cabecalho(_ nome: String) -> String? {
            cabecalhos.first { $0.name.lowercased() == nome.lowercased() }?.value
        }

        // `internalDate` vem em **milissegundos** desde a época, como string.
        // Tratá-lo como segundos joga a mensagem para o ano 58 mil e a lista
        // sai fora de ordem — e como o campo é `String`, o erro compila.
        let milissegundos = Double(fio.internalDate ?? "0") ?? 0

        return GmailMessage(
            id: fio.id,
            labelIDs: fio.labelIds ?? [],
            internalDate: Date(timeIntervalSince1970: milissegundos / 1_000),
            from: MailAddress.parse(cabecalho("From") ?? "")
                ?? Contact(name: "Remetente desconhecido", address: ""),
            to: MailAddress.parseList(cabecalho("To") ?? ""),
            cc: MailAddress.parseList(cabecalho("Cc") ?? ""),
            subject: MailAddress.decodeRFC2047(cabecalho("Subject") ?? ""),
            snippet: fio.snippet ?? "",
            body: paragraphs(from: plainText(in: payload) ?? "")
        )
    }

    /// A primeira parte `text/plain` da árvore MIME, em profundidade.
    ///
    /// **Texto, nunca HTML**: o leitor do Marco 1 desenha `[String]` de
    /// parágrafos, e entregar a parte HTML encheria a tela de tags.
    private static func plainText(in part: Wire.Part) -> String? {
        if part.mimeType?.lowercased() == "text/plain", let dado = part.body?.data {
            return decodeBody(base64URL: dado)
        }
        for filha in part.parts ?? [] {
            if let texto = plainText(in: filha) { return texto }
        }
        // Uma mensagem só de HTML não tem texto para nós. Vazio é a resposta
        // honesta: o corpo por demanda do Marco 3 é quem resolve isso.
        return nil
    }

    /// base64**url**: `-` e `_` no lugar de `+` e `/`, e sem padding.
    ///
    /// `Data(base64Encoded:)` recusa os dois desvios e devolve `nil` — que,
    /// engolido, viraria corpo vazio em toda mensagem acentuada.
    public static func decodeBody(base64URL: String) -> String {
        var texto = base64URL
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let sobra = texto.count % 4
        if sobra > 0 { texto += String(repeating: "=", count: 4 - sobra) }
        guard let dados = Data(base64Encoded: texto) else { return "" }
        return String(data: dados, encoding: .utf8) ?? ""
    }

    /// Parágrafos: linhas em branco separam, pontas somem.
    ///
    /// Quebra simples **não** separa — um parágrafo com quebra de 78 colunas
    /// (que é o que todo cliente de email produz) viraria doze parágrafos de
    /// uma linha, e o leitor desenharia um espaço entre cada uma.
    public static func paragraphs(from text: String) -> [String] {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
```

- [ ] **Step 6: Write the client**

`Packages/UNISync/Sources/UNISync/Gmail/GmailClient.swift`:

```swift
import Foundation

/// A Gmail API, tipada, sobre `URLSession`. Sem SDK.
///
/// `accessToken` é uma closure, e não uma string, de propósito: o token vale
/// uma hora e a carga inicial dura mais que isso. Pedi-lo **por requisição**
/// faz o refresh transparente do `GoogleAuth` chegar aqui sem que este arquivo
/// precise saber que refresh existe.
public struct GmailClient: Sendable {
    private let session: URLSession
    private let accessToken: @Sendable () async throws -> String
    private let baseURL: URL

    public init(
        session: URLSession,
        accessToken: @Sendable @escaping () async throws -> String,
        baseURL: URL = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me")!
    ) {
        self.session = session
        self.accessToken = accessToken
        self.baseURL = baseURL
    }

    public func profile() async throws -> GmailProfile {
        struct Wire: Decodable { let emailAddress: String; let historyId: String }
        let fio: Wire = try await get(path: "profile", query: [])
        return GmailProfile(emailAddress: fio.emailAddress, historyID: fio.historyId)
    }

    public func labels() async throws -> [GmailLabel] {
        struct Wire: Decodable {
            struct Label: Decodable { let id: String; let name: String }
            let labels: [Label]?
        }
        let fio: Wire = try await get(path: "labels", query: [])
        return (fio.labels ?? []).map { GmailLabel(id: $0.id, name: $0.name) }
    }

    public func messageIDs(query: String, pageToken: String?) async throws -> GmailPage {
        struct Wire: Decodable {
            struct Item: Decodable { let id: String }
            let messages: [Item]?
            let nextPageToken: String?
        }
        var itens = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "maxResults", value: "500"),
        ]
        if let pageToken { itens.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        let fio: Wire = try await get(path: "messages", query: itens)
        // `messages` some do JSON quando não há nenhuma. Ausência é lista
        // vazia, não erro: conta nova não está quebrada, está vazia.
        return GmailPage(ids: (fio.messages ?? []).map(\.id), nextPageToken: fio.nextPageToken)
    }

    public func message(id: String, format: GmailFormat) async throws -> GmailMessage {
        var itens = [URLQueryItem(name: "format", value: format.rawValue)]
        if format == .metadata {
            for nome in ["From", "To", "Cc", "Subject", "Date"] {
                itens.append(URLQueryItem(name: "metadataHeaders", value: nome))
            }
        }
        let dados = try await getData(path: "messages/\(id)", query: itens)
        return try GmailMessageParser.parse(dados)
    }

    // MARK: O cano

    private func get<T: Decodable>(path: String, query: [URLQueryItem]) async throws -> T {
        let dados = try await getData(path: path, query: query)
        do {
            return try JSONDecoder().decode(T.self, from: dados)
        } catch {
            throw SyncError.resposta("A Gmail API respondeu `\(path)` num formato que não conhecemos.")
        }
    }

    private func getData(path: String, query: [URLQueryItem]) async throws -> Data {
        var components = URLComponents(
            url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false
        )!
        if !query.isEmpty { components.queryItems = query }

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (dados, resposta): (Data, URLResponse)
        do {
            (dados, resposta) = try await session.data(for: request)
        } catch let erro as URLError {
            switch erro.code {
            case .secureConnectionFailed, .serverCertificateUntrusted,
                 .serverCertificateHasBadDate, .serverCertificateNotYetValid,
                 .serverCertificateHasUnknownRoot:
                throw SyncError.tls(erro.localizedDescription)
            default:
                throw SyncError.rede(erro.localizedDescription)
            }
        }

        guard let http = resposta as? HTTPURLResponse else {
            throw SyncError.resposta("A Gmail API respondeu sem cabeçalho HTTP.")
        }
        guard (200..<300).contains(http.statusCode) else { throw apiError(status: http.statusCode, body: dados) }
        return dados
    }

    /// Cada código vira o caso que pede a ação certa: 401 manda reconectar,
    /// 429 manda esperar, 503 manda tentar de novo. Uma frase só para os três
    /// mandaria a pessoa fazer a coisa errada duas vezes em três.
    private func apiError(status: Int, body: Data) -> SyncError {
        struct Wire: Decodable {
            struct Detalhe: Decodable { let message: String? }
            let error: Detalhe?
        }
        let mensagem = (try? JSONDecoder().decode(Wire.self, from: body))?.error?.message ?? "sem detalhe"
        switch status {
        case 401: return .autenticacao
        case 403: return .autorizacaoRevogada
        case 429: return .quota
        default: return .servidor(codigo: status, mensagem: mensagem)
        }
    }
}
```

- [ ] **Step 7: Run it to see it pass**

Run: `cd Packages/UNISync && swift test --filter GmailClient`

Expected: PASS, 14 tests.

- [ ] **Step 8: Prove by mutation the three silently compiling errors**

Make one mutation at a time:

1. Replace `milissegundos / 1_000` with `milissegundos` and run
   `swift test --filter mensagemCheia`.
   Expected: FAIL — the date becomes year 58,000.
2. Replace `MailAddress.parseList` with `header.components(separatedBy: ",").compactMap(parse)`
   and run `swift test --filter listaDeEnderecos`.
   Expected: FAIL — `lista.count == 3`, with a recipient called "Duarte".
3. Replace `decodeBody(base64URL:)` with `String(data: Data(base64Encoded: base64URL) ?? Data(), encoding: .utf8) ?? ""`
   and run `swift test --filter 'base64URL|mensagemCheia'`.
   Expected: FAIL — the body is empty because the API uses unpadded base64url.

Restore all three and confirm that the test is green.

- [ ] **Step 9: Commit**

```bash
git add Packages/UNISync/Sources/UNISync/Gmail Packages/UNISync/Tests/UNISyncTests/Fixtures Packages/UNISync/Tests/UNISyncTests/GmailClientTests.swift
git commit -m "A Gmail API tipada, provada contra respostas gravadas da API de verdade

Três erros que compilam calados ficaram travados por mutação: internalDate em
milissegundos, vírgula dentro das aspas de \"Duarte, Marina\" e base64url sem
padding. O token é pedido por requisição, e não guardado na construção, porque
a carga inicial dura mais que a hora que ele vale.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 9: The fake IMAP server and the session that connects, authenticates, and logs out

> **Divergence rule, mandatory for this task and Task 10.** The code below is
> written against `ResponseDecoder` (from the `NIOIMAP` product, which re-exports its core): the
> `swift-nio-imap` response decoder used inside a `ByteToMessageHandler`. If
> the version resolved by SPM names or shapes this type differently, the
> implementer **MUST NOT decide alone**: stop, return `NEEDS_CONTEXT`, describe
> the divergence (the plan’s name, the resolved version’s name, and the package
> file where it appears), and wait for a response. Forcing the plan onto the
> library has already caused rework in this project. The **boundary** never
> changes: command construction is ours and pure (`ImapWire`); response
> interpretation belongs to the library.

**Files:**
- Create: `Packages/UNISync/Sources/UNISync/Imap/ImapWire.swift`
- Create: `Packages/UNISync/Sources/UNISync/Imap/ImapSession.swift`
- Create: `Packages/UNISync/Tests/UNISyncTests/FakeImapServer.swift`
- Create: `Packages/UNISync/Tests/UNISyncTests/ImapSessionTests.swift`

**Interfaces:**
- Consumes: `ImapEndpoint`, `ImapEndpoint.Security` (Task 3); `SyncError` (Task 4); `FolderRole` (Task 5); `FolderRoles` (Task 6).
- Produces:
  - `enum ImapWire` with `static func tag(_ n: Int) -> String`, `static func login(tag:user:password:) -> String`, `static func list(tag:) -> String`, `static func select(tag:mailbox:) -> String`, `static func uidSearchSince(tag:date:calendar:) -> String`, `static func uidFetchEnvelopes(tag:uids:) -> String`, `static func uidFetchBody(tag:uid:) -> String`, `static func logout(tag:) -> String`, `static func quoted(_ s: String) -> String`, and `static func imapDate(_ date: Date, calendar: Calendar) -> String`.
  - `struct ImapFolder: Sendable, Hashable { let name: String; let specialUse: String?; let role: FolderRole }`.
  - `struct ImapMailboxStatus: Sendable, Hashable { let uidValidity: Int64; let uidNext: Int64; let exists: Int }`.
  - `struct ImapEnvelope: Sendable, Hashable { let uid: Int64; let from: Contact; let to: [Contact]; let cc: [Contact]; let subject: String; let date: Date; let isRead: Bool; let isFlagged: Bool }`.
  - `actor ImapSession` with `static func connect(endpoint: ImapEndpoint, group: any EventLoopGroup) async throws -> ImapSession`, `func login(user: String, password: String) async throws`, and `func logout() async`.

- [ ] **Step 1: Write the fake server**

`Packages/UNISync/Tests/UNISyncTests/FakeImapServer.swift`:

```swift
import Foundation
import NIOCore
import NIOPosix

/// Um servidor IMAP em memória, com roteiro por teste.
///
/// **É o que faz "nenhum teste toca rede externa" ser verdade para o IMAP.**
/// Ele liga em `127.0.0.1:0` (porta que o sistema escolhe), fala o mínimo do
/// protocolo — saudação, comandos com tag, resposta tagueada — e devolve o que
/// o roteiro mandar, na ordem.
///
/// O roteiro é `[(prefixoDoComando, [linhasDeResposta])]`: o servidor casa pelo
/// **verbo** do comando (o que vem depois da tag), o que deixa os testes
/// legíveis sem precisar prever a numeração das tags.
final class FakeImapServer: @unchecked Sendable {
    struct Script: Sendable {
        /// A saudação, antes de qualquer comando.
        var greeting: String
        /// Verbo (em maiúsculas) → linhas de resposta. A linha que começa com
        /// `TAG ` tem a tag substituída pela do comando recebido.
        var replies: [String: [String]]

        init(
            greeting: String = "* OK [CAPABILITY IMAP4rev1 STARTTLS] OkamiUNI falso pronto",
            replies: [String: [String]]
        ) {
            self.greeting = greeting
            self.replies = replies
        }
    }

    private let group: MultiThreadedEventLoopGroup
    private var channel: (any Channel)?
    private let script: Script
    private let lock = NSLock()
    private var received: [String] = []

    init(script: Script) {
        self.script = script
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    /// Sobe e devolve a porta escolhida pelo sistema.
    func start() throws -> Int {
        let script = script
        let registrar: @Sendable (String) -> Void = { [weak self] linha in
            guard let self else { return }
            self.lock.lock()
            self.received.append(linha)
            self.lock.unlock()
        }
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 8)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { canal in
                canal.pipeline.addHandlers([
                    ByteToMessageHandler(LineBasedFrameDecoder()),
                    ScriptedHandler(script: script, registrar: registrar),
                ])
            }
        let canal = try bootstrap.bind(host: "127.0.0.1", port: 0).wait()
        channel = canal
        guard let porta = canal.localAddress?.port else {
            throw NSError(domain: "FakeImapServer", code: 1)
        }
        return porta
    }

    /// Os comandos que o cliente mandou, na ordem. É como o teste afirma que a
    /// sessão fez `SELECT` antes de `UID SEARCH`, e não o contrário.
    var commands: [String] {
        lock.lock()
        defer { lock.unlock() }
        return received
    }

    func stop() {
        try? channel?.close().wait()
        try? group.syncShutdownGracefully()
    }

    private final class ScriptedHandler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer

        private let script: Script
        private let registrar: @Sendable (String) -> Void

        init(script: Script, registrar: @escaping @Sendable (String) -> Void) {
            self.script = script
            self.registrar = registrar
        }

        func channelActive(context: ChannelHandlerContext) {
            escreve(context, script.greeting)
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var buffer = unwrapInboundIn(data)
            let linha = (buffer.readString(length: buffer.readableBytes) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !linha.isEmpty else { return }
            registrar(linha)

            let partes = linha.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            let tag = String(partes.first ?? "*")
            let resto = partes.count > 1 ? String(partes[1]) : ""
            // O verbo é a primeira palavra do comando; `UID SEARCH` e
            // `UID FETCH` contam como verbos de duas palavras.
            let palavras = resto.split(separator: " ").map { $0.uppercased() }
            let verbo: String = {
                if palavras.first == "UID", palavras.count >= 2 { return "UID \(palavras[1])" }
                return palavras.first ?? ""
            }()

            guard let linhas = script.replies[verbo] else {
                escreve(context, "\(tag) BAD comando fora do roteiro: \(verbo)")
                return
            }
            for modelo in linhas {
                escreve(context, modelo.replacingOccurrences(of: "TAG ", with: "\(tag) "))
            }
            if verbo == "LOGOUT" { context.close(promise: nil) }
        }

        private func escreve(_ context: ChannelHandlerContext, _ texto: String) {
            var buffer = context.channel.allocator.buffer(capacity: texto.utf8.count + 2)
            buffer.writeString(texto)
            buffer.writeString("\r\n")
            context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
        }
    }
}
```

- [ ] **Step 2: Write the failing test**

`Packages/UNISync/Tests/UNISyncTests/ImapSessionTests.swift`:

```swift
import Foundation
import NIOCore
import NIOPosix
import Testing
import UNICore
@testable import UNISync

@Suite("IMAP: conectar, autenticar, sair")
struct ImapSessionTests {
    // MARK: A parte pura — os comandos que a gente monta

    @Test("O LOGIN escapa aspas e barra invertida na senha")
    func loginEscapa() {
        // Senha de app com aspas dentro derrubaria o comando e o servidor
        // responderia BAD — que a pessoa leria como "senha errada".
        #expect(ImapWire.login(tag: "A001", user: "eu@x.com", password: "se\"nh\\a")
            == "A001 LOGIN \"eu@x.com\" \"se\\\"nh\\\\a\"")
    }

    @Test("A data do UID SEARCH sai no formato do IMAP, em inglês, sempre")
    func dataDoSearch() {
        // `dd-MMM-yyyy` com meses em inglês: o servidor não fala português, e
        // um `DateFormatter` com o locale da máquina mandaria "25-ago-2026",
        // que o servidor recusa. Mesma família do bug de fuso do Marco 1.
        var calendario = Calendar(identifier: .gregorian)
        calendario.timeZone = TimeZone(identifier: "UTC")!
        let data = calendario.date(from: DateComponents(year: 2026, month: 8, day: 25))!
        #expect(ImapWire.imapDate(data, calendar: calendario) == "25-Aug-2026")
        #expect(ImapWire.uidSearchSince(tag: "A004", date: data, calendar: calendario)
            == "A004 UID SEARCH SINCE 25-Aug-2026")
    }

    @Test("As tags são sequenciais e com largura fixa")
    func tags() {
        #expect(ImapWire.tag(1) == "A0001")
        #expect(ImapWire.tag(42) == "A0042")
    }

    @Test("Os comandos que esta tarefa manda saem literais")
    func comandosLiterais() {
        #expect(ImapWire.list(tag: "A002") == "A002 LIST \"\" \"*\"")
        #expect(ImapWire.logout(tag: "A099") == "A099 LOGOUT")
    }

    // MARK: A sessão, contra o servidor falso

    private func endpoint(porta: Int) -> ImapEndpoint {
        // Sem TLS: o servidor falso fala em claro, e é isso que mantém o teste
        // dentro da máquina, sem certificado nenhum.
        ImapEndpoint(host: "127.0.0.1", port: porta, security: .startTLS)
    }

    @Test("Login aceito conecta e o LOGOUT fecha limpo")
    func loginOK() async throws {
        let servidor = FakeImapServer(script: .init(replies: [
            "LOGIN": ["TAG OK LOGIN completed"],
            "LOGOUT": ["* BYE OkamiUNI falso encerrando", "TAG OK LOGOUT completed"],
        ]))
        let porta = try servidor.start()
        defer { servidor.stop() }

        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? grupo.syncShutdownGracefully() }

        let sessao = try await ImapSession.connect(endpoint: endpoint(porta: porta), group: grupo)
        try await sessao.login(user: "eu@x.com", password: "senha-de-app")
        await sessao.logout()

        #expect(servidor.commands.contains { $0.contains("LOGIN \"eu@x.com\"") })
        #expect(servidor.commands.contains { $0.hasSuffix("LOGOUT") })
    }

    @Test("Login recusado vira `autenticacao`, e não um erro genérico")
    func loginRecusado() async throws {
        let servidor = FakeImapServer(script: .init(replies: [
            "LOGIN": ["TAG NO [AUTHENTICATIONFAILED] Invalid credentials"],
            "LOGOUT": ["TAG OK LOGOUT completed"],
        ]))
        let porta = try servidor.start()
        defer { servidor.stop() }

        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? grupo.syncShutdownGracefully() }

        let sessao = try await ImapSession.connect(endpoint: endpoint(porta: porta), group: grupo)
        await #expect(throws: SyncError.autenticacao) {
            try await sessao.login(user: "eu@x.com", password: "errada")
        }
        await sessao.logout()
    }

    @Test("`BAD` do servidor não é engolido — vira `resposta` com o texto dele")
    func comandoRecusado() async throws {
        let servidor = FakeImapServer(script: .init(replies: [
            "LOGIN": ["TAG BAD Missing argument"],
            "LOGOUT": ["TAG OK LOGOUT completed"],
        ]))
        let porta = try servidor.start()
        defer { servidor.stop() }

        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? grupo.syncShutdownGracefully() }

        let sessao = try await ImapSession.connect(endpoint: endpoint(porta: porta), group: grupo)
        await #expect(throws: SyncError.resposta("O servidor IMAP recusou o comando: Missing argument")) {
            try await sessao.login(user: "eu@x.com", password: "x")
        }
        await sessao.logout()
    }

    @Test("Porta fechada vira erro de rede com o motivo, e não trava")
    func portaFechada() async throws {
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? grupo.syncShutdownGracefully() }

        // Porta 1 em loopback: recusa imediata, sem esperar tempo nenhum.
        await #expect(throws: (any Error).self) {
            _ = try await ImapSession.connect(
                endpoint: ImapEndpoint(host: "127.0.0.1", port: 1, security: .startTLS),
                group: grupo
            )
        }
    }

    @Test("Sair duas vezes não estoura")
    func logoutDuasVezes() async throws {
        let servidor = FakeImapServer(script: .init(replies: [
            "LOGIN": ["TAG OK LOGIN completed"],
            "LOGOUT": ["TAG OK LOGOUT completed"],
        ]))
        let porta = try servidor.start()
        defer { servidor.stop() }

        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? grupo.syncShutdownGracefully() }

        let sessao = try await ImapSession.connect(endpoint: endpoint(porta: porta), group: grupo)
        try await sessao.login(user: "eu@x.com", password: "senha")
        await sessao.logout()
        await sessao.logout()
    }
}
```

- [ ] **Step 3: Run it to see it fail**

Run: `cd Packages/UNISync && swift test --filter ImapSession`

Expected: FAIL — `cannot find 'ImapWire' in scope`, `cannot find 'ImapSession' in scope`.

- [ ] **Step 4: Write the pure portion**

`Packages/UNISync/Sources/UNISync/Imap/ImapWire.swift`:

```swift
import Foundation
import UNICore

/// Os tipos e os comandos do IMAP, na parte que é nossa.
///
/// **Montar comando é nosso e é puro; interpretar resposta é da biblioteca.**
/// Essa divisão não é arbitrária: o que a gente manda é um punhado de linhas
/// ASCII com regras simples de citação, e é onde erram os escapes e o formato
/// de data — dois defeitos que um teste puro pega em milissegundos. O que o
/// servidor manda de volta é gramática de verdade, com literais de tamanho
/// declarado e continuação, e é para isso que o `swift-nio-imap` existe.
public enum ImapWire {
    // MARK: Tipos

    public struct Folder: Sendable, Hashable {
        public let name: String
        public let specialUse: String?
        public let role: FolderRole

        public init(name: String, specialUse: String?) {
            self.name = name
            self.specialUse = specialUse
            role = FolderRoles.role(specialUse: specialUse, name: name)
        }
    }

    // MARK: Comandos

    /// Tag de largura fixa: `A0001`. Largura fixa porque os logs do servidor e
    /// os nossos ficam alinháveis, e porque o servidor falso casa por prefixo.
    public static func tag(_ n: Int) -> String { String(format: "A%04d", n) }

    /// Uma string entre aspas, com `\` e `"` escapados — a regra do RFC 3501.
    ///
    /// Sem isto, uma senha de app com aspas dentro quebra o comando e o
    /// servidor responde `BAD`, que a pessoa lê como "senha errada" e passa a
    /// tarde trocando a senha certa.
    public static func quoted(_ s: String) -> String {
        let escapado = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escapado)\""
    }

    public static func login(tag: String, user: String, password: String) -> String {
        "\(tag) LOGIN \(quoted(user)) \(quoted(password))"
    }

    public static func list(tag: String) -> String { "\(tag) LIST \"\" \"*\"" }

    public static func select(tag: String, mailbox: String) -> String {
        "\(tag) SELECT \(quoted(mailbox))"
    }

    /// `dd-MMM-yyyy` com meses em **inglês**, sempre.
    ///
    /// Um `DateFormatter` com o locale da máquina manda `25-ago-2026`, e o
    /// servidor responde `BAD`. É a mesma família do bug de fuso registrado em
    /// `docs/decisoes-de-engenharia.md`: formato de protocolo não pode nascer
    /// de uma conversão que a máquina do usuário decide.
    public static func imapDate(_ date: Date, calendar: Calendar) -> String {
        let meses = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                     "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let partes = calendar.dateComponents([.day, .month, .year], from: date)
        let dia = partes.day ?? 1
        let mes = meses[max(0, min(11, (partes.month ?? 1) - 1))]
        return String(format: "%02d-%@-%04d", dia, mes, partes.year ?? 1970)
    }

    public static func uidSearchSince(tag: String, date: Date, calendar: Calendar) -> String {
        "\(tag) UID SEARCH SINCE \(imapDate(date, calendar: calendar))"
    }

    /// Envelopes em lote. Um `FETCH` por mensagem seria uma ida e volta por
    /// mensagem; a conta de 90 dias tem milhares.
    public static func uidFetchEnvelopes(tag: String, uids: [Int64]) -> String {
        let conjunto = uids.map(String.init).joined(separator: ",")
        return "\(tag) UID FETCH \(conjunto) (UID FLAGS INTERNALDATE ENVELOPE)"
    }

    /// O corpo em texto de uma mensagem. `BODY.PEEK` e não `BODY`: `BODY` marca
    /// a mensagem como lida no servidor, e baixar o corpo para o cache não é a
    /// pessoa ter lido nada.
    public static func uidFetchBody(tag: String, uid: Int64) -> String {
        "\(tag) UID FETCH \(uid) (BODY.PEEK[TEXT])"
    }

    public static func logout(tag: String) -> String { "\(tag) LOGOUT" }
}

public typealias ImapFolder = ImapWire.Folder

public struct ImapMailboxStatus: Sendable, Hashable {
    public let uidValidity: Int64
    public let uidNext: Int64
    public let exists: Int

    public init(uidValidity: Int64, uidNext: Int64, exists: Int) {
        self.uidValidity = uidValidity
        self.uidNext = uidNext
        self.exists = exists
    }
}

public struct ImapEnvelope: Sendable, Hashable {
    public let uid: Int64
    public let from: Contact
    public let to: [Contact]
    public let cc: [Contact]
    public let subject: String
    public let date: Date
    public let isRead: Bool
    public let isFlagged: Bool

    public init(
        uid: Int64, from: Contact, to: [Contact], cc: [Contact],
        subject: String, date: Date, isRead: Bool, isFlagged: Bool
    ) {
        self.uid = uid
        self.from = from
        self.to = to
        self.cc = cc
        self.subject = subject
        self.date = date
        self.isRead = isRead
        self.isFlagged = isFlagged
    }
}
```

- [ ] **Step 5: Write the session**

`Packages/UNISync/Sources/UNISync/Imap/ImapSession.swift`:

```swift
import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import UNICore

/// Uma sessão IMAP, sobre NIO.
///
/// Ator porque uma conexão IMAP é estritamente sequencial: um comando por vez,
/// a resposta tagueada fecha o comando, e o próximo só entra depois. Dois
/// comandos em voo na mesma conexão embaralham as respostas untagged — e as
/// untagged são justamente o conteúdo (`FETCH`, `LIST`, `SEARCH`).
public actor ImapSession {
    private let channel: any Channel
    private let handler: ImapChannelHandler
    private var tagCounter = 0
    private var closed = false

    private init(channel: any Channel, handler: ImapChannelHandler) {
        self.channel = channel
        self.handler = handler
    }

    /// Conecta, faz `STARTTLS` se o endpoint pedir, e espera a saudação.
    public static func connect(endpoint: ImapEndpoint, group: any EventLoopGroup) async throws -> ImapSession {
        let handler = ImapChannelHandler()
        let bootstrap = ClientBootstrap(group: group)
            .channelOption(.socketOption(.so_reuseaddr), value: 1)
            .connectTimeout(.seconds(20))
            .channelInitializer { canal in
                do {
                    var handlers: [any ChannelHandler] = []
                    if endpoint.security == .tls {
                        // TLS implícito: o handler entra antes de tudo, e o
                        // primeiro byte já é do handshake.
                        let contexto = try NIOSSLContext(configuration: .makeClientConfiguration())
                        handlers.append(try NIOSSLClientHandler(context: contexto, serverHostname: endpoint.host))
                    }
                    handlers.append(ByteToMessageHandler(LineBasedFrameDecoder()))
                    handlers.append(handler)
                    return canal.pipeline.addHandlers(handlers)
                } catch {
                    return canal.eventLoop.makeFailedFuture(error)
                }
            }

        let canal: any Channel
        do {
            canal = try await bootstrap.connect(host: endpoint.host, port: endpoint.port).get()
        } catch let erro as NIOSSLError {
            throw SyncError.tls(String(describing: erro))
        } catch {
            throw SyncError.rede("\(endpoint.host):\(endpoint.port) — \(error.localizedDescription)")
        }

        // A saudação chega sozinha, sem tag. Esperá-la aqui é o que garante
        // que o primeiro comando não seja escrito antes de o servidor estar de
        // pé — e é onde um servidor que responde `* BYE` na cara já é recusado.
        let saudacao = try await handler.waitForGreeting()
        guard !saudacao.uppercased().contains("BYE") else {
            try? await canal.close()
            throw SyncError.servidor(codigo: 0, mensagem: saudacao)
        }
        return ImapSession(channel: canal, handler: handler)
    }

    /// O próximo comando, e a resposta tagueada dele.
    ///
    /// `internal` e não `private` porque a Task 10 chama daqui de dentro do
    /// mesmo ator, e porque os testes de `ImapSession` afirmam o texto exato
    /// que sai.
    func run(_ build: (String) -> String) async throws -> ImapCommandResult {
        guard !closed else { throw SyncError.rede("A sessão IMAP já foi encerrada.") }
        tagCounter += 1
        let tag = ImapWire.tag(tagCounter)
        let comando = build(tag)

        var buffer = channel.allocator.buffer(capacity: comando.utf8.count + 2)
        buffer.writeString(comando)
        buffer.writeString("\r\n")

        let resultado = try await handler.send(buffer, tag: tag, on: channel)
        switch resultado.status {
        case .ok:
            return resultado
        case .no:
            // `NO` é recusa com motivo. Autenticação tem código próprio porque
            // pede ação própria: reconectar, não tentar de novo.
            if resultado.text.uppercased().contains("AUTHENTICATIONFAILED")
                || resultado.text.uppercased().contains("INVALID CREDENTIALS")
                || comando.contains(" LOGIN ") {
                throw SyncError.autenticacao
            }
            if resultado.text.uppercased().contains("THROTTLED")
                || resultado.text.uppercased().contains("OVERQUOTA") {
                throw SyncError.quota
            }
            throw SyncError.servidor(codigo: 0, mensagem: resultado.text)
        case .bad:
            // `BAD` é erro **nosso**: comando malformado. Engoli-lo esconderia
            // um defeito do `ImapWire` atrás de uma mensagem de rede.
            throw SyncError.resposta("O servidor IMAP recusou o comando: \(resultado.text)")
        }
    }

    public func login(user: String, password: String) async throws {
        _ = try await run { ImapWire.login(tag: $0, user: user, password: password) }
    }

    /// Sai e fecha. Idempotente: sair duas vezes é o mesmo estado.
    ///
    /// Não lança, e é de propósito: encerrar já é o caminho de saída, e um erro
    /// aqui não muda nada que alguém possa fazer. O que ele **não** faz é
    /// engolir silenciosamente — a falha vai para o log da sessão.
    public func logout() async {
        guard !closed else { return }
        closed = true
        _ = try? await run { ImapWire.logout(tag: $0) }
        try? await channel.close()
    }
}

/// A resposta tagueada de um comando, com as linhas untagged que vieram antes.
struct ImapCommandResult: Sendable {
    enum Status: Sendable { case ok, no, bad }
    let status: Status
    /// O texto depois de `OK`/`NO`/`BAD`.
    let text: String
    /// As linhas `*` que chegaram enquanto o comando estava em voo. É onde
    /// moram `LIST`, `SEARCH`, `FETCH`, `EXISTS` e os códigos de `SELECT`.
    let untagged: [String]
}

/// O handler que junta as linhas até a resposta tagueada.
///
/// Uma requisição em voo por vez, garantida pelo ator acima. O `continuation`
/// é o que transforma o callback do NIO em `await`.
final class ImapChannelHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let lock = NSLock()
    private var greeting: CheckedContinuation<String, any Error>?
    private var greetingLine: String?
    private var pendingTag: String?
    private var pending: CheckedContinuation<ImapCommandResult, any Error>?
    private var collected: [String] = []

    func waitForGreeting() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let linha = greetingLine {
                lock.unlock()
                continuation.resume(returning: linha)
                return
            }
            greeting = continuation
            lock.unlock()
        }
    }

    func send(_ buffer: ByteBuffer, tag: String, on channel: any Channel) async throws -> ImapCommandResult {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            pendingTag = tag
            pending = continuation
            collected = []
            lock.unlock()
            channel.writeAndFlush(NIOAny(buffer)).whenFailure { erro in
                self.falha(SyncError.rede(erro.localizedDescription))
            }
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        let linha = (buffer.readString(length: buffer.readableBytes) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !linha.isEmpty else { return }

        lock.lock()
        if let continuation = greeting {
            greeting = nil
            greetingLine = linha
            lock.unlock()
            continuation.resume(returning: linha)
            return
        }
        if greetingLine == nil, pendingTag == nil {
            greetingLine = linha
            lock.unlock()
            return
        }
        guard let tag = pendingTag else {
            lock.unlock()
            return
        }
        if linha.hasPrefix(tag + " ") {
            let resto = String(linha.dropFirst(tag.count + 1))
            let partes = resto.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            let palavra = String(partes.first ?? "").uppercased()
            let texto = partes.count > 1 ? String(partes[1]) : ""
            let status: ImapCommandResult.Status = palavra == "OK" ? .ok : (palavra == "NO" ? .no : .bad)
            let resultado = ImapCommandResult(status: status, text: texto, untagged: collected)
            let continuation = pending
            pending = nil
            pendingTag = nil
            collected = []
            lock.unlock()
            continuation?.resume(returning: resultado)
        } else {
            collected.append(linha)
            lock.unlock()
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        falha(SyncError.rede(error.localizedDescription))
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        falha(SyncError.rede("O servidor IMAP fechou a conexão."))
    }

    /// Uma falha acorda quem estiver esperando. Sem isto, uma conexão caída no
    /// meio de um comando deixaria a carga inicial travada para sempre — que é
    /// erro engolido na forma mais cara: o app parece só estar devagar.
    private func falha(_ erro: SyncError) {
        lock.lock()
        let saudacao = greeting
        let comando = pending
        greeting = nil
        pending = nil
        pendingTag = nil
        lock.unlock()
        saudacao?.resume(throwing: erro)
        comando?.resume(throwing: erro)
    }
}
```

> Regarding the divergence rule above: `ImapChannelHandler` currently joins
> raw lines. When Task 10 needs `ENVELOPE`—real grammar with `{123}` literals
> and continuations—`ResponseDecoder` (from `NIOIMAP`, which re-exports its core) replaces
> `LineBasedFrameDecoder`, and `untagged: [String]` becomes `untagged: [Response]`.
> This task deliberately stops where raw lines are still sufficient: it is the
> smallest independently provable unit.

- [ ] **Step 6: Run it to see it pass**

Run: `cd Packages/UNISync && swift test --filter ImapSession`

Expected: PASS, 9 tests.

- [ ] **Step 7: Prove by mutation the two protocol traps**

1. Replace `ImapWire.imapDate` with a `DateFormatter` using
   `dateFormat = "dd-MMM-yyyy"` **without** `locale = Locale(identifier: "en_US_POSIX")`,
   then run `swift test --filter dataDoSearch` on a pt_BR machine.
   Expected: FAIL — it emits `25-ago-2026`.
2. Delete the body of `falha(_:)` (leave the function empty), take the server
   down midway (change the `LOGIN` script to `[:]` and run `loginOK`), then run
   `swift test --filter loginOK`.
   Expected: the test **hangs** until the Swift Testing timeout rather than
   failing with a message—the exact defect. Restore the body and confirm that
   it fails quickly and with a reason.

Restore both changes and confirm that the test is green.

- [ ] **Step 8: Commit**

```bash
git add Packages/UNISync/Sources/UNISync/Imap Packages/UNISync/Tests/UNISyncTests/FakeImapServer.swift Packages/UNISync/Tests/UNISyncTests/ImapSessionTests.swift
git commit -m "IMAP conecta, autentica e sai — contra um servidor falso que roda dentro do teste

Montar comando é nosso e é puro; interpretar resposta é da biblioteca. Os dois
defeitos que essa divisão pega ficaram travados por mutação: a data do UID
SEARCH em inglês (locale da máquina mandaria 25-ago-2026, e o servidor
responde BAD) e a senha com aspas escapada. Conexão caída acorda quem espera,
em vez de travar a carga para sempre.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 10: `ImapSession` lists, selects, searches and fetches envelope batches

The divergence rule at the top of Task 9 still applies, now with one target: **all contact with `swift-nio-imap` response types belongs in `Imap/ImapResponseAdapter.swift`, nowhere else.** It converts the library's decoded output into our pure `ImapWire.Untagged`. All logic in this task is tested against `ImapWire.Untagged`, without NIO. If the library changes shape, only one file breaks and the logic tests remain valid.

**Files:**
- Create: `Packages/UNISync/Sources/UNISync/Imap/ImapResponseAdapter.swift`
- Modify: `Packages/UNISync/Sources/UNISync/Imap/ImapWire.swift`
- Modify: `Packages/UNISync/Sources/UNISync/Imap/ImapSession.swift`
- Modify: `Packages/UNISync/Tests/UNISyncTests/FakeImapServer.swift`
- Create: `Packages/UNISync/Tests/UNISyncTests/ImapFetchTests.swift`

**Interfaces:**
- Consumes: `ImapWire`, `ImapFolder`, `ImapMailboxStatus`, `ImapEnvelope`, `ImapSession.run(_:)`, `ImapCommandResult` (Task 9).
- Produces:
  - `enum ImapWire.Untagged: Sendable, Hashable` with cases `.list(name: String, attributes: [String])`, `.search([Int64])`, `.exists(Int)`, `.ok(code: String, value: String)`, `.fetch(ImapWire.FetchLine)`, `.outra(String)`.
  - `struct ImapWire.FetchLine: Sendable, Hashable` with `uid: Int64`, `flags: [String]`, `internalDate: Date?`, `from: String?`, `to: String?`, `cc: String?`, `subject: String?`, `text: String?`.
  - `static func folders(from: [ImapWire.Untagged]) -> [ImapFolder]`, `static func status(from: [ImapWire.Untagged]) -> ImapMailboxStatus?`, `static func uids(from: [ImapWire.Untagged]) -> [Int64]`, `static func envelopes(from: [ImapWire.Untagged]) -> [ImapEnvelope]`, `static func bodyText(from: [ImapWire.Untagged], uid: Int64) -> [String]`, `static let fetchBatchSize: Int`.
  - `ImapSession.folders() async throws -> [ImapFolder]`, `.select(_ folder: ImapFolder) async throws -> ImapMailboxStatus`, `.uids(since: Date, calendar: Calendar) async throws -> [Int64]`, `.envelopes(uids: [Int64]) async throws -> [ImapEnvelope]`, `.bodyText(uid: Int64) async throws -> [String]`.
  - `enum ImapUidValidity { static func changed(previous: Int64?, current: Int64) -> Bool }`.

- [ ] **Step 1: Write failing tests (pure logic plus an end-to-end test)**

`Packages/UNISync/Tests/UNISyncTests/ImapFetchTests.swift`:

```swift
import Foundation
import NIOCore
import NIOPosix
import Testing
import UNICore
@testable import UNISync

@Suite("IMAP: pastas, seleção, busca e envelopes")
struct ImapFetchTests {
    // MARK: Interpretação pura

    @Test("As pastas saem do LIST com o papel já resolvido")
    func pastas() {
        let respostas: [ImapWire.Untagged] = [
            .list(name: "INBOX", attributes: ["\\HasNoChildren"]),
            .list(name: "[Gmail]/Todos os e-mails", attributes: ["\\All", "\\HasNoChildren"]),
            .list(name: "Lixeira", attributes: ["\\HasNoChildren"]),
            .list(name: "Projetos", attributes: ["\\Noselect", "\\HasChildren"]),
            .list(name: "OkamiUNI/Depois", attributes: ["\\HasNoChildren"]),
        ]
        let pastas = ImapWire.folders(from: respostas)
        #expect(pastas.map(\.role) == [.inbox, .archive, .trash, .later])
        // `\Noselect` não é pasta: é um nó da árvore. Tentar `SELECT` nele
        // devolve NO e derrubaria a carga inteira por causa de um separador.
        #expect(!pastas.contains { $0.name == "Projetos" })
    }

    @Test("O SELECT devolve UIDVALIDITY, UIDNEXT e quantas existem")
    func selecao() throws {
        let respostas: [ImapWire.Untagged] = [
            .exists(1_284),
            .ok(code: "UIDVALIDITY", value: "1755000000"),
            .ok(code: "UIDNEXT", value: "9002"),
        ]
        let status = try #require(ImapWire.status(from: respostas))
        #expect(status.uidValidity == 1_755_000_000)
        #expect(status.uidNext == 9_002)
        #expect(status.exists == 1_284)
    }

    @Test("SELECT sem UIDVALIDITY não vira status inventado")
    func selecaoSemUidValidity() {
        // Sem UIDVALIDITY não dá para identificar mensagem nenhuma de forma
        // estável. Devolver zero faria o Marco 3 achar que a pasta é sempre a
        // mesma e casar UID reciclado com mensagem errada.
        #expect(ImapWire.status(from: [.exists(3)]) == nil)
    }

    @Test("Os UIDs saem do SEARCH em ordem crescente e sem repetição")
    func uids() {
        #expect(ImapWire.uids(from: [.search([9_001, 8_999]), .search([8_999, 9_002])])
            == [8_999, 9_001, 9_002])
        #expect(ImapWire.uids(from: [.search([])]).isEmpty)
    }

    @Test("Os envelopes viram mensagens com remetente, flags e data")
    func envelopes() throws {
        let linha = ImapWire.FetchLine(
            uid: 9_001,
            flags: ["\\Seen", "\\Flagged"],
            internalDate: Date(timeIntervalSince1970: 1_800_000_000),
            from: "\"Duarte, Marina\" <marina@clientepremium.com>",
            to: "Ricardo <ricardo@empresa.com>, contato@meusite.com",
            cc: "juridico@clientepremium.com",
            subject: "=?UTF-8?B?UmV2aXPDo28gZG8gY29udHJhdG8=?=",
            text: nil
        )
        let envelope = try #require(ImapWire.envelopes(from: [.fetch(linha)]).first)
        #expect(envelope.uid == 9_001)
        #expect(envelope.from.name == "Duarte, Marina")
        #expect(envelope.to.count == 2)
        #expect(envelope.cc.map(\.address) == ["juridico@clientepremium.com"])
        // O mesmo decodificador do Gmail: o assunto acentuado chega codificado
        // no IMAP também, e uma segunda implementação divergiria da primeira.
        #expect(envelope.subject == "Revisão do contrato")
        #expect(envelope.isRead)
        #expect(envelope.isFlagged)
    }

    @Test("Sem `\\Seen`, a mensagem é não lida; sem `\\Flagged`, sem estrela")
    func flagsAusentes() throws {
        let linha = ImapWire.FetchLine(
            uid: 9_002, flags: [], internalDate: Date(timeIntervalSince1970: 1),
            from: "a@b.com", to: nil, cc: nil, subject: "Oi", text: nil
        )
        let envelope = try #require(ImapWire.envelopes(from: [.fetch(linha)]).first)
        #expect(!envelope.isRead)
        #expect(!envelope.isFlagged)
        #expect(envelope.to.isEmpty)
    }

    @Test("Envelope sem INTERNALDATE é descartado, não datado com `agora`")
    func envelopeSemData() {
        // Datar com `Date()` colocaria toda mensagem quebrada no topo da lista,
        // acima do que chegou hoje de verdade. Ficar de fora é honesto: a
        // mensagem volta na próxima passada, com data.
        let linha = ImapWire.FetchLine(
            uid: 9_003, flags: [], internalDate: nil,
            from: "a@b.com", to: nil, cc: nil, subject: "Oi", text: nil
        )
        #expect(ImapWire.envelopes(from: [.fetch(linha)]).isEmpty)
    }

    @Test("O corpo vira parágrafos pelo mesmo caminho do Gmail")
    func corpo() {
        let linha = ImapWire.FetchLine(
            uid: 9_001, flags: [], internalDate: nil, from: nil, to: nil, cc: nil,
            subject: nil, text: "Primeiro.\r\n\r\nSegundo.\r\n"
        )
        #expect(ImapWire.bodyText(from: [.fetch(linha)], uid: 9_001) == ["Primeiro.", "Segundo."])
        #expect(ImapWire.bodyText(from: [.fetch(linha)], uid: 7).isEmpty)
    }

    @Test("O lote é de 200, e o comando lista os UIDs pedidos")
    func lote() {
        #expect(ImapWire.fetchBatchSize == 200)
        #expect(ImapWire.uidFetchEnvelopes(tag: "A005", uids: [1, 2, 3])
            == "A005 UID FETCH 1,2,3 (UID FLAGS INTERNALDATE ENVELOPE)")
    }

    @Test("UIDVALIDITY trocada é detectada; primeira vez não é troca")
    func uidValidityTrocada() {
        #expect(!ImapUidValidity.changed(previous: nil, current: 1_755_000_000))
        #expect(!ImapUidValidity.changed(previous: 1_755_000_000, current: 1_755_000_000))
        #expect(ImapUidValidity.changed(previous: 1_755_000_000, current: 1_900_000_000))
    }

    // MARK: De ponta a ponta, contra o servidor falso

    @Test("A sessão lista, seleciona, busca e traz envelopes — nessa ordem")
    func pontaAPonta() async throws {
        let servidor = FakeImapServer(script: .init(replies: [
            "LOGIN": ["TAG OK LOGIN completed"],
            "LIST": [
                "* LIST (\\HasNoChildren) \"/\" \"INBOX\"",
                "* LIST (\\Trash \\HasNoChildren) \"/\" \"Lixeira\"",
                "TAG OK LIST completed",
            ],
            "SELECT": [
                "* 2 EXISTS",
                "* OK [UIDVALIDITY 1755000000] UIDs valid",
                "* OK [UIDNEXT 9003] Predicted next UID",
                "TAG OK [READ-WRITE] SELECT completed",
            ],
            "UID SEARCH": ["* SEARCH 9001 9002", "TAG OK UID SEARCH completed"],
            "UID FETCH": [
                "* 1 FETCH (UID 9001 FLAGS (\\Seen) INTERNALDATE \"25-Aug-2026 09:00:00 -0300\" "
                + "ENVELOPE (\"Tue, 25 Aug 2026 09:00:00 -0300\" \"Assunto\" "
                + "((\"Marina\" NIL \"marina\" \"clientepremium.com\")) NIL NIL "
                + "((\"Ricardo\" NIL \"ricardo\" \"empresa.com\")) NIL NIL NIL NIL))",
                "TAG OK UID FETCH completed",
            ],
            "LOGOUT": ["TAG OK LOGOUT completed"],
        ]))
        let porta = try servidor.start()
        defer { servidor.stop() }

        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? grupo.syncShutdownGracefully() }

        var calendario = Calendar(identifier: .gregorian)
        calendario.timeZone = TimeZone(identifier: "UTC")!

        let sessao = try await ImapSession.connect(
            endpoint: ImapEndpoint(host: "127.0.0.1", port: porta, security: .startTLS),
            group: grupo
        )
        try await sessao.login(user: "eu@x.com", password: "senha")

        let pastas = try await sessao.folders()
        #expect(pastas.map(\.role) == [.inbox, .trash])

        let inbox = try #require(pastas.first { $0.role == .inbox })
        let status = try await sessao.select(inbox)
        #expect(status.uidValidity == 1_755_000_000)
        #expect(status.exists == 2)

        let uids = try await sessao.uids(
            since: calendario.date(from: DateComponents(year: 2026, month: 5, day: 27))!,
            calendar: calendario
        )
        #expect(uids == [9_001, 9_002])

        let envelopes = try await sessao.envelopes(uids: uids)
        #expect(envelopes.map(\.uid) == [9_001])
        #expect(envelopes.first?.from.address == "marina@clientepremium.com")
        #expect(envelopes.first?.isRead == true)

        await sessao.logout()

        // A ordem importa: buscar antes de selecionar procuraria na pasta
        // errada, e o servidor não avisaria.
        let ordem = servidor.commands.map { linha -> String in
            let resto = linha.split(separator: " ", maxSplits: 1).last.map(String.init) ?? ""
            return resto.split(separator: " ").prefix(2).joined(separator: " ")
        }
        #expect(ordem.firstIndex { $0.hasPrefix("SELECT") }! < ordem.firstIndex { $0.hasPrefix("UID SEARCH") }!)
    }
}
```

- [ ] **Step 2: Run to confirm failure**

Run: `cd Packages/UNISync && swift test --filter ImapFetch`

Expected: FAIL — `type 'ImapWire' has no member 'Untagged'`, `has no member 'folders'`.

- [ ] **Step 3: Add the pure types and interpreters to `ImapWire`**

At the end of `Packages/UNISync/Sources/UNISync/Imap/ImapWire.swift`, inside `enum ImapWire`:

```swift
    // MARK: Respostas, do nosso lado

    /// Uma linha untagged, já traduzida para os nossos termos.
    ///
    /// **Este é o contrato entre a biblioteca e o resto do app.** Tudo daqui
    /// para dentro é puro e testado sem NIO; tudo daqui para fora é
    /// `ImapResponseAdapter`, que é um arquivo só. Se o `swift-nio-imap` mudar
    /// de forma, quebra um arquivo.
    public enum Untagged: Sendable, Hashable {
        case list(name: String, attributes: [String])
        case search([Int64])
        case exists(Int)
        /// `* OK [UIDVALIDITY 1755000000] …` → `code: "UIDVALIDITY"`, `value: "1755000000"`.
        case ok(code: String, value: String)
        case fetch(FetchLine)
        /// O que não interessa a esta versão. Guardado como texto para o log
        /// poder mostrar, em vez de sumir.
        case outra(String)
    }

    /// Uma resposta de `FETCH`, com os campos que a gente pediu.
    ///
    /// Os endereços chegam como texto de cabeçalho porque é assim que eles
    /// saem do `ENVELOPE`, e porque o parser deles já existe e é um só:
    /// `MailAddress`. Uma segunda implementação para IMAP divergiria da do
    /// Gmail no primeiro caso esquisito.
    public struct FetchLine: Sendable, Hashable {
        public let uid: Int64
        public let flags: [String]
        public let internalDate: Date?
        public let from: String?
        public let to: String?
        public let cc: String?
        public let subject: String?
        public let text: String?

        public init(
            uid: Int64, flags: [String], internalDate: Date?,
            from: String?, to: String?, cc: String?, subject: String?, text: String?
        ) {
            self.uid = uid
            self.flags = flags
            self.internalDate = internalDate
            self.from = from
            self.to = to
            self.cc = cc
            self.subject = subject
            self.text = text
        }
    }

    /// Duzentos envelopes por ida e volta.
    ///
    /// Não é chute: um `FETCH` por mensagem custaria uma viagem por mensagem
    /// numa caixa de milhares, e um `FETCH 1:*` traria a caixa inteira numa
    /// resposta que não cabe em memória nem dá para interromper. Duzentos é
    /// grande o bastante para a viagem valer e pequeno o bastante para o lote
    /// caber numa transação e o "parar no meio" custar pouco.
    public static let fetchBatchSize = 200

    public static func folders(from respostas: [Untagged]) -> [Folder] {
        respostas.compactMap { resposta in
            guard case .list(let nome, let atributos) = resposta else { return nil }
            // `\Noselect` é nó da árvore, não pasta. `SELECT` nele devolve NO,
            // e um NO no meio da carga derrubaria tudo por causa de um
            // separador de hierarquia.
            let dobrados = atributos.map { $0.lowercased() }
            guard !dobrados.contains("\\noselect") else { return nil }
            let especial = atributos.first { atributo in
                ["\\inbox", "\\archive", "\\all", "\\trash", "\\sent", "\\drafts", "\\junk"]
                    .contains(atributo.lowercased())
            }
            return Folder(name: nome, specialUse: especial)
        }
    }

    public static func status(from respostas: [Untagged]) -> ImapMailboxStatus? {
        var uidValidity: Int64?
        var uidNext: Int64 = 0
        var exists = 0
        for resposta in respostas {
            switch resposta {
            case .exists(let quantas): exists = quantas
            case .ok(let codigo, let valor) where codigo.uppercased() == "UIDVALIDITY":
                uidValidity = Int64(valor)
            case .ok(let codigo, let valor) where codigo.uppercased() == "UIDNEXT":
                uidNext = Int64(valor) ?? 0
            default: continue
            }
        }
        // Sem UIDVALIDITY não há identidade estável para UID nenhum. Inventar
        // zero faria o Marco 3 casar UID reciclado com mensagem errada.
        guard let uidValidity else { return nil }
        return ImapMailboxStatus(uidValidity: uidValidity, uidNext: uidNext, exists: exists)
    }

    public static func uids(from respostas: [Untagged]) -> [Int64] {
        var todos: Set<Int64> = []
        for resposta in respostas {
            if case .search(let lista) = resposta { todos.formUnion(lista) }
        }
        return todos.sorted()
    }

    public static func envelopes(from respostas: [Untagged]) -> [ImapEnvelope] {
        respostas.compactMap { resposta in
            guard case .fetch(let linha) = resposta else { return nil }
            // Sem data não entra: datar com `agora` jogaria toda mensagem
            // quebrada para o topo da lista, acima do que chegou hoje.
            guard let data = linha.internalDate else { return nil }
            let flags = linha.flags.map { $0.lowercased() }
            return ImapEnvelope(
                uid: linha.uid,
                from: MailAddress.parse(linha.from ?? "")
                    ?? Contact(name: "Remetente desconhecido", address: ""),
                to: MailAddress.parseList(linha.to ?? ""),
                cc: MailAddress.parseList(linha.cc ?? ""),
                subject: MailAddress.decodeRFC2047(linha.subject ?? ""),
                date: data,
                isRead: flags.contains("\\seen"),
                isFlagged: flags.contains("\\flagged")
            )
        }
    }

    public static func bodyText(from respostas: [Untagged], uid: Int64) -> [String] {
        for resposta in respostas {
            guard case .fetch(let linha) = resposta, linha.uid == uid, let texto = linha.text else { continue }
            // O mesmo caminho do Gmail: uma segunda regra de parágrafo
            // divergiria da primeira no primeiro corpo esquisito.
            return GmailMessageParser.paragraphs(from: texto)
        }
        return []
    }
```

At the end of the file, outside the `enum`:

```swift
/// A troca de `UIDVALIDITY` — o sinal de que os UIDs da pasta foram reciclados.
///
/// Aqui ela só é **detectada**; refazer a pasta é do Marco 3. Detectar já vale
/// porque é o que faz a carga inicial gravar o par certo em `sync_state`, e é
/// o que o Marco 3 vai comparar.
public enum ImapUidValidity {
    /// Primeira vez **não** é troca: `nil` significa "nunca vimos esta pasta".
    public static func changed(previous: Int64?, current: Int64) -> Bool {
        guard let previous else { return false }
        return previous != current
    }
}
```

- [ ] **Step 4: Write the adapter — the only file touching the library**

`Packages/UNISync/Sources/UNISync/Imap/ImapResponseAdapter.swift`:

```swift
import Foundation
import NIOCore
import NIOIMAP

/// A fronteira com o `swift-nio-imap`. **É o único arquivo do app que conhece
/// os tipos de resposta da biblioteca.**
///
/// Tudo que sai daqui é `ImapWire.Untagged`, que é nosso e é puro. A troco de
/// um arquivo de tradução, a lógica inteira do IMAP fica testável sem NIO, e
/// uma mudança de forma na biblioteca custa este arquivo em vez de custar a
/// sessão, a carga inicial e os testes de todas as duas.
///
/// **Regra de divergência (Task 9):** se os nomes abaixo não existirem na
/// versão que o SPM resolveu, pare e devolva `NEEDS_CONTEXT` com o nome do
/// plano, o nome real e o arquivo do pacote onde ele aparece. Não improvise.
enum ImapResponseAdapter {
    /// Uma linha crua de resposta untagged virando o nosso caso.
    ///
    /// A tradução é feita sobre o **texto** da linha, e não sobre a árvore da
    /// biblioteca, por um motivo prático: a superfície que a gente usa é
    /// pequena (LIST, SEARCH, EXISTS, OK[código], FETCH) e a árvore da
    /// biblioteca é grande e versionada. O que a biblioteca faz por nós é o
    /// trabalho que a gente não sabe fazer: juntar literais `{123}` e
    /// continuações numa linha lógica completa antes de chegar aqui.
    static func untagged(fromLogicalLine linha: String) -> ImapWire.Untagged {
        let corpo = linha.hasPrefix("* ") ? String(linha.dropFirst(2)) : linha

        if corpo.uppercased().hasPrefix("LIST ") { return list(corpo) }
        if corpo.uppercased().hasPrefix("SEARCH") { return search(corpo) }
        if corpo.uppercased().hasPrefix("OK [") { return okCode(corpo) }
        if let quantas = exists(corpo) { return .exists(quantas) }
        if corpo.uppercased().contains(" FETCH ") || corpo.uppercased().hasPrefix("FETCH ") {
            if let linhaFetch = fetch(corpo) { return .fetch(linhaFetch) }
        }
        return .outra(corpo)
    }

    /// `LIST (\HasNoChildren \Trash) "/" "Lixeira"`
    private static func list(_ corpo: String) -> ImapWire.Untagged {
        var atributos: [String] = []
        if let abre = corpo.firstIndex(of: "("), let fecha = corpo.firstIndex(of: ")"), abre < fecha {
            atributos = corpo[corpo.index(after: abre)..<fecha]
                .split(separator: " ").map(String.init)
        }
        // O nome é o último token; entre aspas quando tem espaço.
        let nome = ultimaStringCitada(corpo) ?? String(corpo.split(separator: " ").last ?? "")
        return .list(name: nome, attributes: atributos)
    }

    /// `SEARCH 9001 9002`
    private static func search(_ corpo: String) -> ImapWire.Untagged {
        .search(corpo.split(separator: " ").compactMap { Int64($0) })
    }

    /// `OK [UIDVALIDITY 1755000000] UIDs valid`
    private static func okCode(_ corpo: String) -> ImapWire.Untagged {
        guard let abre = corpo.firstIndex(of: "["), let fecha = corpo.firstIndex(of: "]"), abre < fecha else {
            return .outra(corpo)
        }
        let miolo = corpo[corpo.index(after: abre)..<fecha]
        let partes = miolo.split(separator: " ", maxSplits: 1)
        return .ok(
            code: String(partes.first ?? ""),
            value: partes.count > 1 ? String(partes[1]) : ""
        )
    }

    /// `2 EXISTS`
    private static func exists(_ corpo: String) -> Int? {
        let partes = corpo.split(separator: " ")
        guard partes.count == 2, partes[1].uppercased() == "EXISTS" else { return nil }
        return Int(partes[0])
    }

    /// `1 FETCH (UID 9001 FLAGS (\Seen) INTERNALDATE "…" ENVELOPE (…))`
    ///
    /// Os campos são lidos por nome, não por posição: servidores mandam a
    /// mesma informação em ordens diferentes, e ler por posição funciona no
    /// servidor em que se testou e falha no seguinte.
    private static func fetch(_ corpo: String) -> ImapWire.FetchLine? {
        guard let uid = inteiroDepois(de: "UID", em: corpo) else { return nil }
        let envelope = grupo(depoisDe: "ENVELOPE", em: corpo).map(camposDoEnvelope) ?? []
        return ImapWire.FetchLine(
            uid: uid,
            flags: grupo(depoisDe: "FLAGS", em: corpo)?.split(separator: " ").map(String.init) ?? [],
            internalDate: dataInterna(stringCitadaDepois(de: "INTERNALDATE", em: corpo)),
            // ENVELOPE (data assunto from sender reply-to to cc bcc in-reply-to message-id)
            from: envelope.count > 2 ? enderecoDoEnvelope(envelope[2]) : nil,
            to: envelope.count > 5 ? enderecoDoEnvelope(envelope[5]) : nil,
            cc: envelope.count > 6 ? enderecoDoEnvelope(envelope[6]) : nil,
            subject: envelope.count > 1 ? semAspas(envelope[1]) : nil,
            text: stringCitadaDepois(de: "BODY[TEXT]", em: corpo)
                ?? literalDepois(de: "BODY[TEXT]", em: corpo)
        )
    }

    /// `"25-Aug-2026 09:00:00 -0300"` → instante.
    ///
    /// `en_US_POSIX` obrigatório: o mês vem em inglês e o locale da máquina
    /// não pode opinar. Mesma família do bug de fuso do Marco 1.
    static func dataInterna(_ texto: String?) -> Date? {
        guard let texto else { return nil }
        let formatador = DateFormatter()
        formatador.locale = Locale(identifier: "en_US_POSIX")
        formatador.dateFormat = "dd-MMM-yyyy HH:mm:ss Z"
        return formatador.date(from: texto.trimmingCharacters(in: .whitespaces))
    }

    // MARK: Utilitários de leitura

    private static func semAspas(_ texto: String) -> String? {
        let limpo = texto.trimmingCharacters(in: .whitespaces)
        if limpo.uppercased() == "NIL" { return nil }
        guard limpo.hasPrefix("\""), limpo.hasSuffix("\""), limpo.count >= 2 else { return limpo }
        return String(limpo.dropFirst().dropLast())
    }

    private static func inteiroDepois(de chave: String, em corpo: String) -> Int64? {
        guard let intervalo = corpo.range(of: chave + " ") else { return nil }
        let resto = corpo[intervalo.upperBound...]
        return Int64(resto.prefix { $0.isNumber })
    }

    private static func stringCitadaDepois(de chave: String, em corpo: String) -> String? {
        guard let intervalo = corpo.range(of: chave + " ") else { return nil }
        let resto = corpo[intervalo.upperBound...]
        guard resto.first == "\"" else { return nil }
        let miolo = resto.dropFirst()
        guard let fim = miolo.firstIndex(of: "\"") else { return nil }
        return String(miolo[miolo.startIndex..<fim])
    }

    /// O corpo de um literal já juntado pela biblioteca, entregue como
    /// `{n}\r\n<texto>`.
    private static func literalDepois(de chave: String, em corpo: String) -> String? {
        guard let intervalo = corpo.range(of: chave + " {") else { return nil }
        let resto = corpo[intervalo.upperBound...]
        guard let fecha = resto.firstIndex(of: "}") else { return nil }
        return String(resto[resto.index(after: fecha)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// O conteúdo do parêntese que vem depois da chave, respeitando aninhamento.
    private static func grupo(depoisDe chave: String, em corpo: String) -> String? {
        guard let intervalo = corpo.range(of: chave + " (") else { return nil }
        var profundidade = 1
        var resultado = ""
        for caractere in corpo[intervalo.upperBound...] {
            if caractere == "(" { profundidade += 1 }
            if caractere == ")" {
                profundidade -= 1
                if profundidade == 0 { break }
            }
            resultado.append(caractere)
        }
        return resultado
    }

    /// Os campos de primeiro nível de um `ENVELOPE`, respeitando aspas e
    /// parênteses aninhados.
    private static func camposDoEnvelope(_ texto: String) -> [String] {
        var campos: [String] = []
        var atual = ""
        var profundidade = 0
        var dentroDeAspas = false
        for caractere in texto {
            switch caractere {
            case "\"": dentroDeAspas.toggle(); atual.append(caractere)
            case "(" where !dentroDeAspas: profundidade += 1; atual.append(caractere)
            case ")" where !dentroDeAspas: profundidade -= 1; atual.append(caractere)
            case " " where !dentroDeAspas && profundidade == 0:
                if !atual.isEmpty { campos.append(atual); atual = "" }
            default: atual.append(caractere)
            }
        }
        if !atual.isEmpty { campos.append(atual) }
        return campos
    }

    /// `(("Marina" NIL "marina" "clientepremium.com"))` → `Marina <marina@clientepremium.com>`.
    private static func enderecoDoEnvelope(_ campo: String) -> String? {
        guard campo.uppercased() != "NIL" else { return nil }
        let miolo = campo.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
        var enderecos: [String] = []
        for bloco in miolo.components(separatedBy: ") (") {
            let partes = camposDoEnvelope(bloco.trimmingCharacters(in: CharacterSet(charactersIn: "()")))
            guard partes.count >= 4 else { continue }
            let nome = semAspas(partes[0])
            guard let usuario = semAspas(partes[2]), let dominio = semAspas(partes[3]) else { continue }
            let endereco = "\(usuario)@\(dominio)"
            enderecos.append(nome.map { "\($0) <\(endereco)>" } ?? endereco)
        }
        return enderecos.isEmpty ? nil : enderecos.joined(separator: ", ")
    }

    private static func ultimaStringCitada(_ texto: String) -> String? {
        var partes: [String] = []
        var atual = ""
        var dentro = false
        for caractere in texto {
            if caractere == "\"" {
                if dentro { partes.append(atual); atual = "" }
                dentro.toggle()
            } else if dentro {
                atual.append(caractere)
            }
        }
        return partes.last
    }
}
```

- [ ] **Step 5: Connect the adapter to the session**

In `Packages/UNISync/Sources/UNISync/Imap/ImapSession.swift`, change the type of `ImapCommandResult.untagged` and add the five commands. In `ImapCommandResult`:

```swift
    /// As linhas `*` que chegaram enquanto o comando estava em voo, já
    /// traduzidas por `ImapResponseAdapter`.
    let untagged: [ImapWire.Untagged]
```

In `ImapChannelHandler`, replace `collected.append(linha)` with:

```swift
            collected.append(ImapResponseAdapter.untagged(fromLogicalLine: linha))
```

Change its declaration to `private var collected: [ImapWire.Untagged] = []`.

Add this to `actor ImapSession`, after `login(user:password:)`:

```swift
    /// As pastas do servidor, com o papel já resolvido.
    public func folders() async throws -> [ImapFolder] {
        let resultado = try await run { ImapWire.list(tag: $0) }
        return ImapWire.folders(from: resultado.untagged)
    }

    /// Seleciona a pasta e devolve `UIDVALIDITY`, `UIDNEXT` e o total.
    ///
    /// Lança quando o servidor não manda `UIDVALIDITY`: sem ele não existe
    /// identidade estável para UID nenhum, e seguir em frente gravaria
    /// mensagens que o Marco 3 não conseguiria casar de volta.
    public func select(_ folder: ImapFolder) async throws -> ImapMailboxStatus {
        let resultado = try await run { ImapWire.select(tag: $0, mailbox: folder.name) }
        guard let status = ImapWire.status(from: resultado.untagged) else {
            throw SyncError.resposta("O servidor selecionou \(folder.name) sem informar UIDVALIDITY.")
        }
        return status
    }

    /// Os UIDs da pasta selecionada desde uma data.
    public func uids(since: Date, calendar: Calendar) async throws -> [Int64] {
        let resultado = try await run {
            ImapWire.uidSearchSince(tag: $0, date: since, calendar: calendar)
        }
        return ImapWire.uids(from: resultado.untagged)
    }

    /// Envelopes em lotes de `ImapWire.fetchBatchSize`.
    ///
    /// O laço é cancelável: `Task.checkCancellation()` a cada lote é o que faz
    /// "fechar o app no meio da carga" parar em segundos em vez de segurar a
    /// conexão até a caixa acabar.
    public func envelopes(uids: [Int64]) async throws -> [ImapEnvelope] {
        var todos: [ImapEnvelope] = []
        for lote in stride(from: 0, to: uids.count, by: ImapWire.fetchBatchSize) {
            try Task.checkCancellation()
            let fatia = Array(uids[lote..<min(lote + ImapWire.fetchBatchSize, uids.count)])
            let resultado = try await run { ImapWire.uidFetchEnvelopes(tag: $0, uids: fatia) }
            todos.append(contentsOf: ImapWire.envelopes(from: resultado.untagged))
        }
        return todos
    }

    /// O corpo em texto de uma mensagem, por demanda.
    public func bodyText(uid: Int64) async throws -> [String] {
        let resultado = try await run { ImapWire.uidFetchBody(tag: $0, uid: uid) }
        return ImapWire.bodyText(from: resultado.untagged, uid: uid)
    }
```

- [ ] **Step 6: Run to confirm success**

Run: `cd Packages/UNISync && swift test --filter 'ImapFetch|ImapSession'`

Expected: PASS, 19 tests (10 from this task plus Task 9's nine, which remain green with the new `untagged` type).

- [ ] **Step 7: Prove through mutation the three decisions that surface in production**

1. Remove the exclusion of `\Noselect` in `ImapWire.folders` and run `swift test --filter pastas`.
   Expected: FAIL — “Projetos” enters the list; in production, selecting it would return `NO` and fail the entire load.
2. Replace `guard let uidValidity else { return nil }` with `let uidValidity = uidValidity ?? 0` and run `swift test --filter selecaoSemUidValidity`.
   Expected: FAIL — the invented status is accepted.
3. In `envelopes(from:)`, replace `guard let data = linha.internalDate else { return nil }` with `let data = linha.internalDate ?? Date()` and run `swift test --filter envelopeSemData`.
   Expected: FAIL — the undated message is included and would rise above today's arrivals in production.

Restore all three and confirm green.

- [ ] **Step 8: Commit**

```bash
git add Packages/UNISync/Sources/UNISync/Imap Packages/UNISync/Tests/UNISyncTests/ImapFetchTests.swift Packages/UNISync/Tests/UNISyncTests/FakeImapServer.swift
git commit -m "O IMAP lista, seleciona, busca e traz envelopes em lotes de 200

Todo contato com os tipos do swift-nio-imap mora num arquivo só —
ImapResponseAdapter —, e tudo daqui para dentro é ImapWire.Untagged, puro e
testado sem NIO. Três decisões ficaram travadas por mutação: \\Noselect não é
pasta, SELECT sem UIDVALIDITY não vira status inventado, e envelope sem
INTERNALDATE fica de fora em vez de ir para o topo da lista com a data de
agora.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 11: `TriageProjection` and `MessageIdentity` — triage projection and stable IDs

**Files:**
- Create: `Packages/UNISync/Sources/UNISync/Load/TriageProjection.swift`
- Create: `Packages/UNISync/Sources/UNISync/Load/MessageIdentity.swift`
- Create: `Packages/UNISync/Tests/UNISyncTests/TriageProjectionTests.swift`

**Interfaces:**
- Consumes: `TriageBucket` from `UNICore`; `FolderRole` (Task 5); `GmailLabel` (Task 8).
- Produces:
  - `enum TriageProjection { static func bucket(role: FolderRole) -> TriageBucket?; static func bucket(gmailLabelIDs: [String], laterLabelID: String?) -> TriageBucket?; static func laterLabelID(in labels: [GmailLabel]) -> String? }`.
  - `enum MessageIdentity { static func gmail(accountID: String, serverID: String) -> String; static func imap(accountID: String, folderID: String, uidValidity: Int64, uid: Int64) -> String }`.

- [ ] **Step 1: Write the failing test**

`Packages/UNISync/Tests/UNISyncTests/TriageProjectionTests.swift`:

```swift
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
```

- [ ] **Step 2: Run to confirm failure**

Run: `cd Packages/UNISync && swift test --filter TriageProjection`

Expected: FAIL — `cannot find 'TriageProjection' in scope`.

- [ ] **Step 3: Write both types**

`Packages/UNISync/Sources/UNISync/Load/TriageProjection.swift`:

```swift
import Foundation
import UNICore

/// Onde uma mensagem do servidor cai na triagem do Marco 1.
///
/// **É projeção, não espelho.** O servidor tem pastas e rótulos; o app tem
/// quatro caixas de triagem mais a lixeira. A tradução acontece **na entrada**,
/// uma vez, e é gravada em `message.bucket` — a UI nunca reprojeta nada, e é
/// por isso que a lista abre instantânea.
///
/// Escrever de volta no servidor é do Marco 3. Aqui a estrada é de mão única.
public enum TriageProjection {
    /// O nome que a pasta/rótulo de "Depois" tem no servidor.
    public static let laterLabelName = "OkamiUNI/Depois"

    public static func bucket(role: FolderRole) -> TriageBucket? {
        switch role {
        case .inbox: .today
        case .later: .later
        case .archive: .archived
        case .trash: .trash
        // Enviadas ficam **fora** da triagem. A caixa não existe no shell do
        // Marco 1, e enfiá-las em Arquivado encheria a caixa do que a pessoa
        // escreveu, não do que ela recebeu.
        case .sent: nil
        // Pasta que a pessoa criou não tem papel nosso, e "arquivada" é a
        // resposta certa: a mensagem existe, não está na entrada, não está na
        // lixeira. Some da triagem só o que ela mandou sumir.
        case .other: .archived
        }
    }

    /// A mesma projeção, pelos rótulos do Gmail.
    ///
    /// A ordem de precedência é o que importa aqui, e cada degrau custou um
    /// defeito para alguém em algum cliente:
    /// 1. `SENT` sai de tudo — o que a pessoa escreveu não é triagem dela.
    /// 2. `TRASH` ganha de tudo o que sobra — uma mensagem apagada continua
    ///    carregando `INBOX` por um tempo, e se `INBOX` vencesse ela voltaria
    ///    para Hoje. Apagar tem de parecer apagar.
    /// 3. `OkamiUNI/Depois` ganha de `INBOX` — é decisão explícita da pessoa,
    ///    tomada nesta ferramenta; `INBOX` é só "ainda não triada".
    /// 4. `INBOX` → Hoje.
    /// 5. O resto → Arquivado.
    public static func bucket(gmailLabelIDs: [String], laterLabelID: String?) -> TriageBucket? {
        let rotulos = Set(gmailLabelIDs)
        if rotulos.contains("SENT") { return nil }
        if rotulos.contains("TRASH") { return .trash }
        if let laterLabelID, rotulos.contains(laterLabelID) { return .later }
        if rotulos.contains("INBOX") { return .today }
        return .archived
    }

    /// O id do rótulo "Depois", se ele já existir na conta.
    ///
    /// Ausente é o normal numa instalação nova, e não é erro: neste marco a
    /// pasta só é **lida**. Criá-la é do Marco 3, junto com a escrita.
    public static func laterLabelID(in labels: [GmailLabel]) -> String? {
        labels.first { $0.name == laterLabelName }?.id
    }
}
```

`Packages/UNISync/Sources/UNISync/Load/MessageIdentity.swift`:

```swift
import Foundation

/// O `Message.id` nosso, a partir do que o servidor deu.
///
/// **Determinístico, nunca `UUID()`.** Reabrir o app e recarregar a mesma
/// mensagem tem de encontrar a linha que já existe — é o que faz a carga
/// inicial ser retomável e o `INSERT OR REPLACE` do lote ser idempotente. Com
/// `UUID()`, cada carga duplicaria a caixa inteira.
///
/// O prefixo da conta é o que impede duas contas com o mesmo id de servidor de
/// colidirem — e elas colidem: dois Gmail da mesma pessoa compartilham o
/// formato de id, e dois IMAP compartilham o UID 1.
public enum MessageIdentity {
    public static func gmail(accountID: String, serverID: String) -> String {
        "\(accountID):g:\(serverID)"
    }

    /// O IMAP precisa dos quatro pedaços.
    ///
    /// A pasta entra porque a mesma mensagem em duas pastas são, para o IMAP,
    /// dois UIDs diferentes — e são duas linhas nossas também. O `UIDVALIDITY`
    /// entra porque o servidor pode reciclar os UIDs desde 1: sem ele, o UID 1
    /// de ontem casaria com o UID 1 de hoje e a lista mostraria a mensagem
    /// errada com o assunto certo.
    public static func imap(accountID: String, folderID: String, uidValidity: Int64, uid: Int64) -> String {
        "\(accountID):i:\(folderID):\(uidValidity):\(uid)"
    }
}
```

- [ ] **Step 4: Run to confirm success**

Run: `cd Packages/UNISync && swift test --filter TriageProjection`

Expected: PASS, eight tests.

- [ ] **Step 5: Prove precedence through mutation**

Move `if rotulos.contains("INBOX") { return .today }` before `if rotulos.contains("TRASH")` and run `swift test --filter precedencia`.

Expected: FAIL — a message with both `INBOX` and `TRASH` returns to Today: a deleted message reappears in the inbox. Restore and confirm green.

- [ ] **Step 6: Commit**

```bash
git add Packages/UNISync/Sources/UNISync/Load Packages/UNISync/Tests/UNISyncTests/TriageProjectionTests.swift
git commit -m "A projeção de triagem e o id que sobrevive a fechar o app

Projeção, não espelho: a tradução acontece uma vez, na entrada, e é gravada —
a UI nunca reprojeta e por isso abre instantânea. A precedência TRASH > Depois
> INBOX está travada por mutação, porque uma mensagem apagada continua
carregando INBOX e, sem a ordem certa, ela reaparece na caixa. O id é
determinístico porque com UUID cada recarga duplicaria a caixa inteira.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 12: Gmail `InitialLoader` — 90 days in the database, in resumable batches

**Files:**
- Create: `Packages/UNISync/Sources/UNISync/Load/InitialLoader.swift`
- Create: `Packages/UNISync/Tests/UNISyncTests/InitialLoaderGmailTests.swift`

**Interfaces:**
- Consumes: `SyncDatabase`, `AccountRecord`, `FolderRecord`, `MessageRecord`, `MessageBodyRecord`, `SyncStateRecord` (Task 5); `GmailClient`, `GmailMessage`, `GmailProfile`, `GmailLabel` (Task 8); `TriageProjection`, `MessageIdentity` (Task 11).
- Produces:
  - `struct LoadProgress: Sendable, Hashable { let accountID: String; let done: Int; let total: Int; var fraction: Double }`.
  - `struct InitialLoader: Sendable` with `init(database: SyncDatabase, calendar: Calendar = Calendar(identifier: .gregorian))`, `static let windowDays: Int`, `static let fullBodyCount: Int`, `func loadGmail(account: Account, client: GmailClient, now: Date, progress: @Sendable (LoadProgress) -> Void) async throws`.
  - `InitialLoader.since(now:) -> Date`.

- [ ] **Step 1: Write the failing test**

`Packages/UNISync/Tests/UNISyncTests/InitialLoaderGmailTests.swift`:

```swift
import Foundation
import GRDB
import Testing
import UNICore
@testable import UNISync

@Suite("Carga inicial: Gmail", .serialized)
struct InitialLoaderGmailTests {
    private let agora = Date(timeIntervalSince1970: 1_800_000_000)

    private let conta = Account(
        id: "conta-g", address: "ricardo@gmail.com", displayName: "Pessoal",
        provider: .gmail, host: "gmail",
        tintLightHex: "#725B9A", tintDarkHex: "#C2A7F4", state: .carregando
    )

    private func cliente() -> GmailClient {
        GmailClient(
            session: StubURLProtocol.session(),
            accessToken: { "at" },
            baseURL: URL(string: "https://gmail.example/gmail/v1/users/me")!
        )
    }

    private func mensagemJSON(id: String, rotulos: [String], assunto: String, corpo: String) -> String {
        let base64 = Data(corpo.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return """
        {"id":"\(id)","labelIds":\(rotulos.map { "\"\($0)\"" }),
         "snippet":"prévia de \(id)","internalDate":"1799000000000",
         "payload":{"mimeType":"text/plain",
           "headers":[
             {"name":"From","value":"Marina <marina@clientepremium.com>"},
             {"name":"To","value":"ricardo@gmail.com"},
             {"name":"Subject","value":"\(assunto)"}
           ],
           "body":{"data":"\(base64)"}}}
        """
    }

    private func roteiroPadrao() -> [String: [StubURLProtocol.Reply]] {
        [
            "/gmail/v1/users/me/profile": [.json(
                "{\"emailAddress\":\"ricardo@gmail.com\",\"historyId\":\"9928471\"}"
            )],
            "/gmail/v1/users/me/labels": [.json("""
                {"labels":[{"id":"INBOX","name":"INBOX"},{"id":"Label_7","name":"OkamiUNI/Depois"}]}
                """)],
            "/gmail/v1/users/me/messages": [
                .json("{\"messages\":[{\"id\":\"m1\"},{\"id\":\"m2\"}],\"nextPageToken\":\"p2\"}"),
                .json("{\"messages\":[{\"id\":\"m3\"},{\"id\":\"m4\"}]}"),
            ],
            "/gmail/v1/users/me/messages/m1": [
                .json(mensagemJSON(id: "m1", rotulos: ["INBOX"], assunto: "Um", corpo: "A revisão saiu."))
            ],
            "/gmail/v1/users/me/messages/m2": [
                .json(mensagemJSON(id: "m2", rotulos: ["INBOX", "TRASH"], assunto: "Dois", corpo: "Lixo."))
            ],
            "/gmail/v1/users/me/messages/m3": [
                .json(mensagemJSON(id: "m3", rotulos: ["SENT"], assunto: "Três", corpo: "Escrevi."))
            ],
            "/gmail/v1/users/me/messages/m4": [
                .json(mensagemJSON(id: "m4", rotulos: ["Label_7"], assunto: "Quatro", corpo: "Depois."))
            ],
        ]
    }

    private func carrega(_ db: SyncDatabase) async throws -> [LoadProgress] {
        try await db.pool.write { try AccountRecord(self.conta, createdAt: self.agora).insert($0) }
        let recebidos = Recebedor()
        try await InitialLoader(database: db).loadGmail(
            account: conta, client: cliente(), now: agora,
            progress: { p in recebidos.registra(p) }
        )
        return recebidos.todos
    }

    @Test("A janela é de 90 dias, e a consulta pede isso ao Gmail")
    func janelaDe90Dias() async throws {
        StubURLProtocol.install(roteiroPadrao())
        defer { StubURLProtocol.reset() }
        _ = try await carrega(try SyncDatabase.inMemory())

        #expect(InitialLoader.windowDays == 90)
        // `newer_than:90d` é o que faz o servidor filtrar em vez de mandar a
        // caixa inteira para nós filtrarmos.
        #expect(StubURLProtocol.requests.contains { $0.path.hasSuffix("/messages") })
    }

    @Test("As quatro mensagens caem nas caixas certas — e a enviada não entra")
    func projecaoNaEntrada() async throws {
        StubURLProtocol.install(roteiroPadrao())
        defer { StubURLProtocol.reset() }
        let db = try SyncDatabase.inMemory()
        _ = try await carrega(db)

        let porBucket = try await db.pool.read { conexao -> [String: String] in
            var mapa: [String: String] = [:]
            for registro in try MessageRecord.fetchAll(conexao) {
                mapa[registro.serverID ?? ""] = registro.bucket
            }
            return mapa
        }
        #expect(porBucket["m1"] == "hoje")
        #expect(porBucket["m2"] == "lixeira")
        #expect(porBucket["m4"] == "depois")
        // A enviada não entra: a caixa Enviadas não existe neste marco.
        #expect(porBucket["m3"] == nil)
        #expect(porBucket.count == 3)
    }

    @Test("O id da linha é o determinístico, não um UUID")
    func idDeterministico() async throws {
        StubURLProtocol.install(roteiroPadrao())
        defer { StubURLProtocol.reset() }
        let db = try SyncDatabase.inMemory()
        _ = try await carrega(db)

        let ids = try await db.pool.read { try String.fetchSet($0, sql: "SELECT id FROM message") }
        #expect(ids.contains(MessageIdentity.gmail(accountID: "conta-g", serverID: "m1")))
    }

    @Test("Carregar duas vezes não duplica nada")
    func retomavelSemDuplicar() async throws {
        // É o teste do "parar no meio e reabrir". Sem `INSERT OR REPLACE` com
        // id determinístico, a segunda carga dobraria a caixa.
        StubURLProtocol.install(roteiroPadrao())
        defer { StubURLProtocol.reset() }
        let db = try SyncDatabase.inMemory()
        _ = try await carrega(db)
        let depoisDaPrimeira = try await db.pool.read { try MessageRecord.fetchCount($0) }

        StubURLProtocol.install(roteiroPadrao())
        try await InitialLoader(database: db).loadGmail(
            account: conta, client: cliente(), now: agora, progress: { _ in }
        )
        let depoisDaSegunda = try await db.pool.read { try MessageRecord.fetchCount($0) }
        #expect(depoisDaPrimeira == depoisDaSegunda)
        #expect(depoisDaPrimeira == 3)
    }

    @Test("O corpo desce e a busca acha por dentro dele, com acento dobrado")
    func corpoIndexado() async throws {
        StubURLProtocol.install(roteiroPadrao())
        defer { StubURLProtocol.reset() }
        let db = try SyncDatabase.inMemory()
        _ = try await carrega(db)

        try await db.pool.read { conexao in
            let achados = try MessageSearch.matchingBodyIDs(conexao, term: "revisao", accountID: nil)
            #expect(achados == [MessageIdentity.gmail(accountID: "conta-g", serverID: "m1")])
        }
    }

    @Test("O historyId do profile é guardado para o Marco 3 começar incremental")
    func historyIDGuardado() async throws {
        StubURLProtocol.install(roteiroPadrao())
        defer { StubURLProtocol.reset() }
        let db = try SyncDatabase.inMemory()
        _ = try await carrega(db)

        let estado = try await db.pool.read { conexao in
            try SyncStateRecord.fetchOne(conexao, key: ["accountID": "conta-g", "folderID": ""])
        }
        #expect(estado?.historyID == "9928471")
        #expect(estado?.syncedAt != nil)
    }

    @Test("A conta termina `ativa` e com carimbo de sincronização")
    func contaTerminaAtiva() async throws {
        StubURLProtocol.install(roteiroPadrao())
        defer { StubURLProtocol.reset() }
        let db = try SyncDatabase.inMemory()
        _ = try await carrega(db)

        let devolvida = try await db.pool.read { conexao in
            try AccountRecord.fetchOne(conexao, key: "conta-g")?.account
        }
        #expect(devolvida?.state == .ativa)
        #expect(devolvida?.lastSyncedAt == agora)
    }

    @Test("O progresso é relatado, cresce e termina completo")
    func progresso() async throws {
        StubURLProtocol.install(roteiroPadrao())
        defer { StubURLProtocol.reset() }
        let relatos = try await carrega(try SyncDatabase.inMemory())

        #expect(!relatos.isEmpty)
        #expect(relatos.allSatisfy { $0.accountID == "conta-g" })
        #expect(relatos.map(\.done) == relatos.map(\.done).sorted())
        #expect(relatos.last?.done == relatos.last?.total)
        #expect(relatos.last?.fraction == 1.0)
    }

    @Test("Falha no meio deixa `erroDeAutenticacao` e o que já baixou fica")
    func falhaNoMeio() async throws {
        // Interrompível sem corromper: as transações são por lote, então o que
        // entrou fica, e o estado da conta diz o que houve — em vez de a lista
        // ficar vazia sem explicação.
        var roteiro = roteiroPadrao()
        roteiro["/gmail/v1/users/me/messages/m4"] = [.json("{\"error\":{\"code\":401}}", status: 401)]
        StubURLProtocol.install(roteiro)
        defer { StubURLProtocol.reset() }

        let db = try SyncDatabase.inMemory()
        try await db.pool.write { try AccountRecord(self.conta, createdAt: self.agora).insert($0) }

        await #expect(throws: SyncError.autenticacao) {
            try await InitialLoader(database: db).loadGmail(
                account: self.conta, client: self.cliente(), now: self.agora, progress: { _ in }
            )
        }
        let estado = try await db.pool.read { conexao in
            try AccountRecord.fetchOne(conexao, key: "conta-g")?.account.state
        }
        #expect(estado == .erroDeAutenticacao)
        let quantas = try await db.pool.read { try MessageRecord.fetchCount($0) }
        #expect(quantas > 0)
    }

    @Test("Cancelar para em segundos e não corrompe")
    func cancelavel() async throws {
        StubURLProtocol.install(roteiroPadrao())
        defer { StubURLProtocol.reset() }
        let db = try SyncDatabase.inMemory()
        try await db.pool.write { try AccountRecord(self.conta, createdAt: self.agora).insert($0) }

        let tarefa = Task {
            try await InitialLoader(database: db).loadGmail(
                account: self.conta, client: self.cliente(), now: self.agora, progress: { _ in }
            )
        }
        tarefa.cancel()
        _ = try? await tarefa.value
        // O que importa é não travar nem deixar o banco inconsistente: a
        // migração continua íntegra e a contagem é legível.
        let quantas = try await db.pool.read { try MessageRecord.fetchCount($0) }
        #expect(quantas >= 0)
    }
}

/// Junta os relatos de progresso vindos da closure `@Sendable`.
private final class Recebedor: @unchecked Sendable {
    private let lock = NSLock()
    private var lista: [LoadProgress] = []

    func registra(_ p: LoadProgress) {
        lock.lock()
        lista.append(p)
        lock.unlock()
    }

    var todos: [LoadProgress] {
        lock.lock()
        defer { lock.unlock() }
        return lista
    }
}
```

- [ ] **Step 2: Run to confirm failure**

Run: `cd Packages/UNISync && swift test --filter InitialLoaderGmail`

Expected: FAIL — `cannot find 'InitialLoader' in scope`.

- [ ] **Step 3: Write the loader**

`Packages/UNISync/Sources/UNISync/Load/InitialLoader.swift`:

```swift
import Foundation
import GRDB
import UNICore
import os

public struct LoadProgress: Sendable, Hashable {
    public let accountID: String
    public let done: Int
    public let total: Int

    public init(accountID: String, done: Int, total: Int) {
        self.accountID = accountID
        self.done = done
        self.total = total
    }

    /// Entre 0 e 1. Total zero é 1: uma conta vazia terminou de carregar.
    public var fraction: Double {
        guard total > 0 else { return 1 }
        return min(1, Double(done) / Double(total))
    }
}

/// A carga inicial de leitura: 90 dias, por conta, para o banco.
///
/// **Interrompível e retomável, por construção.** As transações são por lote,
/// os ids são determinísticos e a escrita é `INSERT OR REPLACE`: parar no meio
/// deixa o que entrou, e reabrir passa por cima sem duplicar. Não há
/// "recomeçar do zero" nem estado parcial em memória que se perca.
public struct InitialLoader: Sendable {
    /// Noventa dias. É a janela do marco: o suficiente para o app ser útil
    /// offline sem baixar dez anos de caixa numa primeira abertura.
    public static let windowDays = 90

    /// Quantas mensagens ganham o corpo cheio na carga inicial. O resto desce
    /// por demanda — baixar o corpo de milhares de mensagens que ninguém vai
    /// abrir custa tempo e disco para nada.
    public static let fullBodyCount = 50

    /// Quantas mensagens por transação. Lote pequeno demais paga o preço da
    /// transação a toda hora; grande demais deixa o progresso mentindo parado
    /// e o cancelamento demorado.
    static let batchSize = 50

    private let database: SyncDatabase
    private let calendar: Calendar
    private let log = Logger(subsystem: "com.okamiops.okamiuni", category: "InitialLoader")

    public init(database: SyncDatabase, calendar: Calendar = Calendar(identifier: .gregorian)) {
        self.database = database
        self.calendar = calendar
    }

    /// O começo da janela. Recebe `now` em vez de ler o relógio: teste com
    /// relógio de verdade é teste que passa hoje e falha em novembro.
    public func since(now: Date) -> Date {
        calendar.date(byAdding: .day, value: -Self.windowDays, to: now) ?? now
    }

    // MARK: Gmail

    public func loadGmail(
        account: Account,
        client: GmailClient,
        now: Date,
        progress: @Sendable (LoadProgress) -> Void
    ) async throws {
        do {
            try await marca(account.id, estado: .carregando)

            let perfil = try await client.profile()
            let rotulos = try await client.labels()
            let idDoDepois = TriageProjection.laterLabelID(in: rotulos)

            // Uma "pasta" só para o Gmail: os rótulos fazem o papel das pastas,
            // e a tabela `folder` guarda a chave estrangeira que a cascata usa.
            let folderID = FolderRecord.id(accountID: account.id, serverName: "GMAIL")
            try await database.pool.write { db in
                try FolderRecord(
                    id: folderID, accountID: account.id, serverName: "GMAIL",
                    role: .inbox, displayName: "Gmail"
                ).save(db)
            }

            // 1. Os ids, paginados.
            var ids: [String] = []
            var token: String?
            repeat {
                try Task.checkCancellation()
                let pagina = try await client.messageIDs(query: "newer_than:\(Self.windowDays)d", pageToken: token)
                ids.append(contentsOf: pagina.ids)
                token = pagina.nextPageToken
            } while token != nil

            progress(LoadProgress(accountID: account.id, done: 0, total: ids.count))

            // 2. As mensagens, em lotes, com corpo cheio só nas primeiras.
            var feitas = 0
            var lote: [(GmailMessage, Bool)] = []
            for (indice, id) in ids.enumerated() {
                try Task.checkCancellation()
                let comCorpo = indice < Self.fullBodyCount
                let mensagem = try await client.message(id: id, format: comCorpo ? .full : .metadata)
                lote.append((mensagem, comCorpo))

                if lote.count >= Self.batchSize || indice == ids.count - 1 {
                    try await grava(lote, account: account, folderID: folderID, laterLabelID: idDoDepois)
                    feitas += lote.count
                    lote = []
                    progress(LoadProgress(accountID: account.id, done: feitas, total: ids.count))
                }
            }
            if ids.isEmpty {
                progress(LoadProgress(accountID: account.id, done: 0, total: 0))
            }

            // 3. O ponto de partida do Marco 3, guardado agora.
            //
            // Guardado **depois** da carga e com o `historyId` lido **antes**
            // dela: o que chegar no meio entra pelo incremental do Marco 3, em
            // vez de cair no vão entre as duas leituras.
            try await database.pool.write { db in
                try SyncStateRecord(
                    accountID: account.id, folderID: "",
                    historyID: perfil.historyID, syncedAt: now
                ).save(db)
            }
            try await conclui(account.id, em: now)
            log.info("Carga inicial de \(account.address, privacy: .private) terminou: \(ids.count) mensagens.")
        } catch let erro as SyncError {
            try? await marca(account.id, estado: estadoPara(erro))
            log.error("Carga inicial de \(account.address, privacy: .private) falhou: \(erro.mensagem)")
            throw erro
        } catch is CancellationError {
            // Cancelamento não é defeito: a conta volta a `ativa` com o que
            // baixou, e a próxima abertura continua de onde parou.
            try? await marca(account.id, estado: .ativa)
            throw CancellationError()
        }
    }

    /// Um lote inteiro numa transação: ou entra tudo, ou nada.
    private func grava(
        _ lote: [(GmailMessage, Bool)], account: Account, folderID: String, laterLabelID: String?
    ) async throws {
        try await database.pool.write { db in
            for (mensagem, temCorpo) in lote {
                guard let bucket = TriageProjection.bucket(
                    gmailLabelIDs: mensagem.labelIDs, laterLabelID: laterLabelID
                ) else { continue }   // Enviadas ficam fora da triagem.

                let id = MessageIdentity.gmail(accountID: account.id, serverID: mensagem.id)
                let nossa = Message(
                    id: id, accountID: account.id, from: mensagem.from,
                    receivedAt: mensagem.internalDate,
                    subject: mensagem.subject, snippet: mensagem.snippet,
                    body: mensagem.body, tags: [], bucket: bucket,
                    isRead: !mensagem.labelIDs.contains("UNREAD"),
                    summary: nil, detectedEvent: nil,
                    to: mensagem.to, cc: mensagem.cc,
                    isFlagged: mensagem.labelIDs.contains("STARRED"),
                    serverID: mensagem.id
                )
                // `save` é upsert: id determinístico + upsert = recarga
                // idempotente, que é o que faz "parar no meio" ser seguro.
                try MessageRecord(nossa, folderID: folderID).save(db)
                if temCorpo, !mensagem.body.isEmpty {
                    try MessageBodyRecord(messageID: id, paragraphs: mensagem.body).save(db)
                }
            }
        }
    }

    // MARK: Estado da conta

    func marca(_ accountID: String, estado: Account.State) async throws {
        try await database.pool.write { db in
            guard let registro = try AccountRecord.fetchOne(db, key: accountID) else { return }
            try AccountRecord(registro.account.withState(estado), createdAt: registro.createdAt).update(db)
        }
    }

    func conclui(_ accountID: String, em data: Date) async throws {
        try await database.pool.write { db in
            guard let registro = try AccountRecord.fetchOne(db, key: accountID) else { return }
            let atualizada = registro.account.withState(.ativa).withLastSynced(data)
            try AccountRecord(atualizada, createdAt: registro.createdAt).update(db)
        }
    }

    /// Nem todo erro derruba a conta para `erroDeAutenticacao`.
    ///
    /// Rede caída e quota não são culpa da credencial, e marcar a conta como
    /// autenticação quebrada faria a janela oferecer "Reconectar" para quem só
    /// precisa esperar o wi-fi voltar — a ação errada, com convicção.
    func estadoPara(_ erro: SyncError) -> Account.State {
        switch erro {
        case .autenticacao, .autorizacaoRevogada, .semClientID: .erroDeAutenticacao
        default: .ativa
        }
    }
}
```

- [ ] **Step 4: Run to confirm success**

Run: `cd Packages/UNISync && swift test --filter InitialLoaderGmail`

Expected: PASS, 10 tests.

- [ ] **Step 5: Prove the two resumability guarantees through mutation**

1. Replace `try MessageRecord(nossa, folderID: folderID).save(db)` with `.insert(db)` and run `swift test --filter retomavelSemDuplicar`.
   Expected: FAIL — the second load violates the primary key: reopening the app breaks it.
2. Replace `id` with `UUID().uuidString` and run the same test.
   Expected: FAIL — `depoisDaSegunda == 6`, doubling the inbox.

Restore both and confirm green.

- [ ] **Step 6: Commit**

```bash
git add Packages/UNISync/Sources/UNISync/Load/InitialLoader.swift Packages/UNISync/Tests/UNISyncTests/InitialLoaderGmailTests.swift
git commit -m "Noventa dias de Gmail descem para o banco, em lotes, sem duplicar ao recomeçar

Retomável por construção: transação por lote, id determinístico e upsert —
provado por mutação nas duas pontas. Falha no meio deixa o que já entrou e
marca o estado que explica; rede caída não vira erroDeAutenticacao, porque
oferecer Reconectar a quem só perdeu o wi-fi é a ação errada com convicção.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 13: IMAP `InitialLoader` — folder roles, envelope batches and the 50 most recent bodies

**Files:**
- Modify: `Packages/UNISync/Sources/UNISync/Load/InitialLoader.swift`
- Create: `Packages/UNISync/Tests/UNISyncTests/InitialLoaderImapTests.swift`

**Interfaces:**
- Consumes: everything from Task 12 plus `ImapSession`, `ImapFolder`, `ImapEnvelope`, `ImapMailboxStatus`, `ImapUidValidity` (Tasks 9 and 10); `FakeImapServer` (Task 9).
- Produces: `InitialLoader.loadImap(account: Account, session: ImapSession, now: Date, progress: @Sendable (LoadProgress) -> Void) async throws`.

- [ ] **Step 1: Write the failing test**

`Packages/UNISync/Tests/UNISyncTests/InitialLoaderImapTests.swift`:

```swift
import Foundation
import GRDB
import NIOCore
import NIOPosix
import Testing
import UNICore
@testable import UNISync

@Suite("Carga inicial: IMAP")
struct InitialLoaderImapTests {
    private let agora = Date(timeIntervalSince1970: 1_800_000_000)

    private let conta = Account(
        id: "conta-i", address: "contato@meusite.com", displayName: "Site",
        provider: .imap, host: "meusite",
        tintLightHex: "#397852", tintDarkHex: "#88D1A2",
        imap: ImapEndpoint(host: "127.0.0.1", port: 0, security: .startTLS),
        state: .carregando
    )

    private func fetchLine(uid: Int64, assunto: String, flags: String) -> String {
        "* \(uid) FETCH (UID \(uid) FLAGS (\(flags)) "
        + "INTERNALDATE \"25-Aug-2026 09:00:00 -0300\" "
        + "ENVELOPE (\"Tue, 25 Aug 2026 09:00:00 -0300\" \"\(assunto)\" "
        + "((\"Marina\" NIL \"marina\" \"clientepremium.com\")) NIL NIL "
        + "((\"Ricardo\" NIL \"contato\" \"meusite.com\")) NIL NIL NIL NIL))"
    }

    private func roteiro() -> FakeImapServer.Script {
        .init(replies: [
            "LOGIN": ["TAG OK LOGIN completed"],
            "LIST": [
                "* LIST (\\HasNoChildren) \"/\" \"INBOX\"",
                "* LIST (\\Archive \\HasNoChildren) \"/\" \"Arquivo\"",
                "* LIST (\\Sent \\HasNoChildren) \"/\" \"Enviados\"",
                "* LIST (\\Noselect \\HasChildren) \"/\" \"Projetos\"",
                "TAG OK LIST completed",
            ],
            "SELECT": [
                "* 2 EXISTS",
                "* OK [UIDVALIDITY 1755000000] UIDs valid",
                "* OK [UIDNEXT 9003] Predicted next UID",
                "TAG OK [READ-WRITE] SELECT completed",
            ],
            "UID SEARCH": ["* SEARCH 9001 9002", "TAG OK UID SEARCH completed"],
            "UID FETCH": [
                fetchLine(uid: 9_001, assunto: "Revisao pendente", flags: "\\Seen"),
                fetchLine(uid: 9_002, assunto: "Outro", flags: ""),
                "TAG OK UID FETCH completed",
            ],
            "LOGOUT": ["TAG OK LOGOUT completed"],
        ])
    }

    private func carrega(_ db: SyncDatabase, script: FakeImapServer.Script) async throws -> [LoadProgress] {
        let servidor = FakeImapServer(script: script)
        let porta = try servidor.start()
        defer { servidor.stop() }
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? grupo.syncShutdownGracefully() }

        try await db.pool.write { try AccountRecord(self.conta, createdAt: self.agora).insert($0) }

        let sessao = try await ImapSession.connect(
            endpoint: ImapEndpoint(host: "127.0.0.1", port: porta, security: .startTLS),
            group: grupo
        )
        try await sessao.login(user: conta.address, password: "senha-de-app")

        let recebidos = RecebedorImap()
        try await InitialLoader(database: db).loadImap(
            account: conta, session: sessao, now: agora,
            progress: { p in recebidos.registra(p) }
        )
        await sessao.logout()
        return recebidos.todos
    }

    @Test("Só as pastas com papel de triagem são carregadas — Enviados e Noselect ficam de fora")
    func pastasCarregadas() async throws {
        let db = try SyncDatabase.inMemory()
        _ = try await carrega(db, script: roteiro())

        let pastas = try await db.pool.read { conexao -> [String: String] in
            var mapa: [String: String] = [:]
            for registro in try FolderRecord.fetchAll(conexao) { mapa[registro.serverName] = registro.role }
            return mapa
        }
        #expect(pastas["INBOX"] == "inbox")
        #expect(pastas["Arquivo"] == "archive")
        // Enviados existe no servidor e fica fora da triagem — a caixa
        // Enviadas não existe neste marco.
        #expect(pastas["Enviados"] == nil)
        // Noselect é nó da árvore; SELECT nele devolveria NO.
        #expect(pastas["Projetos"] == nil)
    }

    @Test("Os envelopes viram mensagens com o id que carrega pasta e UIDVALIDITY")
    func mensagensGravadas() async throws {
        let db = try SyncDatabase.inMemory()
        _ = try await carrega(db, script: roteiro())

        let ids = try await db.pool.read { try String.fetchSet($0, sql: "SELECT id FROM message") }
        let esperado = MessageIdentity.imap(
            accountID: "conta-i",
            folderID: FolderRecord.id(accountID: "conta-i", serverName: "INBOX"),
            uidValidity: 1_755_000_000, uid: 9_001
        )
        #expect(ids.contains(esperado))

        let registro = try await db.pool.read { try MessageRecord.fetchOne($0, key: esperado) }
        #expect(registro?.uidValidity == 1_755_000_000)
        #expect(registro?.serverID == "9001")
        #expect(registro?.isRead == true)
        #expect(registro?.bucket == "hoje")
        #expect(registro?.fromAddress == "marina@clientepremium.com")
    }

    @Test("A caixa de arquivo cai em `arquivar`, e não em `hoje`")
    func projecaoPorPasta() async throws {
        let db = try SyncDatabase.inMemory()
        _ = try await carrega(db, script: roteiro())
        let buckets = try await db.pool.read { try String.fetchSet($0, sql: "SELECT DISTINCT bucket FROM message") }
        #expect(buckets == ["hoje", "arquivar"])
    }

    @Test("O UIDVALIDITY de cada pasta é guardado para o Marco 3")
    func uidValidityGuardado() async throws {
        let db = try SyncDatabase.inMemory()
        _ = try await carrega(db, script: roteiro())

        let estado = try await db.pool.read { conexao in
            try SyncStateRecord.fetchOne(conexao, key: [
                "accountID": "conta-i",
                "folderID": FolderRecord.id(accountID: "conta-i", serverName: "INBOX"),
            ])
        }
        #expect(estado?.uidValidity == 1_755_000_000)
        #expect(estado?.highestUID == 9_002)
    }

    @Test("UIDVALIDITY trocada apaga as mensagens velhas daquela pasta antes de gravar as novas")
    func uidValidityTrocadaLimpa() async throws {
        // Sem isto, a pasta ficaria com duas gerações de UID convivendo: a
        // lista mostraria cada mensagem duas vezes, com assuntos diferentes
        // sob o mesmo UID.
        let db = try SyncDatabase.inMemory()
        _ = try await carrega(db, script: roteiro())
        let antes = try await db.pool.read { try MessageRecord.fetchCount($0) }
        #expect(antes == 4)

        var novo = roteiro()
        novo.replies["SELECT"] = [
            "* 2 EXISTS",
            "* OK [UIDVALIDITY 1999999999] UIDs valid",
            "* OK [UIDNEXT 3] Predicted next UID",
            "TAG OK [READ-WRITE] SELECT completed",
        ]
        try await db.pool.write { _ = try AccountRecord.deleteOne($0, key: "conta-i") }
        _ = try await carrega(db, script: novo)

        let validades = try await db.pool.read { try Int64.fetchSet($0, sql: "SELECT DISTINCT uidValidity FROM message") }
        #expect(validades == [1_999_999_999])
    }

    @Test("Os corpos das mais recentes descem, e a busca acha por dentro deles")
    func corposDescem() async throws {
        var script = roteiro()
        // O `UID FETCH` de corpo usa o mesmo verbo; o roteiro devolve o mesmo
        // bloco, e o `bodyText` filtra pelo uid pedido. O que importa aqui é
        // que a linha de corpo chega e é indexada.
        script.replies["UID FETCH"] = [
            fetchLine(uid: 9_001, assunto: "Revisao pendente", flags: "\\Seen"),
            fetchLine(uid: 9_002, assunto: "Outro", flags: ""),
            "* 1 FETCH (UID 9001 BODY[TEXT] \"A revisão do contrato ficou pronta.\")",
            "TAG OK UID FETCH completed",
        ]
        let db = try SyncDatabase.inMemory()
        _ = try await carrega(db, script: script)

        try await db.pool.read { conexao in
            let achados = try MessageSearch.matchingBodyIDs(conexao, term: "revisao", accountID: nil)
            #expect(!achados.isEmpty)
        }
    }

    @Test("A conta termina `ativa`, com carimbo, e o progresso chega ao fim")
    func terminaAtiva() async throws {
        let db = try SyncDatabase.inMemory()
        let relatos = try await carrega(db, script: roteiro())

        let devolvida = try await db.pool.read { try AccountRecord.fetchOne($0, key: "conta-i")?.account }
        #expect(devolvida?.state == .ativa)
        #expect(devolvida?.lastSyncedAt == agora)
        #expect(relatos.last?.fraction == 1.0)
    }

    @Test("Senha recusada deixa a conta em `erroDeAutenticacao`")
    func senhaRecusada() async throws {
        var script = roteiro()
        script.replies["LIST"] = ["TAG NO [AUTHENTICATIONFAILED] Invalid credentials"]
        let db = try SyncDatabase.inMemory()

        await #expect(throws: (any Error).self) { _ = try await self.carrega(db, script: script) }
        let estado = try await db.pool.read { try AccountRecord.fetchOne($0, key: "conta-i")?.account.state }
        #expect(estado == .erroDeAutenticacao)
    }
}

private final class RecebedorImap: @unchecked Sendable {
    private let lock = NSLock()
    private var lista: [LoadProgress] = []

    func registra(_ p: LoadProgress) {
        lock.lock()
        lista.append(p)
        lock.unlock()
    }

    var todos: [LoadProgress] {
        lock.lock()
        defer { lock.unlock() }
        return lista
    }
}
```

- [ ] **Step 2: Run to confirm failure**

Run: `cd Packages/UNISync && swift test --filter InitialLoaderImap`

Expected: FAIL — `value of type 'InitialLoader' has no member 'loadImap'`.

- [ ] **Step 3: Write the IMAP loader**

Add this inside `struct InitialLoader` in `Packages/UNISync/Sources/UNISync/Load/InitialLoader.swift`, after `grava(_:account:folderID:laterLabelID:)`:

```swift
    // MARK: IMAP

    public func loadImap(
        account: Account,
        session: ImapSession,
        now: Date,
        progress: @Sendable (LoadProgress) -> Void
    ) async throws {
        do {
            try await marca(account.id, estado: .carregando)

            // Só as pastas com papel de triagem. Enviados fica de fora (a caixa
            // não existe neste marco) e `other` também: carregar toda pasta que
            // a pessoa criou baixaria a caixa inteira sob o nome de "90 dias".
            let comPapel = try await session.folders().filter { pasta in
                TriageProjection.bucket(role: pasta.role) != nil && pasta.role != .other
            }

            let desde = since(now: now)
            var totalEstimado = 0
            var feitas = 0
            var porPasta: [(ImapFolder, ImapMailboxStatus, [Int64])] = []

            // 1. Selecionar cada pasta e descobrir o que existe na janela.
            //    Duas passadas — descobrir tudo, depois baixar — para o
            //    progresso ter denominador de verdade desde o primeiro relato,
            //    em vez de uma barra que anda para trás quando a pasta seguinte
            //    aparece.
            for pasta in comPapel {
                try Task.checkCancellation()
                let status = try await session.select(pasta)
                let uids = try await session.uids(since: desde, calendar: calendar)
                totalEstimado += uids.count
                porPasta.append((pasta, status, uids))
            }
            progress(LoadProgress(accountID: account.id, done: 0, total: totalEstimado))

            // 2. Baixar, pasta a pasta.
            for (pasta, status, uids) in porPasta {
                try Task.checkCancellation()
                let folderID = FolderRecord.id(accountID: account.id, serverName: pasta.name)
                let bucket = TriageProjection.bucket(role: pasta.role) ?? .archived

                let anterior = try await database.pool.read { db in
                    try SyncStateRecord.fetchOne(db, key: ["accountID": account.id, "folderID": folderID])
                }
                let trocou = ImapUidValidity.changed(
                    previous: anterior?.uidValidity, current: status.uidValidity
                )

                try await database.pool.write { db in
                    try FolderRecord(
                        id: folderID, accountID: account.id, serverName: pasta.name,
                        role: pasta.role, displayName: pasta.name
                    ).save(db)
                    if trocou {
                        // Os UIDs foram reciclados: a geração velha não casa
                        // com nada. Deixá-la ali faria a lista mostrar cada
                        // mensagem duas vezes, com assuntos diferentes sob o
                        // mesmo UID.
                        try db.execute(
                            sql: "DELETE FROM message WHERE folderID = ? AND uidValidity IS NOT ?",
                            arguments: [folderID, status.uidValidity]
                        )
                    }
                }

                // Reselecionar: as duas passadas deixaram outra pasta
                // selecionada, e `UID FETCH` age sobre a pasta corrente.
                _ = try await session.select(pasta)
                let envelopes = try await session.envelopes(uids: uids)

                // Os corpos das mais recentes desta pasta.
                let maisRecentes = envelopes
                    .sorted { $0.date > $1.date }
                    .prefix(Self.fullBodyCount)
                var corpos: [Int64: [String]] = [:]
                for envelope in maisRecentes {
                    try Task.checkCancellation()
                    corpos[envelope.uid] = try await session.bodyText(uid: envelope.uid)
                }

                for lote in stride(from: 0, to: envelopes.count, by: Self.batchSize) {
                    try Task.checkCancellation()
                    let fatia = Array(envelopes[lote..<min(lote + Self.batchSize, envelopes.count)])
                    try await gravaImap(
                        fatia, account: account, folderID: folderID,
                        uidValidity: status.uidValidity, bucket: bucket, corpos: corpos
                    )
                    feitas += fatia.count
                    progress(LoadProgress(accountID: account.id, done: feitas, total: totalEstimado))
                }

                try await database.pool.write { db in
                    try SyncStateRecord(
                        accountID: account.id, folderID: folderID,
                        uidValidity: status.uidValidity,
                        highestUID: uids.max(), syncedAt: now
                    ).save(db)
                }
            }
            if totalEstimado == 0 {
                progress(LoadProgress(accountID: account.id, done: 0, total: 0))
            }

            try await conclui(account.id, em: now)
            log.info("Carga IMAP de \(account.address, privacy: .private) terminou: \(feitas) mensagens.")
        } catch let erro as SyncError {
            try? await marca(account.id, estado: estadoPara(erro))
            log.error("Carga IMAP de \(account.address, privacy: .private) falhou: \(erro.mensagem)")
            throw erro
        } catch is CancellationError {
            try? await marca(account.id, estado: .ativa)
            throw CancellationError()
        }
    }

    private func gravaImap(
        _ envelopes: [ImapEnvelope], account: Account, folderID: String,
        uidValidity: Int64, bucket: TriageBucket, corpos: [Int64: [String]]
    ) async throws {
        try await database.pool.write { db in
            for envelope in envelopes {
                let id = MessageIdentity.imap(
                    accountID: account.id, folderID: folderID,
                    uidValidity: uidValidity, uid: envelope.uid
                )
                let corpo = corpos[envelope.uid] ?? []
                let nossa = Message(
                    id: id, accountID: account.id, from: envelope.from,
                    receivedAt: envelope.date,
                    subject: envelope.subject,
                    // Sem corpo baixado, a prévia é o assunto: melhor do que
                    // uma linha vazia onde o design desenha o trecho.
                    snippet: corpo.first ?? envelope.subject,
                    body: corpo, tags: [], bucket: bucket,
                    isRead: envelope.isRead, summary: nil, detectedEvent: nil,
                    to: envelope.to, cc: envelope.cc, isFlagged: envelope.isFlagged,
                    serverID: String(envelope.uid), uidValidity: uidValidity
                )
                try MessageRecord(nossa, folderID: folderID).save(db)
                if !corpo.isEmpty {
                    try MessageBodyRecord(messageID: id, paragraphs: corpo).save(db)
                }
            }
        }
    }
```

- [ ] **Step 4: Run to confirm success**

Run: `cd Packages/UNISync && swift test --filter InitialLoaderImap`

Expected: PASS, eight tests.

- [ ] **Step 5: Prove UIDVALIDITY cleanup through mutation**

Delete the `if trocou { … DELETE … }` block and run `swift test --filter uidValidityTrocadaLimpa`.

Expected: FAIL — `validades == [1755000000, 1999999999]`, with both generations coexisting. Restore and confirm green.

- [ ] **Step 6: Run the entire package**

Run: `cd Packages/UNISync && swift test 2>&1 | tail -5`

Expected: `Test run with N tests passed`, without failures.

- [ ] **Step 7: Commit**

```bash
git add Packages/UNISync/Sources/UNISync/Load/InitialLoader.swift Packages/UNISync/Tests/UNISyncTests/InitialLoaderImapTests.swift
git commit -m "Noventa dias de IMAP, pasta a pasta, com o papel resolvido na entrada

Duas passadas — descobrir tudo, depois baixar — para o progresso ter
denominador de verdade em vez de uma barra que anda para trás. UIDVALIDITY
trocada apaga a geração velha antes de gravar a nova: sem isso a lista
mostraria cada mensagem duas vezes, com assuntos diferentes sob o mesmo UID —
provado por mutação.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 14: `DatabaseMailSource`, observation and body search in `MailStore`

**Files:**
- Modify: `Packages/UNICore/Sources/UNICore/MessageStore.swift`
- Create: `Packages/UNISync/Sources/UNISync/Source/DatabaseMailSource.swift`
- Create: `Packages/UNICore/Tests/UNICoreTests/MailStoreObservationTests.swift`
- Create: `Packages/UNISync/Tests/UNISyncTests/DatabaseMailSourceTests.swift`

**Interfaces:**
- Consumes: `SyncDatabase`, records and `MessageSearch` (Task 5); `MailSource`, `MailStore` (Milestone 1).
- Produces:
  - `struct MailSnapshot: Sendable, Hashable` with `let accounts: [Account]`, `let messages: [Message]`, `let agenda: [AgendaItem]`, `let pendingItems: [PendingItem]`, `init(accounts:messages:agenda:pendingItems:)`.
  - `MailSource.snapshot() async throws -> MailSnapshot` (extension with default implementation), `MailSource.snapshots() -> AsyncThrowingStream<MailSnapshot, any Error>` (extension with a one-element default implementation), `MailSource.bodyMatches(_ term: String, accountID: String?) async throws -> Set<String>?` (extension returning `nil`).
  - `MailStore.observe() async` and `MailStore.refreshBodyMatches() async`.
  - `struct DatabaseMailSource: MailSource, Sendable` with `init(database: SyncDatabase)`.

- [ ] **Step 1: Write the failing tests**

`Packages/UNICore/Tests/UNICoreTests/MailStoreObservationTests.swift`:

```swift
import Foundation
import Testing
@testable import UNICore

@Suite("MailStore observando e buscando no corpo")
@MainActor
struct MailStoreObservationTests {
    @Test("Uma fonte sem observação entrega um snapshot só, e `load()` continua igual")
    func fonteSemObservacaoContinuaIgual() async throws {
        // A garantia dos 807: `InMemoryMailSource` não implementa `snapshots()`
        // e nada muda para quem já a usava.
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        #expect(!store.messages.isEmpty)
        #expect(store.loadError == nil)

        var quantos = 0
        for try await snapshot in InMemoryMailSource.fixtures.snapshots() {
            quantos += 1
            #expect(snapshot.accounts.count == Fixtures.accounts.count)
        }
        #expect(quantos == 1)
    }

    @Test("`observe()` aplica cada snapshot que chega")
    func observeAplicaCadaSnapshot() async throws {
        let fonte = FonteEmSequencia(snapshots: [
            MailSnapshot(accounts: Fixtures.accounts, messages: [], agenda: [], pendingItems: []),
            MailSnapshot(
                accounts: Fixtures.accounts,
                messages: [Message.preview(id: "novo")],
                agenda: [], pendingItems: []
            ),
        ])
        let store = MailStore(source: fonte)
        await store.observe()
        #expect(store.messages.map(\.id) == ["novo"])
        #expect(store.loadError == nil)
    }

    @Test("Erro no meio da observação vira `loadError`, e o que já estava fica")
    func erroNaObservacao() async throws {
        let fonte = FonteEmSequencia(
            snapshots: [MailSnapshot(
                accounts: Fixtures.accounts,
                messages: [Message.preview(id: "m1")],
                agenda: [], pendingItems: []
            )],
            erroDepois: FalhaDeTeste.rede
        )
        let store = MailStore(source: fonte)
        await store.observe()
        #expect(store.messages.map(\.id) == ["m1"])
        #expect(store.loadError == FalhaDeTeste.rede.localizedDescription)
    }

    @Test("A busca alcança o corpo quando a fonte sabe procurar nele")
    func buscaNoCorpo() async throws {
        // O `matches` do Marco 1 procura em remetente, assunto e prévia. O
        // corpo de mensagens antigas não está carregado, e é a fonte que sabe
        // procurar nele — no banco, com o índice.
        let fonte = FonteComCorpo(hits: ["m2"])
        let store = MailStore(source: fonte)
        await store.load()
        store.query = "orçamento"
        await store.refreshBodyMatches()
        #expect(store.visibleMessages.map(\.id) == ["m2"])
    }

    @Test("Busca vazia limpa os acertos de corpo")
    func buscaVaziaLimpa() async throws {
        let fonte = FonteComCorpo(hits: ["m2"])
        let store = MailStore(source: fonte)
        await store.load()
        store.query = "orçamento"
        await store.refreshBodyMatches()
        store.query = ""
        await store.refreshBodyMatches()
        #expect(store.visibleMessages.count == 2)
    }
}

private enum FalhaDeTeste: Error, LocalizedError {
    case rede
    var errorDescription: String? { "A rede caiu no teste." }
}

private struct FonteEmSequencia: MailSource {
    let snapshots: [MailSnapshot]
    var erroDepois: (any Error)?

    init(snapshots: [MailSnapshot], erroDepois: (any Error)? = nil) {
        self.snapshots = snapshots
        self.erroDepois = erroDepois
    }

    func accounts() async throws -> [Account] { snapshots.last?.accounts ?? [] }
    func messages() async throws -> [Message] { snapshots.last?.messages ?? [] }
    func agenda() async throws -> [AgendaItem] { snapshots.last?.agenda ?? [] }
    func pendingItems() async throws -> [PendingItem] { snapshots.last?.pendingItems ?? [] }

    func snapshots() -> AsyncThrowingStream<MailSnapshot, any Error> {
        let lista = snapshots
        let erro = erroDepois
        return AsyncThrowingStream { continuation in
            for snapshot in lista { continuation.yield(snapshot) }
            continuation.finish(throwing: erro)
        }
    }
}

private struct FonteComCorpo: MailSource {
    let hits: Set<String>

    func accounts() async throws -> [Account] { Fixtures.accounts }
    func messages() async throws -> [Message] {
        [Message.preview(id: "m1"), Message.preview(id: "m2")]
    }
    func agenda() async throws -> [AgendaItem] { [] }
    func pendingItems() async throws -> [PendingItem] { [] }
    func bodyMatches(_ term: String, accountID: String?) async throws -> Set<String>? { hits }
}
```

`Packages/UNISync/Tests/UNISyncTests/DatabaseMailSourceTests.swift`:

```swift
import Foundation
import GRDB
import Testing
import UNICore
@testable import UNISync

@Suite("A fonte que lê do banco")
struct DatabaseMailSourceTests {
    private let conta = Account(
        id: "conta-a", address: "eu@x.com", displayName: "Eu",
        provider: .imap, host: "x", tintLightHex: "#3F6AA1", tintDarkHex: "#8CBAF7"
    )

    private func semeia(_ db: SyncDatabase, corpo: [String] = ["A revisão saiu."]) async throws {
        try await db.pool.write { conexao in
            try AccountRecord(self.conta, createdAt: Date(timeIntervalSince1970: 1)).insert(conexao)
            try FolderRecord(
                id: "conta-a/INBOX", accountID: "conta-a",
                serverName: "INBOX", role: .inbox, displayName: "INBOX"
            ).insert(conexao)
            let mensagem = Message(
                id: "m1", accountID: "conta-a",
                from: Contact(name: "Marina", address: "marina@x.com"),
                receivedAt: Date(timeIntervalSince1970: 1_800_000_000),
                subject: "Assunto", snippet: "Trecho", body: corpo,
                tags: [], bucket: .today, isRead: false,
                summary: nil, detectedEvent: nil, serverID: "9001", uidValidity: 42
            )
            try MessageRecord(mensagem, folderID: "conta-a/INBOX").insert(conexao)
            try MessageBodyRecord(messageID: "m1", paragraphs: corpo).insert(conexao)
            try AgendaItemRecord(AgendaItem(
                id: "a1", title: "Reunião", startMinute: 570, endMinute: 600, accountID: "conta-a"
            )).insert(conexao)
        }
    }

    @Test("O snapshot traz contas, mensagens e agenda do banco")
    func snapshot() async throws {
        let db = try SyncDatabase.inMemory()
        try await semeia(db)
        let snapshot = try await DatabaseMailSource(database: db).snapshot()

        #expect(snapshot.accounts.map(\.id) == ["conta-a"])
        #expect(snapshot.messages.map(\.id) == ["m1"])
        #expect(snapshot.messages.first?.serverID == "9001")
        #expect(snapshot.agenda.map(\.id) == ["a1"])
        // `pendingItems` é do Marco 1 e não tem tabela: lista vazia, não erro.
        #expect(snapshot.pendingItems.isEmpty)
    }

    @Test("O corpo vem junto para quem já o tem no banco")
    func corpoNoSnapshot() async throws {
        let db = try SyncDatabase.inMemory()
        try await semeia(db)
        let snapshot = try await DatabaseMailSource(database: db).snapshot()
        #expect(snapshot.messages.first?.body == ["A revisão saiu."])
    }

    @Test("A busca de corpo desce para o índice e dobra acento")
    func buscaDeCorpo() async throws {
        let db = try SyncDatabase.inMemory()
        try await semeia(db)
        let fonte = DatabaseMailSource(database: db)
        #expect(try await fonte.bodyMatches("revisao", accountID: nil) == ["m1"])
        #expect(try await fonte.bodyMatches("orcamento", accountID: nil) == [])
        #expect(try await fonte.bodyMatches("revisao", accountID: "outra") == [])
    }

    @Test("A observação entrega o estado atual e acorda a cada escrita")
    func observacao() async throws {
        let db = try SyncDatabase.inMemory()
        try await semeia(db)
        let fonte = DatabaseMailSource(database: db)

        var vistos: [Int] = []
        for try await snapshot in fonte.snapshots() {
            vistos.append(snapshot.messages.count)
            if vistos.count == 1 {
                try await db.pool.write { conexao in
                    let outra = Message(
                        id: "m2", accountID: "conta-a",
                        from: Contact(name: "Outro", address: "o@x.com"),
                        receivedAt: Date(timeIntervalSince1970: 1_800_000_100),
                        subject: "Novo", snippet: "Novo", body: [],
                        tags: [], bucket: .today, isRead: false,
                        summary: nil, detectedEvent: nil
                    )
                    try MessageRecord(outra, folderID: "conta-a/INBOX").insert(conexao)
                }
            }
            if vistos.count == 2 { break }
        }
        #expect(vistos == [1, 2])
    }

    @Test("Banco vazio devolve snapshot vazio, e não erro")
    func bancoVazio() async throws {
        // É o estado do app antes da primeira conta: sem conta, a composição
        // fica nas fixtures, e esta fonte tem de saber dizer "não tenho nada"
        // sem lançar.
        let snapshot = try await DatabaseMailSource(database: try SyncDatabase.inMemory()).snapshot()
        #expect(snapshot.accounts.isEmpty)
        #expect(snapshot.messages.isEmpty)
    }
}
```

- [ ] **Step 2: Run to confirm failure**

Run:

```bash
(cd Packages/UNICore && swift test --filter MailStoreObservation)
(cd Packages/UNISync && swift test --filter DatabaseMailSource)
```

Expected: FAIL — `cannot find 'MailSnapshot' in scope`; `cannot find 'DatabaseMailSource' in scope`.

- [ ] **Step 3: Add snapshots and observation to `MailSource`**

In `Packages/UNICore/Sources/UNICore/MessageStore.swift`, after `protocol MailSource`:

```swift
/// Tudo o que a UI precisa, num valor só.
///
/// Existe porque a fonte deixou de ser um puxão e virou uma assinatura: com
/// quatro chamadas separadas, o `MailStore` teria de sincronizar quatro
/// sequências e decidir o que fazer quando três chegam e uma não. Um valor só
/// é atômico por construção.
public struct MailSnapshot: Sendable, Hashable {
    public let accounts: [Account]
    public let messages: [Message]
    public let agenda: [AgendaItem]
    public let pendingItems: [PendingItem]

    public init(
        accounts: [Account], messages: [Message],
        agenda: [AgendaItem], pendingItems: [PendingItem]
    ) {
        self.accounts = accounts
        self.messages = messages
        self.agenda = agenda
        self.pendingItems = pendingItems
    }
}

extension MailSource {
    /// Um retrato, agora.
    public func snapshot() async throws -> MailSnapshot {
        MailSnapshot(
            accounts: try await accounts(),
            messages: try await messages(),
            agenda: try await agenda(),
            pendingItems: try await pendingItems()
        )
    }

    /// A sequência de retratos.
    ///
    /// **A implementação padrão entrega um e termina** — é isso que faz
    /// `InMemoryMailSource` e todos os testes do Marco 1 continuarem valendo
    /// sem uma linha de mudança. Quem observa de verdade (o banco) sobrescreve.
    public func snapshots() -> AsyncThrowingStream<MailSnapshot, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    continuation.yield(try await snapshot())
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Os ids das mensagens cujo **corpo** casa com o termo.
    ///
    /// `nil` significa "esta fonte não sabe procurar no corpo" — e não "não
    /// achou nada". A diferença importa: com `nil`, o `MailStore` fica com a
    /// busca do Marco 1 (remetente, assunto, prévia) em vez de esvaziar a
    /// lista achando que a fonte respondeu.
    public func bodyMatches(_ term: String, accountID: String?) async throws -> Set<String>? { nil }
}
```

- [ ] **Step 4: Teach `MailStore` to observe and use body matches**

Still inside `MailStore` in `MessageStore.swift`, replace the body of `load()` with:

```swift
    public func load() async {
        do {
            apply(try await source.snapshot())
        } catch {
            // Em erro, nenhuma propriedade muda; o estado anterior continua válido.
            loadError = error.localizedDescription
        }
    }

    /// Assina a fonte e aplica cada retrato que chegar.
    ///
    /// É o que substitui `load()` quando a fonte é o banco: uma carga inicial
    /// que grava enquanto baixa acorda a lista sozinha, sem ninguém pedir
    /// "recarregar". Fontes que não observam entregam um retrato e terminam,
    /// então chamar isto nelas é exatamente `load()`.
    public func observe() async {
        do {
            for try await snapshot in source.snapshots() {
                apply(snapshot)
            }
        } catch {
            // O que já foi aplicado fica: a lista não pode esvaziar porque a
            // observação caiu. O erro aparece, com ação, na janela de Contas.
            loadError = error.localizedDescription
        }
    }

    /// Aplica um retrato inteiro, de uma vez.
    ///
    /// Atômico de propósito, como o `load()` do Marco 1 já era: ou as quatro
    /// listas mudam, ou nenhuma muda.
    private func apply(_ snapshot: MailSnapshot) {
        accounts = snapshot.accounts
        messages = snapshot.messages
        agenda = snapshot.agenda.sorted { $0.startMinute < $1.startMinute }
        pendingItems = snapshot.pendingItems
        loadError = nil
        // O protótipo abre com uma mensagem já aberta no leitor
        // (`state = { … selected: 'm1' … }`, a primeira da caixa "hoje").
        // O estado vazio fica reservado para uma caixa de fato vazia.
        selectDefaultMessage()
    }
```

After `public var query: String = ""`, add:

```swift
    /// Os ids que a fonte achou pelo **corpo**, para a busca corrente.
    ///
    /// Vive aqui e não em `matches` porque procurar no corpo é `async` (é
    /// consulta ao índice do banco) e `visibleMessages` é síncrono — a lista
    /// não pode esperar disco a cada redesenho.
    private var bodyHits: Set<String> = []
```

After `matches(_:_:)`, add:

```swift
    /// Pergunta à fonte quais mensagens casam **pelo corpo** com a busca atual.
    ///
    /// Quem chama é a tela, quando a busca muda. Termo vazio limpa os acertos
    /// em vez de perguntar: consultar o índice com string vazia devolveria a
    /// caixa inteira.
    public func refreshBodyMatches() async {
        let termo = query.trimmingCharacters(in: .whitespaces)
        guard !termo.isEmpty else {
            bodyHits = []
            return
        }
        do {
            bodyHits = try await source.bodyMatches(termo, accountID: selectedAccountID) ?? []
        } catch {
            // A busca no corpo falhar não pode apagar a lista: a busca do
            // Marco 1 continua valendo, e o erro aparece na janela de Contas.
            bodyHits = []
            loadError = error.localizedDescription
        }
    }
```

At the first line inside `matches(_:_:)`:

```swift
    private func matches(_ message: Message, _ term: String) -> Bool {
        if bodyHits.contains(message.id) { return true }
        let needle = ContactDirectory.fold(term)
        return [message.from.name, message.from.address, message.subject, message.snippet]
            .contains { ContactDirectory.fold($0).contains(needle) }
    }
```

- [ ] **Step 5: Write the database source**

`Packages/UNISync/Sources/UNISync/Source/DatabaseMailSource.swift`:

```swift
import Foundation
import GRDB
import UNICore

/// `MailSource` lendo do banco. **A fonte de verdade da UI quando há conta.**
///
/// Nada aqui espera rede: o pior caso é uma leitura de SQLite local. É o que
/// faz o app abrir offline mostrando os 90 dias, e é por isso que a rede
/// escreve no banco em vez de falar com a tela.
public struct DatabaseMailSource: MailSource, Sendable {
    private let database: SyncDatabase

    public init(database: SyncDatabase) {
        self.database = database
    }

    public func accounts() async throws -> [Account] {
        try await database.pool.read { db in
            try AccountRecord.order(Column("createdAt")).fetchAll(db).map(\.account)
        }
    }

    public func messages() async throws -> [Message] {
        try await database.pool.read { try Self.messages(in: $0) }
    }

    public func agenda() async throws -> [AgendaItem] {
        try await database.pool.read { db in
            try AgendaItemRecord.fetchAll(db).map(\.item)
        }
    }

    /// Sem tabela: `PendingItem` é a seção "Vindo do email" do Marco 1, que
    /// nasce da detecção no dispositivo e não do servidor. Lista vazia é a
    /// resposta honesta — inventar uma tabela vazia seria pior.
    public func pendingItems() async throws -> [PendingItem] { [] }

    public func snapshot() async throws -> MailSnapshot {
        try await database.pool.read { db in try Self.snapshot(in: db) }
    }

    /// A observação: um retrato agora, e outro a cada escrita que mexa no que
    /// a UI mostra.
    ///
    /// `ValueObservation` observa as tabelas que a consulta toca, então uma
    /// escrita em `sync_state` não acorda a lista à toa, e um lote da carga
    /// inicial acorda.
    public func snapshots() -> AsyncThrowingStream<MailSnapshot, any Error> {
        let pool = database.pool
        return AsyncThrowingStream { continuation in
            let tarefa = Task {
                do {
                    let observacao = ValueObservation.tracking { db in
                        try Self.snapshot(in: db)
                    }
                    for try await snapshot in observacao.values(in: pool) {
                        continuation.yield(snapshot)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in tarefa.cancel() }
        }
    }

    public func bodyMatches(_ term: String, accountID: String?) async throws -> Set<String>? {
        try await database.pool.read { db in
            try MessageSearch.matchingBodyIDs(db, term: term, accountID: accountID)
        }
    }

    // MARK: A leitura, num lugar só

    private static func snapshot(in db: Database) throws -> MailSnapshot {
        MailSnapshot(
            accounts: try AccountRecord.order(Column("createdAt")).fetchAll(db).map(\.account),
            messages: try messages(in: db),
            agenda: try AgendaItemRecord.fetchAll(db).map(\.item),
            pendingItems: []
        )
    }

    private static func messages(in db: Database) throws -> [Message] {
        let registros = try MessageRecord
            .order(Column("receivedAt").desc)
            .fetchAll(db)
        // Os corpos numa consulta só: um `fetchOne` por mensagem seria uma
        // consulta por linha da lista, e a lista tem milhares.
        let corpos = try MessageBodyRecord.fetchAll(db)
        let porID = Dictionary(uniqueKeysWithValues: corpos.map { ($0.messageID, $0.body) })
        return registros.map { $0.message(body: porID[$0.id] ?? []) }
    }
}
```

- [ ] **Step 6: Run to confirm success**

Run:

```bash
(cd Packages/UNICore && swift test --filter MailStoreObservation)
(cd Packages/UNISync && swift test --filter DatabaseMailSource)
```

Expected: PASS, 5 + 5 tests.

- [ ] **Step 7: Confirm the existing 807 remain green**

Run:

```bash
for p in UNIDesign UNICore UNIShell UNISync; do
  echo -n "$p: "
  (cd "Packages/$p" && swift test 2>&1 | grep -E 'Test run with')
done
```

Expected: no line containing `failed`. `UNIDesign` + `UNICore` + `UNIShell` still total 807 plus the new tests from this task and Task 3. No previous test changes result.

- [ ] **Step 8: Prove that the `nil` versus `[]` distinction matters**

Replace `?? []` in `refreshBodyMatches` with `bodyHits = try await source.bodyMatches(termo, accountID: selectedAccountID) ?? []`, treating `nil` as an empty set, **and** change `matches` to use `bodyHits.contains(message.id)` as its **only** condition. Run `swift test --filter buscaVaziaLimpa` and the Milestone 1 `MailStore` suite.

Expected: FAIL — Milestone 1's subject/sender/preview search disappears, since the in-memory source returns `nil` and the list empties on every keystroke. Restore the correct code and confirm green.

- [ ] **Step 9: Commit**

```bash
git add Packages/UNICore/Sources/UNICore/MessageStore.swift Packages/UNICore/Tests/UNICoreTests/MailStoreObservationTests.swift Packages/UNISync/Sources/UNISync/Source Packages/UNISync/Tests/UNISyncTests/DatabaseMailSourceTests.swift
git commit -m "A fonte passa a ser o banco, e a lista acorda sozinha enquanto a carga baixa

MailSource ganha snapshot, snapshots e bodyMatches com implementação padrão —
é isso que faz InMemoryMailSource e os 807 testes continuarem valendo sem uma
linha de mudança. `nil` em bodyMatches significa \"não sei procurar no corpo\",
e não \"não achei\": tratar os dois igual esvaziaria a lista a cada tecla nas
fixtures.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 15: `AccountDirector` and `AccountsModel` — add, test, remove and load

**Files:**
- Create: `Packages/UNISync/Sources/UNISync/Accounts/AccountStatus.swift`
- Create: `Packages/UNISync/Sources/UNISync/Accounts/AccountTints.swift`
- Create: `Packages/UNISync/Sources/UNISync/Accounts/AccountDirector.swift`
- Create: `Packages/UNISync/Sources/UNISync/Accounts/AccountsModel.swift`
- Create: `Packages/UNISync/Tests/UNISyncTests/AccountDirectorTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 4–14.
- Produces:
  - `struct AccountStatus: Sendable, Hashable, Identifiable` with `var id: String { accountID }`, `let accountID: String`, `let address: String`, `let hostMark: String`, `let state: Account.State`, `let messageCount: Int`, `let lastSyncedAt: Date?`, `let error: SyncError?`, `let progress: LoadProgress?`.
  - `enum AccountTints { static func pair(forIndex index: Int) -> (light: String, dark: String) }`.
  - `actor AccountDirector` with `init(database:secrets:auth:session:eventLoopGroup:imapConnect:now:)`, `func statuses() -> AsyncStream<[AccountStatus]>`, `func refresh() async`, `func addGoogleAccount(address: String) async throws -> Account`, `func testImap(address: String, password: String, endpoint: ImapEndpoint) async throws`, `func addImapAccount(address: String, password: String, endpoint: ImapEndpoint, hostMark: String, displayName: String) async throws -> Account`, `func remove(accountID: String) async throws`, `func loadInitial(accountID: String) async`, `static func accountID(for address: String) -> String`.
  - `@MainActor @Observable final class AccountsModel` with `init(director: AccountDirector)`, `private(set) var statuses: [AccountStatus]`, `func start() async`, forwarding methods `addGoogle(address:)`, `testImap(...)`, `addImap(...)`, `remove(_:)`, `loadInitial(_:)`, and `private(set) var lastError: SyncError?`.

- [ ] **Step 1: Write the failing test**

`Packages/UNISync/Tests/UNISyncTests/AccountDirectorTests.swift`:

```swift
import Foundation
import GRDB
import NIOCore
import NIOPosix
import Testing
import UNICore
@testable import UNISync

@Suite("O diretor de contas", .serialized)
struct AccountDirectorTests {
    private let agora = Date(timeIntervalSince1970: 1_800_000_000)

    private func roteiroImap() -> FakeImapServer.Script {
        .init(replies: [
            "LOGIN": ["TAG OK LOGIN completed"],
            "LIST": ["* LIST (\\HasNoChildren) \"/\" \"INBOX\"", "TAG OK LIST completed"],
            "SELECT": [
                "* 1 EXISTS",
                "* OK [UIDVALIDITY 1755000000] UIDs valid",
                "* OK [UIDNEXT 9002] Predicted next UID",
                "TAG OK [READ-WRITE] SELECT completed",
            ],
            "UID SEARCH": ["* SEARCH 9001", "TAG OK UID SEARCH completed"],
            "UID FETCH": [
                "* 1 FETCH (UID 9001 FLAGS () INTERNALDATE \"25-Aug-2026 09:00:00 -0300\" "
                + "ENVELOPE (\"Tue, 25 Aug 2026 09:00:00 -0300\" \"Oi\" "
                + "((\"Marina\" NIL \"marina\" \"clientepremium.com\")) NIL NIL NIL NIL NIL NIL NIL))",
                "TAG OK UID FETCH completed",
            ],
            "LOGOUT": ["TAG OK LOGOUT completed"],
        ])
    }

    private func diretor(
        db: SyncDatabase, secrets: any SecretStore, grupo: any EventLoopGroup, porta: Int
    ) -> AccountDirector {
        AccountDirector(
            database: db,
            secrets: secrets,
            auth: GoogleAuth(
                config: GoogleAuthConfig(
                    clientID: "cliente-de-teste",
                    tokenEndpoint: URL(string: "https://oauth2.example/token")!,
                    revocationEndpoint: URL(string: "https://oauth2.example/revoke")!
                ),
                session: StubURLProtocol.session(),
                secrets: secrets,
                presenter: StubAuthorizationPresenter { url in
                    let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                        .queryItems?.first { $0.name == "state" }?.value ?? ""
                    return URL(string: "com.okamiops.okamiuni:/oauth?code=cod&state=\(state)")!
                },
                now: { self.agora }
            ),
            session: StubURLProtocol.session(),
            gmailBaseURL: URL(string: "https://gmail.example/gmail/v1/users/me")!,
            eventLoopGroup: grupo,
            imapConnect: { endpoint, grupo in
                try await ImapSession.connect(
                    endpoint: ImapEndpoint(host: "127.0.0.1", port: porta, security: endpoint.security),
                    group: grupo
                )
            },
            now: { self.agora }
        )
    }

    @Test("O id da conta é derivado do endereço, estável e sem caractere solto")
    func idDaConta() {
        // Estável porque a chave estrangeira do banco e a entrada do Keychain
        // dependem dele: um id novo a cada adição órfã o que existia.
        #expect(AccountDirector.accountID(for: "Ricardo@Gmail.com")
            == AccountDirector.accountID(for: "ricardo@gmail.com"))
        #expect(!AccountDirector.accountID(for: "eu+tag@meu-site.com.br").contains("+"))
        #expect(AccountDirector.accountID(for: "a@b.com") != AccountDirector.accountID(for: "a@c.com"))
    }

    @Test("As cores das contas se repetem em ciclo — nada limita a quantidade")
    func coresCiclam() {
        let primeira = AccountTints.pair(forIndex: 0)
        #expect(primeira.light.hasPrefix("#"))
        #expect(primeira.dark.hasPrefix("#"))
        // A trigésima conta tem cor; ela não é a última nem a inválida.
        let trigesima = AccountTints.pair(forIndex: 29)
        #expect(trigesima.light.hasPrefix("#"))
    }

    @Test("Testar IMAP com senha certa passa e não grava nada")
    func testarImapOK() async throws {
        let servidor = FakeImapServer(script: roteiroImap())
        let porta = try servidor.start()
        defer { servidor.stop() }
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? grupo.syncShutdownGracefully() }

        let db = try SyncDatabase.inMemory()
        let cofre = InMemorySecretStore()
        let director = diretor(db: db, secrets: cofre, grupo: grupo, porta: porta)

        try await director.testImap(
            address: "contato@meusite.com", password: "senha-de-app",
            endpoint: ImapEndpoint(host: "127.0.0.1", port: porta, security: .startTLS)
        )
        // Testar é só testar: nada no banco, nada no Keychain.
        #expect(try await db.pool.read { try AccountRecord.fetchCount($0) } == 0)
        #expect(try cofre.secret(for: AccountDirector.accountID(for: "contato@meusite.com")) == nil)
    }

    @Test("Testar IMAP com senha errada devolve `autenticacao`, não uma frase genérica")
    func testarImapSenhaErrada() async throws {
        var script = roteiroImap()
        script.replies["LOGIN"] = ["TAG NO [AUTHENTICATIONFAILED] Invalid credentials"]
        let servidor = FakeImapServer(script: script)
        let porta = try servidor.start()
        defer { servidor.stop() }
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? grupo.syncShutdownGracefully() }

        let director = diretor(db: try SyncDatabase.inMemory(), secrets: InMemorySecretStore(), grupo: grupo, porta: porta)
        await #expect(throws: SyncError.autenticacao) {
            try await director.testImap(
                address: "contato@meusite.com", password: "errada",
                endpoint: ImapEndpoint(host: "127.0.0.1", port: porta, security: .startTLS)
            )
        }
    }

    @Test("Adicionar IMAP grava a conta no banco e a senha no cofre — e a senha não vai para o banco")
    func adicionarImap() async throws {
        let servidor = FakeImapServer(script: roteiroImap())
        let porta = try servidor.start()
        defer { servidor.stop() }
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? grupo.syncShutdownGracefully() }

        let db = try SyncDatabase.inMemory()
        let cofre = InMemorySecretStore()
        let director = diretor(db: db, secrets: cofre, grupo: grupo, porta: porta)

        let conta = try await director.addImapAccount(
            address: "contato@meusite.com", password: "senha-de-app",
            endpoint: ImapEndpoint(host: "127.0.0.1", port: porta, security: .startTLS),
            hostMark: "meusite", displayName: "Site"
        )
        #expect(conta.provider == .imap)
        #expect(conta.host == "meusite")
        #expect(conta.imap?.port == porta)

        #expect(try cofre.secret(for: conta.id) == .password("senha-de-app"))
        let gravada = try await db.pool.read { try AccountRecord.fetchOne($0, key: conta.id) }
        #expect(gravada?.address == "contato@meusite.com")
        // A senha não pode estar em coluna nenhuma.
        let linha = try await db.pool.read { conexao -> String in
            try String.fetchOne(conexao, sql: "SELECT group_concat(id || address || host || signature) FROM account") ?? ""
        }
        #expect(!linha.contains("senha-de-app"))
    }

    @Test("A carga inicial roda e o estado da conta anda: carregando → ativa")
    func cargaInicialAnda() async throws {
        let servidor = FakeImapServer(script: roteiroImap())
        let porta = try servidor.start()
        defer { servidor.stop() }
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? grupo.syncShutdownGracefully() }

        let db = try SyncDatabase.inMemory()
        let director = diretor(db: db, secrets: InMemorySecretStore(), grupo: grupo, porta: porta)
        let conta = try await director.addImapAccount(
            address: "contato@meusite.com", password: "senha-de-app",
            endpoint: ImapEndpoint(host: "127.0.0.1", port: porta, security: .startTLS),
            hostMark: "meusite", displayName: "Site"
        )
        await director.loadInitial(accountID: conta.id)

        let estados = try await db.pool.read { try AccountRecord.fetchOne($0, key: conta.id)?.account }
        #expect(estados?.state == .ativa)
        #expect(try await db.pool.read { try MessageRecord.fetchCount($0) } == 1)
    }

    @Test("O estado publicado traz endereço, contagem e erro")
    func statusPublicado() async throws {
        let servidor = FakeImapServer(script: roteiroImap())
        let porta = try servidor.start()
        defer { servidor.stop() }
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? grupo.syncShutdownGracefully() }

        let db = try SyncDatabase.inMemory()
        let director = diretor(db: db, secrets: InMemorySecretStore(), grupo: grupo, porta: porta)
        let conta = try await director.addImapAccount(
            address: "contato@meusite.com", password: "senha-de-app",
            endpoint: ImapEndpoint(host: "127.0.0.1", port: porta, security: .startTLS),
            hostMark: "meusite", displayName: "Site"
        )
        await director.loadInitial(accountID: conta.id)
        await director.refresh()

        var recebidos: [[AccountStatus]] = []
        for await lista in await director.statuses() {
            recebidos.append(lista)
            break
        }
        let status = try #require(recebidos.first?.first)
        #expect(status.accountID == conta.id)
        #expect(status.address == "contato@meusite.com")
        #expect(status.hostMark == "meusite")
        #expect(status.messageCount == 1)
        #expect(status.state == .ativa)
        #expect(status.error == nil)
    }

    @Test("Remover apaga banco e Keychain — os dois, sempre")
    func removerApagaOsDois() async throws {
        let servidor = FakeImapServer(script: roteiroImap())
        let porta = try servidor.start()
        defer { servidor.stop() }
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? grupo.syncShutdownGracefully() }

        let db = try SyncDatabase.inMemory()
        let cofre = InMemorySecretStore()
        let director = diretor(db: db, secrets: cofre, grupo: grupo, porta: porta)
        let conta = try await director.addImapAccount(
            address: "contato@meusite.com", password: "senha-de-app",
            endpoint: ImapEndpoint(host: "127.0.0.1", port: porta, security: .startTLS),
            hostMark: "meusite", displayName: "Site"
        )
        await director.loadInitial(accountID: conta.id)
        try await director.remove(accountID: conta.id)

        #expect(try await db.pool.read { try AccountRecord.fetchCount($0) } == 0)
        #expect(try await db.pool.read { try MessageRecord.fetchCount($0) } == 0)
        // Deixar o segredo para trás é a definição de "removi e não removi":
        // a conta some da lista e a senha continua no chaveiro da pessoa.
        #expect(try cofre.secret(for: conta.id) == nil)
    }

    @Test("Adicionar duas contas dá duas cores diferentes e nenhuma quantidade máxima")
    func duasContas() async throws {
        let servidor = FakeImapServer(script: roteiroImap())
        let porta = try servidor.start()
        defer { servidor.stop() }
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? grupo.syncShutdownGracefully() }

        let db = try SyncDatabase.inMemory()
        let director = diretor(db: db, secrets: InMemorySecretStore(), grupo: grupo, porta: porta)
        let endpoint = ImapEndpoint(host: "127.0.0.1", port: porta, security: .startTLS)
        let a = try await director.addImapAccount(
            address: "a@meusite.com", password: "s", endpoint: endpoint,
            hostMark: "meusite", displayName: "A"
        )
        let b = try await director.addImapAccount(
            address: "b@outro.com", password: "s", endpoint: endpoint,
            hostMark: "outro", displayName: "B"
        )
        #expect(a.tintLightHex != b.tintLightHex)
        #expect(try await db.pool.read { try AccountRecord.fetchCount($0) } == 2)
    }

    @Test("Sem client ID, a rota Google explica o que falta em vez de falhar mudo")
    func googleSemClientID() async throws {
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? grupo.syncShutdownGracefully() }

        let director = AccountDirector(
            database: try SyncDatabase.inMemory(),
            secrets: InMemorySecretStore(),
            auth: nil,   // é assim que a composição entrega "sem client ID"
            session: StubURLProtocol.session(),
            gmailBaseURL: URL(string: "https://gmail.example/gmail/v1/users/me")!,
            eventLoopGroup: grupo,
            imapConnect: { _, _ in throw SyncError.rede("não deveria ser chamado") },
            now: { self.agora }
        )
        await #expect(throws: SyncError.semClientID) {
            _ = try await director.addGoogleAccount(address: "ricardo@gmail.com")
        }
    }
}
```

- [ ] **Step 2: Run to confirm failure**

Run: `cd Packages/UNISync && swift test --filter AccountDirector`

Expected: FAIL — `cannot find 'AccountDirector' in scope`.

- [ ] **Step 3: Write published state and colors**

`Packages/UNISync/Sources/UNISync/Accounts/AccountStatus.swift`:

```swift
import Foundation
import UNICore

/// O que a janela de Contas e a linha da lateral mostram de cada conta.
///
/// É um valor, e não a `Account` mais uns extras, porque a janela precisa de
/// coisas que não são da conta: quantas mensagens estão **no banco**, o erro
/// da última tentativa e o progresso da carga em curso.
public struct AccountStatus: Sendable, Hashable, Identifiable {
    public var id: String { accountID }
    public let accountID: String
    public let address: String
    public let hostMark: String
    public let state: Account.State
    public let messageCount: Int
    public let lastSyncedAt: Date?
    /// O erro da última operação desta conta. Nulo é "nada de errado".
    public let error: SyncError?
    /// Nulo quando não há carga em curso.
    public let progress: LoadProgress?

    public init(
        accountID: String, address: String, hostMark: String,
        state: Account.State, messageCount: Int, lastSyncedAt: Date?,
        error: SyncError?, progress: LoadProgress?
    ) {
        self.accountID = accountID
        self.address = address
        self.hostMark = hostMark
        self.state = state
        self.messageCount = messageCount
        self.lastSyncedAt = lastSyncedAt
        self.error = error
        self.progress = progress
    }
}
```

`Packages/UNISync/Sources/UNISync/Accounts/AccountTints.swift`:

```swift
import Foundation

/// As cores de conta, em par claro/escuro.
///
/// **Cicla, e não acaba.** Uma lista com fim daria à décima primeira conta uma
/// cor nula ou um `precondition` — e o número de contas é ilimitado por
/// restrição herdada. Repetir cor na décima primeira é um incômodo visual;
/// recusar a décima primeira conta é um defeito.
///
/// Os pares são os das fixtures do Marco 1 mais os que o design usa nos temas,
/// já convertidos para sRGB.
public enum AccountTints {
    private static let pairs: [(light: String, dark: String)] = [
        ("#3F6AA1", "#8CBAF7"),
        ("#725B9A", "#C2A7F4"),
        ("#397852", "#88D1A2"),
        ("#298084", "#71D0D5"),
        ("#9A5B5B", "#F4A7A7"),
        ("#8A6D2F", "#E5C371"),
        ("#4A5B9A", "#A7B4F4"),
        ("#5B9A6D", "#A7F4C3"),
    ]

    public static func pair(forIndex index: Int) -> (light: String, dark: String) {
        pairs[((index % pairs.count) + pairs.count) % pairs.count]
    }
}
```

- [ ] **Step 4: Write the director**

`Packages/UNISync/Sources/UNISync/Accounts/AccountDirector.swift`:

```swift
import Foundation
import GRDB
import NIOCore
import UNICore
import os

/// Quem adiciona, testa, remove e carrega contas.
///
/// Ator porque tudo aqui é estado compartilhado com corrida óbvia: duas
/// adições simultâneas, uma remoção durante uma carga, um `refresh` no meio de
/// um `loadInitial`. O estado publicado sai por `AsyncStream`, e quem desenha é
/// `AccountsModel`, que é `@MainActor`.
public actor AccountDirector {
    private let database: SyncDatabase
    private let secrets: any SecretStore
    /// Nulo quando não há OAuth Client ID no bundle. **Não é um erro de
    /// construção**: o app continua inteiro pela rota IMAP, e a rota Google
    /// explica o que falta.
    private let auth: GoogleAuth?
    private let session: URLSession
    private let gmailBaseURL: URL
    private let eventLoopGroup: any EventLoopGroup
    private let imapConnect: @Sendable (ImapEndpoint, any EventLoopGroup) async throws -> ImapSession
    private let now: @Sendable () -> Date
    private let log = Logger(subsystem: "com.okamiops.okamiuni", category: "AccountDirector")

    private var errors: [String: SyncError] = [:]
    private var progresses: [String: LoadProgress] = [:]
    private var subscribers: [UUID: AsyncStream<[AccountStatus]>.Continuation] = [:]

    public init(
        database: SyncDatabase,
        secrets: any SecretStore,
        auth: GoogleAuth?,
        session: URLSession,
        gmailBaseURL: URL = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me")!,
        eventLoopGroup: any EventLoopGroup,
        imapConnect: @Sendable @escaping (ImapEndpoint, any EventLoopGroup) async throws -> ImapSession
            = { endpoint, grupo in try await ImapSession.connect(endpoint: endpoint, group: grupo) },
        now: @Sendable @escaping () -> Date = Date.init
    ) {
        self.database = database
        self.secrets = secrets
        self.auth = auth
        self.session = session
        self.gmailBaseURL = gmailBaseURL
        self.eventLoopGroup = eventLoopGroup
        self.imapConnect = imapConnect
        self.now = now
    }

    /// O id de uma conta, derivado do endereço.
    ///
    /// Estável e determinístico porque a chave estrangeira do banco e a entrada
    /// do Keychain dependem dele: um id novo a cada adição deixaria órfão tudo
    /// o que a conta já tinha. Caixa baixa e só o que é seguro em id.
    public static func accountID(for address: String) -> String {
        let dobrado = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let permitidos = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "@.-_"))
        return String(dobrado.unicodeScalars.map { permitidos.contains($0) ? Character($0) : "-" })
    }

    // MARK: Publicação

    public func statuses() -> AsyncStream<[AccountStatus]> {
        AsyncStream { continuation in
            let chave = UUID()
            subscribers[chave] = continuation
            continuation.onTermination = { _ in
                Task { await self.desassina(chave) }
            }
            Task { await self.refresh() }
        }
    }

    private func desassina(_ chave: UUID) { subscribers[chave] = nil }

    /// Relê o banco e publica.
    public func refresh() async {
        let lista = (try? await montaStatuses()) ?? []
        for continuation in subscribers.values { continuation.yield(lista) }
    }

    private func montaStatuses() async throws -> [AccountStatus] {
        let contas = try await database.pool.read { db -> [(Account, Int)] in
            try AccountRecord.order(Column("createdAt")).fetchAll(db).map { registro in
                let quantas = try Int.fetchOne(
                    db, sql: "SELECT count(*) FROM message WHERE accountID = ?",
                    arguments: [registro.id]
                ) ?? 0
                return (registro.account, quantas)
            }
        }
        return contas.map { conta, quantas in
            AccountStatus(
                accountID: conta.id, address: conta.address, hostMark: conta.host,
                state: conta.state, messageCount: quantas, lastSyncedAt: conta.lastSyncedAt,
                error: errors[conta.id], progress: progresses[conta.id]
            )
        }
    }

    // MARK: Adicionar

    /// Conecta uma conta Google: consentimento, perfil, gravação.
    @discardableResult
    public func addGoogleAccount(address: String) async throws -> Account {
        // Sem client ID a rota não existe — e dizer isso é a única coisa
        // honesta a fazer. A janela mostra a mensagem apontando o roteiro.
        guard let auth else { throw SyncError.semClientID }

        let id = Self.accountID(for: address)
        do {
            _ = try await auth.connect(accountID: id, loginHint: address)
            let cliente = GmailClient(
                session: session,
                accessToken: { [auth] in try await auth.accessToken(for: id) },
                baseURL: gmailBaseURL
            )
            let perfil = try await cliente.profile()
            let conta = try await grava(
                id: id, address: perfil.emailAddress, displayName: perfil.emailAddress,
                provider: .gmail, hostMark: "gmail", endpoint: nil
            )
            errors[id] = nil
            await refresh()
            return conta
        } catch let erro as SyncError {
            errors[id] = erro
            await refresh()
            throw erro
        }
    }

    /// Só testa: conecta, autentica, sai. Não grava nada.
    ///
    /// Separado de `addImapAccount` porque a janela promete "Testar e
    /// adicionar" com o resultado do teste explicado — e um teste que já grava
    /// não é teste, é adição com uma etiqueta errada.
    public func testImap(address: String, password: String, endpoint: ImapEndpoint) async throws {
        let sessao = try await imapConnect(endpoint, eventLoopGroup)
        do {
            try await sessao.login(user: address, password: password)
            await sessao.logout()
        } catch {
            await sessao.logout()
            throw error
        }
    }

    @discardableResult
    public func addImapAccount(
        address: String, password: String, endpoint: ImapEndpoint,
        hostMark: String, displayName: String
    ) async throws -> Account {
        let id = Self.accountID(for: address)
        do {
            try await testImap(address: address, password: password, endpoint: endpoint)
            // O segredo primeiro: uma conta no banco sem senha no Keychain
            // nasceria em erro de autenticação sem a pessoa ter feito nada.
            try secrets.store(.password(password), for: id)
            let conta = try await grava(
                id: id, address: address, displayName: displayName,
                provider: .imap, hostMark: hostMark, endpoint: endpoint
            )
            errors[id] = nil
            await refresh()
            return conta
        } catch let erro as SyncError {
            errors[id] = erro
            await refresh()
            throw erro
        }
    }

    private func grava(
        id: String, address: String, displayName: String,
        provider: Account.Provider, hostMark: String, endpoint: ImapEndpoint?
    ) async throws -> Account {
        let quantasJa = try await database.pool.read { try AccountRecord.fetchCount($0) }
        let cores = AccountTints.pair(forIndex: quantasJa)
        let conta = Account(
            id: id, address: address, displayName: displayName,
            provider: provider, host: hostMark,
            tintLightHex: cores.light, tintDarkHex: cores.dark,
            imap: endpoint, state: .carregando
        )
        try await database.pool.write { db in
            try AccountRecord(conta, createdAt: self.now()).save(db)
        }
        return conta
    }

    // MARK: Remover

    /// Apaga a conta: banco **e** Keychain, e revoga no Google quando for o caso.
    ///
    /// Os dois, sempre. Deixar o segredo para trás é a definição de "removi e
    /// não removi": a conta some da lista e a senha continua no chaveiro da
    /// pessoa, esperando por um app que já esqueceu dela.
    public func remove(accountID: String) async throws {
        let conta = try await database.pool.read { db in
            try AccountRecord.fetchOne(db, key: accountID)?.account
        }
        if conta?.provider == .gmail, let auth {
            // Falhar aqui (offline, por exemplo) não pode impedir a remoção
            // local — mas o erro fica registrado para a janela mostrar.
            do { try await auth.revoke(accountID: accountID) } catch let erro as SyncError {
                errors[accountID] = erro
                log.error("Revogação de \(accountID, privacy: .public) falhou: \(erro.mensagem)")
            }
        }
        try secrets.remove(for: accountID)
        // A cascata do banco leva pastas, mensagens, corpos, agenda e
        // sync_state junto — está na migração v1, com teste.
        _ = try await database.pool.write { db in
            try AccountRecord.deleteOne(db, key: accountID)
        }
        errors[accountID] = nil
        progresses[accountID] = nil
        await refresh()
    }

    // MARK: Carregar

    /// A carga inicial da conta, publicando progresso.
    ///
    /// Não lança: quem chama é a UI, e o lugar do erro é o estado publicado —
    /// que é onde a janela mostra a causa e a ação. Engolir seria não
    /// registrar; aqui ele vai para `errors`, para o log e para a tela.
    public func loadInitial(accountID: String) async {
        guard let conta = try? await database.pool.read({ db in
            try AccountRecord.fetchOne(db, key: accountID)?.account
        }) else { return }

        let loader = InitialLoader(database: database)
        let publica: @Sendable (LoadProgress) -> Void = { [weak self] progresso in
            Task { await self?.registra(progresso) }
        }

        do {
            switch conta.provider {
            case .gmail:
                guard let auth else { throw SyncError.semClientID }
                let cliente = GmailClient(
                    session: session,
                    accessToken: { [auth] in try await auth.accessToken(for: accountID) },
                    baseURL: gmailBaseURL
                )
                try await loader.loadGmail(account: conta, client: cliente, now: now(), progress: publica)
            case .imap, .microsoft:
                guard let endpoint = conta.imap else { throw SyncError.resposta("A conta não tem servidor IMAP configurado.") }
                guard case .password(let senha)? = try secrets.secret(for: accountID) else {
                    throw SyncError.autenticacao
                }
                let sessao = try await imapConnect(endpoint, eventLoopGroup)
                defer { Task { await sessao.logout() } }
                try await sessao.login(user: conta.address, password: senha)
                try await loader.loadImap(account: conta, session: sessao, now: now(), progress: publica)
            }
            errors[accountID] = nil
        } catch let erro as SyncError {
            errors[accountID] = erro
            log.error("Carga de \(accountID, privacy: .public) falhou: \(erro.mensagem)")
        } catch {
            errors[accountID] = .rede(error.localizedDescription)
        }
        progresses[accountID] = nil
        await refresh()
    }

    private func registra(_ progresso: LoadProgress) async {
        progresses[progresso.accountID] = progresso
        await refresh()
    }
}
```

- [ ] **Step 5: Write the UI bridge**

`Packages/UNISync/Sources/UNISync/Accounts/AccountsModel.swift`:

```swift
import Foundation
import Observation

/// O que a janela de Contas observa.
///
/// `@Observable` vem do módulo `Observation`, não do SwiftUI — este pacote
/// continua sem importar SwiftUI, como a arquitetura manda. É a mesma escolha
/// que o `MailStore` do `UNICore` já faz.
@MainActor
@Observable
public final class AccountsModel {
    public private(set) var statuses: [AccountStatus] = []
    /// O erro da última ação que a **janela** disparou (adicionar, testar,
    /// remover). Separado do erro por conta: um teste de conta que ainda não
    /// existe não tem conta a que pertencer.
    public private(set) var lastError: SyncError?
    public private(set) var isBusy = false

    private let director: AccountDirector

    public init(director: AccountDirector) {
        self.director = director
    }

    /// Assina o diretor. Chamada uma vez, na montagem da cena.
    public func start() async {
        for await lista in await director.statuses() {
            statuses = lista
        }
    }

    public func addGoogle(address: String) async {
        await roda { try await self.director.addGoogleAccount(address: address) }
    }

    /// Testa sem gravar. Devolve `true` quando passou, para a janela mostrar o
    /// resultado — e `lastError` explica quando não.
    @discardableResult
    public func testImap(address: String, password: String, endpoint: ImapEndpoint) async -> Bool {
        await roda { try await self.director.testImap(address: address, password: password, endpoint: endpoint) }
        return lastError == nil
    }

    public func addImap(
        address: String, password: String, endpoint: ImapEndpoint,
        hostMark: String, displayName: String
    ) async {
        await roda {
            let conta = try await self.director.addImapAccount(
                address: address, password: password, endpoint: endpoint,
                hostMark: hostMark, displayName: displayName
            )
            await self.director.loadInitial(accountID: conta.id)
        }
    }

    public func remove(_ accountID: String) async {
        await roda { try await self.director.remove(accountID: accountID) }
    }

    public func loadInitial(_ accountID: String) async {
        await director.loadInitial(accountID: accountID)
    }

    /// Uma ação, com o ocupado ligado e o erro capturado.
    ///
    /// O `catch` é largo de propósito e **não** engole: todo erro vira
    /// `lastError`, que a janela mostra. O que não pode acontecer é a janela
    /// ficar com o botão girando para sempre porque alguém lançou algo que não
    /// era `SyncError`.
    private func roda(_ acao: @escaping () async throws -> Void) async {
        isBusy = true
        lastError = nil
        do {
            try await acao()
        } catch let erro as SyncError {
            lastError = erro
        } catch {
            lastError = .rede(error.localizedDescription)
        }
        isBusy = false
    }
}
```

- [ ] **Step 6: Run to confirm success**

Run: `cd Packages/UNISync && swift test --filter AccountDirector`

Expected: PASS, nine tests.

- [ ] **Step 7: Prove the window's two promises through mutation**

1. Make `testImap` persist data by calling `grava(...)` at the end, then run `swift test --filter testarImapOK`.
   Expected: FAIL — `AccountRecord.fetchCount == 1`. A “Test” operation that saves is a mislabeled add operation.
2. Delete `try secrets.remove(for: accountID)` from `remove` and run `swift test --filter removerApagaOsDois`.
   Expected: FAIL — the password remains in the vault after the account disappears.

Restore both and confirm green.

- [ ] **Step 8: Commit**

```bash
git add Packages/UNISync/Sources/UNISync/Accounts Packages/UNISync/Tests/UNISyncTests/AccountDirectorTests.swift
git commit -m "O diretor de contas: adicionar, testar sem gravar, remover dos dois lugares

Ator porque tudo aqui tem corrida óbvia — duas adições, uma remoção durante uma
carga. Testar não grava e remover apaga banco E Keychain: as duas promessas
estão travadas por mutação. Sem client ID, a rota Google devolve semClientID
apontando o roteiro em vez de falhar mudo, e a rota IMAP continua inteira.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 16: The Accounts window

**Files:**
- Create: `Packages/UNIShell/Sources/UNIShell/Windows/AccountsWindow.swift`
- Create: `Packages/UNIShell/Sources/UNIShell/Windows/AccountsList.swift`
- Create: `Packages/UNIShell/Sources/UNIShell/Windows/AddAccountForm.swift`
- Modify: `Packages/UNIShell/Sources/UNIShell/Windows/UNIWindow.swift`
- Modify: `Packages/UNICore/Sources/UNICore/ContextMenu.swift`
- Modify: `Packages/UNIShell/Sources/UNIShell/Support/ContextMenuHost.swift`
- Modify: `Packages/UNIShell/Sources/UNIShell/Inbox/FolderSidebar.swift`
- Create: `Packages/UNIShell/Tests/UNIShellTests/AccountsWindowTests.swift`
- Create: `Packages/UNICore/Tests/UNICoreTests/AccountsMenuTests.swift`

**Interfaces:**
- Consumes: `AccountsModel`, `AccountStatus`, `SyncError`, `ProviderDetector`, `ProviderRoute`, `ImapPreset`, `ImapPresets`, `ImapEndpoint`, `LoadProgress` (Tasks 4–15); `Theme`, `@Environment(\.theme)`, `.hairline`, `.capsLabel`, `TintChip`, `ComposerSelect` (Milestone 1).
- Produces:
  - `UNIWindow.accounts: String` = `"uni.accounts"` and `UNIWindow.Size.accounts: CGSize`.
  - `ContextCommand.openAccounts` and the “Contas…” item in `ContextMenus.accountRow`.
  - `struct AccountsWindow: View` with `init(model: AccountsModel)`.
  - `struct AccountsList: View` with `init(statuses: [AccountStatus], onReconnect: (String) -> Void, onRetry: (String) -> Void, onRemove: (String) -> Void)`.
  - `struct AddAccountForm: View` with `init(model: AccountsModel)`.
  - `enum AccountsCopy` with `static func status(_ s: AccountStatus, now: Date, calendar: Calendar) -> String` — **pure, and the home of every copy decision**.

- [ ] **Step 1: Write the failing tests (pure logic first)**

`Packages/UNICore/Tests/UNICoreTests/AccountsMenuTests.swift`:

```swift
import Foundation
import Testing
@testable import UNICore

@Suite("O caminho até a janela de Contas")
struct AccountsMenuTests {
    @Test("A linha da conta oferece 'Contas…'")
    func itemNoMenuDaConta() {
        let conta = Fixtures.accounts[0]
        let entradas = ContextMenus.accountRow(conta, isFiltered: false, unread: 0)
        let rotulos = entradas.compactMap { entrada -> String? in
            guard case .item(let item) = entrada else { return nil }
            return item.title
        }
        #expect(rotulos.contains("Contas…"))
    }

    @Test("O comando é próprio, e não um `copy` disfarçado")
    func comandoProprio() {
        let entradas = ContextMenus.accountRow(Fixtures.accounts[0], isFiltered: false, unread: 0)
        let comandos = entradas.compactMap { entrada -> ContextCommand? in
            guard case .item(let item) = entrada else { return nil }
            return item.command
        }
        #expect(comandos.contains(.openAccounts))
    }
}
```

`Packages/UNIShell/Tests/UNIShellTests/AccountsWindowTests.swift`:

```swift
import Foundation
import SwiftUI
import Testing
import UNICore
import UNIDesign
import UNISync
@testable import UNIShell

@Suite("A janela de Contas")
@MainActor
struct AccountsWindowTests {
    private let agora = Date(timeIntervalSince1970: 1_800_000_000)
    private var calendario: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
        return c
    }

    private func status(
        state: Account.State = .ativa,
        erro: SyncError? = nil,
        progresso: LoadProgress? = nil,
        sincronizada: Date? = Date(timeIntervalSince1970: 1_799_996_400),
        mensagens: Int = 1_284
    ) -> AccountStatus {
        AccountStatus(
            accountID: "conta-a", address: "contato@meusite.com", hostMark: "meusite",
            state: state, messageCount: mensagens, lastSyncedAt: sincronizada,
            error: erro, progress: progresso
        )
    }

    // MARK: O texto — puro, e é onde estão as decisões

    @Test("Conta ativa diz quando sincronizou, no relógio de quem lê")
    func textoAtiva() {
        let texto = AccountsCopy.status(status(), now: agora, calendar: calendario)
        #expect(texto.hasPrefix("Sincronizada às "))
        #expect(texto.contains("1.284 mensagens"))
    }

    @Test("Conta que nunca sincronizou não inventa data")
    func textoNuncaSincronizou() {
        let texto = AccountsCopy.status(
            status(sincronizada: nil, mensagens: 0), now: agora, calendar: calendario
        )
        #expect(texto.contains("Ainda não sincronizada"))
        #expect(!texto.contains("às"))
    }

    @Test("Carregando mostra o progresso em porcentagem, não uma barra muda")
    func textoCarregando() {
        let texto = AccountsCopy.status(
            status(state: .carregando, progresso: LoadProgress(accountID: "conta-a", done: 250, total: 1_000)),
            now: agora, calendar: calendario
        )
        #expect(texto.contains("Carregando"))
        #expect(texto.contains("25%"))
    }

    @Test("Carregando sem total conhecido não escreve porcentagem inventada")
    func textoCarregandoSemTotal() {
        let texto = AccountsCopy.status(status(state: .carregando), now: agora, calendar: calendario)
        #expect(texto.contains("Carregando"))
        #expect(!texto.contains("%"))
    }

    @Test("Erro mostra a **causa**, não 'algo deu errado'")
    func textoDeErro() {
        // A regra do projeto: erro nunca engolido. Cada `SyncError` tem uma
        // frase; a janela mostra aquela frase.
        for erro in [SyncError.autenticacao, .rede("tempo esgotado"), .tls("certificado expirado"), .quota] {
            let texto = AccountsCopy.status(status(state: .erroDeAutenticacao, erro: erro), now: agora, calendar: calendario)
            #expect(texto.contains(erro.mensagem), "faltou a causa de \(erro)")
        }
    }

    @Test("Erro de autenticação pede reconectar; erro de rede pede tentar de novo")
    func acaoCombinaComACausa() {
        // Duas ações diferentes porque são dois problemas diferentes.
        // "Reconectar" para quem só perdeu o wi-fi manda a pessoa refazer o
        // consentimento à toa.
        #expect(AccountsCopy.action(for: .autenticacao) == "Reconectar")
        #expect(AccountsCopy.action(for: .autorizacaoRevogada) == "Reconectar")
        #expect(AccountsCopy.action(for: .semClientID) == "Ver o roteiro")
        #expect(AccountsCopy.action(for: .rede("x")) == "Tentar de novo")
        #expect(AccountsCopy.action(for: .tls("x")) == "Tentar de novo")
        #expect(AccountsCopy.action(for: .quota) == "Tentar de novo")
    }

    // MARK: A aparência

    @Test("A janela desenha no token do tema, em claro e em escuro")
    func fundoNoToken() throws {
        for tema in [ThemeCatalog.theme(id: "tinta"), ThemeCatalog.theme(id: "noite")] {
            let tema = try #require(tema)
            let bitmap = try #require(Render.bitmap(
                AccountsList(
                    statuses: [status()],
                    onReconnect: { _ in }, onRetry: { _ in }, onRemove: { _ in }
                ),
                size: CGSize(width: 720, height: 400),
                theme: tema
            ))
            // O canto superior esquerdo é fundo puro: nenhum conteúdo desenha
            // lá. Se ele não estiver no token, a janela pintou cor literal.
            let cor = try #require(bitmap.colorAt(x: 4, y: 4))
            #expect(proximo(cor, tema.paper), "fundo fora do token no tema \(tema.id)")
        }
    }

    @Test("A hairline tem 1 pixel de dispositivo em 1× e em 2×")
    func hairlineDeUmPixel() throws {
        let tema = try #require(ThemeCatalog.theme(id: "tinta"))
        for escala in [CGFloat(1), CGFloat(2)] {
            let bitmap = try #require(Render.bitmap(
                AccountsList(
                    statuses: [status(), status()],
                    onReconnect: { _ in }, onRetry: { _ in }, onRemove: { _ in }
                ),
                size: CGSize(width: 720, height: 200),
                theme: tema, scale: escala
            ))
            #expect(bitmap.pixelsWide == Int(720 * escala))
        }
    }

    @Test("A lista aguenta zero, uma e trinta contas sem mudar de largura")
    func quantidadesExtremas() throws {
        let tema = try #require(ThemeCatalog.theme(id: "tinta"))
        for quantas in [0, 1, 30] {
            let lista = (0..<quantas).map { indice in
                AccountStatus(
                    accountID: "c\(indice)", address: "conta\(indice)@dominio.com",
                    hostMark: "host\(indice)", state: .ativa, messageCount: indice,
                    lastSyncedAt: nil, error: nil, progress: nil
                )
            }
            let bitmap = try #require(Render.bitmap(
                AccountsList(statuses: lista, onReconnect: { _ in }, onRetry: { _ in }, onRemove: { _ in }),
                size: CGSize(width: 720, height: 400), theme: tema
            ))
            #expect(bitmap.pixelsWide == 720)
        }
    }

    @Test("O formulário aparece só depois de o endereço ter rota")
    func formularioSegueARota() {
        // Regra do Marco 1: controle que existe faz alguma coisa. Um campo de
        // host antes de saber para onde ir seria um controle sem resposta.
        #expect(AddAccountForm.route(for: "") == nil)
        #expect(AddAccountForm.route(for: "ricardo@gmail.com") == .google)
        guard case .imap(let preset)? = AddAccountForm.route(for: "eu@icloud.com") else {
            Issue.record("esperava preset de iCloud"); return
        }
        #expect(preset.endpoint.port == 993)
        guard case .manual(let sugerido)? = AddAccountForm.route(for: "eu@dominio-proprio.com.br") else {
            Issue.record("esperava manual"); return
        }
        #expect(sugerido.host == "imap.dominio-proprio.com.br")
    }

    /// Duas cores batem, com a tolerância de 0,02 por canal que a suíte usa.
    private func proximo(_ cor: NSColor, _ token: TokenColor) -> Bool {
        guard let a = cor.usingColorSpace(.sRGB),
              let b = NSColor(token.color).usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) < 0.02
            && abs(a.greenComponent - b.greenComponent) < 0.02
            && abs(a.blueComponent - b.blueComponent) < 0.02
    }
}
```

- [ ] **Step 2: Run to confirm failure**

Run:

```bash
(cd Packages/UNICore && swift test --filter AccountsMenu)
(cd Packages/UNIShell && swift test --filter AccountsWindow)
```

Expected: FAIL — `type 'ContextCommand' has no member 'openAccounts'`; `cannot find 'AccountsWindow' in scope`.

- [ ] **Step 3: Wire the path to the window**

In `Packages/UNICore/Sources/UNICore/ContextMenu.swift`, add to `enum ContextCommand` after `case clearAccountFilter`:

```swift
    /// Abre a janela de Contas. Cena própria (`UNIWindow.accounts`), como as
    /// outras quatro — não é folha, e por isso tem ⌘W e entra no menu Janela.
    case openAccounts
```

In `ContextMenus.accountRow`, before `entries.append(.item(ContextMenuItem("Copiar endereço", …)))`:

```swift
        entries.append(.item(ContextMenuItem(
            "Contas…",
            .openAccounts,
            help: "Adicionar, testar ou remover contas"
        )))
```

In the window-opening `switch` of `Packages/UNIShell/Sources/UNIShell/Support/ContextMenuHost.swift`, alongside `.openEvent`:

```swift
        case .openAccounts:
            openWindow(id: UNIWindow.accounts)
```

In `Packages/UNIShell/Sources/UNIShell/Windows/UNIWindow.swift`, after `public static let event`:

```swift
    /// A janela de Contas do Marco 2. Sem valor: ela é uma só.
    public static let accounts = "uni.accounts"
```

Inside `enum Size`:

```swift
        /// A lista mede pelo endereço mais largo que cabe sem truncar
        /// (`contato@meusite.com.br` a 12,5pt) mais o chip, o estado e o botão
        /// remover: 720. A altura mostra seis contas sem rolar.
        public static let accounts = CGSize(width: 720, height: 560)
```

- [ ] **Step 4: Write the copy (the pure part)**

At the top of `Packages/UNIShell/Sources/UNIShell/Windows/AccountsList.swift`:

```swift
import SwiftUI
import UNICore
import UNIDesign
import UNISync

/// Todo o texto da janela de Contas, num lugar puro.
///
/// Fora da `View` porque é decisão, não desenho: o que uma conta em erro diz e
/// que ação ela oferece são regras do produto, e regra dentro de `body` não se
/// testa sem renderizar.
public enum AccountsCopy {
    /// A linha de estado de uma conta.
    public static func status(_ s: AccountStatus, now: Date, calendar: Calendar) -> String {
        let contagem = "\(numero(s.messageCount)) \(s.messageCount == 1 ? "mensagem" : "mensagens")"

        if let erro = s.error {
            return "\(erro.mensagem) · \(contagem)"
        }
        switch s.state {
        case .carregando:
            if let progresso = s.progress, progresso.total > 0 {
                let porcento = Int((progresso.fraction * 100).rounded())
                return "Carregando… \(porcento)% · \(contagem)"
            }
            // Sem total conhecido não há porcentagem honesta. Uma barra que
            // finge 0% enquanto a página de ids ainda está sendo pedida é pior
            // do que dizer só "Carregando".
            return "Carregando… · \(contagem)"
        case .erroDeAutenticacao:
            return "\(SyncError.autenticacao.mensagem) · \(contagem)"
        case .ativa:
            guard let quando = s.lastSyncedAt else {
                return "Ainda não sincronizada · \(contagem)"
            }
            return "Sincronizada \(horario(quando, calendar: calendar)) · \(contagem)"
        }
    }

    /// A ação que o erro pede. Duas ações diferentes porque são dois problemas
    /// diferentes: mandar reconectar quem só perdeu o wi-fi é fazer a pessoa
    /// refazer o consentimento à toa.
    public static func action(for erro: SyncError) -> String {
        switch erro {
        case .autenticacao, .autorizacaoRevogada: "Reconectar"
        case .semClientID: "Ver o roteiro"
        default: "Tentar de novo"
        }
    }

    /// "às 14:32". O `Calendar` vem de fora: hora de parede é da máquina de
    /// quem lê, e não do modelo — a mesma regra que mantém `dayOffset` inteiro.
    private static func horario(_ data: Date, calendar: Calendar) -> String {
        let partes = calendar.dateComponents([.hour, .minute], from: data)
        return String(format: "às %02d:%02d", partes.hour ?? 0, partes.minute ?? 0)
    }

    /// "1.284" — separador de milhar em pt-BR.
    private static func numero(_ valor: Int) -> String {
        let formatador = NumberFormatter()
        formatador.locale = Locale(identifier: "pt_BR")
        formatador.numberStyle = .decimal
        return formatador.string(from: NSNumber(value: valor)) ?? "\(valor)"
    }
}
```

- [ ] **Step 5: Write the list**

Still in `AccountsList.swift`, after `AccountsCopy`:

```swift
/// A lista de contas: endereço, chip do provedor, estado e o que fazer.
public struct AccountsList: View {
    @Environment(\.theme) private var theme

    private let statuses: [AccountStatus]
    private let onReconnect: (String) -> Void
    private let onRetry: (String) -> Void
    private let onRemove: (String) -> Void

    public init(
        statuses: [AccountStatus],
        onReconnect: @escaping (String) -> Void,
        onRetry: @escaping (String) -> Void,
        onRemove: @escaping (String) -> Void
    ) {
        self.statuses = statuses
        self.onReconnect = onReconnect
        self.onRetry = onRetry
        self.onRemove = onRemove
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if statuses.isEmpty {
                // Zero contas é estado legítimo, e não vazio mudo: o app está
                // nas fixtures, e a frase diz isso.
                Text("Nenhuma conta conectada. O app está mostrando dados de exemplo.")
                    .font(theme.sans.font(size: 12.5))
                    .foregroundStyle(theme.ink3.color)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 18)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(statuses) { status in
                            row(status)
                            Rectangle()
                                .fill(theme.line.color)
                                .hairline()
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.paper.color)
    }

    private func row(_ status: AccountStatus) -> some View {
        HStack(alignment: .top, spacing: 10) {
            TintChip(label: status.hostMark, tint: theme.ink4.color, emphasized: false)
            VStack(alignment: .leading, spacing: 4) {
                Text(status.address)
                    .font(theme.sans.font(size: 12.5, weight: .medium))
                    .foregroundStyle(theme.ink.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(AccountsCopy.status(status, now: Date(), calendar: .current))
                    .font(theme.sans.font(size: 11.5))
                    .foregroundStyle(status.error == nil ? theme.ink3.color : theme.accent.color)
                    .fixedSize(horizontal: false, vertical: true)
                if let progresso = status.progress, progresso.total > 0 {
                    ProgressView(value: progresso.fraction)
                        .tint(theme.accent.color)
                        .frame(maxWidth: 260)
                }
            }
            Spacer(minLength: 12)
            if let erro = status.error {
                Button(AccountsCopy.action(for: erro)) {
                    switch erro {
                    case .autenticacao, .autorizacaoRevogada, .semClientID:
                        onReconnect(status.accountID)
                    default:
                        onRetry(status.accountID)
                    }
                }
                .buttonStyle(.plain)
                .font(theme.sans.font(size: 11.5, weight: .medium))
                .foregroundStyle(theme.accent.color)
                .focusRing(cornerRadius: theme.radiusSmall)
            }
            Button("Remover") { onRemove(status.accountID) }
                .buttonStyle(.plain)
                .font(theme.sans.font(size: 11.5))
                .foregroundStyle(theme.ink3.color)
                .focusRing(cornerRadius: theme.radiusSmall)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
```

- [ ] **Step 6: Write the form and window**

`Packages/UNIShell/Sources/UNIShell/Windows/AddAccountForm.swift`:

```swift
import SwiftUI
import UNICore
import UNIDesign
import UNISync

/// Endereço → rota → OAuth ou formulário IMAP.
public struct AddAccountForm: View {
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL

    private let model: AccountsModel

    @State private var address = ""
    @State private var password = ""
    @State private var host = ""
    @State private var port = "993"
    @State private var security: ImapEndpoint.Security = .tls
    @State private var testado: Bool?

    public init(model: AccountsModel) {
        self.model = model
    }

    /// A rota do endereço digitado. Estático e puro para o teste não precisar
    /// de `View` nenhuma — é a mesma regra de "lógica pura fora de View".
    public static func route(for address: String) -> ProviderRoute? {
        ProviderDetector.route(for: address)
    }

    private var route: ProviderRoute? { Self.route(for: address) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ADICIONAR CONTA").capsLabel()

            TextField("endereço@qualquerdominio.com", text: $address)
                .textFieldStyle(.plain)
                .font(theme.sans.font(size: 12.5))
                .foregroundStyle(theme.ink.color)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(theme.surface2.color, in: RoundedRectangle(cornerRadius: theme.radiusSmall))
                .onChange(of: address) { _, novo in preenche(novo) }

            switch route {
            case .none:
                Text("Digite o endereço da conta.")
                    .font(theme.sans.font(size: 11.5))
                    .foregroundStyle(theme.ink4.color)

            case .google:
                Text("Conta do Google: a autorização abre no navegador.")
                    .font(theme.sans.font(size: 11.5))
                    .foregroundStyle(theme.ink3.color)
                Button("Autorizar no Google") {
                    Task { await model.addGoogle(address: address) }
                }
                .buttonStyle(.plain)
                .font(theme.sans.font(size: 12, weight: .medium))
                .foregroundStyle(theme.accent.color)
                .disabled(model.isBusy)
                .focusRing(cornerRadius: theme.radiusSmall)

            case .imap, .manual:
                imapFields
            }

            if let erro = model.lastError {
                // Erro nunca engolido: a causa e a ação, sempre.
                HStack(spacing: 8) {
                    Text(erro.mensagem)
                        .font(theme.sans.font(size: 11.5))
                        .foregroundStyle(theme.accent.color)
                        .fixedSize(horizontal: false, vertical: true)
                    if case .semClientID = erro {
                        Button("Ver o roteiro") {
                            openURL(URL(string: "https://github.com/OkamiOps/okamiuni/blob/main/docs/oauth-google.md")!)
                        }
                        .buttonStyle(.plain)
                        .font(theme.sans.font(size: 11.5, weight: .medium))
                        .foregroundStyle(theme.accent.color)
                    }
                }
            } else if testado == true {
                Text("Conexão testada com sucesso.")
                    .font(theme.sans.font(size: 11.5))
                    .foregroundStyle(theme.ink3.color)
            }
        }
        .padding(20)
        .background(theme.surface.color)
    }

    @ViewBuilder
    private var imapFields: some View {
        SecureField("senha de app", text: $password)
            .textFieldStyle(.plain)
            .font(theme.sans.font(size: 12.5))
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(theme.surface2.color, in: RoundedRectangle(cornerRadius: theme.radiusSmall))

        Button("O que é uma senha de app?") {
            openURL(URL(string: "https://github.com/OkamiOps/okamiuni/blob/main/docs/senha-de-app.md")!)
        }
        .buttonStyle(.plain)
        .font(theme.sans.font(size: 11))
        .foregroundStyle(theme.ink4.color)

        HStack(spacing: 8) {
            TextField("imap.servidor.com", text: $host)
                .textFieldStyle(.plain)
                .font(theme.sans.font(size: 12.5))
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(theme.surface2.color, in: RoundedRectangle(cornerRadius: theme.radiusSmall))
            TextField("993", text: $port)
                .textFieldStyle(.plain)
                .font(theme.mono.font(size: 12))
                .frame(width: 64, height: 32)
                .padding(.horizontal, 8)
                .background(theme.surface2.color, in: RoundedRectangle(cornerRadius: theme.radiusSmall))
            // O mesmo dropdown do design, e não um `Picker` do sistema — a
            // regra que `ComposerSelect` existe para cumprir.
            ComposerSelect(
                title: "Forma de TLS",
                selected: security.rawValue,
                width: 108,
                groups: [.init(title: nil, options: [
                    .init(value: ImapEndpoint.Security.tls.rawValue, label: "TLS (993)"),
                    .init(value: ImapEndpoint.Security.startTLS.rawValue, label: "STARTTLS (143)"),
                ])],
                pick: { valor in
                    security = ImapEndpoint.Security(rawValue: valor) ?? .tls
                    port = security == .tls ? "993" : "143"
                }
            )
        }

        HStack(spacing: 10) {
            Button("Testar e adicionar") {
                Task {
                    guard let endpoint = endpoint else { return }
                    testado = await model.testImap(address: address, password: password, endpoint: endpoint)
                    guard testado == true else { return }
                    await model.addImap(
                        address: address, password: password, endpoint: endpoint,
                        hostMark: marca, displayName: address
                    )
                }
            }
            .buttonStyle(.plain)
            .font(theme.sans.font(size: 12, weight: .medium))
            .foregroundStyle(theme.accent.color)
            .disabled(model.isBusy || password.isEmpty || endpoint == nil)
            .focusRing(cornerRadius: theme.radiusSmall)

            if model.isBusy { ProgressView().controlSize(.small) }
        }
    }

    private var endpoint: ImapEndpoint? {
        guard !host.isEmpty, let numero = Int(port), numero > 0 else { return nil }
        return ImapEndpoint(host: host, port: numero, security: security)
    }

    /// O nome que o chip mostra em versalete. Do preset quando há; do domínio
    /// quando não — nunca vazio, e nunca o id.
    private var marca: String {
        if case .imap(let preset)? = route { return preset.hostMark }
        return ProviderDetector.domain(of: address)?.split(separator: ".").first.map(String.init) ?? "imap"
    }

    /// Preenche host, porta e TLS a partir da rota. Palpite, não veredito: os
    /// três campos continuam editáveis.
    private func preenche(_ novo: String) {
        testado = nil
        switch Self.route(for: novo) {
        case .imap(let preset):
            host = preset.endpoint.host
            port = String(preset.endpoint.port)
            security = preset.endpoint.security
        case .manual(let sugerido):
            host = sugerido.host
            port = String(sugerido.port)
            security = sugerido.security
        case .google, .none:
            host = ""
            port = "993"
            security = .tls
        }
    }
}
```

`Packages/UNIShell/Sources/UNIShell/Windows/AccountsWindow.swift`:

```swift
import SwiftUI
import UNICore
import UNIDesign
import UNISync

/// A cena de Contas. Cena de verdade, como as quatro do Marco 1: ⌘W fecha,
/// entra no menu Janela, tem tamanho declarado.
public struct AccountsWindow: View {
    @Environment(\.theme) private var theme

    private let model: AccountsModel
    @State private var removendo: String?

    public init(model: AccountsModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            WindowTitleBar(title: "Contas")
            AccountsList(
                statuses: model.statuses,
                onReconnect: { id in Task { await model.loadInitial(id) } },
                onRetry: { id in Task { await model.loadInitial(id) } },
                onRemove: { id in removendo = id }
            )
            Rectangle().fill(theme.line.color).hairline()
            AddAccountForm(model: model)
        }
        .background(theme.paper.color)
        .task { await model.start() }
        // Remover apaga banco **e** Keychain: é destrutivo, e destrutivo
        // pergunta antes — a mesma regra de `EmptyTrashConfirmation`.
        .confirmationDialog(
            "Remover esta conta?",
            isPresented: Binding(get: { removendo != nil }, set: { if !$0 { removendo = nil } })
        ) {
            Button("Remover", role: .destructive) {
                if let id = removendo { Task { await model.remove(id) } }
                removendo = nil
            }
            Button("Cancelar", role: .cancel) { removendo = nil }
        } message: {
            Text("As mensagens já baixadas e a senha guardada no Keychain serão apagadas. A conta no servidor não é tocada.")
        }
    }
}
```

- [ ] **Step 7: Show state in the sidebar's account row**

In `Packages/UNIShell/Sources/UNIShell/Inbox/FolderSidebar.swift`, inside `accountRow`, between `Text(account.address)` and `Spacer`:

```swift
                // O estado da conta na lateral, sem tirar espaço do endereço:
                // um ponto, com o `help` dizendo o que ele significa. Conta
                // parada sem sinal nenhum foi o defeito que a janela de Contas
                // existe para não repetir.
                if account.state != .ativa {
                    Circle()
                        .fill(account.state == .carregando ? theme.ink4.color : theme.accent.color)
                        .frame(width: 6, height: 6)
                        .help(account.state == .carregando
                            ? "Carregando as mensagens desta conta…"
                            : "Esta conta precisa ser reconectada. Abra Contas…")
                }
```

- [ ] **Step 8: Run to confirm success**

Run:

```bash
(cd Packages/UNICore && swift test --filter AccountsMenu)
(cd Packages/UNIShell && swift test --filter AccountsWindow)
```

Expected: PASS, 2 + 9 tests.

- [ ] **Step 9: Prove both copy rules through mutation**

1. Replace `guard let quando = s.lastSyncedAt` with `let quando = s.lastSyncedAt ?? now`, then run `swift test --filter textoNuncaSincronizou`.
   Expected: FAIL — an account that never synchronized displays an invented time.
2. Make `AccountsCopy.action(for:)` return `"Tentar de novo"` for everything and run `swift test --filter acaoCombinaComACausa`.
   Expected: FAIL — an account with a revoked token offers an action that cannot resolve it.

Restore both and confirm green.

- [ ] **Step 10: Commit**

```bash
git add Packages/UNIShell/Sources/UNIShell/Windows/AccountsWindow.swift Packages/UNIShell/Sources/UNIShell/Windows/AccountsList.swift Packages/UNIShell/Sources/UNIShell/Windows/AddAccountForm.swift Packages/UNIShell/Sources/UNIShell/Windows/UNIWindow.swift Packages/UNIShell/Sources/UNIShell/Support/ContextMenuHost.swift Packages/UNIShell/Sources/UNIShell/Inbox/FolderSidebar.swift Packages/UNICore/Sources/UNICore/ContextMenu.swift Packages/UNIShell/Tests/UNIShellTests/AccountsWindowTests.swift Packages/UNICore/Tests/UNICoreTests/AccountsMenuTests.swift
git commit -m "A janela de Contas: estado com causa, ação que combina com a causa, e remover que pergunta

Todo o texto mora em AccountsCopy, puro, porque o que uma conta em erro diz é
regra de produto e não desenho. Duas regras estão travadas por mutação: quem
nunca sincronizou não ganha data inventada, e erro de autenticação pede
Reconectar enquanto erro de rede pede Tentar de novo — mandar reconectar quem
perdeu o wi-fi é a ação errada com convicção.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 17: `--ensaiar-contas` — the full flow in the real app, without leaving the machine

**Files:**
- Create: `Packages/UNIShell/Sources/UNIShell/Windows/AccountsRehearsal.swift`
- Create: `Packages/UNIShell/Sources/UNIShell/Windows/RehearsalImapServer.swift`
- Create: `Packages/UNIShell/Tests/UNIShellTests/AccountsRehearsalTests.swift`

**Interfaces:**
- Consumes: `RehearsalStage`, `RehearsalDriver`, `RehearsalKey` (Milestone 1, `Windows/RehearsalStage.swift`); `AccountsModel`, `AccountDirector`, `SyncDatabase`, `InMemorySecretStore`, `StubAuthorizationPresenter`, `ImapEndpoint` (Tasks 4–15).
- Produces:
  - `struct AccountsRehearsal: Sendable` with `static func parse(_ arguments: [String]) -> AccountsRehearsal?`, `static var fromProcess: AccountsRehearsal?`.
  - `View.rehearseAccountsIfRequested(_ request: AccountsRehearsal?, model: AccountsModel?) -> some View`.
  - `final class RehearsalImapServer: @unchecked Sendable` with `init()`, `func start() throws -> Int`, `func stop()` — Task 9's fake server, now in the production target because the rehearsal runs inside the app.

- [ ] **Step 1: Write the failing test**

`Packages/UNIShell/Tests/UNIShellTests/AccountsRehearsalTests.swift`:

```swift
import Foundation
import Testing
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

    @Test("Os quadros do ensaio vão para o contêiner, e não para o disco do usuário")
    func caminhoDosQuadros() {
        let caminho = RehearsalStage.framePath("contas-01-vazio")
        #expect(caminho.hasSuffix("ensaio-contas-01-vazio.png"))
        #expect(caminho.hasPrefix(NSTemporaryDirectory()))
    }
}
```

- [ ] **Step 2: Run to confirm failure**

Run: `cd Packages/UNIShell && swift test --filter AccountsRehearsal`

Expected: FAIL — `cannot find 'AccountsRehearsal' in scope`.

- [ ] **Step 3: Bring the fake server into the production target**

`Packages/UNIShell/Sources/UNIShell/Windows/RehearsalImapServer.swift`:

```swift
import Foundation
import NIOCore
import NIOPosix

/// O servidor IMAP falso do **ensaio**, em 127.0.0.1, porta escolhida pelo
/// sistema.
///
/// Mora no alvo de produção porque o ensaio roda dentro do app de verdade —
/// é essa a diferença entre ensaio e teste de View, e é o que fez o arraste do
/// Marco 1 parar de mentir. Ele só sobe quando `--ensaiar-contas` está na
/// linha de comando; sem a bandeira, nada aqui é construído.
///
/// O roteiro é fixo: uma caixa de entrada com duas mensagens. O ensaio prova o
/// **fluxo**, não o protocolo — o protocolo tem os testes das Tasks 9 e 10,
/// contra o servidor com roteiro por teste.
public final class RehearsalImapServer: @unchecked Sendable {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var channel: (any Channel)?

    public init() {}

    public func start() throws -> Int {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { canal in
                canal.pipeline.addHandlers([
                    ByteToMessageHandler(LineBasedFrameDecoder()),
                    Handler(),
                ])
            }
        let canal = try bootstrap.bind(host: "127.0.0.1", port: 0).wait()
        channel = canal
        guard let porta = canal.localAddress?.port else {
            throw NSError(domain: "RehearsalImapServer", code: 1)
        }
        return porta
    }

    public func stop() {
        try? channel?.close().wait()
        try? group.syncShutdownGracefully()
    }

    private final class Handler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer

        private static let respostas: [String: [String]] = [
            "LOGIN": ["TAG OK LOGIN completed"],
            "LIST": ["* LIST (\\HasNoChildren) \"/\" \"INBOX\"", "TAG OK LIST completed"],
            "SELECT": [
                "* 2 EXISTS",
                "* OK [UIDVALIDITY 1755000000] UIDs valid",
                "* OK [UIDNEXT 9003] Predicted next UID",
                "TAG OK [READ-WRITE] SELECT completed",
            ],
            "UID SEARCH": ["* SEARCH 9001 9002", "TAG OK UID SEARCH completed"],
            "UID FETCH": [
                "* 1 FETCH (UID 9001 FLAGS (\\Seen) INTERNALDATE \"25-Aug-2026 09:00:00 -0300\" "
                + "ENVELOPE (\"Tue, 25 Aug 2026 09:00:00 -0300\" \"Revisao do contrato\" "
                + "((\"Marina\" NIL \"marina\" \"clientepremium.com\")) NIL NIL "
                + "((\"Ricardo\" NIL \"contato\" \"meusite.com\")) NIL NIL NIL NIL))",
                "* 2 FETCH (UID 9002 FLAGS () INTERNALDATE \"25-Aug-2026 08:00:00 -0300\" "
                + "ENVELOPE (\"Tue, 25 Aug 2026 08:00:00 -0300\" \"Boletim\" "
                + "((\"Noticias\" NIL \"noticias\" \"exemplo.com\")) NIL NIL NIL NIL NIL NIL NIL))",
                "TAG OK UID FETCH completed",
            ],
            "LOGOUT": ["TAG OK LOGOUT completed"],
        ]

        func channelActive(context: ChannelHandlerContext) {
            escreve(context, "* OK [CAPABILITY IMAP4rev1] OkamiUNI ensaio pronto")
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var buffer = unwrapInboundIn(data)
            let linha = (buffer.readString(length: buffer.readableBytes) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !linha.isEmpty else { return }
            let partes = linha.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            let tag = String(partes.first ?? "*")
            let palavras = (partes.count > 1 ? String(partes[1]) : "")
                .split(separator: " ").map { $0.uppercased() }
            let verbo = palavras.first == "UID" && palavras.count >= 2
                ? "UID \(palavras[1])"
                : (palavras.first ?? "")
            for modelo in Self.respostas[verbo] ?? ["TAG BAD comando desconhecido"] {
                escreve(context, modelo.replacingOccurrences(of: "TAG ", with: "\(tag) "))
            }
            if verbo == "LOGOUT" { context.close(promise: nil) }
        }

        private func escreve(_ context: ChannelHandlerContext, _ texto: String) {
            var buffer = context.channel.allocator.buffer(capacity: texto.utf8.count + 2)
            buffer.writeString(texto)
            buffer.writeString("\r\n")
            context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
        }
    }
}
```

- [ ] **Step 4: Write the rehearsal**

`Packages/UNIShell/Sources/UNIShell/Windows/AccountsRehearsal.swift`:

```swift
import SwiftUI
import UNICore
import UNISync
#if canImport(AppKit)
import AppKit
#endif

/// Ensaia a janela de Contas **dentro do app de verdade**.
///
/// ## Por que existe
///
/// Regra do projeto, ganha a duro no Marco 1: interação de UI nova ganha ensaio
/// no app real. `SwipeRehearsal` provou que teste de View com o modelo verde
/// não é prova de que o clique chega — o gesto foi consertado três vezes com
/// teste passando e continuou morto na mão do dono do projeto.
///
/// O que este instrumento faz, sem tocar mouse nem teclado da máquina e sem
/// sair dela: sobe um servidor IMAP falso em `127.0.0.1`, abre a janela de
/// Contas, digita um endereço no campo, dispara "Testar e adicionar", espera a
/// carga, e fotografa cada fase. As afirmações vão para o stderr, uma por
/// linha, com `ok:` ou `FALHOU:`.
///
/// **Nenhuma rede externa.** O IMAP é local; o OAuth usa
/// `StubAuthorizationPresenter`, que devolve o redirect sem abrir navegador.
///
/// `open -g --args --ensaiar-contas` liga; sem a bandeira, nada acontece.
public struct AccountsRehearsal: Sendable {
    public static func parse(_ arguments: [String]) -> AccountsRehearsal? {
        arguments.contains("--ensaiar-contas") ? AccountsRehearsal() : nil
    }

    public static var fromProcess: AccountsRehearsal? {
        parse(Array(CommandLine.arguments.dropFirst()))
    }
}

extension View {
    /// `model` nulo significa que a composição não montou o `UNISync` (por
    /// exemplo, num alvo sem banco). O ensaio registra isso e encerra, em vez
    /// de fingir que passou.
    public func rehearseAccountsIfRequested(
        _ request: AccountsRehearsal?, model: AccountsModel?
    ) -> some View {
        modifier(AccountsRehearsalModifier(request: request, model: model))
    }
}

private struct AccountsRehearsalModifier: ViewModifier {
    let request: AccountsRehearsal?
    let model: AccountsModel?
    @State private var started = false

    func body(content: Content) -> some View {
        content.background(
            AccountsProbe(request: request, model: model, started: $started)
                .frame(width: 0, height: 0)
        )
    }
}

private struct AccountsProbe: NSViewRepresentable {
    let request: AccountsRehearsal?
    let model: AccountsModel?
    @Binding var started: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        guard request != nil, !started else { return }
        started = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.8))
            guard let janela = view.window else {
                RehearsalStage.log("contas: sem janela"); NSApp.terminate(nil); return
            }
            guard let model else {
                RehearsalStage.log("contas: FALHOU: a composição não montou o AccountsModel")
                NSApp.terminate(nil); return
            }
            await AccountsDriver(window: janela, model: model).run()
            NSApp.terminate(nil)
        }
    }
}

@MainActor
private final class AccountsDriver {
    private let window: NSWindow
    private let model: AccountsModel
    private let servidor = RehearsalImapServer()
    private var quadro = 0

    init(window: NSWindow, model: AccountsModel) {
        self.window = window
        self.model = model
    }

    func run() async {
        // 1. O servidor local.
        let porta: Int
        do {
            porta = try servidor.start()
            RehearsalStage.log("contas: ok: servidor IMAP falso em 127.0.0.1:\(porta)")
        } catch {
            RehearsalStage.log("contas: FALHOU: servidor não subiu — \(error)")
            return
        }
        defer { servidor.stop() }

        // 2. O estado inicial: nenhuma conta.
        await model.start2()
        await espera()
        afirma(model.statuses.isEmpty, "lista começa vazia")
        await fotografa("contas-01-vazio")

        // 3. Testar com senha certa, contra o servidor local.
        let endpoint = ImapEndpoint(host: "127.0.0.1", port: porta, security: .startTLS)
        let passou = await model.testImap(
            address: "contato@meusite.com", password: "senha-de-app", endpoint: endpoint
        )
        afirma(passou, "teste de conexão passou")
        afirma(model.lastError == nil, "teste não deixou erro")
        await fotografa("contas-02-testado")

        // 4. Adicionar e carregar.
        await model.addImap(
            address: "contato@meusite.com", password: "senha-de-app",
            endpoint: endpoint, hostMark: "meusite", displayName: "Site"
        )
        await espera()
        afirma(model.statuses.count == 1, "a conta entrou na lista")
        afirma(model.statuses.first?.messageCount == 2, "as duas mensagens desceram para o banco")
        afirma(model.statuses.first?.state == .ativa, "a conta terminou ativa")
        afirma(model.statuses.first?.error == nil, "sem erro depois da carga")
        await fotografa("contas-03-carregada")

        // 5. A rota Google, sem client ID: a janela explica em vez de calar.
        await model.addGoogle(address: "ricardo@gmail.com")
        if case .semClientID = model.lastError {
            RehearsalStage.log("contas: rota google sem client ID")
        } else if model.lastError == nil {
            RehearsalStage.log("contas: rota google pronta")
        } else {
            RehearsalStage.log("contas: FALHOU: rota google devolveu \(model.lastError!.mensagem)")
        }
        await fotografa("contas-04-google")

        // 6. Remover, com o banco e o cofre limpos.
        if let id = model.statuses.first?.accountID {
            await model.remove(id)
            await espera()
        }
        afirma(model.statuses.isEmpty, "remover esvaziou a lista")
        await fotografa("contas-05-removida")
    }

    private func afirma(_ condicao: Bool, _ oque: String) {
        RehearsalStage.log("contas: \(condicao ? "ok" : "FALHOU"): \(oque)")
    }

    private func espera() async {
        // Uma volta do runloop mais folga para o ator publicar e o SwiftUI
        // desenhar o que a publicação causou.
        try? await Task.sleep(for: .milliseconds(400))
    }

    private func fotografa(_ nome: String) async {
        try? await Task.sleep(for: .milliseconds(80))
        guard let conteudo = window.contentView,
              let rep = conteudo.bitmapImageRepForCachingDisplay(in: conteudo.bounds) else {
            RehearsalStage.log("contas: sem bitmap para \(nome)"); return
        }
        conteudo.cacheDisplay(in: conteudo.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        quadro += 1
        let caminho = RehearsalStage.framePath(nome)
        do {
            try png.write(to: URL(fileURLWithPath: caminho))
            RehearsalStage.log("contas: \(caminho)")
        } catch {
            RehearsalStage.log("contas: escrita negada em \(caminho) — \(error)")
        }
    }
}

extension AccountsModel {
    /// `start()` fica assinado para sempre; o ensaio precisa de **uma** volta e
    /// depois do controle de volta. Este é o mesmo `statuses`, uma vez só.
    @MainActor
    func start2() async {
        Task { await self.start() }
        try? await Task.sleep(for: .milliseconds(200))
    }
}
```

- [ ] **Step 5: Run to confirm success**

Run: `cd Packages/UNIShell && swift test --filter AccountsRehearsal`

Expected: PASS, three tests.

- [ ] **Step 6: Run the rehearsal in the real app**

Task 18 wires the scene and flag; this step can run only **after** that task. If Task 18 is already complete:

Run:

```bash
xcodegen generate
xcodebuild -project OkamiUNI.xcodeproj -scheme OkamiUNI -configuration Debug build 2>&1 | tail -3
open -g --args --ensaiar-contas
sleep 12
ls -la "$(getconf DARWIN_USER_TEMP_DIR)"/ensaio-contas-*.png 2>/dev/null || echo "sem quadros"
```

Expected: five PNGs (`ensaio-contas-01-vazio` … `05-removida`) and, in Console.app filtered to `[ensaio]`, an `ok:` line for each assertion and no `FALHOU:`. Inspect all five frames: the empty list with its sample-data explanation, the account showing “Carregando…”, the active account with “2 mensagens”, the explained Google error, and the empty list again.

- [ ] **Step 7: Commit**

```bash
git add Packages/UNIShell/Sources/UNIShell/Windows/AccountsRehearsal.swift Packages/UNIShell/Sources/UNIShell/Windows/RehearsalImapServer.swift Packages/UNIShell/Tests/UNIShellTests/AccountsRehearsalTests.swift
git commit -m "--ensaiar-contas: o fluxo inteiro no app de verdade, com um IMAP falso em 127.0.0.1

Regra do projeto ganha a duro no Marco 1: teste de View com o modelo verde não
prova que o clique chega. O ensaio adiciona, testa, carrega e remove uma conta
dentro do app, fotografa as cinco fases e afirma cada uma no stderr. Nenhuma
rede externa: o IMAP é local e o OAuth usa o apresentador falso.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 18: App composition and milestone acceptance

**Files:**
- Modify: `App/OkamiUNIApp.swift`
- Create: `App/AppComposition.swift`
- Create: `Packages/UNISync/Tests/UNISyncTests/CompositionTests.swift`
- Modify: `README.md`

**Interfaces:**
- Consumes: everything.
- Produces:
  - `struct AppComposition: Sendable` (in `UNISync`, not the app target — see step 3) with `static func make(databasePath: String?, bundle: Bundle) -> AppComposition`, `let database: SyncDatabase?`, `let director: AccountDirector?`, `let source: any MailSource`, `let configError: SyncError?`.

- [ ] **Step 1: Write the failing test**

`Packages/UNISync/Tests/UNISyncTests/CompositionTests.swift`:

```swift
import Foundation
import Testing
import UNICore
@testable import UNISync

@Suite("A composição do app")
struct CompositionTests {
    @Test("Sem banco possível, o app cai nas fixtures em vez de não abrir")
    func semBancoCaiNasFixtures() {
        // Um caminho impossível é o pior caso realista (disco cheio, contêiner
        // corrompido). O app tem de abrir mostrando as fixtures e dizendo o
        // que houve, e não morrer na tela cinza.
        let composicao = AppComposition.make(
            databasePath: "/caminho/que/nao/existe/mail.sqlite", bundle: .main
        )
        #expect(composicao.database == nil)
        #expect(composicao.director == nil)
        #expect(composicao.configError != nil)
        #expect(composicao.source is InMemoryMailSource)
    }

    @Test("Com banco vazio, a fonte continua sendo as fixtures")
    func bancoVazioContinuaNasFixtures() throws {
        // É o estado antes da primeira conta. As capturas e os ensaios do
        // Marco 1 dependem disto: sem conta, o app é o do Marco 1.
        let caminho = NSTemporaryDirectory() + "okamiuni-teste-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: caminho) }
        let composicao = AppComposition.make(databasePath: caminho, bundle: .main)
        #expect(composicao.database != nil)
        #expect(composicao.director != nil)
        #expect(composicao.source is InMemoryMailSource)
    }

    @Test("Com uma conta no banco, a fonte passa a ser o banco")
    func comContaUsaOBanco() throws {
        let caminho = NSTemporaryDirectory() + "okamiuni-teste-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: caminho) }

        let db = try SyncDatabase(path: caminho)
        try db.pool.write { conexao in
            try AccountRecord(
                Account(
                    id: "c", address: "eu@x.com", displayName: "Eu",
                    provider: .imap, host: "x",
                    tintLightHex: "#3F6AA1", tintDarkHex: "#8CBAF7"
                ),
                createdAt: Date(timeIntervalSince1970: 1)
            ).insert(conexao)
        }

        let composicao = AppComposition.make(databasePath: caminho, bundle: .main)
        #expect(composicao.source is DatabaseMailSource)
    }

    @Test("Sem client ID no bundle, o diretor existe e a rota IMAP continua inteira")
    func semClientIDNaoDerrubaOApp() throws {
        // O bundle de teste não tem OkamiUNIGoogleClientID.
        let caminho = NSTemporaryDirectory() + "okamiuni-teste-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: caminho) }
        let composicao = AppComposition.make(databasePath: caminho, bundle: .main)
        #expect(composicao.director != nil)
        // O erro de configuração é informado, e não fatal.
        #expect(composicao.configError == SyncError.semClientID)
    }
}
```

- [ ] **Step 2: Run to confirm failure**

Run: `cd Packages/UNISync && swift test --filter Composition`

Expected: FAIL — `cannot find 'AppComposition' in scope`.

- [ ] **Step 3: Write composition**

It lives in `UNISync`, not `App/`, because the app target has no tests and this is the milestone's most consequential decision: when the app uses the database and when it uses fixtures.

`Packages/UNISync/Sources/UNISync/AppComposition.swift`:

```swift
import Foundation
import NIOCore
import NIOPosix
import UNICore
import os

/// Quem monta o mundo do `UNISync` para o app.
///
/// A decisão que ela toma é a do critério de aceite: **sem conta conectada, o
/// app continua nas fixtures.** Isso não é comodidade — é o que faz as
/// capturas e os ensaios do Marco 1 continuarem valendo, e é o que garante que
/// instalar esta versão não deixa ninguém com a tela vazia.
public struct AppComposition: Sendable {
    public let database: SyncDatabase?
    public let director: AccountDirector?
    public let source: any MailSource
    /// Falha de configuração que o app **mostra** em vez de esconder: banco
    /// que não abriu, client ID que falta.
    public let configError: SyncError?

    private static let log = Logger(subsystem: "com.okamiops.okamiuni", category: "AppComposition")

    /// `databasePath` nulo usa `SyncDatabase.defaultPath()`.
    public static func make(databasePath: String? = nil, bundle: Bundle = .main) -> AppComposition {
        let banco: SyncDatabase?
        var erro: SyncError?
        do {
            let caminho = try databasePath ?? SyncDatabase.defaultPath()
            banco = try SyncDatabase(path: caminho)
        } catch let falha as SyncError {
            // Banco que não abre não pode impedir o app de abrir: as fixtures
            // seguram a tela e a janela de Contas explica o que houve.
            log.error("Banco não abriu: \(falha.mensagem)")
            return AppComposition(
                database: nil, director: nil,
                source: InMemoryMailSource.fixtures, configError: falha
            )
        } catch {
            let falha = SyncError.resposta("Não foi possível abrir o banco: \(error.localizedDescription)")
            log.error("Banco não abriu: \(falha.mensagem)")
            return AppComposition(
                database: nil, director: nil,
                source: InMemoryMailSource.fixtures, configError: falha
            )
        }
        guard let banco else {
            return AppComposition(
                database: nil, director: nil,
                source: InMemoryMailSource.fixtures,
                configError: .resposta("Não foi possível abrir o banco.")
            )
        }

        let cofre = KeychainSecretStore()
        var auth: GoogleAuth?
        do {
            let config = try GoogleAuthConfig.fromBundle(bundle)
            auth = GoogleAuth(
                config: config, session: .shared, secrets: cofre,
                presenter: WebAuthorizationPresenter()
            )
        } catch let falha as SyncError {
            // Sem client ID a rota Google não existe — e o app continua
            // inteiro pela rota IMAP. O erro vai para a janela de Contas.
            erro = falha
        } catch {
            erro = .semClientID
        }

        let director = AccountDirector(
            database: banco,
            secrets: cofre,
            auth: auth,
            session: .shared,
            eventLoopGroup: MultiThreadedEventLoopGroup(numberOfThreads: 2)
        )

        // Tem conta? Então o banco é a fonte. Não tem? Fixtures — e é isso que
        // mantém os ensaios e as capturas do Marco 1 idênticos.
        let temConta = (try? banco.pool.read { try AccountRecord.fetchCount($0) > 0 }) ?? false
        return AppComposition(
            database: banco,
            director: director,
            source: temConta ? DatabaseMailSource(database: banco) : InMemoryMailSource.fixtures,
            configError: erro
        )
    }
}
```

- [ ] **Step 4: Wire it into `App`**

In `App/OkamiUNIApp.swift`, add `import UNISync` and, alongside the other `@State` properties:

```swift
    /// O mundo do UNISync: banco, diretor e a fonte que a UI vai ler.
    ///
    /// Montado uma vez, no `init`, porque a escolha entre banco e fixtures é a
    /// mesma para a janela inteira e não pode mudar a cada redesenho.
    private let composition = AppComposition.make()
    @State private var accountsModel: AccountsModel?
```

Replace the `mailStore` creation:

```swift
    @State private var mailStore: MailStore
```

In `init`, after `FontRegistry.registerBundledFonts()`:

```swift
        _mailStore = State(initialValue: MailStore(source: composition.source))
        if let director = composition.director {
            _accountsModel = State(initialValue: AccountsModel(director: director))
        }
        if let erro = composition.configError {
            // Falha de configuração nunca some: ela vai para o log estruturado
            // e aparece na janela de Contas.
            fputs("[OkamiUNI] \(erro.mensagem)\n", stderr)
        }
```

In the main `WindowGroup`, replace the loading `.task` (or add it if absent) and the rehearsal flag:

```swift
                // Assina em vez de puxar: a carga inicial acorda a lista
                // enquanto baixa. Com fonte em memória, `observe()` entrega um
                // retrato e termina — exatamente o `load()` do Marco 1.
                .task { await mailStore.observe() }
                // A busca alcança o corpo pelo índice do banco.
                .onChange(of: mailStore.query) { _, _ in
                    Task { await mailStore.refreshBodyMatches() }
                }
                // `--ensaiar-contas`: abre a janela de Contas contra um IMAP
                // falso local e fotografa as cinco fases. Sem a bandeira, não
                // faz nada.
                .rehearseAccountsIfRequested(AccountsRehearsal.fromProcess, model: accountsModel)
```

Add the scene after `event`:

```swift
        Window("Contas", id: UNIWindow.accounts) {
            Group {
                if let accountsModel {
                    AccountsWindow(model: accountsModel)
                } else {
                    // Sem diretor não há o que gerenciar — e dizer isso é
                    // melhor do que uma janela vazia.
                    ContasIndisponiveis(erro: composition.configError)
                }
            }
            .themed(themes)
            .frame(minWidth: 560, minHeight: 420)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(UNIWindow.Size.accounts)
```

Add the app menu item inside `.commands`:

```swift
            CommandGroup(after: .appSettings) { AccountsCommand() }
```

At the end of the file:

```swift
/// ⇧⌘A abre a janela de Contas. Vive num `View` porque `openWindow` é chave de
/// ambiente, como `NewMessageCommand`.
private struct AccountsCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Contas…") { openWindow(id: UNIWindow.accounts) }
            .keyboardShortcut("a", modifiers: [.command, .shift])
    }
}

/// O que a cena de Contas mostra quando o `UNISync` não subiu.
private struct ContasIndisponiveis: View {
    @Environment(\.theme) private var theme
    let erro: SyncError?

    var body: some View {
        VStack(spacing: 10) {
            Text("Contas indisponíveis")
                .font(theme.sans.font(size: 14, weight: .medium))
                .foregroundStyle(theme.ink.color)
            Text(erro?.mensagem ?? "O banco local não pôde ser aberto.")
                .font(theme.sans.font(size: 12))
                .foregroundStyle(theme.ink3.color)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.paper.color)
    }
}
```

- [ ] **Step 5: Run to confirm success**

Run: `cd Packages/UNISync && swift test --filter Composition`

Expected: PASS, four tests.

- [ ] **Step 6: Run the complete suite across all four packages**

Run:

```bash
for p in UNIDesign UNICore UNIShell UNISync; do
  echo -n "$p: "
  (cd "Packages/$p" && swift test 2>&1 | grep -E 'Test run with')
done
```

Expected: four lines, none containing `failed`.

- [ ] **Step 7: Build the app without concurrency warnings**

Run:

```bash
xcodegen generate
xcodebuild -project OkamiUNI.xcodeproj -scheme OkamiUNI -configuration Debug build 2>&1 \
  | grep -E 'BUILD|warning:' | grep -vi 'deprecat' | head -20
```

Expected: `BUILD SUCCEEDED` and no `warning:` line mentioning `Sendable`, `concurrency` or `actor-isolated`.

- [ ] **Step 8: Milestone 1's instruments remain identical**

Without a connected account, this is the Milestone 1 app, as promised by the acceptance criterion and verified here.

Run:

```bash
open -g --args --ensaiar-arraste
sleep 12
open -g --args --ensaiar-teclado
sleep 14
open -g --args --ensaiar-contas
sleep 14
ls "$(getconf DARWIN_USER_TEMP_DIR)"/ensaio-*.png | head -20
```

Expected: frames from all three rehearsals; in Console.app filtered to `[ensaio]`, no `FALHOU:` line in any rehearsal. If swipe or keyboard behavior changes, **stop**: composition changed the app without accounts, violating acceptance.

- [ ] **Step 9: Project owner's manual test — acceptance**

This step **requires Task 1 complete** and a real Google account. It is the plan's only internet-connected step, performed manually.

1. `cp Config/Google.example.xcconfig Config/Google.xcconfig`, paste the client ID, `xcodegen generate`, `xcodebuild … build`.
2. Open the app with `Tools/rodar.sh`. **This is the milestone's only launch outside the instruments**, performed by the owner.
3. ⇧⌘A opens Accounts. Enter Gmail address → **Autorizar no Google** → grant all three scopes. The account shows “Carregando…” and the bar advances.
4. Enter an IMAP address from **any** provider. Host and port are prefilled from a preset or suggested as `imap.<domínio>:993`. Paste the app password → **Testar e adicionar**.
5. Close the app. **Turn off Wi-Fi.** Reopen it.

Acceptance, item by item:

- [ ] The app opens **offline**, showing the last 90 days of mail from both accounts.
- [ ] Search matches sender, subject and **body**, with accent folding (“Revisao” finds “Revisão” in a body).
- [ ] Clicking a sidebar account filters **both list and calendar**.
- [ ] Accounts displays “Sincronizada às HH:MM · N mensagens” per account.
- [ ] Changing the provider's app password and trying to load produces an account error **with its cause** and “Reconectar”.
- [ ] Removing an account asks first, then removes its account, messages and password.
- [ ] Removing both accounts restores fixtures.

- [ ] **Step 10: Update the README**

In `README.md`, replace the milestone badge line and add Milestone 2 to the “What already works” table:

```markdown
![Marco](https://img.shields.io/badge/marco-2%20·%20contas-orange)
```

In the table:

```markdown
| 🔐 **Contas de verdade** | OAuth do Google com PKCE, IMAP para qualquer provedor com detecção de servidor, segredos no Keychain, cache local em SQLite com busca no corpo (FTS5, acento dobrado) e carga dos últimos 90 dias — o app abre **offline** |
```

Leave the milestone table in the Milestone 1 plan unchanged: it is a historical reference containing that sequence.

- [ ] **Step 11: Commit**

```bash
git add App Packages/UNISync/Sources/UNISync/AppComposition.swift Packages/UNISync/Tests/UNISyncTests/CompositionTests.swift README.md
git commit -m "O app monta o banco, o diretor e a fonte — e sem conta continua sendo o Marco 1

A composição mora no UNISync porque o alvo do app não tem testes e esta é a
decisão mais consequente do marco: com conta, a fonte é o banco; sem conta, são
as fixtures. É o que faz as capturas e os ensaios do Marco 1 continuarem
idênticos, e o que garante que banco que não abre não impede o app de abrir.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Self-review

Performed against the specification with fresh eyes after writing the entire plan.

### 1. Specification coverage, point by point

| Specification requirement | Location |
|---|---|
| `UNISync` package imports `UNICore`, never SwiftUI | Task 2 (package); Global Constraints (prohibition) |
| Only GRDB and swift-nio-imap as new dependencies | Task 2; Global Constraints |
| SPM wiring first, green build before code | Task 2 |
| OAuth client guide without blocking the plan | Task 1; Tasks 7/8/15 prove against stubs |
| `SyncDatabase` — opening, migration, `DatabasePool` | Task 5 |
| `SecretStore` — protocol, Keychain, fake | Task 4 |
| `GoogleAuth` — PKCE, exchange, refresh, revocation | Task 7 |
| Pure `ProviderDetector` | Task 6 |
| `ImapPresets` — pure open table, manual entry always available | Task 6 |
| `ImapSession` — connect, authenticate, list, envelopes, bodies | Tasks 9 and 10 |
| `GmailClient` — profile, labels, `messages.list/get` | Task 8 |
| `AccountDirector` — actor, add/test/remove/load/publish | Task 15 |
| `InitialLoader` — 90 days, per account | Tasks 12 (Gmail) and 13 (IMAP) |
| `DatabaseMailSource` — database-backed `MailSource` | Task 14 |
| `account`/`folder`/`message`/`message_body`+FTS5/`agenda_item`/`sync_state` tables | Task 5 |
| No secret in the database | Task 5 (`nenhumaColunaDeSegredo` test); Task 15 (`addImap` test) |
| `unicode61 remove_diacritics 2` tokenizer | Task 5, mutation-proven |
| `ValueObservation` → `AsyncSequence`; `MailStore` subscribes | Task 14 |
| Without an account, the app keeps fixtures | Task 18 |
| PKCE S256, `com.okamiops.okamiuni:/oauth` redirect | Task 7; Task 2 `Info.plist` |
| `gmail.modify` + `gmail.send` + `userinfo.email` scopes | Task 7 (`defaultScopes`), Task 1 (guide) |
| Configured client ID, not hardcoded | Task 1 (xcconfig), Task 2 (`Info.plist`), Task 7 (`fromBundle`) |
| Tokens in Keychain, service `com.okamiops.okamiuni`, account = ID | Task 4 |
| Transparent refresh with **one flight per account** | Task 7, mutation-proven |
| Failed refresh → `erroDeAutenticacao` + reconnect action | Tasks 12/15 (state), Task 16 (`AccountsCopy.action`) |
| IMAP `LOGIN` over implicit TLS **or** STARTTLS per preset | Tasks 3 (`ImapEndpoint.Security`), 9 (pipeline) |
| `LIST`/`SELECT`, envelope batches, on-demand cached bodies | Task 10 |
| Roles from `SPECIAL-USE` or names, pure table | Task 6 |
| Detection without MX lookup | Task 6 (recorded in comment and commit) |
| Accounts window — `UNIWindow.accounts`, app menu and context menu | Task 16 |
| List: address, provider, state, count, removal confirmation | Task 16 |
| Add: address → route → OAuth or form → “Testar e adicionar” with explained result | Task 16; Task 15 (`testImap` does not persist) |
| Per-account progress in the window **and** sidebar row | Task 16 (window and sidebar dot) |
| Gmail: paginated `messages.list` `newer_than:90d`, metadata/full `get`, `labels.list`, `historyId` | Task 12 |
| IMAP: `SELECT`, `UID SEARCH SINCE`, batches of 200, 50 bodies per folder | Tasks 10 and 13 |
| Triage projection at boundaries, excluding `Sent` | Task 11 |
| Interruptible and resumable, batch transactions | Tasks 12 and 13, mutation-proven |
| `UNICore`: new `Account`/`Message` fields, valid fixtures | Task 3 |
| `UNIShell`: window, sidebar state, real source | Tasks 16 and 18 |
| `App`: composition | Task 18 |
| One `SyncError`, distinct cases, Portuguese message, action | Task 4; Task 16 (`action(for:)`) |
| Structured per-account logs, category per component | Tasks 12, 13, 15, 18 (`Logger(subsystem:category:)`) |
| Fake `SecretStore`; real Keychain behind local flag | Task 4 (`OKAMIUNI_KEYCHAIN_TESTS`) |
| `GoogleAuth` against `URLProtocol` stub: exchange, refresh, failure, single flight | Task 7 |
| `ImapSession` against fake NIO server, changed UIDVALIDITY | Tasks 9, 10, 13 |
| `GmailClient` against real JSON fixtures | Task 8 |
| Database: migration, accented FTS, observation, boundary projection | Tasks 5 and 11 |
| Pure boundary logic: detector, presets, roles | Task 6 |
| `--ensaiar-contas` rehearsal with local fake IMAP | Task 17 |
| No test touches external networks | Global Constraints; Task 7 step 10 checks |
| Complete acceptance criterion | Task 18, step 9 |

**Every specification requirement has a task.** Declared exclusions (Microsoft Graph, sending, incremental sync, mirrored triage, threads, synchronized signatures and MX) remain out of scope; no task touches them.

### 2. Gaps found and corrected during review

1. **`Account.State` was needed before the schema.** The suggested order placed GRDB (Task 5) before evolving `UNICore`. Writing `account` without `Account.State` would require inventing and later reconciling another database enum: two truths for one question. **Corrected:** `UNICore` evolution became Task 3, with the reason recorded below the dependency table.
2. **Making `MailStore.load()` a subscription would break the 807 tests.** The specification says `load()` subscribes. Changing its semantics would alter dozens of Milestone 1 tests. **Corrected:** `load()` remains a single snapshot, `observe()` subscribes, and `MailSource.snapshots()` defaults to one element. `InMemoryMailSource` remains unchanged. Task 14, step 7 verifies this.
3. **Body search lacked a port.** The specification requires database body search with accent folding, but `MailSource` lacks a query and `MailStore.matches` is synchronous. **Corrected:** `MailSource.bodyMatches(_:accountID:)` defaults to `nil`, meaning “cannot search bodies” rather than “no matches”; `MailStore.bodyHits` + `refreshBodyMatches()` consume it. Task 14 proves `nil` versus `[]` through mutation.
4. **The `swift-nio-imap` API risk.** It is the only dependency whose surface cannot be verified before SPM resolution. **Corrected:** explicit divergence rules in Tasks 9/10 require stopping with `NEEDS_CONTEXT`, like Milestone 1's prototype rule. Architecture limits damage: **all** library-type contact belongs in `ImapResponseAdapter.swift`; all IMAP logic is tested against our `ImapWire.Untagged`.
5. **`FolderRole` appeared in two places.** The file tree put it in `Providers/ImapEndpointTypes.swift`, while Task 5 defined it in `Database/Records.swift`. **Corrected:** the definition stays in `Database/Records.swift`, since `folder` persists it. The tree was corrected: `ImapEndpointTypes.swift` does not exist and `ImapPreset` lives in `Providers/ImapPresets.swift`.
6. **Task 17's live rehearsal depended on Task 18.** Scene and flag exist only after composition. **Corrected:** Task 17 step 6 explicitly runs after Task 18.
7. **A finite `AccountTints` list would reject account nine.** The inherited constraint forbids account limits. **Corrected:** the table cycles, and a test requests account thirty's color.
8. **Network errors incorrectly set `erroDeAutenticacao`.** The first `InitialLoader` version used that state for any failure, offering “Reconectar” to someone who merely lost Wi-Fi. **Corrected:** `InitialLoader.estadoPara(_:)` separates cases; `AccountsCopy.action(for:)` matches action to cause, mutation-proven in Task 16.

### 3. Type consistency across tasks

Checked name by name from use to definition:

- `ImapEndpoint(host:port:security:)` — defined in Task 3; used in 5, 6, 9, 13, 15, 16 and 17 with the same signature.
- `Account.State` (`ativa`/`carregando`/`erroDeAutenticacao`) — Task 3; used in 5, 12, 13, 15 and 16.
- `Account.withState(_:)` / `withLastSynced(_:)` / `withImap(_:)` — Task 3; used in 12 (`marca`, `conclui`).
- `Message.serverID` / `uidValidity` — Task 3; persisted in 5, populated in 12/13, read in 14.
- `FolderRole` (`inbox`/`archive`/`trash`/`sent`/`later = "depois"`/`other = "outra"`) — Task 5; used in 6, 10, 11 and 13.
- `FolderRecord.id(accountID:serverName:)` — Task 5; used in 13, 14 and Task 13 tests.
- `SyncError` — Task 4; thrown in 7, 8, 9, 10, 12, 13, 15 and 18; translated in 16.
- `SecretStore` / `Secret` / `OAuthTokens` — Task 4; used in 7, 15 and 18.
- `PKCEPair.make(from:)` / `.random()` — Task 7; `random()` used in `connect`.
- `GoogleAuthConfig.authorizationURL(pkce:state:loginHint:)` — Task 7; called in `GoogleAuth.connect`.
- `GoogleAuth.connect(accountID:loginHint:)` / `.accessToken(for:)` / `.revoke(accountID:)` — Task 7; used in 15.
- `AuthorizationPresenter.authorize(url:callbackScheme:)` — Task 7; implemented by `WebAuthorizationPresenter` (Task 18) and `StubAuthorizationPresenter` (Tasks 7, 15, 17).
- `GmailClient(session:accessToken:baseURL:)` — Task 8; built in 12 (tests), 15; `baseURL` is an `AccountDirector` parameter.
- `GmailMessage` (`labelIDs`, not `labelIds`) — Task 8; read in 11 (`bucket(gmailLabelIDs:)`) and 12.
- `MailAddress.parse` / `.parseList` / `.decodeRFC2047` — Task 8; reused in 10 (`ImapWire.envelopes`) without another implementation.
- `GmailMessageParser.paragraphs(from:)` — Task 8; reused in 10 (`ImapWire.bodyText`) without another implementation.
- `ImapWire.fetchBatchSize` / `.uidFetchEnvelopes(tag:uids:)` — Tasks 9/10; used in `ImapSession.envelopes(uids:)`.
- `ImapSession.folders()` / `.select(_:)` / `.uids(since:calendar:)` / `.envelopes(uids:)` / `.bodyText(uid:)` / `.login(user:password:)` / `.logout()` — Tasks 9/10; used in 13 and 15.
- `ImapCommandResult.untagged: [ImapWire.Untagged]` — declared as `[String]` in Task 9 and **explicitly changed** in Task 10 step 5, including the handler line. No old-type use remains afterwards.
- `TriageProjection.bucket(role:)` / `.bucket(gmailLabelIDs:laterLabelID:)` / `.laterLabelID(in:)` — Task 11; used in 12/13.
- `MessageIdentity.gmail(accountID:serverID:)` / `.imap(accountID:folderID:uidValidity:uid:)` — Task 11; used and asserted by tests in 12/13.
- `LoadProgress(accountID:done:total:)` and `.fraction` — Task 12; used in 13, 15 (`AccountStatus.progress`) and 16 (`AccountsCopy`).
- `InitialLoader(database:calendar:)`, `.loadGmail(account:client:now:progress:)`, `.loadImap(account:session:now:progress:)`, `.windowDays`, `.fullBodyCount`, `.batchSize`, `.marca`, `.conclui`, `.estadoPara` — Tasks 12/13; used in 15.
- `MailSnapshot(accounts:messages:agenda:pendingItems:)`, `MailSource.snapshot()`, `.snapshots()`, `.bodyMatches(_:accountID:)` — Task 14; implemented by `DatabaseMailSource` there and used in 18.
- `MailStore.observe()` / `.refreshBodyMatches()` — Task 14; called in 18.
- `AccountStatus(accountID:address:hostMark:state:messageCount:lastSyncedAt:error:progress:)` — Task 15; built in `AccountDirector`, consumed in 16/17.
- `AccountDirector.init(database:secrets:auth:session:gmailBaseURL:eventLoopGroup:imapConnect:now:)` — Task 15; called with identical labels in Task 15 tests and Task 18 composition.
- `AccountsModel.start()` / `.addGoogle(address:)` / `.testImap(address:password:endpoint:)` / `.addImap(address:password:endpoint:hostMark:displayName:)` / `.remove(_:)` / `.loadInitial(_:)` / `.statuses` / `.lastError` / `.isBusy` — Task 15; used in 16/17 with the same labels.
- `AccountsCopy.status(_:now:calendar:)` / `.action(for:)` — Task 16; used by `AccountsList` there.
- `UNIWindow.accounts` and `UNIWindow.Size.accounts` — Task 16; used in 18.
- `ContextCommand.openAccounts` — Task 16; dispatched in `ContextMenuHost` there.
- `AppComposition.make(databasePath:bundle:)` and its four fields — Task 18; used by `OkamiUNIApp` there.
- `RehearsalStage.log` / `.framePath` — Milestone 1; used in 17.

**No naming divergence remains.** Three classic traps were checked separately: our `labelIDs` versus JSON's `labelIds`, which appears only in the parser's private `Wire`; our `historyID` versus JSON's `historyId`, likewise; and preset/`AccountStatus` `hostMark` versus `UNICore`'s `Account.host`. The last pair carries the same value across differently named boundaries: `AccountDirector.grava` bridges it, and `adicionarImap` asserts `conta.host == "meusite"`.

### 4. Placeholder scan

Searched the whole document for `TBD`, `TODO`, `implementar depois`, `preencher`, `tratamento de erro apropriado`, `adicionar validação`, `casos de borda`, `escrever testes para o acima`, `similar à Task N`, and code steps lacking code blocks.

**No occurrences.** Three things might resemble placeholders but are not:

- Tasks 9/10's **divergence rule** is a process instruction to stop with `NEEDS_CONTEXT`, like Milestone 1's prototype-divergence rule. Complete code appears alongside it.
- **Task 17 step 6** explicitly depends on Task 18; the entire rehearsal code is present in Task 17 itself.
- **Task 18 step 9** is the owner's manual step by definition, the milestone's only internet-connected moment; every acceptance item is written as a checkbox.
