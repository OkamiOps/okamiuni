# Dashboard 08 — a IA trabalhando · plano de implementação

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development, uma tarefa por vez na mesma árvore.

**Goal:** construir a tela `design/08-dashboard-ia.dc.html` (aprovada em 2026-09-03) com a gaveta (09) e a janela (10) do assistente, em Swift, sobre o que já existe.

**Spec:** `docs/superpowers/specs/2026-09-01-ia-e-dashboard-design.md` (§2 dashboard, §3 triagem, §4 agente com ações) + a tabela de medidas no topo de `design/08-dashboard-ia.dc.html`. Onde o desenho 08 e a §2.2 divergirem, **vale o 08**.

## Global Constraints

- Swift 6 strict concurrency · macOS 26 · Swift Testing (nunca XCTest) · pt-BR em tudo.
- Só tokens do tema; hairline `1/displayScale`; `strokeBorder`; raios só `radiusSmall`. Uma única caixa de cor na tela (o herói).
- Lógica pura em UNICore, `nonisolated`, com teste próprio. Nada de decisão em `static` dentro de `View`.
- **A IA nunca executa sozinha.** Toda proposta vira ação só depois de clique. Ações passam por `ContextCommand` (fila transacional, desfazer).
- **Enviar** (ruling 2026-09-03): a §4 proíbe a *IA* de enviar e isso continua. "Enviar" de um rascunho visível inteiro é a pessoa enviando: na prévia envia direto pela fila de saída normal; na linha (texto truncado) seleciona a linha e pede confirmação de uma linha antes. Nunca envia rascunho que a pessoa não viu por inteiro.
- Rascunho antecipado e proposta remota obedecem ao **mesmo opt-in** da análise automática (`automaticAnalysis`, `automaticAnalysisSince`). Sem opt-in, só o Foundation Models antecipa.
- Regra aprendida ("Arquivar e aprender") é por endereço exato do remetente, revogável em Configurações, e aparece em "Tirei da lista".
- Teste que passa com o defeito reintroduzido é defeito.
- Suíte completa do UNIShell trava neste ambiente: filtros estreitos, um por vez.

## Interfaces (o que cada tarefa produz e a seguinte consome)

```swift
// UNICore — Tarefa 1
public struct DayPlan: Sendable, Hashable {
    public struct Hero: Sendable, Hashable { public let messageID: String; public let sentence: String; public let hasReadyDraft: Bool }
    public enum Proposal: Sendable, Hashable {
        case sendDraft(messageID: String, preview: String)            // "Resposta pronta. “…”"
        case later(messageID: String, until: Date, why: String)       // "Sem prazo… sexta 9h?"
        case archiveAndLearn(messageID: String, why: String)          // "Você nunca abriu…"
        case keep(messageID: String, why: String)                     // sem sugestão forte
    }
    public struct Row: Sendable, Hashable, Identifiable { public let id: String; public let item: DashboardFocus.MailItem; public let why: String; public let proposal: Proposal }
    public struct Section: Sendable, Hashable { public enum Kind: String { case waitingOnYou, due, lead }; public let kind: Kind; public let rows: [Row] }
    public struct Filter: Sendable, Hashable { public enum Category: String, CaseIterable { case people, deadlines, leads, broadcasts, newsletters }; public var on: Set<Category>; public var accounts: Set<String> }
    public struct Removed: Sendable, Hashable { public let messageID: String; public let subject: String; public let why: String }
    public struct ReplyBlock: Sendable, Hashable { public let day: Int; public let startMinute: Int; public let minutes: Int; public let messageIDs: [String] }
    public let hero: Hero?
    public let sections: [Section]
    public let counts: [Filter.Category: Int]
    public let removed: [Removed]
    public let replyBlock: ReplyBlock?
    public static func make(focus: DashboardFocus, drafts: [String: ReadyDraft], rules: [SenderRule], agenda: [AgendaItem], filter: Filter, now: Date, nowMinute: Int) -> DayPlan
}
public struct ReadyDraft: Sendable, Hashable, Codable { public let messageID: String; public let text: String; public let contentHash: String; public let modelVersion: String; public let usedAgenda: Bool }
public struct SenderRule: Sendable, Hashable, Codable { public let address: String; public let neverPriority: Bool; public let createdAt: Date }
public struct FreeSlots { public static func next(days: Int, minMinutes: Int, agenda: [AgendaItem], workday: ClosedRange<Int>, now: Date) -> [ (day: Int, start: Int, end: Int) ] }
```

