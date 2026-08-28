# OkamiUNI — Marco 1: Shell e Caixa Unificada

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Entregar o app macOS abrindo numa janela própria com a Caixa unificada de três painéis — barra lateral, lista de mensagens, leitor e trilha de agenda — navegável com dados mock e trocando entre os 26 temas.

**Architecture:** SwiftUI para a composição e o sistema de temas; AppKit via `NSViewRepresentable` só onde a lista densa e o texto rico exigirem. A janela desenha o próprio chrome (a barra de 58px do design) sobre uma `NSWindow` com título escondido, mantendo os semáforos nativos. Os dados vêm de um `MessageStore` alimentado por fixtures neste marco e por backends reais no Marco 2 — a UI nunca vê o backend, só o protocolo.

**Tech Stack:** Swift 6.3, SwiftUI, AppKit, Swift Testing, XcodeGen, macOS 26 (Tahoe).

## Global Constraints

- Alvo mínimo: **macOS 26.0**. `SWIFT_VERSION` 6.0, `SWIFT_STRICT_CONCURRENCY: complete`.
- O projeto Xcode é **gerado** por `xcodegen` a partir de `project.yml`. O `.xcodeproj` fica no `.gitignore` — nunca editar à mão, nunca versionar.
- `Packages/UNIDesign` já existe e está pronto: 26 temas, `TokenColor`, `FontFamily`, `FontRegistry`, `ThemeStore`, `EnvironmentValues.theme`. **Não reescrever.** Regenerar temas só via `python3 Tools/generate_themes.py`.
- **Número de contas ilimitado, provedores abertos.** Nenhum literal de quantidade, nenhuma lista de domínios ou provedores conhecidos em código de produção. Ver "Contas" abaixo.
- **Cor, raio e tipografia vêm sempre de `Theme`** — isto é absoluto. Nenhum literal de cor (`Color.blue`, `#FFF`), nenhum raio solto, nenhuma `Font.system` direta numa View. Se falta um token de cor ou raio, o caminho é acrescentar ao design e regenerar, nunca inventar no Swift.
- **Espaçamento inline é permitido** (`padding(.horizontal, 24)`, `spacing: 10`, `frame(height: 40)`), porque o protótipo não tokeniza a escala de espaçamento — ele posiciona elemento a elemento. A regra é: **todo número de espaçamento tem de vir do protótipo, não da sua intuição.** Em caso de dúvida, medir no `.dc.html` em vez de arredondar. Os quatro tokens de métrica que existem (`radiusSmall`, `radiusLarge`, `rowPadding`, `capsTracking`) são obrigatórios onde se aplicam.
- **Dois andaimes temporários são mandados pelo plano e não são defeitos:** o `Color.clear` que segura o lugar do seletor de temas na Task 5 (removido na Task 6) e o `print` do `onAddEvent` na Task 11 (substituído por EventKit no Marco 4). Ambos levam comentário dizendo o que os remove.
- Todo texto de interface em **português do Brasil**, idêntico ao protótipo (`design/OkamiUNI - Mail + Agenda.dc.html`).
- **Fonte da verdade visual: o protótipo.** Quando o plano e o protótipo divergirem, o implementador **NÃO decide**: para, devolve `NEEDS_CONTEXT` descrevendo a divergência (o valor do plano, o valor do protótipo, a linha do `.dc.html`) e espera resposta. Seguir o plano contra o protótipo já produziu retrabalho neste projeto — a barra lateral inteira teve de ser refeita porque um implementador achou a divergência, registrou no relatório, e mesmo assim seguiu o plano.
- Testes com **Swift Testing** (`import Testing`, `@Test`, `#expect`), não XCTest.
- Um commit por tarefa concluída, mensagem em português, com trailer `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.

---

## Contexto: onde este marco se encaixa

O app inteiro é grande demais para um plano só. Esta é a sequência; **este documento cobre apenas o Marco 1**, que entrega software rodando e testável por si.

| Marco | Entrega | Estado |
|---|---|---|
| 0 | Design baixado, 26 temas em Swift, testes verdes | ✅ feito |
| **1** | **Shell + Caixa unificada navegável com mock** | **este plano** |
| 2 | IMAP/SMTP universal com autodescoberta de servidor; Gmail API e Graph depois, como otimização | a planejar |
| 3 | Composer (inline, em janela, nova mensagem) | a planejar |
| 4 | Agenda semanal + EventKit | a planejar |
| 5 | Detecção de compromisso e resumo no dispositivo (Foundation Models) | a planejar |
| 6 | Janelas destacadas, atalhos, busca ⌘K | a planejar |
| 7 | Empacotamento, assinatura, notarização | a planejar |

### Contas: quantas o usuário quiser, de onde ele quiser

**O número de contas é ilimitado e os provedores são abertos.** Qualquer provedor, qualquer domínio — servidor próprio, hospedagem compartilhada, provedor regional, o que for. Nada na UI nem no modelo pode presumir uma quantidade, um conjunto de provedores ou uma lista de domínios conhecidos.

As quatro caixas que aparecem no protótipo (`ricardo@empresa.com`, `ricardo@gmail.com`, `contato@meusite.com`, `ricardo@icloud.com`) são **exemplos que o designer usou para desenhar**, não o escopo do produto. Elas viram fixtures no Marco 1 só para a comparação visual bater com o protótipo.

Consequências concretas, que valem para todas as tarefas deste plano:

- Nenhum literal `4` em código de produção. O texto da busca é `"Buscar nas \(accountCount) caixas…"`.
- Nenhum `switch` exaustivo sobre contas conhecidas. `Account.id` é opaco.
- A UI tem de aguentar 0, 1 e 30 contas. A barra lateral rola; a lista não muda de largura.
- `Account.Provider` classifica **como falar com o servidor**, não quem é o provedor. `.imap` é o caso geral, não a exceção.

**IMAP/SMTP é o caminho universal e a prioridade número um do Marco 2** — é o que faz "qualquer provedor, qualquer domínio" ser verdade. Gmail API e Microsoft Graph entram depois, como otimização para esses dois casos (sync incremental melhor, threading nativo), nunca como pré-requisito para a conta funcionar. Uma conta Gmail tem de funcionar via IMAP mesmo antes de a Gmail API existir no código.

Isso obriga o Marco 2 a incluir **autodescoberta de servidor** — Mozilla ISPDB, `autoconfig.<domínio>`, `autodiscover`, registros SRV — para o usuário digitar email e senha e o app achar host e porta sozinho. Sem isso, "qualquer domínio" vira "qualquer domínio desde que você saiba decorar IMAP/SMTP", que não é a mesma coisa.

---

## Estrutura de arquivos

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

**Por que essa divisão:** `UNICore` não importa SwiftUI, então os modelos podem ser testados sem UI e reaproveitados pelos backends do Marco 2. `UNIShell` não conhece rede. `UNIDesign` não conhece nem modelos nem rede. As três camadas só apontam para baixo.

---

### Task 1: Projeto Xcode que abre uma janela temada

**Files:**
- Create: `project.yml`
- Create: `App/OkamiUNIApp.swift`
- Create: `App/Info.plist`
- Create: `App/OkamiUNI.entitlements`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: `UNIDesign.Theme`, `UNIDesign.ThemeStore`, `View.theme(_:)`
- Produces: alvo `OkamiUNI` compilável; `OkamiUNIApp` como `@main`

- [ ] **Step 1: Escrever `project.yml`**

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

- [ ] **Step 2: Escrever `App/Info.plist`**

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

- [ ] **Step 3: Escrever `App/OkamiUNI.entitlements`**

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

- [ ] **Step 4: Escrever `App/OkamiUNIApp.swift`**

A janela do design não usa a barra de título do sistema: ela desenha a própria barra de 58px e mantém só os semáforos. `.windowStyle(.hiddenTitleBar)` faz isso.

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

- [ ] **Step 5: Ignorar o projeto gerado**

Acrescentar a `.gitignore`:

```
*.xcodeproj
```

- [ ] **Step 6: Gerar e compilar**

Run:
```bash
xcodegen generate && xcodebuild -project OkamiUNI.xcodeproj -scheme OkamiUNI -configuration Debug build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 7: Abrir o app e confirmar visualmente**

