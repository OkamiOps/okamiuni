# Decisões de engenharia — OkamiUNI

Registro do que **não** dá para deduzir lendo o código. Cada entrada existe porque a escolha
custou caro, ou porque a alternativa óbvia estava errada.

O diário de execução detalhado vive em `.superpowers/sdd/<plano>/progress.md`, que o git
ignora por convenção. Este arquivo é a parte que precisa sobreviver a ele.

---

## Fixture de "hoje" é horário de parede, não instante

`Fixtures.today` já foi fixada em `America/Sao_Paulo`. Tudo que a lê formata com
`Calendar.current`. Numa máquina em Berlim o meio-dia virava 17:00 e a agenda marcava "agora"
no compromisso errado; em Tóquio o cabeçalho renderizava o dia seguinte.

**O pin de fuso era o defeito, não a solução.** Sem ele, `today` é meio-dia local de 25/08 em
qualquer máquina — que é o que a fixture quer dizer. Dois testes em `UNICore` travam a
invariante e falham se alguém refixar.

Pelo mesmo motivo `AgendaItem` guarda minutos desde a meia-noite e `dayOffset: Int`, nunca
`Date`: uma data ali reintroduz a conversão de fuso. O Marco 4 troca por data real quando o
EventKit entrar — dívida deliberada, não descuido.

## `View` é `@MainActor` implícito no Swift 6

Lógica pura num `static` dentro de uma `View` **herda o isolamento** e trapa em runtime
(SIGTRAP) quando um teste nonisolated a chama. Custou uma investigação inteira em `AgendaRail`.

Por isso `AgendaSummary`, `PaneLayout` e afins moram em `UNICore`, fora de qualquer `View`.

## Teste que passa com o código quebrado não vale

Sete rejeitados neste projeto. O padrão mais comum não é o teste vazio — é a asserção que liga
duas coisas em que **uma é derivada da outra**:

```swift
// eventLeading é DEFINIDO como labelGutter + gutterGap.
// Isto é verdadeiro por construção e passaria com a calha errada.
#expect(layout.eventLeading >= layout.labelGutter + layout.gutterGap)
```

Trave a literal. E depois de escrever um teste, quebre o código de propósito e confirme que
ele falha.

Corolário: teste que possa entrar em laço leva teto e asserção sobre o teto. Um `while let` sem
teto estourou o timeout de 600s em vez de falhar.

## Conversões CSS→SwiftUI que já custaram rodadas de review

- `.tracking()` é em **pontos**; CSS `letter-spacing` vem em **em**. `0.06em` a 8.5pt = 0.51pt.
- `.lineSpacing()` é o espaço **extra**: `line-height: 1.55` a 15pt → `1.55×15−15 = 8.25`.
- `.shadow(radius:)` ≈ **metade** do blur do CSS.
- `box-shadow` com **spread** é borda, não sombra. `.shadow(radius: 0, x: 0, y: 0)` não desenha
  nada — use `strokeBorder`.
- `soft(c, p)` no protótipo ≈ `.opacity(p/100)`.

## Intenção do usuário é separada do que cabe na janela

`wantsSidebar` / `wantsAgenda` são **intenção**; o que aparece é intenção **e** largura
suficiente. Sem essa separação acontece o bug clássico: o usuário abre a lateral, encolhe a
janela, ela fecha sozinha, ele alarga de novo — e ela não volta.

Arraste de divisória entra como mais uma entrada do mesmo modelo, nunca como bypass.

## Semáforos nativos podem ser recentrados

Um relatório anterior concluiu que não dava, tendo testado `NSTitlebarAccessoryViewController`
numa janela `.hiddenTitleBar`. **Dá** — reposicionando os `NSButton` que
`window.standardWindowButton(_:)` devolve. O desencontro de 13,5pt virou 0,5.

Lição de processo: "não dá" precisa dizer *o que foi tentado e medido*, senão fecha uma porta
que estava aberta.

## Quando o protótipo se contradiz, ele não decide

`RAIL` põe 5 compromissos na terça 25; `WEEK` põe 3, com títulos encurtados. A regra "o
protótipo vence" pressupõe que ele tenha **uma** resposta.

Com duas, o critério passa a ser o produto: a mesma terça não pode divergir entre duas visões
do mesmo app. Títulos curtos numa coluna estreita são **renderização**, não dados — encurte ao
desenhar, não guarde dois títulos.

## Nunca limitar contas

As 4 caixas das fixtures são exemplo de design. O app aceita qualquer provedor e qualquer
domínio. `Provider.imap` é o **caso geral** e vem primeiro no enum de propósito; Gmail e Graph
são atalhos por cima dele. Nada de `switch` sobre as contas das fixtures.

## Paralelismo entre implementadores exige fronteira de commit, não só de edição

Dizer a cada agente quais arquivos pode **editar** não basta. Um `git add -A` varreu os
arquivos de outra tarefa para dentro de um commit alheio, cuja mensagem não os mencionava —
conteúdo correto, histórico enganoso.

Todo dispatch paralelo tem de instruir: caminhos explícitos, nunca `-A` nem `.`, e
`git status --short` antes de cada commit.

## Integridade de asset binário não se verifica com `file`

Um PNG truncado (6.738 bytes, sem `IEND`) passou por dois agentes que rodaram `file` — que lê
só os 33 bytes do cabeçalho. O SwiftUI renderiza `Image` ausente como **nada**, em silêncio.

Verifique o marcador final e o tamanho. E base64 de ~50k caracteres não sobrevive ao
transporte entre agentes: baixe da origem.