## Tarefas (uma por vez, nesta ordem)

### Tarefa 1 · UNICore — `DayPlan`, `SenderRule`, `FreeSlots`
Puro. `make` decide: herói (o mais antigo entre os que esperam resposta com rascunho pronto; frase com dias esperando e "sim ou não" quando o rascunho é curto); seções; `why` por linha (a pergunta extraída pelo `MessageTriage`, ou o pedido, ou o prazo); proposta por linha (rascunho pronto → `sendDraft`; sem prazo e sem rascunho → `later` para o próximo dia útil 9h; remetente que a pessoa nunca abriu (`isRead == false` em todas as mensagens dele) e é disparo → `archiveAndLearn`); `removed` = o que `SenderRule` e a barreira de disparo tiraram, com o porquê; `replyBlock` = primeiro `FreeSlots` de ≥ 20 min depois de agora, antes do prazo mais próximo; `counts` por categoria e a aplicação do `Filter`. Testes com os sete emails do dono como fixture.

### Tarefa 2 · UNISync — rascunho antecipado e regras
- Tabela `ready_draft` (migração v20): `messageID`, `text`, `contentHash`, `modelVersion`, `usedAgenda`, `createdAt`. Fila serial reativa como a da análise: para toda mensagem com `needsReply` e sem rascunho para o hash atual, gera pelo `draftReply` do roteador — Foundation Models sempre; remoto só sob o opt-in. Se o `MessageTriage.intent == .scheduling` ou o texto pede disponibilidade, o prompt recebe `FreeSlots.next(days: 14)` e o rascunho grava `usedAgenda = true`.
- Tabela `sender_rule` (v20): `address`, `neverPriority`, `createdAt`. `ContextCommand.learnSender(address:neverPriority:)` grava e é desfazível.
- `AssistantAction` ganha `.learnSender(address:)` e `.reserveBlock(day:start:minutes:title:)`; o validador da §4 os aceita; `reply` continua abrindo o composer.

### Tarefa 3 · UNIShell — o dashboard 08
Reescrever `DashboardScreen` contra a tabela de medidas: cabeçalho de uma linha; herói; filtro em texto; seções; `DashboardRow` sem barra lateral, com ponto da conta e a linha `↳`; prévia com o cartão do rascunho **antes** do resumo; dia com o bloco sugerido; rodapé "Tirei da lista"; botão "Perguntar · ⌘J". `Enviar` conforme o ruling. `Reservar` cria o evento pelo `ContextCommand` existente de agenda. "Atualizado agora · próximo em N min": o dashboard recalcula a cada mudança do store e num relógio de 5 min. Render offscreen contra o mockup em `okami` e `tinta`; paridade de medidas em teste.

### Tarefa 4 · UNIShell — gaveta e janela do assistente
`AssistantDrawer` por cima do `InboxScreen` (440, borda direita, sombra, fundo a 45%), `⌘J` abre/fecha, Esc fecha. Reusa `AssistantConversation` com `answerWithProposals()` da §4; cada proposta vira `AssistantProposalCard` (botão confirmar + "ver"). Contexto: "o seu dia" ou o email selecionado, com trocar. Chips de partida. Ícone ↗ destaca em `AssistantWindow` (cena própria, ⌘W, uma por app). O campo do rodapé da lista sai.

### Tarefa 5 · Revisão final do branch, instalação, `main`, release 0.4.0.
