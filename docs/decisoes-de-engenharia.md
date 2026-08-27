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

## Nunca dirigir a interface com eventos sintéticos

O app roda no computador de **trabalho** do dono. `CGEvent`, `keystroke` do System Events e
qualquer coisa que mova o ponteiro **tomam a máquina dele** enquanto ele está usando. Isso não
é uma questão de gosto; foi feito, ele reclamou, e não se repete.

O que usar no lugar:

- **Aparência e layout:** `Render` em `UNIShellTests/RenderHarness.swift`. Ele desenha a
  hierarquia SwiftUI numa `NSWindow` a 50.000pt fora da área visível, nunca trazida à frente.
  O AppKit renderiza tudo — `ScrollView`, `TextField`, o que tiver respaldo nativo. Nada
  aparece em tela, nada recebe foco. Com `UNI_RENDER_DIR=<pasta>` grava PNGs para inspeção.
  (`ImageRenderer` sozinho **não** serve: deixa lista e campo de texto em branco.)
- **Comportamento:** exercite o `MailStore` e os tipos puros direto. Quase toda pergunta de
  "isso funciona?" é pergunta de modelo, não de pixel.
- **Geometria de janela**, quando for inevitável: `open -g` lança **sem** trazer à frente, e
  leitura por acessibilidade não mexe em nada. Ler pode; sintetizar evento, não.

Armadilha do harness: parte do código formata data com `pt_BR` fixo e parte com
`Locale.current`, que resolve contra as localizações do bundle. No bundle de teste não há
nenhuma, então datas saem em inglês ali e em português no app. Injetar `\.locale` não corrige,
porque esses formatadores não passam pelo ambiente. É inconsistência real, marcada para
conserto — não relate como defeito de aparência.

## O anel de foco do sistema é invisível no harness, por construção

Três relatos de "contorno duplo" nos botões, com print: borda nítida, **folga**,
segundo anel, nos quatro lados. Uma causa era sombra `inset` desenhada por fora
(`4993e2e`). A que sobrava é o **anel de foco do macOS**, que o AppKit desenha
justamente com folga em volta do controle.

Ele nunca apareceu em renderização nenhuma nossa, e não por descuido: o AppKit só
desenha o anel quando a janela é a **janela-chave** de um app **ativo**. A janela
do `Render` fica a 50.000pt fora da tela e nunca é nem uma coisa nem outra.

**Consequência de método:** "não reproduzi no harness" não é evidência de que o
defeito não existe quando o estado que o dispara depende de foco, de janela-chave
ou de app ativo. Nesses casos o caminho é o mesmo de `debugOpenPanel`: um
parâmetro interno que força o estado, e comparar os dois desenhos.

O protótipo não tem anel de foco (`cursor: default`, nenhum `outline`), mas
apagar sem repor cega quem navega por teclado. `Support/FocusRing.swift` mata o
do sistema com `focusEffectDisabled()` e desenha o nosso **dentro** da forma do
controle, encostado na borda — a folga é a assinatura do defeito, não a segunda
linha.

Armadilha achada quebrando o teste de propósito: em `tinta`, `surface` e `btn`
diferem 0,02. Um teste que procure "o fundo reaparece entre a borda e o anel"
passa com 3pt de folga, porque as duas cores caem na mesma tolerância. Meça
**distância**, não igualdade de cor.

## `Font` do SwiftUI é opaca — texto rico precisa de um atributo próprio por baixo

`AttributedString` num `TextEditor` aceita `\.font`, mas `Font` só se **escreve**: não há
como perguntar a ela se está em negrito, em que corpo, em que família. Uma barra que só
escrevesse ficaria pela metade — selecionar um trecho já negrito não acenderia o B.

Por isso o corpo do composer guarda `BodyStyleAttribute` (família, corpo, negrito, itálico,
sublinhado, tachado, cor, realce) como **fonte de verdade**, e os atributos do SwiftUI são
uma **projeção** dele, reescrita a cada comando. Ler o estado da seleção lê o atributo, não
a fonte.

Consequência obrigatória: o editor precisa de
`.attributedTextFormattingDefinition(AttributeScopes.UNIComposerAttributes.self)`. Sem o
escopo declarado, o `TextEditor` descarta o atributo desconhecido e o modelo morre no
primeiro caractere digitado. Há teste que prova isso chamando `constrain(_:)` — o mesmo que
o editor aplica — com o escopo certo e com o escopo do SwiftUI puro.

Alinhamento é a exceção e mora no atributo do CoreText, que já tem fronteira de parágrafo.
Ele só tem `left`, `center` e `right`: **não existe justificar** neste SDK, e o botão "≡"
fica desabilitado por isso, não por preguiça.