Run:
```bash
open "$(xcodebuild -project OkamiUNI.xcodeproj -scheme OkamiUNI -showBuildSettings 2>/dev/null | awk -F'= ' '/BUILT_PRODUCTS_DIR/{print $2; exit}')/OkamiUNI.app"
```
Expected: janela sem barra de título, fundo `#F4F2EE` (o `paper` do tema Tinta), texto "OkamiUNI" em serifa escura. Se o fundo vier branco puro, o tema não chegou ao ambiente — verificar `.theme(themes.theme)`.

- [ ] **Step 8: Commit**

```bash
git add project.yml App .gitignore
git commit -m "Projeto Xcode gerado por XcodeGen, janela com chrome próprio

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: Fontes do design embarcadas

Sem isso, `FontRegistry.missing` lista as seis famílias e todo o app renderiza em system font — parecido, mas não é o design.

**Files:**
- Create: `Tools/fetch_fonts.sh`
- Create: `App/Resources/Fonts/` (arquivos baixados)
- Modify: `project.yml`
- Test: `Packages/UNIDesign/Tests/UNIDesignTests/FontRegistryTests.swift`

**Interfaces:**
- Consumes: `FontRegistry.required`, `FontRegistry.registerBundledFonts(in:)`
- Produces: bundle com `Fonts/*.ttf`; `FontRegistry.missing` vazio em runtime

- [ ] **Step 1: Escrever o teste que falha**

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

- [ ] **Step 2: Rodar o teste**

Run: `cd Packages/UNIDesign && swift test --filter FontRegistry`
Expected: PASS nos dois — este teste protege o contrato, não a presença dos arquivos.

- [ ] **Step 3: Escrever `Tools/fetch_fonts.sh`**

As seis famílias estão no repositório `google/fonts` sob licença OFL. Baixamos as variable fonts, que cobrem todos os pesos que o design pede num arquivo por família.

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

- [ ] **Step 4: Rodar e conferir**

Run:
```bash
chmod +x Tools/fetch_fonts.sh && ./Tools/fetch_fonts.sh
file App/Resources/Fonts/*.ttf
```
Expected: cada arquivo reportado como `TrueType Font data` ou `OpenType font data`. Se algum vier como `ASCII text`, o caminho no repo `google/fonts` mudou — abrir `https://github.com/google/fonts/tree/main/ofl/<familia>` e corrigir a entrada em `FILES`. Não seguir com um arquivo inválido: o registro falha silenciosamente e a fonte cai no fallback.

- [ ] **Step 5: Declarar os recursos no `project.yml`**

Dentro de `targets.OkamiUNI`, acrescentar antes de `dependencies`:

```yaml
    sources:
      - path: App
        excludes:
          - "Resources/Fonts"
      - path: App/Resources/Fonts
        type: folder
```

O `type: folder` preserva `Fonts/` como pasta dentro do bundle, que é onde `registerBundledFonts` procura (`subdirectory: "Fonts"`).

- [ ] **Step 6: Verificar o registro em runtime**

Acrescentar temporariamente ao `init()` de `OkamiUNIApp`:

```swift
init() {
    let registered = FontRegistry.registerBundledFonts()
    print("[fontes] registradas: \(registered.count) — faltando: \(FontRegistry.missing)")
}
```

Run: `xcodegen generate && xcodebuild -project OkamiUNI.xcodeproj -scheme OkamiUNI build && open ...`
Expected no console: `faltando: []`. Se alguma família aparecer, o nome no `FontRegistry.required` não bate com o nome interno da face — conferir com `fc-scan` ou abrindo no Font Book.

- [ ] **Step 7: Commit**

```bash
git add Tools/fetch_fonts.sh App/Resources/Fonts project.yml \
        Packages/UNIDesign/Tests/UNIDesignTests/FontRegistryTests.swift
git commit -m "Embarca as 6 famílias OFL que o design usa

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: Modelos de domínio

**Files:**
- Create: `Packages/UNICore/Package.swift`
- Create: `Packages/UNICore/Sources/UNICore/Account.swift`
- Create: `Packages/UNICore/Sources/UNICore/Contact.swift`
- Create: `Packages/UNICore/Sources/UNICore/Message.swift`
- Create: `Packages/UNICore/Sources/UNICore/DetectedEvent.swift`
- Create: `Packages/UNICore/Sources/UNICore/AgendaItem.swift`
- Test: `Packages/UNICore/Tests/UNICoreTests/ModelTests.swift`

**Interfaces:**
- Consumes: nada (camada de baixo)
- Produces: `Account`, `Account.Provider`, `Contact`, `Message`, `Tag`, `TriageBucket`, `DetectedEvent`, `AgendaItem`

- [ ] **Step 1: Escrever `Package.swift`**

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

- [ ] **Step 2: Escrever os testes que falham**

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

- [ ] **Step 3: Rodar para ver falhar**

Run: `cd Packages/UNICore && swift test`
Expected: FAIL na compilação — `cannot find 'Contact' in scope`.

- [ ] **Step 4: Escrever `Contact.swift`**

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

- [ ] **Step 5: Escrever `Account.swift`**

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

- [ ] **Step 6: Escrever `DetectedEvent.swift` e `AgendaItem.swift`**

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

- [ ] **Step 7: Escrever `Message.swift`**

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

- [ ] **Step 8: Rodar os testes**

Run: `cd Packages/UNICore && swift test`
Expected: PASS, 5 testes.

- [ ] **Step 9: Commit**

```bash
git add Packages/UNICore
git commit -m "UNICore: modelos de conta, contato, mensagem e agenda

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: Store e fixtures do protótipo

**Files:**
- Create: `Packages/UNICore/Sources/UNICore/MessageStore.swift`
- Create: `Packages/UNICore/Sources/UNICore/Fixtures/Fixtures.swift`
- Test: `Packages/UNICore/Tests/UNICoreTests/StoreTests.swift`

**Interfaces:**
- Consumes: `Account`, `Message`, `TriageBucket`, `AgendaItem`
- Produces: `protocol MailSource`, `InMemoryMailSource`, `MailStore` (`@Observable`), `Fixtures.accounts`, `Fixtures.messages`, `Fixtures.agenda`

- [ ] **Step 1: Escrever os testes que falham**

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

- [ ] **Step 2: Rodar para ver falhar**

Run: `cd Packages/UNICore && swift test --filter MailStore`
Expected: FAIL — `cannot find 'MailStore' in scope`.

- [ ] **Step 3: Escrever `MessageStore.swift`**

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

- [ ] **Step 4: Escrever `Fixtures.swift`**

Copiar os dados de `MSGS`, `ACC` e `RAIL` do protótipo. As cores OKLCH das contas já convertidas: `zoho` `oklch(0.52 0.10 255)` → `#3E6FA8`, `gmail` `oklch(0.52 0.10 300)` → `#7E5FB4`, `host` `oklch(0.52 0.09 155)` → `#2C7D5E`, `icloud` `oklch(0.55 0.08 200)` → `#3C87A0`.

Conferir cada conversão com o helper que já existe:

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

Usar a saída desse comando, não os valores acima, se divergirem.

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

- [ ] **Step 5: Rodar os testes**

Run: `cd Packages/UNICore && swift test`
Expected: PASS, 15 testes (5 de modelos + 10 do store).

- [ ] **Step 6: Commit**

```bash
git add Packages/UNICore
git commit -m "UNICore: MailStore observável e fixtures do protótipo

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: Assets de marca, modificadores de token e a barra de 58px

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

- [ ] **Step 1: Baixar os 3 assets que faltam**

Só o `uni-lockup-light.png` foi baixado no Marco 0. Os outros três estão no projeto do Claude Design `40478c81-e3be-42cc-aad1-f0c2d28d292c`: `uni-lockup-dark.png`, `uni-mark-light.png`, `uni-mark-dark.png`.

Para cada um, chamar a ferramenta `DesignSync` com `method: "get_file"`, esse `projectId` e o `path` do arquivo. A resposta é JSON com `content` em base64 e `isBase64: true`. Quando o resultado for grande demais e for salvo em arquivo, decodificar assim (foi o caminho usado no Marco 0):

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

Expected: `file` reporta os quatro como `PNG image data` com dimensões plausíveis (o lockup claro é 587×162).

Depois criar os image sets. Os nomes têm de ser exatamente `uni-lockup-light`, `uni-lockup-dark`, `uni-mark-light`, `uni-mark-dark` — é o que `WindowChrome` e `ReaderPane` já pedem em `Image(...)`.

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

Expected: quatro pastas `.imageset` mais o `Contents.json` raiz.

Se o lockup vier em resolução baixa e pixelar a 38pt de altura, pedir ao design uma exportação 2×/3× em vez de escalar o 1× — a barra é a primeira coisa que a pessoa vê.

- [ ] **Step 2: Escrever `Package.swift`**

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

- [ ] **Step 3: Escrever o teste que falha**

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

- [ ] **Step 4: Rodar para ver falhar**

Run: `cd Packages/UNIShell && swift test`
Expected: FAIL — `cannot find 'Workspace' in scope`.

- [ ] **Step 5: Escrever `TokenModifiers.swift`**

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

- [ ] **Step 6: Escrever `WindowChrome.swift`**

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

- [ ] **Step 7: Adicionar `UNIShell` ao `project.yml`**

Em `packages`:
```yaml
  UNICore:
    path: Packages/UNICore
  UNIShell:
    path: Packages/UNIShell
```

Em `targets.OkamiUNI.dependencies`:
```yaml
      - package: UNICore
        product: UNICore
      - package: UNIShell
        product: UNIShell
```

- [ ] **Step 8: Rodar os testes**

Run: `cd Packages/UNIShell && swift test`
Expected: PASS, 4 testes.

- [ ] **Step 9: Commit**

```bash
git add Packages/UNIShell project.yml
git commit -m "UNIShell: modificadores de token e a barra de 58px

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: Seletor de temas

**Files:**
- Create: `Packages/UNIShell/Sources/UNIShell/Chrome/ThemePicker.swift`
- Test: `Packages/UNIShell/Tests/UNIShellTests/ThemePickerTests.swift`

**Interfaces:**
- Consumes: `UNIDesign.ThemeStore`, `UNIDesign.Theme.all`
- Produces: `ThemePicker`, `ThemePreview`

- [ ] **Step 1: Escrever o teste que falha**

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

- [ ] **Step 2: Rodar para ver falhar**

Run: `cd Packages/UNIShell && swift test --filter ThemePicker`
Expected: FAIL na compilação — `ThemePicker` não existe.

- [ ] **Step 3: Escrever `ThemePicker.swift`**

Cada card é uma miniatura da janela: barra com dois pontos, barra lateral, corpo com duas linhas.

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

- [ ] **Step 4: Rodar os testes**

Run: `cd Packages/UNIShell && swift test`
Expected: PASS, 7 testes.

- [ ] **Step 5: Ligar o seletor na barra**

Em `WindowChrome.swift`, trocar o vazio que a Task 5 deixou:

```swift
            // antes
            Color.clear.frame(width: 96, height: 26)

            // depois
            ThemePicker()
```

- [ ] **Step 6: Verificar no app**

Gerar e abrir.

Run: `xcodegen generate && xcodebuild -project OkamiUNI.xcodeproj -scheme OkamiUNI build && open ...`
Expected: clicar em "Tinta" abre o popover com 26 miniaturas; escolher "Okami" muda a janela inteira para onyx com o laranja `#FF7527`; fechar e reabrir o app mantém Okami.

- [ ] **Step 7: Commit**

```bash
git add Packages/UNIShell
git commit -m "Seletor de temas com as 26 miniaturas, escolha persistida

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 7: Filtro por conta e barra lateral expandida

O plano original descrevia esta barra errada em quase tudo. Os valores abaixo foram
extraídos do protótipo e são os corretos.

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
  `MailStore.select(account:)`, `MailStore.count(for:)` sensível ao filtro,
  `FolderSidebar`, `FolderSidebar.expandedWidth` (= 236)

#### Parte A — o modelo aprende o filtro por conta

No protótipo, clicar numa conta filtra a lista, e os contadores das pastas passam a
contar só aquela conta. Clicar de novo na mesma conta desliga o filtro.

O código do protótipo:
```js
onPick: () => this.setState({ account: on ? null : k })
// e nos contadores:
MSGS.filter(m => (v.id === 'todos' ? true : bucketOf(m) === v.id) && (!st.account || m.acc === st.account))
```

`MailStore` ganha:
- `public private(set) var selectedAccountID: String?`
- `public func select(account id: String?)` — passar o id já selecionado desliga o filtro
- `visibleMessages` passa a aplicar o filtro de conta junto com bucket e busca
- `count(for:)` passa a respeitar o filtro de conta

#### Parte B — cores de conta que se adaptam ao tema

O protótipo troca a cor de cada conta conforme o tema, porque a cor clara não tem
contraste em fundo escuro:

```js
// tema claro:  ACC[k].c        — L ~0.52
// temas escuros: L sobe para ~0.78-0.80
DK = { zoho: oklch(0.78 0.10 255), gmail: oklch(0.78 0.11 300),
       host: oklch(0.80 0.10 155), icloud: oklch(0.80 0.09 200) }
```

`Account.tintHex` vira dois campos: `tintLightHex` e `tintDarkHex`, mais
`public func tint(isDark: Bool) -> String`. Converter os OKLCH acima para hex com
`Tools/generate_themes.py` (função `oklch_to_srgb`) e usar a saída real.

#### Parte C — a barra expandida, com os valores do protótipo

Container: largura **236**, fundo `surface2`, borda direita `0.5px line`,
`padding-top: 14`, e transição de largura de 180ms.

Cabeçalho de seção (os dois): mono **9.5px**, caps, tracking `capsTracking`, cor `ink4`.
- "**Fluxo**" com padding `0 16px 7px`  (o plano antigo dizia "Pastas" — errado)
- "**Caixas**" com padding `22px 16px 7px`

Linha de pasta (`views`): altura **30**, gap **9**, padding `0 8`, raio `radiusSmall`.
- rótulo 13px peso 500, ocupando o espaço livre
- contador em mono 10px
- selecionada: cor `accentInk`, fundo `accentSoft`, contador também `accentInk`
- não selecionada: cor `ink2`, contador `ink4`, fundo transparente

Linha de conta (`accounts`): altura **32**, gap **8**, padding `0 8`, raio `radiusSmall`.
- chip do host à esquerda: mono **9px**, tracking 0.06em, caps, padding `2px 6px 1.5px`,
  raio 4, cor = tint da conta, fundo = tint a 14% (22% quando selecionada),
  borda `0.5px` do tint a 32%
- rótulo (endereço) 12.5px, truncado com reticências, ocupando o espaço livre
- contador em mono 10px, `ink4`
- selecionada: fundo = tint a 16% e uma barra interna de 2px à esquerda na cor do tint
  (no CSS é `box-shadow: inset 2px 0 0`; em SwiftUI, um retângulo de 2px alinhado à esquerda)

Rodapé, fixo no fim (`margin-top: auto`), padding 16, borda superior `0.5px line`:
- um ponto de 5px na cor semântica "ok" (verde), gap 7
- "**Triagem local ativa**" — 11.5px, peso 590, `ink2`
- "**Classificação, resumo e busca semântica rodam no Mac. Nada sai daqui.**"
  — 11px, line-height 1.5, `ink3`

Este rodapé é promessa de produto, não decoração. O texto vai verbatim.

#### Steps

- [ ] **Step 1: Escrever os testes que falham** — no UNICore, cobrindo o filtro por
  conta: filtrar reduz `visibleMessages`; clicar de novo na mesma conta desliga;
  `count(for:)` respeita o filtro; filtro por conta e busca se combinam. No UNIShell,
  os testes de escalabilidade que já existem mais um que fixe `expandedWidth == 236`.
  Todo teste tem de falhar antes da implementação — rode e confirme.

- [ ] **Step 2: Implementar a Parte A** (filtro no `MailStore`), rodar os testes do
  UNICore até passarem.

- [ ] **Step 3: Implementar a Parte B** (tint por tema). Converter os OKLCH com o
  helper e registrar a saída no relatório.

- [ ] **Step 4: Reescrever a `FolderSidebar`** com os valores da Parte C.

- [ ] **Step 5: Verificar contra o protótipo.** Abrir o app e comparar com o
  `.dc.html`: largura, "Fluxo", chips de host, contadores, seleção de conta com a
  barrinha à esquerda, rodapé. Trocar para um tema escuro e confirmar que as cores das
  contas clareiam.

- [ ] **Step 6: Commit.**

---

### Task 7B: Trilha recolhida de 62px

O botão da barra de 58px não esconde a barra lateral: ele a troca por uma trilha
estreita. O plano original tratava isso como mostrar/esconder — errado.

**Files:**
- Create: `Packages/UNIShell/Sources/UNIShell/Inbox/SidebarRail.swift`
- Modify: `Packages/UNIShell/Sources/UNIShell/Inbox/FolderSidebar.swift`
- Test: `Packages/UNIShell/Tests/UNIShellTests/SidebarRailTests.swift`

**Interfaces:**
- Consumes: `MailStore`, `Theme`, `TriageBucket`
- Produces: `SidebarRail`, `SidebarRail.width` (= 62)

Container: largura **62**, fundo `surface2`, borda direita `0.5px line`,
conteúdo centralizado, padding `14px 0`.

Botão de pasta: **46×40**, raio `radiusSmall`, coluna centralizada, gap 3.
- abreviação em mono **8.5px**, tracking 0.06em, caps: `hoje`, `dep`, `tudo`, `arq`
  (nessa ordem, correspondendo a Hoje/Depois/Tudo/Arquivado)
- contador 13px peso 650
- selecionado: cor `accentInk`, fundo `accentSoft`, borda `0.5px accentLine`
- não selecionado: cor `ink3`, fundo transparente

Divisória: 26px de largura, `0.5px line`, margem vertical 8.

Rótulo "caixas": mono **7.5px**, tracking 0.08em, caps, `ink4`, margem inferior 2.

Marca de conta: **40×24**, raio `radiusSmall`, mono 10px peso 500, centralizado.
- texto = as **3 primeiras letras do host** (`zoh`, `gma`, `hos`, `icl`)
- cor = tint da conta; fundo = tint a 12% (26% quando selecionada);
  borda `0.5px` do tint a 26% (70% quando selecionada)
- cada uma leva o endereço completo num `.help()`

#### Steps

- [ ] **Step 1: Escrever os testes que falham** — `SidebarRail.width == 62`; as
  abreviações das quatro pastas na ordem certa; a marca de conta são as 3 primeiras
  letras do host; a trilha aguenta 0 e 25 contas.

- [ ] **Step 2: Rodar e ver falhar.**

- [ ] **Step 3: Implementar `SidebarRail`.**

- [ ] **Step 4: Ligar o toggle.** O botão da barra alterna entre `FolderSidebar`
  (236px) e `SidebarRail` (62px) — nunca esconde tudo. Animar com a transição de
  180ms que o protótipo usa.

- [ ] **Step 5: Verificar no app.** Clicar no botão vai e volta entre os dois estados,
  a seleção de pasta e de conta sobrevive à troca.

- [ ] **Step 6: Commit.**

---

### Task 8: Lista de mensagens agrupada

O painel de 370px do design. As mensagens vêm agrupadas por dia, com cabeçalho em versalete.

**Files:**
- Create: `Packages/UNIShell/Sources/UNIShell/Inbox/MessageRow.swift`
- Create: `Packages/UNIShell/Sources/UNIShell/Inbox/MessageList.swift`
- Test: `Packages/UNIShell/Tests/UNIShellTests/MessageListTests.swift`

**Interfaces:**
- Consumes: `MailStore.visibleMessages`, `MailStore.select(message:)`, `Message`, `Tag`
- Produces: `MessageList`, `MessageList.width` (= 370), `MessageRow`, `MessageGroup`

- [ ] **Step 1: Escrever os testes que falham**

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

- [ ] **Step 2: Rodar para ver falhar**

Run: `cd Packages/UNIShell && swift test --filter MessageList`
Expected: FAIL — `MessageGroup` não existe.

- [ ] **Step 3: Escrever `MessageRow.swift`**

A anatomia da linha, direto do protótipo: remetente à esquerda e hora à direita; assunto; trecho em duas linhas; rodapé com o host da conta e as etiquetas.

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

- [ ] **Step 4: Escrever `MessageList.swift`**

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

- [ ] **Step 5: Rodar os testes**

Run: `cd Packages/UNIShell && swift test`
Expected: PASS, 13 testes.

- [ ] **Step 6: Commit**

```bash
git add Packages/UNIShell
git commit -m "Lista de mensagens agrupada por dia, com etiquetas

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 9: Painel de leitura

**Files:**
- Create: `Packages/UNIShell/Sources/UNIShell/Inbox/ReaderPane.swift`
- Test: `Packages/UNIShell/Tests/UNIShellTests/ReaderTests.swift`

**Interfaces:**
- Consumes: `MailStore.selectedMessage`, `Message.summary`, `Message.detectedEvent`
- Produces: `ReaderPane`

- [ ] **Step 1: Escrever o teste que falha**

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

- [ ] **Step 2: Rodar para ver falhar**

Run: `cd Packages/UNIShell && swift test --filter ReaderPane`
Expected: FAIL na compilação.

- [ ] **Step 3: Escrever `ReaderPane.swift`**

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

- [ ] **Step 4: Rodar os testes**

Run: `cd Packages/UNIShell && swift test`
Expected: PASS, 16 testes.

- [ ] **Step 5: Commit**

```bash
git add Packages/UNIShell
git commit -m "Painel de leitura com resumo e compromisso detectado

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 10: Trilha de agenda

**Files:**
- Create: `Packages/UNIShell/Sources/UNIShell/Inbox/AgendaRail.swift`
- Test: `Packages/UNIShell/Tests/UNIShellTests/AgendaRailTests.swift`

**Interfaces:**
- Consumes: `MailStore.agenda`, `AgendaItem`
- Produces: `AgendaRail`, `AgendaRail.width` (= 262), `AgendaRail.Layout`

- [ ] **Step 1: Escrever os testes que falham**

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

- [ ] **Step 2: Rodar para ver falhar**

Run: `cd Packages/UNIShell && swift test --filter AgendaRail`
Expected: FAIL na compilação.

- [ ] **Step 3: Escrever `AgendaRail.swift`**

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

- [ ] **Step 4: Rodar os testes**

Run: `cd Packages/UNIShell && swift test`
Expected: PASS, 21 testes.

- [ ] **Step 5: Commit**

```bash
git add Packages/UNIShell
git commit -m "Trilha de agenda com posicionamento por minuto do dia

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 11: Montar a tela e ligar no app

O último passo: compor os quatro painéis sob a barra e trocar o `RootView` provisório da Task 1.

**Files:**
- Create: `Packages/UNIShell/Sources/UNIShell/Inbox/InboxScreen.swift`
- Modify: `App/OkamiUNIApp.swift`
- Test: `Packages/UNIShell/Tests/UNIShellTests/InboxScreenTests.swift`

**Interfaces:**
- Consumes: `WindowChrome`, `FolderSidebar`, `MessageList`, `ReaderPane`, `AgendaRail`, `MailStore`
- Produces: `InboxScreen`

- [ ] **Step 1: Escrever o teste que falha**

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

- [ ] **Step 2: Rodar para ver falhar**

Run: `cd Packages/UNIShell && swift test --filter InboxScreen`
Expected: FAIL na compilação — `InboxScreen` não existe.

- [ ] **Step 3: Escrever `InboxScreen.swift`**

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

- [ ] **Step 4: Trocar o `RootView` provisório**

Em `App/OkamiUNIApp.swift`, substituir o `RootView` da Task 1:

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

- [ ] **Step 5: Rodar todos os testes**

Run:
```bash
for p in UNIDesign UNICore UNIShell; do
  echo "== $p =="
  (cd "Packages/$p" && swift test 2>&1 | grep -E 'Test run with')
done
```
Expected: os três suites passando, sem falha.

- [ ] **Step 6: Compilar e conferir contra o protótipo**

Run:
```bash
xcodegen generate
xcodebuild -project OkamiUNI.xcodeproj -scheme OkamiUNI -configuration Debug build 2>&1 | tail -3
open "$(xcodebuild -project OkamiUNI.xcodeproj -scheme OkamiUNI -showBuildSettings 2>/dev/null | awk -F'= ' '/BUILT_PRODUCTS_DIR/{print $2; exit}')/OkamiUNI.app"
```

Abrir `design/OkamiUNI - Mail + Agenda.dc.html` no navegador ao lado e comparar. Conferir cada item:

- [ ] Barra de 58px com os semáforos nativos à esquerda, sem barra de título do sistema
- [ ] Logo trocando entre `uni-lockup-light` e `uni-lockup-dark` ao mudar para um tema escuro
- [ ] Abas Caixa/Agenda com a ativa em fundo `surface`
- [ ] Busca dizendo "Buscar nas 4 caixas…" com "⌘K" em mono à direita
- [ ] Barra lateral com Hoje/Depois/Tudo/Arquivado e uma linha por conta das fixtures, cada uma com seu ponto colorido
- [ ] Lista de 370px, agrupada, com etiquetas coloridas no rodapé de cada linha
- [ ] Clicar numa linha carrega o leitor e o remetente perde o negrito
- [ ] O cartão "Resumo no dispositivo" aparece em m1 com a faixa "Compromisso detectado" e o botão "Colocar na agenda"
- [ ] m2 mostra o leitor sem o cartão de compromisso
- [ ] Trilha de agenda de 262px com os cinco compromissos nas alturas certas
- [ ] Sem seleção, o leitor mostra a marca em opacidade baixa e "Nada aqui. Bom sinal."
- [ ] Trocar para "Okami" no seletor muda tudo e o laranja é `#FF7527`
- [ ] Trocar para "Brutal" zera os raios de canto (`radiusSmall` = 0)
- [ ] Digitar "marina" na busca filtra a lista; apagar restaura

Anotar cada divergência com o número da linha do protótipo. Divergências viram tarefas de ajuste — não são para "arrumar depois", são o próximo commit.

- [ ] **Step 7: Commit**

```bash
git add Packages/UNIShell App
git commit -m "Caixa unificada montada: quatro painéis sob a barra

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task P: Passe de polimento visual — OBRIGATÓRIA antes de fechar o marco

**Pedido explícito do dono do projeto, 27/08/2026:** *"vamos ter que fazer um polimento na
interface, tem muita coisa desalinhada... essa parte estética conta muito pra mim."*

Esta tarefa **não é opcional** e não pode ser dispensada por "os testes passam". Nenhum teste
deste projeto mede alinhamento; o olho mede.

### O caso que originou a tarefa

O vão entre os semáforos nativos do macOS e o primeiro controle da barra estava grande demais,
fazendo a janela parecer amadora ao lado de qualquer app nativo.

Medições reais, feitas via acessibilidade na janela rodando:
- semáforos nativos: fechar em x=8, minimizar em x=31, tela cheia em x=54 — todos com 16pt de
  largura, então o **último termina em x=70**
- o protótipo põe seu primeiro controle **14pt depois** do fim dos semáforos
- portanto o primeiro controle deve começar em **x=84**

Compare com o Chrome e com o app do Claude: em ambos os controles encostam nos semáforos com
uma folga curta. É esse o padrão da plataforma.

### O que a passe tem de cobrir

Percorrer a janela inteira **lado a lado com o protótipo**, na mesma escala, e corrigir:

1. **Alinhamento horizontal entre painéis.** Os cabeçalhos de lista, leitor e agenda começam
   na mesma linha de base? As divisórias verticais caem onde o protótipo põe?
2. **Alinhamento vertical dentro da barra.** Logo, abas, busca e seletor centrados na mesma
   linha média dos 58px?
3. **Ritmo vertical da barra lateral.** O espaço entre "Fluxo" e a primeira pasta é igual ao
   que há entre "Caixas" e a primeira conta?
4. **Densidade das linhas de mensagem.** O `rowPadding` do tema está sendo respeitado, ou algum
   `padding` extra está somando por cima?
5. **Óptica dos chips e etiquetas.** Alturas, raios e folga interna consistentes entre a barra
   lateral e a lista.
6. **Estados vazios.** Os textos reservados estão opticamente centrados no painel, não apenas
   matematicamente?

### Método

Capturar a janela e o protótipo no mesmo tamanho, sobrepor, e listar cada desvio com a medida.
Corrigir os desvios. Recapturar. Repetir até o desvio ser imperceptível.

Onde uma medida do protótipo brigar com a convenção do macOS — como o caso dos semáforos, que
no protótipo são desenhados e no app são nativos — **a convenção da plataforma vence**, e a
decisão fica registrada no relatório.

---

## Task R: Layout responsivo — OBRIGATÓRIA antes de fechar o marco

**Pedido explícito do dono do projeto, 27/08/2026:** *"tem mais polimento, primeiro que voce
deixou tudo fixo, e eu quero responsividade eu nao consigo redimensionar o app e isso é
fundamental."*

### O estado medido

A janela **redimensiona**, mas trava num piso de 1100pt de largura (`App/OkamiUNIApp.swift:20`,
`minWidth: 1100`) e a altura trava em 732 mesmo pedindo 700. Medido via acessibilidade na
janela rodando: pedi 900×700, recebi 1100×732.

O piso é sintoma. A causa é que três dos quatro painéis têm largura cravada:

| painel | largura | onde |
|---|---|---|
| `FolderSidebar` | 236 fixa | `FolderSidebar.swift:6,58` |
| `MessageList` | 370 fixa | `MessageList.swift:44,63` |
| `AgendaRail` | 262 fixa | `AgendaRail.swift:6,101` |
| `ReaderPane` | `maxWidth: .infinity` | `ReaderPane.swift:23` |

São 868pt cravados. Só o leitor estica. A 1100 sobram **232pt para o leitor** — mais estreito
que a lista de mensagens, e muito abaixo da medida de 64ch que a Task 9 estabeleceu para o
corpo serif 16. O layout não tem como funcionar em janela pequena porque nada cede.

A busca em `WindowChrome.swift:161` também é `.frame(width: 400, height: 28)` fixa e é
candidata a estourar a barra em janela estreita.

### O modelo

Painéis somem por faixa de largura, e a **intenção do usuário é preservada**. O erro clássico
aqui é o recolhimento automático sobrescrever o toggle manual: o usuário abre a lateral, a
janela encolhe, a lateral fecha sozinha, a janela cresce de novo e a lateral **não volta**.

Evita-se separando as duas coisas: `sidebarExpanded` e `agendaVisible` são **intenção**, e o
que é renderizado é intenção **E** largura suficiente. Quando a janela cresce de novo, a
intenção original volta a valer sozinha.

Faixas:

| largura da janela | lateral | lista | leitor | agenda |
|---|---|---|---|---|
| ≥ 1360 | 236 expandida | flexível 340–420 | resto (≥ 478) | 262 |
| 1120–1360 | 236 expandida | flexível 340–420 | resto | **oculta** |
| 920–1120 | **trilha de 62** | flexível 320–380 | resto | oculta |
| < 920 | trilha de 62 | 320 | resto (≥ 420) | oculta |

Piso da janela: `minWidth` cai de 1100 para **860**, `minHeight` de 700 para **600**.

> **Correção, 27/08:** a primeira versão desta tabela anotava "resto (≥ 568)" na faixa ≥1360.
> É impossível com os próprios números da tabela: em 1360, `236 + 340 + 262 = 838`, sobrando
> 522 no melhor caso. O implementador da Task R achou o erro e implementou contra a invariante
> que de fato importa e que os testes travam — o leitor nunca abaixo de 420. Medido, o mínimo
> real é 478.
>
> **`minHeight: 600` significa 600 de conteúdo, 632 de quadro.** Os 32pt são a barra de título
> que a janela `.hiddenTitleBar` reserva no quadro, e não conteúdo que se recusa a comprimir —
> com `minHeight: 100` o shell inteiro comprime até 100. Fica 600, porque é o conteúdo que a
> constante deve descrever.

A lateral **nunca some por completo** — recolhida ela é a trilha de 62pt da Task 7B, que já
existe. Esse comportamento já está especificado e testado; a Task R só o dispara por largura
além de por clique.

### O núcleo testável

A decisão é aritmética pura e não pode morar numa `View` — um `View` do SwiftUI é
implicitamente `@MainActor` no Swift 6, e uma `static` dentro dele herda o isolamento e
**trapa em runtime** quando chamada de teste nonisolated. Isso já aconteceu nesta base
(`AgendaRail`, resolvido criando `AgendaSummary` em UNICore).

Portanto: criar `Packages/UNICore/Sources/UNICore/PaneLayout.swift`.

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

- [ ] **Step 1: Escrever os testes que falham**

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

- [ ] **Step 2: Rodar para ver falhar**

`cd Packages/UNICore && swift test --filter PaneLayout` → FAIL, `PaneLayout` não existe.

- [ ] **Step 3: Implementar `PaneLayout`**, **Step 4: ver passar**, **Step 5: commit**

- [ ] **Step 6: Ligar na `InboxScreen`**

`InboxScreen` lê a largura com `GeometryReader` (ou `containerRelativeFrame`), chama
`PaneLayout.resolve`, e passa o resultado adiante. `FolderSidebar`, `MessageList` e
`AgendaRail` param de cravar `.frame(width:)` e passam a receber a largura resolvida.
As constantes `expandedWidth` / `width` viram os valores **canônicos** que `PaneLayout`
usa, não larguras aplicadas direto na View.

Animar a transição com o mesmo `easeInOut(duration: 0.18)` que o toggle manual já usa, para
recolher por arraste e por clique parecerem a mesma coisa.

- [ ] **Step 7: Baixar o piso da janela**

`App/OkamiUNIApp.swift`: `minWidth: 860, minHeight: 600`. Verificar que a altura de fato
desce até 600 — hoje ela trava em 732 mesmo com `minHeight: 700`, o que significa que algum
conteúdo tem altura intrínseca grande demais. Achar e corrigir.

- [ ] **Step 8: A busca da barra**

`WindowChrome.swift:161` sai de `.frame(width: 400, height: 28)` para uma faixa que encolhe
em janela estreita sem colidir com as abas nem com o seletor de temas.

- [ ] **Step 9: Verificar com a janela na mão**

Redimensionar de 860 até a tela cheia observando as três transições. Capturar em 880, 1000,
1200 e 1440. Nenhuma transição pode cortar texto, sobrepor painel, ou fazer a barra estourar.

### O que não muda

A fidelidade em 1440×916 que a Task P estabeleceu. Depois da Task R, a janela em 1440×916
tem de continuar idêntica ao que a Task P entregou — a responsividade acontece **fora** desse
ponto, não em cima dele. Recapturar em 1440 e comparar com a captura da Task P.

---

## Marco 1.5 — o que o dono do projeto pediu em 27/08 para conseguir validar

Palavras dele, na íntegra:

> "varias coisas, primeiro a gente ta sem modal nehum eu nem consigo testar escrever email,
> responder, agenda e etc, outra coisa a barra superior está bem ruim nao está conforme eu
> falei ou seja os icones do mac ainda estao desalinhados da nossa ferramenta, recomendo
> colocar o logo ao lado do seletor de tema e ajustar a barra porque está bem ruim, terceiro
> ponto, tem uma barra entre a lista de email e o email em si porém eu nao consigo
> redimensionar para direita e esquerda para deixar o composer maior ou menor, isso também
> deveria se repetir com a barra de calendário outro ponto a aba de agenda está literalmente
> vazia"

Três destes itens estavam **fora do Marco 1 por decisão minha**, registrada na seção "o que
este marco deliberadamente não faz": composer, aba Agenda e janelas destacadas. A decisão
estava errada pelo motivo que importa — ela deixou o app impossível de validar por quem
encomendou. O escopo passa a incluí-los.

---

## Task S: Barra superior — alinhamento com os controles nativos

**Files:** `Packages/UNIShell/Sources/UNIShell/Chrome/WindowChrome.swift`, `App/OkamiUNIApp.swift`

O dono reclamou disto **duas vezes**. A Task P reduziu o vão de 45pt para 13pt corrigindo a
área segura, mas o resíduo vertical continua: os semáforos nativos têm centro em y=16 e os
nossos controles em y=29, numa barra de 58pt.

O relatório da Task P registra que `NSTitlebarAccessoryViewController` não teve efeito em
janela `.hiddenTitleBar`. Isso não esgota as opções. Tentar, nesta ordem:

1. **Reposicionar os botões nativos.** `window.standardWindowButton(.closeButton)` devolve um
   `NSButton` real; dá para mover cada um, ou mover a superview deles, para o centro vertical
   da barra de 58pt. É API pública e é como apps de barra alta fazem.
2. Se (1) não funcionar, **alinhar os nossos controles aos deles** — a primeira fileira da
   barra passa a ter centro em y=16 em vez de y=29.

Uma das duas tem de resolver. "Não dá" não é resultado aceitável aqui: existem apps de
terceiros nesta máquina com barra alta e semáforos centrados, e o dono citou dois deles.

**Layout que o dono pediu:** o lockup do logo sai da esquerda e vai **ao lado do seletor de
temas**, à direita. A esquerda fica com os semáforos, o botão da lateral e as abas —
encostados, no ritmo do Chrome e do app do Claude, que foram as referências que ele deu.

Isso é divergência deliberada do protótipo, pedida pelo dono. Registrar no relatório.

- [ ] Medir as posições atuais por acessibilidade e registrar antes/depois de cada controle
- [ ] Aplicar (1) ou, falhando, (2)
- [ ] Mover o lockup para a direita, ao lado do seletor
- [ ] Recapturar em 880, 1200 e 1440 — a barra não pode estourar em nenhuma
- [ ] Teste travando as posições/ordem dos controles como função pura (fora de `View`)

---

## Task T: Divisórias arrastáveis entre painéis

**Files:** `Packages/UNICore/Sources/UNICore/PaneLayout.swift`,
`Packages/UNIShell/Sources/UNIShell/Inbox/InboxScreen.swift`, novo `Inbox/PaneDivider.swift`

Pedido: *"tem uma barra entre a lista de email e o email em si porém eu nao consigo
redimensionar para direita e esquerda... isso também deveria se repetir com a barra de
calendário"*.

Duas divisórias arrastáveis: **lista ↔ leitor** e **leitor ↔ agenda**. A da lateral também,
se sair de graça.

Regras:

- O arraste ajusta a largura **dentro das faixas que a `PaneLayout` já define** (lista
  320–420 hoje; a faixa pode ser alargada se o arraste pedir, mas o leitor nunca abaixo de
  420). A `PaneLayout` continua sendo quem decide o que cabe — o arraste vira mais uma
  entrada dela, ao lado de `wantsSidebar`/`wantsAgenda`, e **não** um bypass.
- A largura escolhida **persiste** entre execuções (`UserDefaults`, como o `ThemeStore`).
- Estreitar a janela até a faixa não caber mais não pode apagar a preferência: mesma regra de
  intenção-versus-cabimento da Task R.
- Cursor de redimensionamento horizontal ao passar por cima; alvo de arraste com pelo menos
  6pt de largura mesmo que a linha desenhada tenha 0,5pt.
- Duplo clique na divisória volta à largura canônica.

O núcleo (clamp, persistência, resolução com as faixas) é aritmética pura → vai na
`PaneLayout`, em UNICore, com testes. A `View` só traduz o gesto.

---

## Task U: Janelas — composer, resposta, email destacado, detalhe do compromisso

**Files:** novo diretório `Packages/UNIShell/Sources/UNIShell/Windows/`, mais os ganchos em
`ReaderPane.swift`, `AgendaRail.swift`, `InboxScreen.swift`

Sem isto o dono não consegue testar nada do fluxo de escrita. As quatro telas estão no
protótipo e são a fonte da verdade:

| tela | linha do `.dc.html` | tamanho |
|---|---|---|
| 03 Composer em janela | 788–1059 | 820×660 |
| 04 Detalhe do compromisso | 588–742 | 560 × até 86% |
| 05 Email em janela | 743–787 | 800×600 |
| 06 Nova mensagem | 368–587 | 820×620 |

- Cada uma é uma janela de verdade (`Window`/`WindowGroup` ou `NSWindow`), não uma folha
  dentro da janela principal — o protótipo as chama de "em janela" e desenha sombra e raio
  próprios.
- Gatilhos: "Responder" no leitor abre 03; duplo clique numa mensagem abre 05; "Nova
  mensagem" (⌘N e um botão na barra) abre 06; clicar num compromisso da trilha abre 04.
- **Não envia nada.** Marco 1 não tem rede. "Enviar" fecha a janela e registra no console.
  Isso é limite de marco, não de fidelidade: a janela tem de ficar visualmente completa.
- O tema atual atravessa para as janelas novas (`.theme(...)` e o `ThemeStore` no ambiente).

---

## Task V: Aba Agenda — a tela 02 do protótipo

**Files:** novo `Packages/UNIShell/Sources/UNIShell/Calendar/WeekScreen.swift`,
`InboxScreen.swift` (troca de aba)

Hoje `Workspace.calendar` renderiza vazio — *"a aba de agenda está literalmente vazia"*.

A tela 02 "Agenda semanal" começa na linha **1394** do `.dc.html` e é a fonte da verdade:
cabeçalho com as abas Dia/Semana/Mês, grade da semana, colunas por dia, faixa de horas e
blocos de compromisso.

> **Correção, 27/08:** a primeira versão desta tarefa listava "a seção que vem do email" como
> parte da tela 02. Errado — "Vindo do email" está na linha 1381, dentro da tela 01, e já está
> implementada como `AgendaRail.pendingSection`. O implementador achou e devolveu
> NEEDS_CONTEXT em vez de inventar a seção.
>
> **Contradição do próprio protótipo, decidida no produto:** `RAIL` (1617) põe 5 compromissos
> na terça 25; `WEEK` (1625) põe 3, com títulos encurtados. A regra "o protótipo vence"
> pressupõe que ele tenha uma resposta; aqui tem duas, então o critério passa a ser o produto —
> a mesma terça não pode mostrar coisas diferentes em duas visões do mesmo app. A terça sai de
> `Fixtures.agenda`; os outros seis dias saem do `WEEK`. Os títulos curtos do `WEEK` são
> renderização para coluna estreita, não dados: encurte ao desenhar, não guarde dois títulos.
>
> **`AgendaItem` ganha `dayOffset: Int = 0`**, dias relativos a `Fixtures.today`, aditivo.
> Não uma `Date`: o tipo modela horário de parede de propósito, e uma data reintroduz a
> conversão de fuso que já foi bug aqui. O Marco 4 troca por data real com o EventKit.
> A alternativa (semana num `Fixtures.week` separado) foi recusada por embarcar um defeito
> conhecido — clicar num evento de quarta abriria a janela 04 vazia.
>
> **Dia e Mês** (1439–1497) ficam fora deste marco, desenhadas e **visivelmente desabilitadas**,
> não inertes: aba que parece clicável e não faz nada é a mesma falha que originou esta tarefa. Mesmas regras dos outros painéis: cor/raio/tipografia do `Theme`, medidas do
protótipo, nada de limitar contas.

Sem EventKit neste marco — a semana sai das fixtures, como a trilha diária. Estender
`Fixtures` com uma semana de compromissos, mantendo `Fixtures.today` como âncora e sem
refixar fuso (ver a nota da Task 10).

---

## Definição de pronto

O Marco 1 está fechado quando:

1. `xcodegen generate && xcodebuild ... build` termina em `BUILD SUCCEEDED` sem avisos de concorrência.
2. Os três pacotes passam nos testes.
3. `FontRegistry.missing` volta vazio em runtime.
4. Todos os itens do checklist do Step 7 da Task 11 estão marcados.
5. O app abre, navega entre mensagens, filtra por busca e troca entre os 26 temas sem travar.

## O que este marco deliberadamente não faz

Para o Marco 2 não achar que herdou algo pronto:

- Nenhuma rede. `MailStore` só fala com `InMemoryMailSource`.
- Nenhum acesso a calendário. O botão "Colocar na agenda" só imprime no console.
- Nada de composer — a barra de resposta do protótipo (linhas 1128–1340) fica fora.
- A aba Agenda é um placeholder.
- Nenhum resumo é gerado; `Message.summary` vem das fixtures.
- Sem janelas destacadas, sem ⌘K funcional, sem anexos.
