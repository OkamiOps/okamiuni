# OkamiUNI — Milestone 1: Shell and Unified Inbox

> **Historical design and implementation record.** This document preserves the decisions made on its stated date and is not evidence of current behavior. [Leia o original em Português](2026-08-26-okamiuni-shell.md).

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver the macOS app opening in its own window with the unified three-pane Inbox — sidebar, message list, reader, and agenda rail — navigable with mock data and switching between the 26 themes.

**Architecture:** SwiftUI for composition and the theme system; AppKit through `NSViewRepresentable` only where the dense list and rich text require it. The window draws its own chrome (the 58px bar from the design) over an `NSWindow` with hidden title, keeping the native traffic lights. Data comes from a `MessageStore` powered by fixtures in this milestone and real backends in Milestone 2 — the UI never sees the backend, only the protocol.

**Tech Stack:** Swift 6.3, SwiftUI, AppKit, Swift Testing, XcodeGen, macOS 26 (Tahoe).

## Global Constraints

- Minimum target: **macOS 26.0**. `SWIFT_VERSION` 6.0, `SWIFT_STRICT_CONCURRENCY: complete`.

- The Xcode project is **generated** by `xcodegen` from `project.yml`. The `.xcodeproj` stays in `.gitignore` — never edit by hand, never version.

- `Packages/UNIDesign` already exists and is ready: 26 themes, `TokenColor`, `FontFamily`, `FontRegistry`, `ThemeStore`, `EnvironmentValues.theme`. **Do not rewrite.** Regenerate themes only via `python3 Tools/generate_themes.py`.

- **Unlimited accounts and open providers.** No literal quantity and no list of known domains or providers in production code. See "Accounts" below.

- **Color, radius and typography always come from `Theme`** - this is absolute. No color literal (`Color.blue`, `#FFF`), no loose radius, no `Font.system` direct in a View. If a color or radius token is missing, the path is to add it to the design and regenerate, never invent in Swift.

- **Inline spacing is allowed** (`padding(.horizontal, 24)`, `spacing: 10`, `frame(height: 40)`), because the prototype does not tokenize the spacing scale — it positions element by element. The rule is: **any spacing number must come from the prototype, not your intuition.** In case of doubt, measure on `.dc.html` instead of rounding. The four metric tokens that exist (`radiusSmall`, `radiusLarge`, `rowPadding`, `capsTracking`) are mandatory where applicable.

- **Two temporary scaffolds are mandated by the plan and are not defects:** the `Color.clear` that holds the place of the theme selector in Task 5 (removed in Task 6) and the `print` of `onAddEvent` in Task 11 (replaced by EventKit in Milestone 4). Both have comments saying what removes them.

- All interface text in **Brazilian Portuguese**, identical to the prototype (`design/OkamiUNI - Mail + Agenda.dc.html`).

- **Visual source of truth: the prototype.** When plan and prototype diverge, the implementer
  **DOES NOT decide**: stop, return `NEEDS_CONTEXT` with the discrepancy (plan value,
  prototype value, and `.dc.html` line), and await a response. Following a plan over the
  prototype has already caused rework here — an implementer found and recorded a discrepancy,
  but still followed the plan, so the entire sidebar had to be rebuilt.

- Tests with **Swift Testing** (`import Testing`, `@Test`, `#expect`), not XCTest.

- One commit per completed task, message in Portuguese, with trailer `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.

---

## Context: where this milestone fits in

The entire app is too big for a single plan. This is the sequence; **this document only covers Milestone 1**, which delivers software that runs and is testable on its own.

| Milestone | Delivery | Status |
|---|---|---|
| 0 | Design downloaded, 26 themes in Swift, green tests | ✅ done |
| **1** | **Shell + navigable unified Inbox with mock data** | **this plan** |
| 2 | Universal IMAP/SMTP with server self-discovery; Gmail API and Graph later, as optimization | to plan |
| 3 | Compose (inline, in window, new message) | to plan |
| 4 | Weekly agenda + EventKit | to be planned |
| 5 | Commitment detection and summary on the device (Foundation Models) | to be planned |
| 6 | Highlighted windows, shortcuts, search ⌘K | to plan |
| 7 | Packaging, signature, notarization | to be planned |

### Accounts: as many as the user wants, from wherever he wants

**The number of accounts is unlimited and providers are open.** Any provider, any domain - own server, shared hosting, regional provider, whatever. Nothing in the UI or template can assume a quantity, a set of providers or a list of known domains.

The four mailboxes that appear in the prototype (`ricardo@empresa.com`, `ricardo@gmail.com`, `contato@meusite.com`, `ricardo@icloud.com`) are **examples the designer used to draw**, not product scope. They become fixtures in Milestone 1 only so the visual comparison matches the prototype.

Concrete consequences, which apply to all tasks of this plan:

- No literal `4` in production code. The search text is `"Buscar nas \(accountCount) caixas…"`.

- No `switch` exhaustive on known accounts. `Account.id` is opaque.

- The UI must handle 0, 1, and 30 accounts. The sidebar scrolls; the list does not change width.

- `Account.Provider` classifies **how to talk to the server**, not who the provider is. `.imap` is the general case, not the exception.

**IMAP/SMTP is the universal path and Milestone 2’s top priority** — that is what makes “any provider, any domain” true. Gmail API and Microsoft Graph come later, as an optimization for those two cases (better incremental sync, native threading), never as a prerequisite for an account to work. A Gmail account must work through IMAP even before the Gmail API exists in the code.

This requires Milestone 2 to include **server self-discovery** — Mozilla ISPDB, `autoconfig.<domain>`, `autodiscover`, and SRV records — so the user can enter an email address and password and the app can find the host and port itself. Without it, “any domain” becomes “any domain if you already know the IMAP/SMTP settings,” which is not the same thing.

---

## File structure

```
project.yml                              XcodeGen: alvo do app, pacotes, entitlements
Tools/fetch_fonts.sh                     Baixa as 6 famílias OFL do repo google/fonts
App/
  OkamiUNIApp.swift                      @main, registro de fontes, cena da janela
  Info.plist                             Metadados do bundle
  OkamiUNI.entitlements                  Sandbox, rede, calendários
  Resources/Fonts/                       Arquivos .ttf embarcados
  Resources/Assets.xcassets/             Logos e ícone do app
Packages/UNICore/                        Modelos puros, sem UI, sem rede
  Sources/UNICore/
    Account.swift                        Account, Account.Provider
    Contact.swift                        Contact e iniciais
    Message.swift                        Message, Tag, TriageBucket
    DetectedEvent.swift                  Compromisso detectado no corpo
    AgendaItem.swift                     Item da trilha de agenda
    MessageStore.swift                   Protocolo + store em memória
  Sources/UNICore/Fixtures/
    Fixtures.swift                       Dados do protótipo, para dev e testes
Packages/UNIShell/                       As Views
  Sources/UNIShell/
    Chrome/
      WindowChrome.swift                 Barra de 58px
      ThemePicker.swift                  Popover com 26 previews
      SearchField.swift                  Campo de busca com ⌘K
    Inbox/
      InboxScreen.swift                  Composição dos três painéis
      FolderSidebar.swift                Pastas e caixas
      MessageList.swift                  Lista de 370px, agrupada
      MessageRow.swift                   Anatomia da linha
      ReaderPane.swift                   Painel de leitura
      AgendaRail.swift                   Trilha de 262px
    Support/
      TokenModifiers.swift               .tokenBackground, .hairline, .capsLabel
```


**Why this split:** `UNICore` does not import SwiftUI, so its models can be tested without UI and reused by Milestone 2 backends. `UNIShell` does not know about networking. `UNIDesign` knows neither models nor networking. The three layers point only downward.

---

### Task 1: Xcode project that opens a themed window

**Files:**

- Create: `project.yml`

- Create: `App/OkamiUNIApp.swift`

- Create: `App/Info.plist`

- Create: `App/OkamiUNI.entitlements`

- Modify: `.gitignore`

**Interfaces:**

- Consumes: `UNIDesign.Theme`, `UNIDesign.ThemeStore`, `View.theme(_:)`

- Produces: a compilable `OkamiUNI` target; `OkamiUNIApp` as `@main`

- [ ] **Step 1: Write `project.yml`**

```yaml
name: OkamiUNI
options:
  bundleIdPrefix: com.okamiops
  deploymentTarget:
    macOS: "26.0"
  createIntermediateGroups: true

settings:
  base:
    SWIFT_VERSION: "6.0"
    SWIFT_STRICT_CONCURRENCY: complete
    ENABLE_USER_SCRIPT_SANDBOXING: YES
    MARKETING_VERSION: "0.1.0"
    CURRENT_PROJECT_VERSION: "1"
    DEAD_CODE_STRIPPING: YES

packages:
  UNIDesign:
    path: Packages/UNIDesign

targets:
  OkamiUNI:
    type: application
    platform: macOS
    sources:
      - path: App
    dependencies:
      - package: UNIDesign
        product: UNIDesign
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.okamiops.okamiuni
        INFOPLIST_FILE: App/Info.plist
        CODE_SIGN_ENTITLEMENTS: App/OkamiUNI.entitlements
        CODE_SIGN_STYLE: Automatic
        ENABLE_HARDENED_RUNTIME: YES
        COMBINE_HIDPI_IMAGES: YES
```


- [ ] **Step 2: Write `App/Info.plist`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>pt_BR</string>
  <key>CFBundleExecutable</key><string>$(EXECUTABLE_NAME)</string>
  <key>CFBundleIdentifier</key><string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
  <key>CFBundleName</key><string>OkamiUNI</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$(MARKETING_VERSION)</string>
  <key>CFBundleVersion</key><string>$(CURRENT_PROJECT_VERSION)</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 OkamiOps</string>
  <key>NSCalendarsFullAccessUsageDescription</key>
  <string>O OkamiUNI mostra seus compromissos ao lado dos emails e cria eventos a partir das mensagens.</string>
</dict>
</plist>
```


- [ ] **Step 3: Write `App/OkamiUNI.entitlements`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.app-sandbox</key><true/>
  <key>com.apple.security.network.client</key><true/>
  <key>com.apple.security.personal-information.calendars</key><true/>
  <key>com.apple.security.files.user-selected.read-write</key><true/>
</dict>
</plist>
```


- [ ] **Step 4: Write `App/OkamiUNIApp.swift`**

The design window does not use the system title bar: it draws its own 58px bar and only keeps the traffic lights. `.windowStyle(.hiddenTitleBar)` does that.

```swift
import SwiftUI
import UNIDesign

@main
struct OkamiUNIApp: App {
    @State private var themes = ThemeStore()

    init() {
        FontRegistry.registerBundledFonts()
    }

    var body: some Scene {
        WindowGroup("OkamiUNI") {
            RootView()
                .environment(themes)
                .theme(themes.theme)
                .frame(minWidth: 1100, minHeight: 700)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 916)
    }
}

struct RootView: View {
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            theme.paper.color.ignoresSafeArea()
            Text("OkamiUNI")
                .font(theme.serif.font(size: 28, weight: .medium))
                .foregroundStyle(theme.ink.color)
        }
    }
}
```


- [ ] **Step 5: Ignore the generated project**

Add `.gitignore`:

```
*.xcodeproj
```


- [ ] **Step 6: Generate and compile**

Run:

```bash
xcodegen generate && xcodebuild -project OkamiUNI.xcodeproj -scheme OkamiUNI -configuration Debug build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 7: Open the app and confirm visually**

Run:

```bash
open "$(xcodebuild -project OkamiUNI.xcodeproj -scheme OkamiUNI -showBuildSettings 2>/dev/null | awk -F'= ' '/BUILT_PRODUCTS_DIR/{print $2; exit}')/OkamiUNI.app"
```
Expected: window without title bar, background `#F4F2EE` (the `paper` from the Ink theme), text "OkamiUNI" in dark serif. If the background comes in pure white, the theme has not arrived in the environment - check `.theme(themes.theme)`.

- [ ] **Step 8: Commit**

```bash
git add project.yml App .gitignore
git commit -m "Projeto Xcode gerado por XcodeGen, janela com chrome próprio

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```


---

### Task 2: Embedded design fonts

Without that, `FontRegistry.missing` lists the six families and the entire app renders in system font - similar, but it's not the design.

**Files:**

- Create: `Tools/fetch_fonts.sh`

- Create: `App/Resources/Fonts/` (downloaded files)

- Modify: `project.yml`

- Test: `Packages/UNIDesign/Tests/UNIDesignTests/FontRegistryTests.swift`

**Interfaces:**

- Consumes: `FontRegistry.required`, `FontRegistry.registerBundledFonts(in:)`

- Produces: bundle with `Fonts/*.ttf`; `FontRegistry.missing` empty in runtime

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import UNIDesign

@Suite("FontRegistry")
struct FontRegistryTests {

    @Test("a lista de famílias exigidas cobre todas as usadas pelos temas")
    func requiredCoversThemes() {
        var used = Set<String>()
        for theme in Theme.all {
            for family in [theme.serif, theme.sans, theme.mono] {
                if let name = family.name { used.insert(name) }
            }
        }
        let declared = Set(FontRegistry.required)
        #expect(used.subtracting(declared).isEmpty,
                "temas usam famílias não declaradas: \(used.subtracting(declared))")
    }

    @Test("FontFamily cai no system font quando a face não está instalada")
    func fallsBackWhenMissing() {
        let ghost = FontFamily(name: "Fonte Que Nao Existe", design: .serif)
        // Não deve travar nem devolver uma fonte inválida.
        _ = ghost.font(size: 14)
        #expect(FontRegistry.isAvailable("Fonte Que Nao Existe") == false)
    }
}
```


- [ ] **Step 2: Run the test**

Run: `cd Packages/UNIDesign && swift test --filter FontRegistry`

Expected: PASS in both - this test protects the contract, not the presence of the files.

- [ ] **Step 3: Write `Tools/fetch_fonts.sh`**

The six families are in the `google/fonts` repository under the OFL license. Download the variable fonts, which cover every weight the design needs in one file per family.

```bash
#!/usr/bin/env bash
# Baixa as famílias OFL que o design usa para App/Resources/Fonts/.
# Rode de novo quando quiser atualizar as faces.
set -euo pipefail