## Escrever atributo invalida `AttributedTextSelection`

Medido nesta máquina: escrever um atributo num trecho parte os runs, e depois disso
`AttributedTextSelection.indices(in:)` devolve **ponto de inserção** em vez do intervalo que
tinha. Não é preciso mexer no texto para perder a seleção.

Efeito prático, se ignorado: o usuário seleciona, clica em **B**, clica em **I** — e o
itálico cai nos atributos de digitação em vez da seleção. A tela não muda e não há erro
nenhum. Por isso **toda** mutação do corpo passa por `text.transform(updating: &selection)`,
inclusive a que só mexe em atributos.

## Rótulo de estado não divide faixa com barra de ferramentas

O protótipo pendura "N palavras · não salvo" no fim da barra de formatação da tela 03. Em
820pt isso rouba ~150pt, os sete grupos deixam de caber, a `FlowLayout` quebra em duas
linhas e a moldura da faixa fica com o dobro da altura da borda — o "as box não estão
certas" que o dono do projeto relatou.

Regra: a faixa da barra é da barra. Contagem foi para a barra de título e carimbo de
salvamento para o rodapé, nas duas janelas. O teste mede
`NSHostingView.fittingSize.height` a 820, 1100 e 1440 — e mede também a 420, onde a faixa
**tem** de crescer, senão o teto passaria com uma medida presa.

## Hairline é um pixel do dispositivo, e `strokeBorder` não arredonda sozinho

O protótipo escreve `0.5px`. O navegador **não desenha meio pixel**: em 1× arredonda para um,
em 2× meio pixel CSS já *é* um pixel do dispositivo. Nos dois casos o design mostra **uma linha
cheia de um pixel**. Meio **ponto** ao pé da letra é outra coisa — em 1× é um pixel pintado
pela metade. Por isso `Hairline.thickness(_ displayScale:)` = `1 / displayScale`, lido do
ambiente por cada `View` que desenha borda.

O que só apareceu ao medir: **os dois caminhos de desenho não erravam igual.**

- `Rectangle().frame(height: 0.5)` — divisória — já saía **certa**. O SwiftUI alinha o quadro
  de uma forma cheia à grade de pixels, então ela virava um pixel inteiro mesmo com o número
  dizendo 0,5. Medida em `tinta`, com o código quebrado: `rgb(235,232,226)`, o token na bica.
- `strokeBorder(…, lineWidth: 0.5)` — borda — saía **lavada**. O traçado pinta com alfa
  parcial em vez de arredondar: `rgb(239,237,234)` onde o token é `rgb(218,214,206)`, 28 níveis.

É exatamente a assimetria que o dono relatou quatro vezes: divisória forte, borda fantasma, e
o olho trocando uma pela outra. A conclusão de método é que **"a hairline está errada" não é
uma pergunta só** — vale medir cada caminho de desenho, porque o mesmo número dá resultados
diferentes em forma cheia e em traçado.

Consequências que pegaram testes de carona, ambas por o desenho ter **melhorado**:

- `FocusRingMetrics.inset` tinha de virar função da escala junto com a borda. Recuo cravado em
  meio ponto contra borda de um ponto põe o anel por baixo dela, não encostado.
- `ComposerToolbarCapsuleTests` media as cápsulas por luminância e mesclava buracos menores que
  5px. Com a borda a meio ponto o pixel mais externo dela ficava **debaixo** do limiar de
  detecção e o buraco entre cápsulas media 5px; com a borda cheia ele passa a contar e o mesmo
  buraco mede 3. O corte foi para 2px — buraco dentro de cápsula continua 1px, e os dois
  números nunca se aproximaram. Literal calibrada contra desenho errado envelhece assim.

Armadilha do harness, achada antes de qualquer medida valer: `Render` renderizava em `scale: 2`
mas o `displayScale` do ambiente continuava o do monitor da máquina (1× nesta). Tudo que decide
espessura pela escala media a tela errada, e o teste de 2× verificava o desenho de 1× ampliado.
O `Render` agora injeta `\.displayScale` igual ao `scale` pedido.

## Integridade de asset binário não se verifica com `file`

Um PNG truncado (6.738 bytes, sem `IEND`) passou por dois agentes que rodaram `file` — que lê
só os 33 bytes do cabeçalho. O SwiftUI renderiza `Image` ausente como **nada**, em silêncio.

Verifique o marcador final e o tamanho. E base64 de ~50k caracteres não sobrevive ao
transporte entre agentes: baixe da origem.