DEST="$(cd "$(dirname "$0")/.." && pwd)/App/Resources/Fonts"
mkdir -p "$DEST"
BASE="https://raw.githubusercontent.com/google/fonts/main"

# caminho-no-repo -> nome-do-arquivo-local
FILES=(
  "ofl/newsreader/Newsreader%5Bopsz,wght%5D.ttf|Newsreader.ttf"
  "ofl/newsreader/Newsreader-Italic%5Bopsz,wght%5D.ttf|Newsreader-Italic.ttf"
  "ofl/spacegrotesk/SpaceGrotesk%5Bwght%5D.ttf|SpaceGrotesk.ttf"
  "ofl/inter/Inter%5Bopsz,wght%5D.ttf|Inter.ttf"
  "ofl/intertight/InterTight%5Bwght%5D.ttf|InterTight.ttf"
  "ofl/ibmplexmono/IBMPlexMono-Regular.ttf|IBMPlexMono-Regular.ttf"
  "ofl/ibmplexmono/IBMPlexMono-Medium.ttf|IBMPlexMono-Medium.ttf"
  "ofl/jetbrainsmono/JetBrainsMono%5Bwght%5D.ttf|JetBrainsMono.ttf"
)

for entry in "${FILES[@]}"; do
  path="${entry%%|*}"
  name="${entry##*|}"
  echo "baixando $name"
  curl -fsSL "$BASE/$path" -o "$DEST/$name"
done

echo
echo "arquivos em $DEST:"
ls -la "$DEST"
```


- [ ] **Step 4: Run and check**

Run:

```bash
chmod +x Tools/fetch_fonts.sh && ./Tools/fetch_fonts.sh
file App/Resources/Fonts/*.ttf
```
Expected: each file is reported as `TrueType Font data` or `OpenType font data`. If any is `ASCII text`, the path in the `google/fonts` repository changed — open `https://github.com/google/fonts/tree/main/ofl/<familia>` and correct the entry in `FILES`. Do not continue with an invalid file: registration fails silently and the font falls back.

- [ ] **Step 5: Declare the resources in `project.yml`**

Inside `targets.OkamiUNI`, add before `dependencies`:

```yaml
    sources:
      - path: App
        excludes:
          - "Resources/Fonts"
      - path: App/Resources/Fonts
        type: folder
```


`type: folder` preserves `Fonts/` as a folder inside the bundle, where `registerBundledFonts` looks (`subdirectory: "Fonts"`).

- [ ] **Step 6: Verify the runtime record**

Temporarily add to `init()` of `OkamiUNIApp`:
```swift
init() {
    let registered = FontRegistry.registerBundledFonts()
    print("[fontes] registradas: \(registered.count) — faltando: \(FontRegistry.missing)")
}
```


Run: `xcodegen generate && xcodebuild -project OkamiUNI.xcodeproj -scheme OkamiUNI build && open ...`

Expected on the console: `faltando: []`. If any family appears, the name in `FontRegistry.required` does not match the internal name of the face - check with `fc-scan` or open it in the Font Book.

- [ ] **Step 7: Commit**

```bash
git add Tools/fetch_fonts.sh App/Resources/Fonts project.yml \
        Packages/UNIDesign/Tests/UNIDesignTests/FontRegistryTests.swift
git commit -m "Embarca as 6 famílias OFL que o design usa

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```


---

### Task 3: Domain models

**Files:**

- Create: `Packages/UNICore/Package.swift`

- Create: `Packages/UNICore/Sources/UNICore/Account.swift`

- Create: `Packages/UNICore/Sources/UNICore/Contact.swift`

- Create: `Packages/UNICore/Sources/UNICore/Message.swift`

- Create: `Packages/UNICore/Sources/UNICore/DetectedEvent.swift`

- Create: `Packages/UNICore/Sources/UNICore/AgendaItem.swift`

- Test: `Packages/UNICore/Tests/UNICoreTests/ModelTests.swift`

**Interfaces:**

- Consumes: nothing (bottom layer)

- Produces: `Account`, `Account.Provider`, `Contact`, `Message`, `Tag`, `TriageBucket`, `DetectedEvent`, `AgendaItem`

- [ ] **Step 1: Write `Package.swift`**

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "UNICore",
    platforms: [.macOS(.v26)],
    products: [.library(name: "UNICore", targets: ["UNICore"])],
    targets: [
        .target(name: "UNICore"),
        .testTarget(name: "UNICoreTests", dependencies: ["UNICore"]),
    ]
)
```


- [ ] **Step 2: Write the failing tests**

```swift
import Testing
import Foundation
@testable import UNICore

@Suite("Modelos")
struct ModelTests {

    @Test("iniciais saem do nome, não do email")
    func initialsFromName() {
        #expect(Contact(name: "Marina Duarte", address: "marina@x.com").initials == "MD")
        #expect(Contact(name: "Equipe Produto", address: "p@x.com").initials == "EP")
        #expect(Contact(name: "Ricardo", address: "r@x.com").initials == "R")
    }

    @Test("sem nome, as iniciais vêm do endereço")
    func initialsFromAddress() {
        #expect(Contact(name: "", address: "contato@meusite.com").initials == "C")
    }

    @Test("nomes com mais de duas palavras usam a primeira e a última")
    func initialsThreeWords() {
        #expect(Contact(name: "Ana Beatriz Silva", address: "a@x.com").initials == "AS")
    }

    @Test("as pastas de triagem batem com o protótipo")
    func triageBuckets() {
        #expect(TriageBucket.allCases.map(\.rawValue) == ["hoje", "depois", "todos", "arquivar"])
        #expect(TriageBucket.today.label == "Hoje")
        #expect(TriageBucket.later.label == "Depois")
        #expect(TriageBucket.all.label == "Tudo")
        #expect(TriageBucket.archived.label == "Arquivado")
    }

    @Test("a caixa Tudo aceita qualquer mensagem; as outras filtram")
    func bucketMatching() {
        let m = Message.preview(bucket: .today)
        #expect(TriageBucket.all.contains(m))
        #expect(TriageBucket.today.contains(m))
        #expect(TriageBucket.archived.contains(m) == false)
    }
}
```


- [ ] **Step 3: Run to see it fail**

Run: `cd Packages/UNICore && swift test`

Expected: FAIL in compilation — `cannot find 'Contact' in scope`.

- [ ] **Step 4: Write `Contact.swift`**

```swift
import Foundation

public struct Contact: Sendable, Hashable, Identifiable {
    public var id: String { address.lowercased() }
    public let name: String
    public let address: String

    public init(name: String, address: String) {
        self.name = name
        self.address = address
    }

    /// Duas letras para o avatar. Nomes de três ou mais palavras usam a
    /// primeira e a última — "Ana Beatriz Silva" vira "AS", não "AB".
    public var initials: String {
        let words = name.split(separator: " ").filter { !$0.isEmpty }
        switch words.count {
        case 0:
            return address.first.map { String($0).uppercased() } ?? "?"
        case 1:
            return String(words[0].prefix(1)).uppercased()
        default:
            let first = words[0].prefix(1)
            let last = words[words.count - 1].prefix(1)
            return (first + last).uppercased()
        }
    }

    /// Como o protótipo escreve: "Marina Duarte · marina@clientepremium.com"
    public var display: String {
        name.isEmpty ? address : "\(name) · \(address)"
    }
}
```


- [ ] **Step 5: Write `Account.swift`**

```swift
import Foundation

public struct Account: Sendable, Hashable, Identifiable {
    /// Como o app conversa com o servidor — não quem é o provedor.
    ///
    /// `imap` é o caso geral e cobre qualquer provedor em qualquer domínio.
    /// `gmail` e `microsoft` existem só onde a API nativa rende sync melhor;
    /// uma conta desses dois continua funcionando por `imap`. Nunca tratar
    /// `imap` como exceção nem presumir que a lista de provedores é fechada.
    public enum Provider: String, Sendable, CaseIterable {
        case imap, gmail, microsoft
    }

    public let id: String
    public let address: String
    public let displayName: String
    public let provider: Provider
    /// Matiz OKLCH que o design dá a cada caixa, já convertida para sRGB.
    public let tintHex: String

    public init(
        id: String, address: String, displayName: String,
        provider: Provider, tintHex: String
    ) {
        self.id = id
        self.address = address
        self.displayName = displayName
        self.provider = provider
        self.tintHex = tintHex
    }

    /// O host que a linha da lista mostra em miúdo: "zoho", "gmail", ...
    public var host: String { id }
}
```


- [ ] **Step 6: Write `DetectedEvent.swift` and `AgendaItem.swift`**

```swift
// DetectedEvent.swift
import Foundation

/// Compromisso que o app encontrou dentro do corpo de uma mensagem.
/// No Marco 1 vem das fixtures; no Marco 5, do modelo no dispositivo.
public struct DetectedEvent: Sendable, Hashable {
    public let label: String        // "Call de contrato · qui 27, 15:00"
    public let start: Date
    public let duration: TimeInterval

    public init(label: String, start: Date, duration: TimeInterval) {
        self.label = label
        self.start = start
        self.duration = duration
    }

    public var end: Date { start.addingTimeInterval(duration) }
}
```


```swift
// AgendaItem.swift
import Foundation

/// Um compromisso na trilha lateral. `startMinute` e `endMinute` são minutos
/// desde a meia-noite, como o protótipo modela (`s: 570, e: 600`).
public struct AgendaItem: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let startMinute: Int
    public let endMinute: Int
    public let accountID: String

    public init(
        id: String, title: String,
        startMinute: Int, endMinute: Int, accountID: String
    ) {
        self.id = id
        self.title = title
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.accountID = accountID
    }

    public var durationMinutes: Int { endMinute - startMinute }

    /// "09:30"
    public var startLabel: String {
        String(format: "%02d:%02d", startMinute / 60, startMinute % 60)
    }
}
```


- [ ] **Step 7: Write `Message.swift`**

```swift
import Foundation

/// Etiqueta do protótipo: "Precisa resposta", "Compromisso", "Lead"...
public struct Tag: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public let name: String
    /// Cor do design, em hex. `nil` usa `ink3` do tema.
    public let tintHex: String?

    public init(name: String, tintHex: String? = nil) {
        self.name = name
        self.tintHex = tintHex
    }
}

public enum TriageBucket: String, Sendable, CaseIterable {
    case today = "hoje"
    case later = "depois"
    case all = "todos"
    case archived = "arquivar"

    public var label: String {
        switch self {
        case .today: "Hoje"
        case .later: "Depois"
        case .all: "Tudo"
        case .archived: "Arquivado"
        }
    }

    /// `all` é uma visão, não um estado: aceita tudo.
    public func contains(_ message: Message) -> Bool {
        self == .all || message.bucket == self
    }
}

public struct Message: Sendable, Hashable, Identifiable {
    public let id: String
    public let accountID: String
    public let from: Contact
    public let receivedAt: Date
    public let subject: String
    public let snippet: String
    public let body: [String]
    public let tags: [Tag]
    public let bucket: TriageBucket
    public let isRead: Bool
    /// Resumo gerado no dispositivo. `nil` enquanto não houver.
    public let summary: String?
    public let detectedEvent: DetectedEvent?

    public init(
        id: String, accountID: String, from: Contact, receivedAt: Date,
        subject: String, snippet: String, body: [String],
        tags: [Tag], bucket: TriageBucket, isRead: Bool,
        summary: String?, detectedEvent: DetectedEvent?
    ) {
        self.id = id
        self.accountID = accountID
        self.from = from
        self.receivedAt = receivedAt
        self.subject = subject
        self.snippet = snippet
        self.body = body
        self.tags = tags
        self.bucket = bucket
        self.isRead = isRead
        self.summary = summary
        self.detectedEvent = detectedEvent
    }
}

extension Message {
    /// Só para testes e previews.
    public static func preview(
        id: String = "m1",
        bucket: TriageBucket = .today
    ) -> Message {
        Message(
            id: id, accountID: "zoho",
            from: Contact(name: "Marina Duarte", address: "marina@clientepremium.com"),
            receivedAt: .now, subject: "Assunto", snippet: "Trecho",
            body: ["Corpo"], tags: [], bucket: bucket, isRead: false,
            summary: nil, detectedEvent: nil
        )
    }
}
```


- [ ] **Step 8: Run the tests**

Run: `cd Packages/UNICore && swift test`

Expected: PASS, 5 tests.

- [ ] **Step 9: Commit**

```bash
git add Packages/UNICore
git commit -m "UNICore: modelos de conta, contato, mensagem e agenda

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```


---

### Task 4: Prototype store and fixtures

**Files:**

- Create: `Packages/UNICore/Sources/UNICore/MessageStore.swift`

- Create: `Packages/UNICore/Sources/UNICore/Fixtures/Fixtures.swift`

- Test: `Packages/UNICore/Tests/UNICoreTests/StoreTests.swift`

**Interfaces:**

- Consumes: `Account`, `Message`, `TriageBucket`, `AgendaItem`

- Produces: `protocol MailSource`, `InMemoryMailSource`, `MailStore` (`@Observable`), `Fixtures.accounts`, `Fixtures.messages`, `Fixtures.agenda`

- [ ] **Step 1: Write down the failing tests**

```swift
import Testing
import Foundation
@testable import UNICore

@Suite("MailStore")
struct StoreTests {

    @MainActor
    private func loadedStore() async -> MailStore {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        return store
    }

    @Test("carrega as contas que a fonte entregar")
    @MainActor
    func loadsAccounts() async {
        let store = await loadedStore()
        #expect(store.accounts.isEmpty == false)
        // Sem asserção de quantidade: o número de contas é do usuário.
        #expect(Set(store.accounts.map(\.id)).count == store.accounts.count)
    }

    /// O produto aceita qualquer quantidade de contas, de qualquer provedor,
    /// em qualquer domínio. Estes três testes existem para que nenhuma
    /// mudança futura reintroduza um limite por descuido.
    @Test("funciona sem nenhuma conta")
    @MainActor
    func handlesZeroAccounts() async {
        let store = MailStore(
            source: InMemoryMailSource(accounts: [], messages: [], agenda: [])
        )
        await store.load()
        #expect(store.accounts.isEmpty)
        #expect(store.visibleMessages.isEmpty)
        #expect(store.selectedMessage == nil)
        #expect(store.loadError == nil)
    }

    @Test("funciona com muitas contas em domínios arbitrários")
    @MainActor
    func handlesManyAccounts() async {
        let many = (1...30).map { i in
            Account(
                id: "acc\(i)", address: "pessoa@dominio\(i).com.br",
                displayName: "Conta \(i)", provider: .imap, tintHex: "#3E6FA8"
            )
        }
        let store = MailStore(
            source: InMemoryMailSource(accounts: many, messages: [], agenda: [])
        )
        await store.load()
        #expect(store.accounts.count == 30)
        #expect(store.account("acc17")?.address == "pessoa@dominio17.com.br")
    }

    @Test("uma conta de provedor desconhecido é tratada como IMAP normal")
    @MainActor
    func unknownProviderIsOrdinary() async throws {
        let obscure = Account(
            id: "servidor-proprio", address: "eu@meuservidor.xyz",
            displayName: "Servidor próprio", provider: .imap, tintHex: "#2C7D5E"
        )
        let store = MailStore(
            source: InMemoryMailSource(accounts: [obscure], messages: [], agenda: [])
        )
        await store.load()
        let found = try #require(store.account("servidor-proprio"))
        #expect(found.provider == .imap)
        #expect(found.host == "servidor-proprio")
    }

    @Test("a caixa Tudo mostra mais mensagens que Hoje")
    @MainActor
    func bucketFiltering() async {
        let store = await loadedStore()
        store.select(bucket: .all)
        let all = store.visibleMessages.count
        store.select(bucket: .today)
        let today = store.visibleMessages.count
        #expect(all > 0)
        #expect(today > 0)
        #expect(all >= today)
    }

    @Test("a busca casa remetente, assunto e trecho, ignorando acento e caixa")
    @MainActor
    func searchMatches() async {
        let store = await loadedStore()
        store.select(bucket: .all)
        store.query = "MARINA"
        #expect(store.visibleMessages.allSatisfy {
            $0.from.name.localizedCaseInsensitiveContains("marina")
                || $0.subject.localizedCaseInsensitiveContains("marina")
                || $0.snippet.localizedCaseInsensitiveContains("marina")
        })
        #expect(store.visibleMessages.isEmpty == false)
    }

    @Test("busca sem resultado devolve lista vazia, não a lista inteira")
    @MainActor
    func searchMiss() async {
        let store = await loadedStore()
        store.select(bucket: .all)
        store.query = "zzzznadaaqui"
        #expect(store.visibleMessages.isEmpty)
    }

    @Test("selecionar uma mensagem marca como lida")
    @MainActor
    func selectionMarksRead() async throws {
        let store = await loadedStore()
        store.select(bucket: .all)
        let first = try #require(store.visibleMessages.first)
        store.select(message: first.id)
        #expect(store.selectedMessage?.id == first.id)
        #expect(store.selectedMessage?.isRead == true)
    }

    @Test("mudar de caixa limpa a seleção que não pertence mais à visão")
    @MainActor
    func selectionClearedOnBucketChange() async throws {
        let store = await loadedStore()
        store.select(bucket: .all)
        let archived = try #require(
            store.visibleMessages.first { $0.bucket == .archived }
        )
        store.select(message: archived.id)
        store.select(bucket: .today)
        #expect(store.selectedMessage == nil)
    }

    @Test("a trilha de agenda vem ordenada por horário")
    @MainActor
    func agendaSorted() async {
        let store = await loadedStore()
        let starts = store.agenda.map(\.startMinute)
        #expect(starts == starts.sorted())
    }
}
```


- [ ] **Step 2: Run to see failure**

Run: `cd Packages/UNICore && swift test --filter MailStore`

Expected: FAIL — `cannot find 'MailStore' in scope`.

- [ ] **Step 3: Write `MessageStore.swift`**

```swift
import Foundation
import Observation

/// De onde as mensagens vêm. No Marco 1 só existe a implementação em memória;
/// no Marco 2, Gmail, Graph e IMAP passam a conformar a este mesmo protocolo
/// e a UI não muda.
public protocol MailSource: Sendable {
    func accounts() async throws -> [Account]
    func messages() async throws -> [Message]
    func agenda() async throws -> [AgendaItem]
}

public struct InMemoryMailSource: MailSource {
    private let _accounts: [Account]
    private let _messages: [Message]
    private let _agenda: [AgendaItem]

    public init(accounts: [Account], messages: [Message], agenda: [AgendaItem]) {
        self._accounts = accounts
        self._messages = messages
        self._agenda = agenda
    }

    public static var fixtures: InMemoryMailSource {
        InMemoryMailSource(
            accounts: Fixtures.accounts,
            messages: Fixtures.messages,
            agenda: Fixtures.agenda
        )
    }

    public func accounts() async throws -> [Account] { _accounts }
    public func messages() async throws -> [Message] { _messages }
    public func agenda() async throws -> [AgendaItem] { _agenda }
}

@MainActor
@Observable
public final class MailStore {
    public private(set) var accounts: [Account] = []
    public private(set) var messages: [Message] = []
    public private(set) var agenda: [AgendaItem] = []

    public private(set) var bucket: TriageBucket = .today
    public private(set) var selectedMessageID: String?
    public var query: String = ""
    public private(set) var loadError: String?

    private let source: MailSource

    public init(source: MailSource) {
        self.source = source
    }

    public func load() async {
        do {
            accounts = try await source.accounts()
            messages = try await source.messages()
            agenda = try await source.agenda().sorted { $0.startMinute < $1.startMinute }
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Mensagens da caixa atual que casam com a busca, mais recentes primeiro.
    public var visibleMessages: [Message] {
        let inBucket = messages.filter { bucket.contains($0) }
        let searched = query.trimmingCharacters(in: .whitespaces).isEmpty
            ? inBucket
            : inBucket.filter { matches($0, query) }
        return searched.sorted { $0.receivedAt > $1.receivedAt }
    }

    private func matches(_ message: Message, _ term: String) -> Bool {
        [message.from.name, message.from.address, message.subject, message.snippet]
            .contains { $0.localizedCaseInsensitiveContains(term) }
    }

    public var selectedMessage: Message? {
        guard let selectedMessageID else { return nil }
        return messages.first { $0.id == selectedMessageID }
    }

    public func account(_ id: String) -> Account? {
        accounts.first { $0.id == id }
    }

    public func select(bucket newBucket: TriageBucket) {
        bucket = newBucket
        // Uma seleção que saiu da visão deixa o leitor mostrando algo que a
        // lista não contém mais. Melhor limpar.
        if let selected = selectedMessage, !newBucket.contains(selected) {
            selectedMessageID = nil
        }
    }

    public func select(message id: String) {
        selectedMessageID = id
        markRead(id)
    }

    private func markRead(_ id: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }),
              !messages[index].isRead else { return }
        let m = messages[index]
        messages[index] = Message(
            id: m.id, accountID: m.accountID, from: m.from, receivedAt: m.receivedAt,
            subject: m.subject, snippet: m.snippet, body: m.body, tags: m.tags,
            bucket: m.bucket, isRead: true, summary: m.summary,
            detectedEvent: m.detectedEvent
        )
    }

    /// Contagem por caixa, para os contadores da barra lateral.
    public func count(for bucket: TriageBucket) -> Int {
        messages.filter { bucket.contains($0) }.count
    }
}
```


- [ ] **Step 4: Write `Fixtures.swift`**

Copy the data of `MSGS`, `ACC` and `RAIL` from the prototype. The OKLCH colors of the already converted lines: `zoho` `oklch(0.52 0.10 255)` → `#3E6FA8`, `gmail` `oklch(0.52 0.10 300)` → `#7E5FB4`, `host` `oklch(0.52 0.09 155)` → `#2C7D5E`, `icloud` `oklch(0.55 0.08 200)` → `#3C87A0`.

Compare each conversion with the existing helper:

```bash
python3 -c "
import sys; sys.path.insert(0,'Tools')
from generate_themes import oklch_to_srgb
for nome,L,C,H in [('zoho',0.52,0.10,255),('gmail',0.52,0.10,300),
                   ('host',0.52,0.09,155),('icloud',0.55,0.08,200)]:
    r,g,b = oklch_to_srgb(L,C,H)
    print(f'{nome:8s} #%02X%02X%02X' % (round(r*255),round(g*255),round(b*255)))
"
```


Use the output of this command, not the values above, if they differ.

```swift
import Foundation

/// Dados do protótipo, para desenvolver e testar a UI antes dos backends.
///
/// As contas aqui são **exemplos** que o designer usou — não o escopo do
/// produto, que aceita quantas contas o usuário quiser, de qualquer provedor
/// e qualquer domínio. Nenhum teste deve afirmar a quantidade destas contas.
public enum Fixtures {

    public static let accounts: [Account] = [
        Account(id: "zoho", address: "ricardo@empresa.com",
                displayName: "Empresa", provider: .imap, tintHex: "#3E6FA8"),
        Account(id: "gmail", address: "ricardo@gmail.com",
                displayName: "Pessoal", provider: .gmail, tintHex: "#7E5FB4"),
        Account(id: "host", address: "contato@meusite.com",
                displayName: "Site", provider: .imap, tintHex: "#2C7D5E"),
        Account(id: "icloud", address: "ricardo@icloud.com",
                displayName: "iCloud", provider: .imap, tintHex: "#3C87A0"),
    ]

    /// Âncora fixa para os testes não dependerem do relógio.
    /// Terça, 25 de agosto de 2026 — o "hoje" do protótipo.
    public static let today: Date = {
        var c = DateComponents()
        c.year = 2026; c.month = 8; c.day = 25
        c.hour = 12; c.minute = 0
        c.timeZone = TimeZone(identifier: "America/Sao_Paulo")
        return Calendar(identifier: .gregorian).date(from: c)!
    }()

    private static func at(_ hour: Int, _ minute: Int) -> Date {
        Calendar.current.date(
            bySettingHour: hour, minute: minute, second: 0, of: today
        ) ?? today
    }

    public static let messages: [Message] = [
        Message(
            id: "m1", accountID: "zoho",
            from: Contact(name: "Marina Duarte", address: "marina@clientepremium.com"),
            receivedAt: at(9, 42),
            subject: "Revisão do contrato — podemos fechar quinta?",
            snippet: "Revisei as cláusulas 4 e 7. Consigo assinar se conseguirmos uma call quinta às 15h para alinhar o escopo de suporte.",
            body: [
                "Ricardo, tudo bem?",
                "Revisei as cláusulas 4 e 7 com o jurídico. A única pendência real é o escopo de suporte — queremos deixar claro o SLA de resposta em horário comercial.",
                "Consigo assinar ainda esta semana se conseguirmos uma call na quinta às 15h.",
            ],
            tags: [
                Tag(name: "Precisa resposta", tintHex: "#A8722B"),
                Tag(name: "Compromisso", tintHex: "#3E6FA8"),
            ],
            bucket: .today, isRead: false,
            summary: "Marina fecha o contrato com dois ajustes no escopo de suporte e pede uma call na quinta às 15h. Assinatura precisa sair até sexta — ela viaja depois.",
            detectedEvent: DetectedEvent(
                label: "Call de contrato · qui 27, 15:00",
                start: Calendar.current.date(byAdding: .day, value: 2, to: at(15, 0))!,
                duration: 3600
            )
        ),
        Message(
            id: "m2", accountID: "zoho",
            from: Contact(name: "Equipe Produto", address: "produto@empresa.com"),
            receivedAt: at(8, 30),
            subject: "Notas do standup — bloqueio no deploy",
            snippet: "Deu problema no certificado SSL de madrugada. Precisamos de uma decisão sua hoje.",
            body: [
                "Bom dia,",
                "O certificado SSL expirou às 03h. Subimos o provisório, mas a renovação definitiva precisa da sua aprovação.",
            ],
            tags: [
                Tag(name: "Precisa resposta", tintHex: "#A8722B"),
                Tag(name: "Equipe", tintHex: "#3E6FA8"),
            ],
            bucket: .today, isRead: false, summary: nil, detectedEvent: nil
        ),
        Message(
            id: "m3", accountID: "host",
            from: Contact(name: "Formulário do site", address: "contato@meusite.com"),
            receivedAt: at(7, 15),
            subject: "Novo lead: consultoria para 40 pessoas",
            snippet: "Empresa de logística, 40 funcionários, quer proposta de consultoria até o fim do mês.",
            body: [
                "Nome: Transportadora TransRota",
                "Mensagem: Precisamos de uma proposta de consultoria em segurança para 40 funcionários.",
            ],
            tags: [
                Tag(name: "Lead", tintHex: "#2C7D5E"),
                Tag(name: "Prazo", tintHex: "#A8722B"),
            ],
            bucket: .later, isRead: true, summary: nil, detectedEvent: nil
        ),
        Message(
            id: "m4", accountID: "gmail",
            from: Contact(name: "Boletim Swift", address: "news@swiftweekly.dev"),
            receivedAt: at(6, 0),
            subject: "Swift 6.3 e o que mudou em concorrência",
            snippet: "Resumo das mudanças de isolamento e o que quebra em projetos existentes.",
            body: ["Edição desta semana."],
            tags: [Tag(name: "Leitura", tintHex: nil)],
            bucket: .archived, isRead: true, summary: nil, detectedEvent: nil
        ),
    ]

    /// A trilha de "Terça, 25 de agosto" do protótipo, em minutos desde a meia-noite.
    public static let agenda: [AgendaItem] = [
        AgendaItem(id: "e1", title: "Standup produto",
                   startMinute: 570, endMinute: 600, accountID: "zoho"),
        AgendaItem(id: "e2", title: "1:1 Marina Duarte",
                   startMinute: 660, endMinute: 705, accountID: "zoho"),
        AgendaItem(id: "e3", title: "Almoço — bloqueado",
                   startMinute: 750, endMinute: 810, accountID: "icloud"),
        AgendaItem(id: "e4", title: "Revisão do contrato",
                   startMinute: 840, endMinute: 900, accountID: "zoho"),
        AgendaItem(id: "e5", title: "Foco: proposta TransRota",
                   startMinute: 990, endMinute: 1080, accountID: "host"),
    ]
}
```


- [ ] **Step 5: Run the tests**

Run: `cd Packages/UNICore && swift test`

Expected: PASS, 15 tests (5 of models + 10 from the store).

- [ ] **Step 6: Commit**

```bash
git add Packages/UNICore
git commit -m "UNICore: MailStore observável e fixtures do protótipo

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```


---

### Task 5: Brand assets, token modifiers and the 58px bar

**Files:**

- Create: `design/assets/uni-lockup-dark.png`, `uni-mark-light.png`, `uni-mark-dark.png`

- Create: `App/Resources/Assets.xcassets/` (4 image sets)

- Create: `Packages/UNIShell/Package.swift`

- Create: `Packages/UNIShell/Sources/UNIShell/Support/TokenModifiers.swift`

- Create: `Packages/UNIShell/Sources/UNIShell/Chrome/WindowChrome.swift`

- Modify: `App/OkamiUNIApp.swift`

- Modify: `project.yml`

- Test: `Packages/UNIShell/Tests/UNIShellTests/TokenModifierTests.swift`

**Interfaces:**

- Consumes: `UNIDesign.Theme`, `UNICore.TriageBucket`, `UNICore.MailStore`

- Produces: `View.hairline(_:edges:)`, `View.capsLabel(size:)`, `WindowChrome`, `enum Workspace { case mail, calendar }`

- [ ] **Step 1: Download the 3 missing assets**

Only `uni-lockup-light.png` was downloaded in Milestone 0. The other three are in the Claude
Design project `40478c81-e3be-42cc-aad1-f0c2d28d292c`: `uni-lockup-dark.png`,
`uni-mark-light.png`, `uni-mark-dark.png`.

For each one, call the `DesignSync` tool with `method: "get_file"`, this `projectId` and the `path` from the file. The response is JSON with `content` in base64 and `isBase64: true`. When the result is too large and is saved to a file, decode it like this (it was the path used in Marker 0):

```bash
python3 - <<'PY'
import json, base64, pathlib
# trocar pelo caminho que a ferramenta reportou e pelo nome do asset
src = "<caminho-do-resultado>.txt"
dest = "design/assets/uni-lockup-dark.png"
d = json.load(open(src, encoding="utf-8"))
pathlib.Path(dest).write_bytes(base64.b64decode(d["content"]))
print("ok", dest)
PY
file design/assets/*.png
```


Expected: `file` reports the four as `PNG image data` with plausible dimensions (the clear lockup is 587×162).

Then create the image sets. The names must be exactly `uni-lockup-light`, `uni-lockup-dark`, `uni-mark-light`, `uni-mark-dark` — that's what `WindowChrome` and `ReaderPane` already ask for in `Image(...)`.

```bash
for n in uni-lockup-light uni-lockup-dark uni-mark-light uni-mark-dark; do
  dir="App/Resources/Assets.xcassets/$n.imageset"
  mkdir -p "$dir"
  cp "design/assets/$n.png" "$dir/$n.png"
  cat > "$dir/Contents.json" <<JSON
{
  "images" : [
    { "filename" : "$n.png", "idiom" : "universal", "scale" : "1x" },
    { "idiom" : "universal", "scale" : "2x" },
    { "idiom" : "universal", "scale" : "3x" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON
done
cat > App/Resources/Assets.xcassets/Contents.json <<'JSON'
{ "info" : { "author" : "xcode", "version" : 1 } }
JSON
ls App/Resources/Assets.xcassets/
```


Expected: four folders `.imageset` plus the `Contents.json` root.

If the lockup comes in low resolution and pixelates at 38pt height, ask the design for a 2×/3× export instead of scaling the 1× - the bar is the first thing the person sees.

- [ ] **Step 2: Write `Package.swift`**

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "UNIShell",
    platforms: [.macOS(.v26)],
    products: [.library(name: "UNIShell", targets: ["UNIShell"])],
    dependencies: [
        .package(path: "../UNIDesign"),
        .package(path: "../UNICore"),
    ],
    targets: [
        .target(name: "UNIShell", dependencies: ["UNIDesign", "UNICore"]),
        .testTarget(name: "UNIShellTests", dependencies: ["UNIShell"]),
    ]
)
```


- [ ] **Step 3: Write the failing test**

```swift
import Testing
import SwiftUI
import UNIDesign
@testable import UNIShell

@Suite("Chrome")
struct TokenModifierTests {

    @Test("as duas áreas de trabalho batem com as abas do protótipo")
    func workspaceTabs() {
        #expect(Workspace.allCases.map(\.label) == ["Caixa", "Agenda"])
    }

    @Test("a barra tem a altura do design")
    func chromeHeight() {
        #expect(WindowChrome.height == 58)
    }

    @Test("o espaço reservado aos semáforos cobre os três botões")
    func trafficLightInset() {
        // Três botões de 12px com 8px de folga, mais a margem da janela.
        #expect(WindowChrome.trafficLightInset >= 68)
    }

    @Test("o texto da busca concorda com o número de contas", arguments: [
        (0, "Buscar"),
        (1, "Buscar na caixa…"),
        (4, "Buscar nas 4 caixas…"),
        (37, "Buscar nas 37 caixas…"),
    ])
    func searchPlaceholderAgrees(count: Int, expected: String) {
        #expect(WindowChrome.searchPlaceholder(count) == expected)
    }
}
```


- [ ] **Step 4: Run to see failure**

Run: `cd Packages/UNIShell && swift test`

Expected: FAIL — `cannot find 'Workspace' in scope`.

- [ ] **Step 5: Write `TokenModifiers.swift`**

```swift
import SwiftUI
import UNIDesign

extension View {
    /// A divisória de 0.5px que o design usa em toda parte.
    public func hairline(_ color: TokenColor, edges: Edge.Set = .bottom) -> some View {
        overlay(alignment: alignment(for: edges)) {
            Rectangle()
                .fill(color.color)
                .frame(
                    width: edges.contains(.leading) || edges.contains(.trailing) ? 0.5 : nil,
                    height: edges.contains(.top) || edges.contains(.bottom) ? 0.5 : nil
                )
        }
    }

    private func alignment(for edges: Edge.Set) -> Alignment {
        if edges.contains(.top) { return .top }
        if edges.contains(.leading) { return .leading }
        if edges.contains(.trailing) { return .trailing }
        return .bottom
    }
}

/// Rótulo em versalete que o design usa nos cabeçalhos de seção:
/// mono, minúsculo, caixa alta, muito espaçado.
public struct CapsLabel: ViewModifier {
    @Environment(\.theme) private var theme
    let size: CGFloat

    public func body(content: Content) -> some View {
        content
            .font(theme.mono.font(size: size, weight: .medium))
            .tracking(theme.capsTracking(at: size))
            .textCase(.uppercase)
            .foregroundStyle(theme.ink4.color)
    }
}

extension View {
    public func capsLabel(size: CGFloat = 9) -> some View {
        modifier(CapsLabel(size: size))
    }
}
```


- [ ] **Step 6: Write `WindowChrome.swift`**

```swift
import SwiftUI
import UNIDesign
import UNICore

public enum Workspace: String, CaseIterable, Sendable {
    case mail, calendar

    public var label: String {
        switch self {
        case .mail: "Caixa"
        case .calendar: "Agenda"
        }
    }
}

public struct WindowChrome: View {
    public static let height: CGFloat = 58
    /// Espaço à esquerda para os semáforos da janela, que continuam nativos.
    public static let trafficLightInset: CGFloat = 78

    /// O protótipo diz "Buscar nas 4 caixas…" porque tinha quatro contas.
    /// Como a quantidade é do usuário, o texto concorda com ela.
    public static func searchPlaceholder(_ accountCount: Int) -> String {
        switch accountCount {
        case 0: "Buscar"
        case 1: "Buscar na caixa…"
        default: "Buscar nas \(accountCount) caixas…"
        }
    }

    @Environment(\.theme) private var theme
    @Binding var workspace: Workspace
    @Binding var query: String
    let accountCount: Int
    let onToggleSidebar: () -> Void

    public init(
        workspace: Binding<Workspace>,
        query: Binding<String>,
        accountCount: Int,
        onToggleSidebar: @escaping () -> Void
    ) {
        self._workspace = workspace
        self._query = query
        self.accountCount = accountCount
        self.onToggleSidebar = onToggleSidebar
    }

    public var body: some View {
        HStack(spacing: 14) {
            Color.clear.frame(width: Self.trafficLightInset - 14, height: 1)

            sidebarToggle

            Image(theme.isDark ? "uni-lockup-dark" : "uni-lockup-light")
                .resizable()
                .scaledToFit()
                .frame(height: 38)
                .accessibilityLabel("OkamiUNI")

            workspaceTabs

            searchField
                .frame(maxWidth: .infinity)

            // O seletor de temas entra aqui na Task 6. Até lá, um vazio do
            // tamanho do botão para o espaçamento da barra já ficar certo.
            Color.clear.frame(width: 96, height: 26)
        }
        .padding(.horizontal, 14)
        .frame(height: Self.height)
        .background(theme.surface2.color)
        .hairline(theme.line, edges: .bottom)
    }

    private var sidebarToggle: some View {
        Button(action: onToggleSidebar) {
            HStack(spacing: 2.5) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(theme.ink3.color)
                    .frame(width: 3, height: 11)
                RoundedRectangle(cornerRadius: 1)
                    .strokeBorder(theme.ink4.color, lineWidth: 0.5)
                    .frame(width: 7, height: 11)
            }
            .frame(width: 26, height: 24)
            .background(theme.btn.color)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(theme.btnLine.color, lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Mostrar ou esconder a barra lateral")
    }

    private var workspaceTabs: some View {
        HStack(spacing: 2) {
            ForEach(Workspace.allCases, id: \.self) { tab in
                let active = tab == workspace
                Button { workspace = tab } label: {
                    Text(tab.label)
                        .font(theme.sans.font(size: 12, weight: active ? .semibold : .regular))
                        .foregroundStyle((active ? theme.ink : theme.ink3).color)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background {
                            if active {
                                RoundedRectangle(cornerRadius: theme.radiusSmall - 2)
                                    .fill(theme.surface.color)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(theme.surface3.color)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Circle()
                .strokeBorder(theme.ink4.color, lineWidth: 1.5)
                .frame(width: 10, height: 10)
            TextField(Self.searchPlaceholder(accountCount), text: $query)
                .textFieldStyle(.plain)
                .font(theme.sans.font(size: 12.5))
                .foregroundStyle(theme.ink.color)
            Text("⌘K")
                .font(theme.mono.font(size: 10))
                .foregroundStyle(theme.ink4.color)
        }
        .padding(.horizontal, 10)
        .frame(width: 400, height: 28)
        .background(theme.surface.color)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
        .overlay {
            RoundedRectangle(cornerRadius: theme.radiusSmall)
                .strokeBorder(theme.line.color, lineWidth: 0.5)
        }
    }
}
```


- [ ] **Step 7: Add `UNIShell` to `project.yml`**

In `packages`:

```yaml
  UNICore:
    path: Packages/UNICore
  UNIShell:
    path: Packages/UNIShell
```


In `targets.OkamiUNI.dependencies`:

```yaml
      - package: UNICore
        product: UNICore
      - package: UNIShell
        product: UNIShell
```


- [ ] **Step 8: Run the tests**

Run: `cd Packages/UNIShell && swift test`

Expected: PASS, 4 tests.

- [ ] **Step 9: Commit**

```bash
git add Packages/UNIShell project.yml
git commit -m "UNIShell: modificadores de token e a barra de 58px

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```


---

### Task 6: Theme selector

**Files:**

- Create: `Packages/UNIShell/Sources/UNIShell/Chrome/ThemePicker.swift`

- Test: `Packages/UNIShell/Tests/UNIShellTests/ThemePickerTests.swift`

**Interfaces:**

- Consumes: `UNIDesign.ThemeStore`, `UNIDesign.Theme.all`

- Produces: `ThemePicker`, `ThemePreview`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
import UNIDesign
@testable import UNIShell

@Suite("ThemePicker")
struct ThemePickerTests {

    @Test("o seletor oferece os 26 temas")
    @MainActor
    func offersEveryTheme() {
        let store = ThemeStore(defaults: UserDefaults(suiteName: #function)!)
        #expect(store.all.count == 26)
    }

    @Test("a escolha sobrevive a uma nova instância")
    @MainActor
    func choicePersists() throws {
        let suite = UserDefaults(suiteName: #function)!
        suite.removePersistentDomain(forName: #function)

        let first = ThemeStore(defaults: suite)
        let okami = try #require(Theme.named("okami"))
        first.select(okami)

        let second = ThemeStore(defaults: suite)
        #expect(second.theme.id == "okami")
    }

    @Test("um id salvo inválido cai no tema padrão em vez de travar")
    @MainActor
    func invalidSavedIDFallsBack() {
        let suite = UserDefaults(suiteName: #function)!
        suite.removePersistentDomain(forName: #function)
        suite.set("tema-que-nao-existe", forKey: "okamiuni.theme")

        let store = ThemeStore(defaults: suite)
        #expect(store.theme.id == Theme.default.id)
    }
}
```


- [ ] **Step 2: Run to see failure**

Run: `cd Packages/UNIShell && swift test --filter ThemePicker`

Expected: FAIL in compilation — `ThemePicker` does not exist.

- [ ] **Step 3: Write `ThemePicker.swift`**

Each card is a miniature window: a bar with two dots, a sidebar, and a body with two lines.

```swift
import SwiftUI
import UNIDesign

public struct ThemePicker: View {
    @Environment(\.theme) private var theme
    @Environment(ThemeStore.self) private var store
    @State private var open = false

    public init() {}

    public var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(theme.accent.color)
                    .frame(width: 8, height: 8)
                Text(theme.name)
                    .font(theme.sans.font(size: 11.5))
                    .foregroundStyle(theme.ink2.color)
                Text("▼")
                    .font(.system(size: 7))
                    .foregroundStyle(theme.ink3.color)
            }
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(theme.btn.color)
            .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
            .overlay {
                RoundedRectangle(cornerRadius: theme.radiusSmall)
                    .strokeBorder(theme.btnLine.color, lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Escolher tema, atual \(theme.name)")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            popoverBody
        }
    }

    private var popoverBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Temas · cor, tipo e densidade")
                .capsLabel()
                .padding(.horizontal, 8)
                .padding(.top, 4)
                .padding(.bottom, 8)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(store.all) { candidate in
                        Button { store.select(candidate); open = false } label: {
                            ThemeRow(
                                candidate: candidate,
                                isCurrent: candidate.id == theme.id
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 420)
        }
        .padding(8)
        .frame(width: 300)
        .background(theme.surface.color)
    }
}

private struct ThemeRow: View {
    @Environment(\.theme) private var theme
    let candidate: Theme
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 10) {
            ThemePreview(candidate: candidate)
            VStack(alignment: .leading, spacing: 1) {
                Text(candidate.name)
                    .font(theme.sans.font(size: 12, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(theme.ink.color)
                Text(candidate.isDark ? "escuro" : "claro")
                    .font(theme.mono.font(size: 9))
                    .foregroundStyle(theme.ink4.color)
            }
            Spacer()
            if isCurrent {
                Circle().fill(theme.accent.color).frame(width: 6, height: 6)
            }
        }
        .padding(6)
        .contentShape(Rectangle())
        .background {
            RoundedRectangle(cornerRadius: theme.radiusSmall)
                .fill(isCurrent ? theme.accentSoft.color : .clear)
        }
    }
}

/// Miniatura da janela no tema candidato.
struct ThemePreview: View {
    let candidate: Theme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                Circle().fill(candidate.ink4.color).frame(width: 3, height: 3)
                Circle().fill(candidate.ink4.color).frame(width: 3, height: 3)
                Spacer()
            }
            .padding(.horizontal, 4)
            .frame(height: 9)
            .background(candidate.surface2.color)

            HStack(spacing: 0) {
                candidate.surface3.color.frame(width: 12)
                VStack(alignment: .leading, spacing: 3) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(candidate.accent.color)
                        .frame(width: 22, height: 3)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(candidate.ink4.color)
                        .frame(width: 30, height: 2)
                }
                .padding(.leading, 5)
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity)
            .background(candidate.surface.color)
        }
        .frame(width: 54, height: 38)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(candidate.line.color, lineWidth: 0.5)
        }
    }
}
```


- [ ] **Step 4: Run the tests**

Run: `cd Packages/UNIShell && swift test`

Expected: PASS, 7 tests.

- [ ] **Step 5: Turn on the selector on the bar**

In `WindowChrome.swift`, change the blank space that Task 5 left:

```swift
            // antes
            Color.clear.frame(width: 96, height: 26)

            // depois
            ThemePicker()
```


- [ ] **Step 6: Check in the app**

Generate and open.

Run: `xcodegen generate && xcodebuild -project OkamiUNI.xcodeproj -scheme OkamiUNI build && open ...`

Expected: click on "Tinta" opens the popover with 26 thumbnails; choose "Okami" changes the entire window to onyx with the orange `#FF7527`; closing and reopening the app keeps Okami.

- [ ] **Step 7: Commit**

```bash
git add Packages/UNIShell
git commit -m "Seletor de temas com as 26 miniaturas, escolha persistida

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```


---

### Task 7: Account filter and expanded sidebar

The original plan described this sidebar incorrectly in nearly every respect. The values below were extracted from the prototype and are correct.

**Files:**

- Modify: `Packages/UNICore/Sources/UNICore/Account.swift`

- Modify: `Packages/UNICore/Sources/UNICore/MessageStore.swift`

- Modify: `Packages/UNICore/Sources/UNICore/Fixtures/Fixtures.swift`

- Modify: `Packages/UNICore/Tests/UNICoreTests/StoreTests.swift`

- Rewrite: `Packages/UNIShell/Sources/UNIShell/Inbox/FolderSidebar.swift`

- Modify: `Packages/UNIShell/Tests/UNIShellTests/SidebarTests.swift`

**Interfaces:**

- Consumes: `Theme`, `MailStore`, `TriageBucket`, `Account`

- Produces: `Account.tint(isDark:)`, `MailStore.selectedAccountID`,

`MailStore.select(account:)`, filter-sensitive `MailStore.count(for:)`,

`FolderSidebar`, `FolderSidebar.expandedWidth` (= 236)

### Part A — the model learns the filter by account

In the prototype, clicking an account filters the list, and folder counters count only that account. Clicking the same account again disables the filter.

The prototype code:

```js
onPick: () => this.setState({ account: on ? null : k })
// e nos contadores:
MSGS.filter(m => (v.id === 'todos' ? true : bucketOf(m) === v.id) && (!st.account || m.acc === st.account))
```


`MailStore` gains:

- `public private(set) var selectedAccountID: String?`

- `public func select(account id: String?)` — pass the already selected ID turns off the filter

- `visibleMessages` applies the account filter together with bucket and search

- `count(for:)` respects the account filter

### Part B — account colors that adapt to the theme

The prototype changes each account’s color according to the theme because the light color lacks contrast on a dark background:

```js
// tema claro:  ACC[k].c        — L ~0.52
// temas escuros: L sobe para ~0.78-0.80
DK = { zoho: oklch(0.78 0.10 255), gmail: oklch(0.78 0.11 300),
       host: oklch(0.80 0.10 155), icloud: oklch(0.80 0.09 200) }
```


`Account.tintHex` becomes two fields, `tintLightHex` and `tintDarkHex`, plus
`public func tint(isDark: Bool) -> String`. Convert the OKLCH values above to hex with
`Tools/generate_themes.py` (the `oklch_to_srgb` function) and use its actual output.

### Part C — the expanded bar, with the prototype values

Container: width **236**, `surface2` background, `0.5px line` right border,

`padding-top: 14`, and 180ms width transition.

Section header (both): mono **9.5px**, caps, tracking `capsTracking`, color `ink4`.

- "**Fluxo**" with padding `0 16px 7px`  (the old plan said "Pastas" — wrong)

- "**Caixas**" with padding `22px 16px 7px`

Folder row (`views`): height **30**, gap **9**, padding `0 8`, radius `radiusSmall`.

- label 13px weight 500, occupying the free space

- counter in mono 10px

- selected: color `accentInk`, background `accentSoft`, counter also `accentInk`

- not selected: color `ink2`, counter `ink4`, transparent background

Account row (`accounts`): height **32**, gap **8**, padding `0 8`, radius `radiusSmall`.

- host chip on the left: mono **9px**, tracking 0.06em, caps, padding `2px 6px 1.5px`,
  radius 4, account-tint foreground, 14% tint background (22% when selected), and a
  `0.5px` tint border at 32%

- label (address) 12.5px, truncated with an ellipsis, occupying the free space

- counter in mono 10px, `ink4`

- selected: background = tint at 16% and an inner bar of 2px on the left in the tint color

(in CSS it is `box-shadow: inset 2px 0 0`; in SwiftUI, a 2px rectangle aligned to the left)

Footer, fixed at the end (`margin-top: auto`), padding 16, top border `0.5px line`:

- a 5px point in the semantic color "ok" (green), gap 7

- "**Triagem local ativa**" — 11.5px, weight 590, `ink2`

- "**Classificação, resumo e busca semântica rodam no Mac. Nada sai daqui.**"

- 11px, line-height 1.5, `ink3`

This footer is a product promise, not decoration. The text will go verbatim.

#### Steps

- [ ] **Step 1: Write the failing tests** — in UNICore, cover account filtering: filtering
  reduces `visibleMessages`; clicking the selected account again disables it;
  `count(for:)` respects it; and account filtering combines with search. In UNIShell, retain
  existing scalability tests and add one that fixes `expandedWidth == 236`. Every test must
  fail before implementation — run and confirm it.

- [ ] **Step 2: Implement Part A** (the `MailStore` filter), then run UNICore tests until
  they pass.

- [ ] **Step 3: Implement Part B** (tint by theme). Convert the OKLCH values with the helper
  and record the result in the report.

- [ ] **Step 4: Rewrite the `FolderSidebar`** with the values from Part C.

- [ ] **Step 5: Verify against the prototype.** Open the app and compare with the `.dc.html`:
  width, "Fluxo", host chips, counters, selected-account left bar, and footer. Switch to a
  dark theme and confirm that account colors become lighter.

- [ ] **Step 6: Commit.**

---

### Task 7B: 62px collapsed rail

The 58px bar button does not hide the sidebar: it replaces it with a narrow rail. The original plan treated this as show/hide behavior — incorrectly.

**Files:**

- Create: `Packages/UNIShell/Sources/UNIShell/Inbox/SidebarRail.swift`

- Modify: `Packages/UNIShell/Sources/UNIShell/Inbox/FolderSidebar.swift`

- Test: `Packages/UNIShell/Tests/UNIShellTests/SidebarRailTests.swift`

**Interfaces:**

- Consumes: `MailStore`, `Theme`, `TriageBucket`

- Produces: `SidebarRail`, `SidebarRail.width` (= 62)

Container: width **62**, `surface2` background, `0.5px line` right border, centered content, padding `14px 0`.

Folder button: **46×40**, radius `radiusSmall`, centered column, gap 3.

- abbreviation in mono **8.5px**, tracking 0.06em, caps: `hoje`, `dep`, `tudo`, `arq`

(in this order, corresponding to Today/Later/All/Archived)

- counter 13px weight 650

- selected: color `accentInk`, background `accentSoft`, border `0.5px accentLine`

- not selected: color `ink3`, transparent background

Divider: 26px wide, `0.5px line`, vertical margin 8.

Label "caixas": mono **7.5px**, tracking 0.08em, caps, `ink4`, bottom margin 2.

Account mark: **40×24**, radius `radiusSmall`, mono 10px weight 500, centralized.

- text = the **first 3 letters of the host** (`zoh`, `gma`, `hos`, `icl`)

- color = account tint; background = 12% tint (26% when selected);

`0.5px` border in the tint at 26% (70% when selected)

- each carries the full address in `.help()`

#### Steps

- [ ] **Step 1: Write the failing tests** — `SidebarRail.width == 62`; the

Abbreviations of the four folders in the correct order; the account number is the first 3 digits

Host letters; the track can hold 0 and 25 accounts.

- [ ] **Step 2: Run and see it fail.**

- [ ] **Step 3: Implement `SidebarRail`.**

- [ ] **Step 4: Turn on the toggle.** The bar button alternates between `FolderSidebar`

(236px) and `SidebarRail` (62px) — never hides everything. Cheer with the transition of

180ms that the prototype uses.

- [ ] **Step 5: Check in the app.** Click the go and return button between the two states,

The folder and account selection survive the exchange.

- [ ] **Step 6: Commit.**

---

### Task 8: Grouped message list

The 370px design panel. The messages come grouped by day, with a bold header.

**Files:**

- Create: `Packages/UNIShell/Sources/UNIShell/Inbox/MessageRow.swift`

- Create: `Packages/UNIShell/Sources/UNIShell/Inbox/MessageList.swift`

- Test: `Packages/UNIShell/Tests/UNIShellTests/MessageListTests.swift`

**Interfaces:**

- Consumes: `MailStore.visibleMessages`, `MailStore.select(message:)`, `Message`, `Tag`

- Produces: `MessageList`, `MessageList.width` (= 370), `MessageRow`, `MessageGroup`

- [ ] **Step 1: Write down the failing tests**

```swift
import Testing
import Foundation
import UNICore
@testable import UNIShell

@Suite("MessageList")
struct MessageListTests {

    @Test("mensagens se agrupam por dia, mais recente primeiro")
    @MainActor
    func groupsByDay() async {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        store.select(bucket: .all)

        let groups = MessageGroup.build(from: store.visibleMessages)
        #expect(groups.isEmpty == false)
        // Cada grupo carrega ao menos uma mensagem e nenhuma se perde.
        let regrouped = groups.flatMap(\.messages).count
        #expect(regrouped == store.visibleMessages.count)
    }

    @Test("o rótulo do grupo de hoje é 'Hoje'")
    @MainActor
    func todayLabel() {
        let groups = MessageGroup.build(from: [Message.preview()])
        #expect(groups.first?.label == "Hoje")
    }

    @Test("lista vazia não gera grupo vazio")
    func noEmptyGroups() {
        #expect(MessageGroup.build(from: []).isEmpty)
    }

    @Test("a largura da lista é a do design")
    func width() {
        #expect(MessageList.width == 370)
    }
}
```


- [ ] **Step 2: Run to see failure**

Run: `cd Packages/UNIShell && swift test --filter MessageList`

Expected: FAIL — `MessageGroup` does not exist.

- [ ] **Step 3: Write `MessageRow.swift`**

The anatomy of the line, straight from the prototype: sender to the left and time to the right; subject; paragraph in two lines; footer with the account host and the labels.

```swift
import SwiftUI
import UNIDesign
import UNICore

public struct MessageRow: View {
    @Environment(\.theme) private var theme
    let message: Message
    let accountHost: String
    let isSelected: Bool

    public init(message: Message, accountHost: String, isSelected: Bool) {
        self.message = message
        self.accountHost = accountHost
        self.isSelected = isSelected
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(message.from.name)
                    .font(theme.sans.font(size: 12.5, weight: message.isRead ? .regular : .semibold))
                    .foregroundStyle(theme.ink.color)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(message.receivedAt, format: .dateTime.hour().minute())
                    .font(theme.mono.font(size: 10))
                    .foregroundStyle(theme.ink4.color)
            }

            Text(message.subject)
                .font(theme.body.font(size: theme.subjectSize, weight: theme.subjectWeight))
                .foregroundStyle(theme.ink.color)
                .lineLimit(1)

            Text(message.snippet)
                .font(theme.sans.font(size: 11.5))
                .foregroundStyle(theme.ink3.color)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 5) {
                Text(accountHost)
                    .font(theme.mono.font(size: 9))
                    .foregroundStyle(theme.ink4.color)
                ForEach(message.tags) { tag in
                    TagChip(tag: tag)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
        }
        .padding(theme.rowPadding.edgeInsets)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? theme.accentSoft.color : .clear)
        .hairline(theme.line2, edges: .bottom)
        .contentShape(Rectangle())
    }
}

struct TagChip: View {
    @Environment(\.theme) private var theme
    let tag: Tag

    var body: some View {
        let tint = tag.tintHex.flatMap(TokenColor.init(css:)) ?? theme.ink3
        Text(tag.name)
            .font(theme.mono.font(size: 8.5, weight: .medium))
            .tracking(theme.capsTracking(at: 8.5))
            .textCase(.uppercase)
            .foregroundStyle(tint.color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(tint.color.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}
```


- [ ] **Step 4: Write `MessageList.swift`**

```swift
import SwiftUI
import UNIDesign
import UNICore

/// Um dia de mensagens, com o rótulo que a lista mostra no cabeçalho.
public struct MessageGroup: Identifiable {
    public let id: String
    public let label: String
    public let messages: [Message]

    /// Agrupa por dia preservando a ordem que veio (mais recente primeiro).
    public static func build(
        from messages: [Message],
        calendar: Calendar = .current,
        now: Date = .now
    ) -> [MessageGroup] {
        guard !messages.isEmpty else { return [] }

        var order: [Date] = []
        var byDay: [Date: [Message]] = [:]
        for message in messages {
            let day = calendar.startOfDay(for: message.receivedAt)
            if byDay[day] == nil { order.append(day) }
            byDay[day, default: []].append(message)
        }

        return order.map { day in
            MessageGroup(
                id: ISO8601DateFormatter().string(from: day),
                label: label(for: day, calendar: calendar, now: now),
                messages: byDay[day] ?? []
            )
        }
    }

    private static func label(for day: Date, calendar: Calendar, now: Date) -> String {
        if calendar.isDateInToday(day) { return "Hoje" }
        if calendar.isDateInYesterday(day) { return "Ontem" }
        return day.formatted(.dateTime.day().month(.abbreviated))
    }
}

public struct MessageList: View {
    public static let width: CGFloat = 370

    @Environment(\.theme) private var theme
    let store: MailStore

    public init(store: MailStore) {
        self.store = store
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            if store.visibleMessages.isEmpty {
                empty
            } else {
                list
            }
        }
        .frame(width: Self.width)
        .background(theme.surface.color)
        .hairline(theme.line, edges: .trailing)
    }

    private var header: some View {
        HStack {
            Text(store.bucket.label)
                .font(theme.sans.font(size: 12.5, weight: .semibold))
                .foregroundStyle(theme.ink.color)
            Spacer()
            Text("\(store.visibleMessages.count) mensagens")
                .font(theme.mono.font(size: 9.5))
                .foregroundStyle(theme.ink4.color)
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
        .background(theme.surface2.color)
        .hairline(theme.line, edges: .bottom)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(MessageGroup.build(from: store.visibleMessages)) { group in
                    Section {
                        ForEach(group.messages) { message in
                            Button { store.select(message: message.id) } label: {
                                MessageRow(
                                    message: message,
                                    accountHost: store.account(message.accountID)?.host ?? "",
                                    isSelected: message.id == store.selectedMessageID
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text(group.label)
                            .capsLabel()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background(theme.surface.color)
                    }
                }
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Spacer()
            Text(store.query.isEmpty ? "Fim da lista" : "Nada encontrado")
                .font(theme.sans.font(size: 12))
                .foregroundStyle(theme.ink4.color)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
```


- [ ] **Step 5: Run the tests**

Run: `cd Packages/UNIShell && swift test`

Expected: PASS, 13 tests.

- [ ] **Step 6: Commit**

```bash
git add Packages/UNIShell
git commit -m "Lista de mensagens agrupada por dia, com etiquetas

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```


---

### Task 9: Reading panel

**Files:**

- Create: `Packages/UNIShell/Sources/UNIShell/Inbox/ReaderPane.swift`

- Test: `Packages/UNIShell/Tests/UNIShellTests/ReaderTests.swift`

**Interfaces:**

- Consumes: `MailStore.selectedMessage`, `Message.summary`, `Message.detectedEvent`

- Produces: `ReaderPane`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import UNICore
@testable import UNIShell

@Suite("ReaderPane")
struct ReaderTests {

    @Test("sem seleção não há o que ler")
    @MainActor
    func noSelection() async {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        #expect(store.selectedMessage == nil)
    }

    @Test("a mensagem m1 traz resumo e compromisso detectado")
    @MainActor
    func summaryAndEvent() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        store.select(bucket: .all)
        store.select(message: "m1")

        let selected = try #require(store.selectedMessage)
        #expect(selected.summary?.isEmpty == false)
        let event = try #require(selected.detectedEvent)
        #expect(event.label.contains("15:00"))
        #expect(event.end > event.start)
    }

    @Test("a mensagem m2 não tem compromisso — a faixa não deve aparecer")
    @MainActor
    func noEvent() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        store.select(bucket: .all)
        store.select(message: "m2")
        #expect(try #require(store.selectedMessage).detectedEvent == nil)
    }
}
```


- [ ] **Step 2: Run to see failure**

Run: `cd Packages/UNIShell && swift test --filter ReaderPane`

Expected: FAIL in compilation.

- [ ] **Step 3: Write `ReaderPane.swift`**

```swift
import SwiftUI
import UNIDesign
import UNICore

public struct ReaderPane: View {
    @Environment(\.theme) private var theme
    let store: MailStore
    let onAddEvent: (DetectedEvent) -> Void

    public init(store: MailStore, onAddEvent: @escaping (DetectedEvent) -> Void) {
        self.store = store
        self.onAddEvent = onAddEvent
    }

    public var body: some View {
        Group {
            if let message = store.selectedMessage {
                content(message)
            } else {
                empty
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.surface.color)
    }

    private func content(_ message: Message) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                triageBar(message)

                Text(message.subject)
                    .font(theme.body.font(size: 21, weight: .medium))
                    .foregroundStyle(theme.ink.color)
                    .padding(.horizontal, 24)
                    .padding(.top, 16)

                sender(message)

                if let summary = message.summary {
                    summaryCard(summary, event: message.detectedEvent)
                        .padding(.horizontal, 24)
                        .padding(.top, 14)
                }

                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(message.body.enumerated()), id: \.offset) { _, para in
                        Text(para)
                            .font(theme.body.font(size: 14))
                            .foregroundStyle(theme.ink.color)
                            .lineSpacing(5)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 28)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func triageBar(_ message: Message) -> some View {
        HStack(spacing: 6) {
            ForEach(TriageBucket.allCases.filter { $0 != .all }, id: \.self) { bucket in
                Text(bucket == .archived ? "Arquivar" : bucket.label)
                    .font(theme.sans.font(size: 11))
                    .foregroundStyle(theme.ink2.color)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(theme.btn.color)
                    .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
                    .overlay {
                        RoundedRectangle(cornerRadius: theme.radiusSmall)
                            .strokeBorder(theme.btnLine.color, lineWidth: 0.5)
                    }
            }
            Spacer()
            Text(store.account(message.accountID)?.address ?? "")
                .font(theme.mono.font(size: 9))
                .foregroundStyle(theme.ink4.color)
        }
        .padding(.horizontal, 24)
        .frame(height: 44)
        .background(theme.surface2.color)
        .hairline(theme.line, edges: .bottom)
    }

    private func sender(_ message: Message) -> some View {
        HStack(spacing: 10) {
            Text(message.from.initials)
                .font(theme.mono.font(size: 10, weight: .medium))
                .foregroundStyle(theme.onAccent.color)
                .frame(width: 26, height: 26)
                .background(theme.accent.color)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(message.from.display)
                    .font(theme.sans.font(size: 12))
                    .foregroundStyle(theme.ink2.color)
                Text(message.receivedAt, format: .dateTime.day().month(.abbreviated).hour().minute())
                    .font(theme.mono.font(size: 9.5))
                    .foregroundStyle(theme.ink4.color)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
    }

    private func summaryCard(_ summary: String, event: DetectedEvent?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Resumo no dispositivo").capsLabel()
            Text(summary)
                .font(theme.sans.font(size: 12.5))
                .foregroundStyle(theme.ink2.color)
                .fixedSize(horizontal: false, vertical: true)

            if let event {
                Divider().overlay(theme.accentLine.color)
                HStack(spacing: 10) {
                    Text("Compromisso detectado — \(event.label)")
                        .font(theme.sans.font(size: 11.5))
                        .foregroundStyle(theme.ink2.color)
                    Spacer(minLength: 8)
                    Button { onAddEvent(event) } label: {
                        Text("Colocar na agenda")
                            .font(theme.sans.font(size: 11, weight: .medium))
                            .foregroundStyle(theme.onAccent.color)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(theme.accent.color)
                            .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .background(theme.accentSoft.color)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusLarge))
        .overlay {
            RoundedRectangle(cornerRadius: theme.radiusLarge)
                .strokeBorder(theme.accentLine.color, lineWidth: 0.5)
        }
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(theme.isDark ? "uni-mark-dark" : "uni-mark-light")
                .resizable()
                .scaledToFit()
                .frame(width: 44)
                .opacity(0.35)
            Text("Nada aqui. Bom sinal.")
                .font(theme.sans.font(size: 12.5))
                .foregroundStyle(theme.ink4.color)
        }
    }
}
```


- [ ] **Step 4: Run the tests**

Run: `cd Packages/UNIShell && swift test`

Expected: PASS, 16 tests.

- [ ] **Step 5: Commit**

```bash
git add Packages/UNIShell
git commit -m "Painel de leitura com resumo e compromisso detectado

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```


---

### Task 10: Agenda trail

**Files:**

- Create: `Packages/UNIShell/Sources/UNIShell/Inbox/AgendaRail.swift`

- Test: `Packages/UNIShell/Tests/UNIShellTests/AgendaRailTests.swift`

**Interfaces:**

- Consumes: `MailStore.agenda`, `AgendaItem`

- Produces: `AgendaRail`, `AgendaRail.width` (= 262), `AgendaRail.Layout`

- [ ] **Step 1: Write down the failing tests**

```swift
import Testing
import UNICore
@testable import UNIShell

@Suite("AgendaRail")
struct AgendaRailTests {

    private let layout = AgendaRail.Layout(
        firstHour: 8, lastHour: 19, pointsPerHour: 44
    )

    @Test("a trilha tem a largura do design")
    func width() {
        #expect(AgendaRail.width == 262)
    }

    @Test("um compromisso das 09:30 às 10:00 cai na posição certa")
    func placesEvent() {
        let standup = AgendaItem(
            id: "e1", title: "Standup produto",
            startMinute: 570, endMinute: 600, accountID: "zoho"
        )
        // 09:30 é 1,5h depois das 08:00 -> 66pt
        #expect(layout.offset(for: standup) == 66)
        #expect(layout.height(for: standup) == 22)
    }

    @Test("compromissos curtos ainda têm altura clicável")
    func minimumHeight() {
        let tiny = AgendaItem(
            id: "x", title: "Rápido",
            startMinute: 600, endMinute: 605, accountID: "zoho"
        )
        #expect(layout.height(for: tiny) >= AgendaRail.Layout.minimumHeight)
    }

    @Test("a trilha cobre a jornada inteira do dia")
    func totalHeight() {
        #expect(layout.totalHeight == 11 * 44)
    }

    @Test("o rótulo de início é HH:MM")
    func startLabel() {
        let item = AgendaItem(id: "e", title: "T", startMinute: 570, endMinute: 600, accountID: "z")
        #expect(item.startLabel == "09:30")
    }
}
```


- [ ] **Step 2: Run to see failure**

Run: `cd Packages/UNIShell && swift test --filter AgendaRail`

Expected: FAIL in compilation.

- [ ] **Step 3: Write `AgendaRail.swift`**

```swift
import SwiftUI
import UNIDesign
import UNICore

public struct AgendaRail: View {
    public static let width: CGFloat = 262

    /// Converte minutos do dia em pontos na trilha.
    public struct Layout: Sendable {
        public static let minimumHeight: CGFloat = 18

        public let firstHour: Int
        public let lastHour: Int
        public let pointsPerHour: CGFloat

        public init(firstHour: Int, lastHour: Int, pointsPerHour: CGFloat) {
            self.firstHour = firstHour
            self.lastHour = lastHour
            self.pointsPerHour = pointsPerHour
        }

        public var totalHeight: CGFloat {
            CGFloat(lastHour - firstHour) * pointsPerHour
        }

        public func offset(for item: AgendaItem) -> CGFloat {
            CGFloat(item.startMinute - firstHour * 60) / 60 * pointsPerHour
        }

        public func height(for item: AgendaItem) -> CGFloat {
            max(
                Self.minimumHeight,
                CGFloat(item.durationMinutes) / 60 * pointsPerHour
            )
        }
    }

    @Environment(\.theme) private var theme
    let store: MailStore
    let layout: Layout

    public init(
        store: MailStore,
        layout: Layout = Layout(firstHour: 8, lastHour: 19, pointsPerHour: 44)
    ) {
        self.store = store
        self.layout = layout
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                ZStack(alignment: .topLeading) {
                    hourLines
                    ForEach(store.agenda) { item in
                        eventBlock(item)
                            .offset(y: layout.offset(for: item))
                    }
                }
                .frame(height: layout.totalHeight, alignment: .top)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
        .frame(width: Self.width)
        .background(theme.surface2.color)
        .hairline(theme.line, edges: .leading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Date.now, format: .dateTime.weekday(.wide).day().month(.wide))
                .font(theme.sans.font(size: 12, weight: .semibold))
                .foregroundStyle(theme.ink.color)
            Text("\(store.agenda.count) compromissos")
                .capsLabel()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .hairline(theme.line, edges: .bottom)
    }

    private var hourLines: some View {
        VStack(spacing: 0) {
            ForEach(layout.firstHour..<layout.lastHour, id: \.self) { hour in
                HStack(alignment: .top, spacing: 6) {
                    Text(String(format: "%02d", hour))
                        .font(theme.mono.font(size: 8.5))
                        .foregroundStyle(theme.ink4.color)
                        .frame(width: 16, alignment: .trailing)
                    Rectangle()
                        .fill(theme.line2.color)
                        .frame(height: 0.5)
                    Spacer(minLength: 0)
                }
                .frame(height: layout.pointsPerHour, alignment: .top)
            }
        }
    }

    private func eventBlock(_ item: AgendaItem) -> some View {
        let tint = store.account(item.accountID)
            .flatMap { TokenColor(css: $0.tintHex) } ?? theme.accent

        return HStack(spacing: 0) {
            Rectangle()
                .fill(tint.color)
                .frame(width: 2.5)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(theme.sans.font(size: 11, weight: .medium))
                    .foregroundStyle(theme.ink.color)
                    .lineLimit(1)
                Text(item.startLabel)
                    .font(theme.mono.font(size: 8.5))
                    .foregroundStyle(theme.ink3.color)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            Spacer(minLength: 0)
        }
        .frame(height: layout.height(for: item), alignment: .top)
        .background(tint.color.opacity(theme.isDark ? 0.18 : 0.10))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .padding(.leading, 24)
    }
}
```


- [ ] **Step 4: Run the tests**

Run: `cd Packages/UNIShell && swift test`

Expected: PASS, 21 tests.

- [ ] **Step 5: Commit**

```bash
git add Packages/UNIShell
git commit -m "Trilha de agenda com posicionamento por minuto do dia

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```


---

### Task 11: Assemble the screen and turn on the app

The last step: assemble the four panels under the bar and replace the Task 1's temporary `RootView`.

**Files:**

- Create: `Packages/UNIShell/Sources/UNIShell/Inbox/InboxScreen.swift`

- Modify: `App/OkamiUNIApp.swift`

- Test: `Packages/UNIShell/Tests/UNIShellTests/InboxScreenTests.swift`

**Interfaces:**

- Consumes: `WindowChrome`, `FolderSidebar`, `MessageList`, `ReaderPane`, `AgendaRail`, `MailStore`

- Produces: `InboxScreen`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import UNICore
@testable import UNIShell

@Suite("InboxScreen")
struct InboxScreenTests {

    @Test("as larguras dos painéis somam a janela do design")
    func paneWidths() {
        // 1440 = 236 lateral + 370 lista + leitor + 262 agenda
        let fixed = FolderSidebar.expandedWidth + MessageList.width + AgendaRail.width
        #expect(fixed == 868)
        #expect(1440 - fixed == 572)  // sobra para o leitor
        // recolhida, a lateral vira trilha de 62 — nunca some
        #expect(SidebarRail.width == 62)
    }

    @Test("o store carrega e já tem uma caixa selecionada")
    @MainActor
    func startsOnToday() async {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        #expect(store.bucket == .today)
        #expect(store.loadError == nil)
    }
}
```


- [ ] **Step 2: Run to see failure**

Run: `cd Packages/UNIShell && swift test --filter InboxScreen`

Expected: FAIL in compilation — `InboxScreen` does not exist.

- [ ] **Step 3: Write `InboxScreen.swift`**

```swift
import SwiftUI
import UNIDesign
import UNICore

public struct InboxScreen: View {
    @Environment(\.theme) private var theme
    @State private var workspace: Workspace = .mail
    @State private var sidebarExpanded = true

    private let store: MailStore

    public init(store: MailStore) {
        self.store = store
    }

    public var body: some View {
        @Bindable var bindableStore = store

        VStack(spacing: 0) {
            WindowChrome(
                workspace: $workspace,
                query: $bindableStore.query,
                accountCount: store.accounts.count,
                onToggleSidebar: {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        sidebarExpanded.toggle()
                    }
                }
            )

            switch workspace {
            case .mail: mailPanes
            case .calendar: calendarPlaceholder
            }
        }
        .background(theme.surface.color)
        .task { await store.load() }
    }

    private var mailPanes: some View {
        HStack(spacing: 0) {
            // O protótipo nunca esconde a lateral: alterna 236px <-> trilha de 62px.
            if sidebarExpanded {
                FolderSidebar(store: store)
            } else {
                SidebarRail(store: store)
            }
            MessageList(store: store)
            ReaderPane(store: store) { event in
                // Marco 4 liga isto ao EventKit.
                print("[agenda] pedido para criar: \(event.label)")
            }
            AgendaRail(store: store)
        }
        .frame(maxHeight: .infinity)
    }

    /// A Agenda semanal é o Marco 4.
    private var calendarPlaceholder: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("Agenda semanal")
                .font(theme.body.font(size: 18, weight: .medium))
                .foregroundStyle(theme.ink.color)
            Text("Chega no Marco 4.")
                .font(theme.sans.font(size: 12))
                .foregroundStyle(theme.ink4.color)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.surface.color)
    }
}
```


- [ ] **Step 4: Replace the temporary `RootView`**

In `App/OkamiUNIApp.swift`, replace the `RootView` from Task 1:

```swift
import SwiftUI
import UNIDesign
import UNICore
import UNIShell

@main
struct OkamiUNIApp: App {
    @State private var themes = ThemeStore()
    @State private var store = MailStore(source: InMemoryMailSource.fixtures)

    init() {
        FontRegistry.registerBundledFonts()
    }

    var body: some Scene {
        WindowGroup("OkamiUNI") {
            InboxScreen(store: store)
                .environment(themes)
                .theme(themes.theme)
                .frame(minWidth: 1100, minHeight: 700)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 916)
    }
}
```


- [ ] **Step 5: Run all tests**

Run:

```bash
for p in UNIDesign UNICore UNIShell; do
  echo "== $p =="
  (cd "Packages/$p" && swift test 2>&1 | grep -E 'Test run with')
done
```
Expected: the three suites passing, without failure.

- [ ] **Step 6: Compile and check against the prototype**

Run:

```bash
xcodegen generate
xcodebuild -project OkamiUNI.xcodeproj -scheme OkamiUNI -configuration Debug build 2>&1 | tail -3
open "$(xcodebuild -project OkamiUNI.xcodeproj -scheme OkamiUNI -showBuildSettings 2>/dev/null | awk -F'= ' '/BUILT_PRODUCTS_DIR/{print $2; exit}')/OkamiUNI.app"
```


Open `design/OkamiUNI - Mail + Agenda.dc.html` in a browser alongside it and compare. Check
each item:

- [ ] 58 px bar with native traffic lights on the left and no system title bar

- [ ] Logo switches between `uni-lockup-light` and `uni-lockup-dark` when switching to a dark theme

- [ ] Caixa/Agenda tabs, with the active tab on a `surface` background

- [ ] Search saying "Buscar nas 4 caixas…" with "⌘K" in mono on the right

- [ ] Sidebar with Hoje/Depois/Tudo/Arquivado and one row per fixture account, each with its colored dot

- [ ] List of 370px, grouped, with colored tags at the bottom of each line

- [ ] Clicking on a line loads the reader and the sender loses the bold text

- [ ] The "Resumo no dispositivo" card appears in m1, with the "Compromisso detectado" band and "Colocar na agenda" button

- [ ] m2 shows the reader without the appointment card

- [ ] 262 px agenda rail with five appointments at the correct heights

- [ ] Without selection, the reader shows the mark in low opacity and "Nada aqui. Bom sinal."

- [ ] Change to "Okami" in the selector changes everything and the orange is `#FF7527`

- [ ] Change to "Brutal" sets the corner rays to zero (`radiusSmall` = 0)

- [ ] Type "marina" in the search to filter the list; delete restores

Record every divergence with the prototype line number. Divergences become adjustment tasks;
they are not for “fix later,” they are the next commit.

- [ ] **Step 7: Commit**

```bash
git add Packages/UNIShell App
git commit -m "Caixa unificada montada: quatro painéis sob a barra

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```


---

## Task P: Visual-polish pass — REQUIRED before closing the milestone

**Explicit request from the project owner, 08/27/2026:** *“we will need to polish the
interface; many things are misaligned … the visual part matters a lot to me.”*

This task **is not optional** and cannot be waived because “the tests pass.” No test in this
project measures alignment; the eye does.

### The case that originated the task

The gap between native macOS traffic lights and the first control in the bar was too wide,
making the window look amateur beside any native app.

Actual measurements, made with accessibility in the running window:

- native traffic lights: close at x=8, minimize at x=31, full screen at x=54 — each 16 pt
  wide, so the **last ends at x=70**;
- the prototype places its first control **14 pt after** the traffic lights end;
- therefore the first control must begin at **x=84**.

Compare with Chrome and the Claude app: in both, controls sit next to traffic lights with a
short gap. That is the platform standard.

### What the pass must cover

Traverse the entire window **side by side with the prototype**, at the same scale, and correct:

1. **Horizontal alignment between panels.** Do list, reader, and agenda headers begin on the
   same baseline? Do vertical dividers fall where the prototype places them?
2. **Vertical alignment inside the bar.** Are logo, tabs, search, and selector centered on the
   same midline of the 58 px bar?
3. **Sidebar vertical rhythm.** Does the space between “Fluxo” and the first folder equal the
   space between “Caixas” and the first account?
4. **Message-row density.** Is the theme’s `rowPadding` respected, or is extra `padding` being
   added on top?
5. **Chip and tag optics.** Are heights, radii, and internal spacing consistent between the
   sidebar and list?
6. **Empty states.** Are reserved texts optically centered in their panel, rather than merely
   mathematically centered?

### Method

Capture the window and prototype at the same size, overlay them, and list every deviation
with its measurement. Correct deviations, capture again, and repeat until deviations are
imperceptible.

When a prototype measurement conflicts with a macOS convention — as with traffic lights,
which are drawn in the prototype and native in the app — **the platform convention wins**;
record that decision in the report.

---

## Task R: Responsive layout — MANDATORY before closing the milestone

**Explicit request from the project owner, 08/27/2026:** *“there is more polishing: first,
you left everything fixed. I need responsiveness; I cannot resize the app, and that is
fundamental.”*

### The measured state

The window **resizes**, but is constrained to a 1100 pt minimum width
(`App/OkamiUNIApp.swift:20`, `minWidth: 1100`), and height locks at 732 even when 700 is
requested. Measured through accessibility in the running window: request 900×700, receive
1100×732.

That floor is a symptom. The cause is that three of four panels have fixed widths:

| panel | width | where |
|---|---|---|
| `FolderSidebar` | 236 fixed | `FolderSidebar.swift:6,58` |
| `MessageList` | 370 fixed | `MessageList.swift:44,63` |
| `AgendaRail` | 262 fixed | `AgendaRail.swift:6,101` |
| `ReaderPane` | `maxWidth: .infinity` | `ReaderPane.swift:23` |

That locks 868 pt. Only the reader stretches. At 1100, **232 pt remain for the reader** —
narrower than the message list and far below the 64ch measurement Task 9 established for a
16 pt serif body. The layout cannot work in a small window because nothing yields.

The search in `WindowChrome.swift:161` is also fixed at `.frame(width: 400, height: 28)` and
can overflow the bar in a narrow window.

### The model

Panels disappear by width band while **preserving user intent**. The classic mistake is to let
automatic collapse overwrite the manual toggle: the user opens the sidebar, the window
shrinks and sidebar closes itself, then the window grows and the sidebar **does not return**.

Avoid this by separating both concerns: `sidebarExpanded` and `agendaVisible` express
**intent**; rendering requires intent **and** sufficient width. When the window grows again,
the original intent becomes valid again by itself.

Bands:

| window width | sidebar | list | reader | agenda |
|---|---|---|---|---|
| ≥ 1360 | 236 expanded | flexible 340–420 | remainder (≥ 478) | 262 |
| 1120–1360 | 236 expanded | flexible 340–420 | rest | **hidden** |
| 920–1120 | **62 pt rail** | flexible 320–380 | remainder | hidden |
| < 920 | 62 pt rail | 320 | remainder (≥ 420) | hidden |

Window floor: `minWidth` drops from 1100 to **860**, `minHeight` from 700 to **600**.

> **Correction, 08/27:** the first version of this table noted "resto (≥ 568)" in the ≥1360 range.

> It is impossible with the numbers in the table itself: in 1360, `236 + 340 + 262 = 838`, remaining

> 522 at best. The Task R implementer found the error and implemented against the invariant

> that actually matters and that the tests stop - the reader never below 420. Measured, the minimum

> real is 478.

>

> **`minHeight: 600` means 600 of content, 632 of frame.** The 32pt are the title bar

> that the `.hiddenTitleBar` window reserves in the frame, and not content that refuses to compress —

> with `minHeight: 100` the entire shell compresses up to 100. It stays at 600, because it is the content that the

> constant must describe.

The sidebar **never disappears completely** — when collapsed, it is the 62 pt rail from Task
7B, which already exists. That behavior is specified and tested; Task R only triggers it by
width as well as by click.

### The testable core

The decision is pure arithmetic and cannot live in a `View` — a SwiftUI `View` is implicitly
`@MainActor` in Swift 6, and a `static` member inside it inherits that isolation and **traps
at runtime** when a nonisolated test calls it. That has already occurred in this codebase
(`AgendaRail`, resolved by creating `AgendaSummary` in UNICore).

Therefore: create `Packages/UNICore/Sources/UNICore/PaneLayout.swift`.

```swift
/// Quais painéis cabem numa janela desta largura, dada a intenção do usuário.
public struct PaneLayout: Sendable, Hashable {
    public let sidebarExpanded: Bool
    public let agendaVisible: Bool
    public let messageListWidth: CGFloat

    /// `wantsSidebar` e `wantsAgenda` são a intenção do usuário, não o resultado.
    /// A janela pode negar as duas; quando ela cresce, a intenção volta a valer.
    public static func resolve(
        width: CGFloat,
        wantsSidebar: Bool,
        wantsAgenda: Bool
    ) -> PaneLayout
}
```


- [ ] **Step 1: Write down the failing tests**

```swift
import Testing
import UNICore

@Suite("PaneLayout")
struct PaneLayoutTests {

    @Test("em janela larga tudo aparece se o usuário quiser")
    func wideShowsEverything() {
        let l = PaneLayout.resolve(width: 1440, wantsSidebar: true, wantsAgenda: true)
        #expect(l.sidebarExpanded)
        #expect(l.agendaVisible)
    }

    @Test("a agenda é o primeiro painel a sair")
    func agendaGoesFirst() {
        let l = PaneLayout.resolve(width: 1200, wantsSidebar: true, wantsAgenda: true)
        #expect(l.sidebarExpanded)
        #expect(l.agendaVisible == false)
    }

    @Test("abaixo de 1120 a lateral recolhe para a trilha")
    func sidebarCollapses() {
        let l = PaneLayout.resolve(width: 1000, wantsSidebar: true, wantsAgenda: true)
        #expect(l.sidebarExpanded == false)
        #expect(l.agendaVisible == false)
    }

    @Test("a janela nega, mas não apaga a intenção: ao crescer, volta")
    func intentSurvivesShrinking() {
        // o mesmo `wants` atravessa as três larguras
        let narrow = PaneLayout.resolve(width: 900, wantsSidebar: true, wantsAgenda: true)
        let wide = PaneLayout.resolve(width: 1440, wantsSidebar: true, wantsAgenda: true)
        #expect(narrow.sidebarExpanded == false)
        #expect(wide.sidebarExpanded)      // sem estado persistido entre as duas chamadas
    }

    @Test("quem não quer a lateral não a ganha de volta ao alargar")
    func refusalIsRespected() {
        let l = PaneLayout.resolve(width: 1440, wantsSidebar: false, wantsAgenda: false)
        #expect(l.sidebarExpanded == false)
        #expect(l.agendaVisible == false)
    }

    @Test("a lista fica dentro da faixa em qualquer largura", arguments: [
        860.0, 920.0, 1000.0, 1120.0, 1280.0, 1440.0, 1920.0, 2560.0,
    ])
    func listStaysInRange(width: CGFloat) {
        let l = PaneLayout.resolve(width: width, wantsSidebar: true, wantsAgenda: true)
        #expect(l.messageListWidth >= 320)
        #expect(l.messageListWidth <= 420)
    }

    @Test("o leitor nunca fica abaixo do mínimo legível")
    func readerNeverStarves() {
        for width in stride(from: 860.0, through: 2560.0, by: 20.0) {
            let l = PaneLayout.resolve(width: width, wantsSidebar: true, wantsAgenda: true)
            let taken = (l.sidebarExpanded ? 236 : 62)
                + l.messageListWidth
                + (l.agendaVisible ? 262 : 0)
            #expect(width - taken >= 420, "leitor espremido em \(width)pt")
        }
    }
}
```


- [ ] **Step 2: Run to see failure**

`cd Packages/UNICore && swift test --filter PaneLayout` → FAIL, `PaneLayout` does not exist.

- [ ] **Step 3: Implement `PaneLayout`**, **Step 4: see pass**, **Step 5: commit**

- [ ] **Step 6: Connect `InboxScreen`**

`InboxScreen` read the width with `GeometryReader` (or `containerRelativeFrame`), call

`PaneLayout.resolve`, and forward the result. `FolderSidebar`, `MessageList` and

`AgendaRail` stop applying fixed `.frame(width:)` values and receive the resolved width.

The `expandedWidth` / `width` constants become the **canonical** values used by `PaneLayout`,
not widths applied directly in the view.

Animate the transition with the same `easeInOut(duration: 0.18)` that the manual toggle already uses, to

collapsing through dragging and clicking feels like the same behavior.

- [ ] **Step 7: Lower the window minimum**

`App/OkamiUNIApp.swift`: `minWidth: 860, minHeight: 600`. Verify that height actually drops
to 600 — today it stops at 732 even with `minHeight: 700`, meaning some content has too much
intrinsic height. Find and correct it.

- [ ] **Step 8: Bar search.** In `WindowChrome.swift:161`, replace
  `.frame(width: 400, height: 28)` with a width range that shrinks in a narrow window without
  colliding with tabs or the theme selector.

- [ ] **Step 9: Check with the window in hand**

Resize from 860 to full screen while observing the three transitions. Capture at 880, 1000,

1200 and 1440. No transition can cut text, overlay panel, or make the bar explode.

### What does not change

The 1440×916 fidelity established by Task P. After Task R, the 1440×916 window must remain
identical to Task P’s result — responsiveness happens **outside** that point, not on top of it.
Capture at 1440 again and compare it with the Task P capture.

---

## Milestone 1.5 — what the project owner requested on 08/27 to be able to validate

His words, in full:

> "several things, first we are without any mode I can't even test writing an email,

> reply, agenda and etc, another thing the top bar is very bad it's not as I like it

> I said that the Mac icons are still misaligned from our tool, I recommend it

> put the logo next to the theme selector and adjust the bar because it's very bad, third

> point, there is a bar between the email list and the email itself but I can't

> resize to the right and left to make the composer larger or smaller, this also

> it should be repeated with the calendar bar another point the agenda tab is literally

> empty"

Three of these items were **outside Milestone 1 by my decision**, recorded in “What this
milestone deliberately does not do”: composer, the Agenda tab, and detached windows. The
decision was wrong for the reason that matters — it made the app impossible to validate for
the person who commissioned it. Scope now includes them.

---

## Task S: Top bar — alignment with the native controls

**Files:** `Packages/UNIShell/Sources/UNIShell/Chrome/WindowChrome.swift`, `App/OkamiUNIApp.swift`

The owner complained about this **twice**. Task P reduced the gap from 45pt to 13pt by correcting the

Safe area, but the vertical residue continues: the native traffic lights have the center at y=16 and the

Our controls at y=29, on a 58pt bar.

The Task P report records that `NSTitlebarAccessoryViewController` had no effect on

window `.hiddenTitleBar`. This does not exhaust the options. Try, in this order:

1. **Reposition the native buttons.** `window.standardWindowButton(.closeButton)` returns a

`NSButton` real; you can move each one, or move their superview, to the vertical center

From the 58pt bar. It is a public API and it is like high-end bar apps do.

2. If (1) does not work, **align our controls with theirs** - the first row of the

The bar now has its center at y=16 instead of y=29.

One of the two has to be solved. "Não dá" it is not an acceptable result here: there are apps of

Third parties on this machine with a high bar and centered traffic lights, and the owner mentioned two of them.

**Layout that the owner requested:** the logo lockup comes out from the left and goes **next to the selector of

Themes**, on the right. On the left are the traffic lights, the side button and the tabs —

Aligned, to the rhythm of Chrome and the Claude app, which were the references he gave.

This is deliberate divergence from the prototype, requested by the owner. Record in the report.- [ ] Measure the current positions by accessibility and record before/after each control

- [ ] Apply (1) or, failing, (2)

- [ ] Move the lockup to the right, next to the selector

- [ ] Recapture at 880, 1200 and 1440 — the bar cannot burst in any

- [ ] Test locking the positions/order of the controls as a pure function (outside `View`)

---

## Task T: Dragable dividers between panels

**Files:** `Packages/UNICore/Sources/UNICore/PaneLayout.swift`,

`Packages/UNIShell/Sources/UNIShell/Inbox/InboxScreen.swift`, new `Inbox/PaneDivider.swift`

Request: *"there is a bar between the email list and the email itself but I can't

Resize to the right and left... this should also repeat with the bar of

Calendar"*.

Two dragable dividers: **list ↔ reader** and **reader ↔ agenda**. The one on the side too,

If it comes out for free.

Rules:

- The drag adjusts the width **within the ranges that `PaneLayout` already defines** (list

320–420 today; the range can be extended if you drag it, but the reader will never go below

420). `PaneLayout` continues to be the one who decides what is appropriate - the drag becomes another one

an additional input alongside `wantsSidebar`/`wantsAgenda`, and **not** a bypass.

- The chosen width **persists** between executions (`UserDefaults`, as the `ThemeStore`).

- Narrow the window until the strip no longer fits, you cannot delete the preference: same rule as

Intention-versus-fit of the Task R.

- Horizontal resizing cursor when hovering over; drag target with at least

6pt wide even if the drawn line has 0.5pt.

- Double click on the divider returns to the canonical width.

The core (clamp, persistence, resolution with the bands) is pure arithmetic → goes in the

`PaneLayout`, in UNICore, with tests. The `View` only translates the gesture.

---

## Task U: Windows — composer, reply, detached email, appointment detail

**Files:** new directory `Packages/UNIShell/Sources/UNIShell/Windows/`, plus the hooks in

`ReaderPane.swift`, `AgendaRail.swift`, `InboxScreen.swift`

Without this, the owner cannot test the writing flow. The four screens are in the prototype
and are the source of truth:

| screen | `.dc.html` line | size |
|---|---|---|
| 03 Composer in a window | 788–1059 | 820×660 |
| 04 Appointment detail | 588–742 | 560 × up to 86% |
| 05 Detached email | 743–787 | 800×600 |
| 06 New message | 368–587 | 820×620 |

- Each is a real window (`Window`/`WindowGroup` or `NSWindow`), not a sheet inside the main
  window — the prototype calls them “em janela” and draws its own shadow and radius.

- Triggers: "Responder" in the reader opens 03; double-clicking a message opens 05; "Nova
  mensagem" (⌘N and a button in the bar) opens 06; clicking a rail appointment opens 04.

- **Do not send anything.** Milestone 1 has no network. "Enviar" closes the window and logs
  to the console. That is a milestone boundary, not a fidelity exemption: the window must be
  visually complete.

- The current theme propagates to new windows (`.theme(...)` and `ThemeStore` in the environment).

---

## Task V: Agenda tab — screen 02 of the prototype

**Files:** new `Packages/UNIShell/Sources/UNIShell/Calendar/WeekScreen.swift`,

`InboxScreen.swift` (tab change)

Today `Workspace.calendar` renders nothing — *“the agenda tab is literally empty.”*

Screen 02, “Agenda semanal,” starts on line **1394** of `.dc.html` and is the source of truth:
its header has Day/Week/Month tabs, a weekly grid, day columns, a time rail, and appointment blocks.

> **Correction, 08/27:** the first version of this task listed “the section that comes from
> email” as part of screen 02. Incorrect — “Vindo do email” is on line 1381, inside screen
> 01, and is already implemented as `AgendaRail.pendingSection`. The implementer found this
> and returned `NEEDS_CONTEXT` instead of inventing a section.

>

> **A contradiction in the prototype itself, resolved at the product level:** `RAIL` (1617)
> puts five appointments on Tuesday the 25th; `WEEK` (1625) puts three, with shortened
> titles. The “prototype wins” rule assumes it has one answer; here it has two, so the
> product decides — the same Tuesday cannot show different items in two views of one app.
> Tuesday comes from `Fixtures.agenda`; the other six days come from `WEEK`. Short `WEEK`
> titles are narrow-column rendering, not data: shorten while drawing; do not store two titles.

>

> **`AgendaItem` gains `dayOffset: Int = 0`**, additive days relative to `Fixtures.today`.
> Not a `Date`: the type deliberately models wall-clock time, and a date would reintroduce
> the time-zone conversion that has already been a bug here. Milestone 4 replaces it with a
> real date through EventKit. The alternative (a week in a separate `Fixtures.week`) was
> rejected because it would retain a known defect — clicking a Wednesday event would open an
> empty window 04.

>

> **Day and Month** (1439–1497) remain outside this milestone, drawn and **visibly disabled**,
> never inert: a tab that looks clickable and does nothing is the same bug that originated
> this task. Apply the same rules as other panels: color/radius/typography from `Theme`,
> prototype measurements, and no account limit.

There is no EventKit in this milestone — the week comes from fixtures, as does the daily rail.
Extend `Fixtures` with one week of appointments, keeping `Fixtures.today` as the anchor and
without reintroducing time-zone conversion (see the Task 10 note).

---

## Ready definition

Milestone 1 is complete when:

1. `xcodegen generate && xcodebuild ... build` ends in `BUILD SUCCEEDED` without concurrency warnings.

2. The three packages pass the tests.

3. `FontRegistry.missing` returns empty at runtime.

4. All items on the checklist of Step 7 of Task 11 are marked.

5. The app opens, navigates between messages, filters by search and switches between the 26 themes without freezing.

## What this milestone deliberately does not do

So Milestone 2 does not assume it inherited finished work:

- No network. `MailStore` talks only to `InMemoryMailSource`.

- No access to calendar. The "Colocar na agenda" button only prints on the console.

- No composing — the prototype's response bar (lines 1128–1340) is omitted.

- The Agenda tab is a placeholder.

- No summary is generated; `Message.summary` comes from the fixtures.

- No highlighted windows, no functional ⌘K, no attachments.
