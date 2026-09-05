# Decisões de engenharia — OkamiUNI

**Português (Brasil)** · [English](decisoes-de-engenharia.en.md)

> Registro histórico de engenharia. Cada entrada descreve evidências e decisões da época. Totais de testes, etapas de implementação e regras iniciais de consentimento de IA são históricos; o [README da v0.5.4](../README.pt-BR.md) descreve o comportamento atual. Em particular, a v0.5.3 substituiu o opt-in separado para análise remota descrito abaixo. Exemplos de código e identificadores originais são preservados.

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
- **`width` do protótipo nem sempre é a largura da caixa.** Não há
  `box-sizing: border-box` global: o autor o declara elemento a elemento, e onde não declara
  vale `content-box` — o `padding` soma **por fora**. `.frame(width:)` do SwiftUI é a caixa
  toda. Cravar o número do CSS no quadro externo encolhe o conteúdo pelos dois recuos: o
  seletor de data de `width: 244px; padding: 12px` mede 268, não 244, e com 244 as células de
  33,1pt viravam 30,3. Leia o `box-sizing` **computado** antes de copiar a largura.
- **`Rectangle` irmã num `HStack` não tem altura própria** — ela pede o máximo disponível. Como
  faixa de cor de um cartão isso só passa despercebido enquanto a altura do cartão vem imposta
  de fora; numa célula com altura de sobra, a mesma faixa esticou uma pastilha de 16pt para
  mais de 50. Faixa de borda é `.overlay(alignment:)`, não irmã.
- **`flex: 1` com `min-height: 0` não é `.frame(maxHeight: .infinity)`.** O CSS deixa a linha
  ignorar o tamanho do conteúdo; o SwiftUI ainda respeita o mínimo intrínseco, e a linha mais
  cheia rouba altura das outras. Para N linhas iguais, o conteúdo entra por `.overlay` sobre um
  `Color.clear` — que não tem tamanho próprio — com `.clipped()`.

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

Alinhamento era a exceção e morava no atributo do CoreText, que já tem fronteira de
parágrafo. **Isso valia enquanto o editor era o `TextEditor`** — ver a entrada seguinte, que
o substituiu por um `NSTextView`.

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

## Comparar a caixa inteira esconde defeito de empilhamento

O harness **enxerga** ordem de desenho: tirar o `zIndex` da barra de formatação faz
`ToolbarPanelTests` cair na hora. Ele só não enxerga quando a **medida** está errada, e o
jeito errado é natural o bastante para ter passado por mim.

A lista de contatos mede ~280pt e a barra que a cobria, ~50. Coberta, ela continua desenhando
inteira **acima** da barra (na própria linha do campo) e **abaixo** dela (por cima do editor,
que a linha ganha por ser desenhada depois). A caixa que envolve a diferença media 312pt nos
dois casos, e o teste passava com o defeito no lugar. Medido na fatia da barra: **0** pixels
contra 13.718.

Regra: quando o que cobre é uma **faixa** e o que é coberto atravessa ela, meça **dentro da
faixa**, não a caixa toda. E localize a faixa no próprio desenho — cravar a coordenada faz o
teste passar a medir outro lugar assim que uma linha nova entra no cabeçalho. A âncora usada
lá é a cápsula de fonte e corpo, o único pedaço da barra pintado em `btn`.

Corolário da mesma família, achado no cartão da paleta: **sombra não é cartão**. O cartão tem
`box-shadow: 0 10px 12px`, e a sombra estica a caixa da diferença em ~30pt — o bastante para
"o cartão cresceu" passar com o item de cor livre arrancado (80pt contra 117). Conte as linhas
**opacas** numa coluna que atravessa o cartão: 38 sem o item, 66 com ele.

## O menu que um `<select>` abre não é do protótipo

Vale antes de alguém especificar "desenhe o menu como o protótipo": os quatro `<select>` do
`.dc.html` — fonte, corpo, conta e rascunho sugerido — têm o **controle fechado** estilizado
(`appearance: none`) e o menu **do sistema**. `appearance: none` não alcança o popup em
navegador nenhum.

O menu próprio do design é outro: o seletor de tema (linha 328), um gatilho `div` com o mesmo
`▼` e um painel absoluto de `max-height: 420px; overflow-y: auto`. É dele que se copia painel,
e é ele que dá o teto de rolagem para uma lista de centenas de fontes.

O defeito que o dono relatou como "dropdown do sistema" é do **controle fechado**: um
`Picker(.menu)` é um `NSPopUpButton` e pinta a moldura do macOS por cima da cápsula do design.
Dá para medir sem olhar: o controle do protótipo é chapado, então fora dos glifos todo pixel
de dentro da cápsula está no token `btn`. Medido — 0,002 com `Picker`, 0,77 com o controle
nosso.

## O menu de contexto deixou de ser do sistema (2026-08-27, Task AN)

**Decisão revogada.** Ficava escrito aqui, e em `ContextMenuHost.swift`, que "menu de contexto
é do sistema, e o protótipo não desenha nenhum". O dono do projeto mandou o print — o `NSMenu`
cinza do macOS, com o realce rosa do sistema, em cima de uma interface que desenha todos os
dropdowns dela — e disse: "as actions estão usando ainda o padrao do sistema ao invés de
custom". Não vale mais.

O que substituiu o `contextMenu` do SwiftUI, sem mexer numa linha do **conteúdo** dos menus
(`UNICore.ContextMenus` continua sendo o modelo, com os mesmos testes):

- `RightClickCatcher` — uma `NSView` que **só existe para o mouse quando o evento corrente é de
  botão direito** (ou Control-clique). Para qualquer outro evento o `hitTest` devolve `nil` e o
  AppKit segue procurando, caindo na `NSHostingView`. É o que deixa clique, duplo clique e o
  arraste lateral da linha intactos: o SwiftUI não tem gesto de botão direito, e uma `NSView`
  opaca por cima roubaria os três. Ela vai de `overlay`, nunca de `background` — o teste de
  acerto do AppKit corre de frente para trás, e só quem está na frente pode devolver `nil`.
- `ContextMenuPanel` + `MenuSurface` — o painel, no idioma do `ComposerSelect`: `surface`,
  raio `--r3`, borda `strokeBorder` de um pixel do dispositivo em `line`, realce `accentSoft`
  com tinta `accentInk`, divisória `line2`. A divisória e o realce **saem** do `ComposerSelect`
  e passam a ser compartilhados: duplicar idioma visual é como os dois `.stroke` borrados
  sobreviveram um marco inteiro.
- `ContextMenuPresenter` — uma janela sem moldura por nível, um menu aberto por vez no app.
  Janela e não `overlay` pelo motivo já registrado do `popover`: um `overlay` é recortado pela
  janela, e um menu aberto na última linha da lista sairia cortado no rodapé.
- `UNICore.MenuPlacement` — a aritmética de virada e de ancoragem do submenu, em coordenadas
  de tela do AppKit (y para cima), com testes que medem o ponto de virada **por um ponto**.

**Exceção deliberada: o editor do composer fica no menu do sistema.** `ComposerTextView`
*acrescenta* itens ao `NSMenu` que o AppKit monta (ver `augment(_:)`), e esse menu traz
ortografia, substituições e serviços. Redesenhá-lo custaria essas funções, que não têm
equivalente nosso. Se o dono quiser mexer nele também, é conversa separada.

Duas armadilhas medidas no caminho, ambas do tipo "o sistema decidindo a aparência por baixo do
pano":

1. **`.disabled` apaga o botão sozinho.** Com ele no lugar, o teste de pixel do item
   desabilitado continuava passando com a tinta `ink4` **arrancada** do código — a opacidade do
   SwiftUI apagava o rótulo do mesmo jeito. O clique morre em `allowsHitTesting` e na guarda da
   ação; o apagado é o token, e aí o teste tem o que afirmar.
2. **A sombra do tema passa exatamente por `line2`.** Contando o bitmap inteiro, um painel sem
   separador nenhum acusava 4.454 pixels de divisória em `tinta`: o degradê da sombra sobre
   `paper` cai dentro da tolerância de 0,02. Toda contagem por token do painel é feita numa
   janela **dentro** dele.

## O que era "limite do SDK" era limite do `TextEditor`

Tabela, hyperlink e justificado ficaram desabilitados um marco inteiro, com o motivo escrito
no `help`, e o motivo estava certo **para o tipo em uso**: `AttributedString` não tem modelo
de tabela, e `AttributeScopes.CoreTextAttributes.TextAlignmentAttribute` tem três casos.

O que não estava certo era a conclusão. Trocado o editor por um `NSTextView`, os três saem
de `NSParagraphStyle` — `textBlocks` para a tabela, `.justified` para o alinhamento — e o
link é o `\.link` da Foundation, que o `NSTextView` desenha e clica sozinho.

A mesma correção alcançou a altura de linha. O relato anterior era que `NSParagraphStyle` não
servia porque a conformidade dele a `Sendable` é indisponível no macOS. Verdade — mas a
exigência de `Sendable` é da `AttributedTextValueConstraint` **do SwiftUI**. Sem `TextEditor`
não há restrição, e `minimumLineHeight`/`maximumLineHeight` voltam a ser o caminho normal.

Regra de método que vale além daqui: **"não dá neste SDK" quase sempre quer dizer "não dá
neste tipo".** Antes de escrever a frase, vale perguntar qual tipo está fechando a porta e se
ele é obrigatório.

## `NSTextTable` é TextKit 1

O `NSTextView()` de conveniência entrega TextKit 2 (`textLayoutManager` preenchido,
`layoutManager` nulo), e ali não há `textBlocks`. Montar a vista à mão — `NSTextStorage` +
`NSLayoutManager` + `NSTextContainer` — devolve TextKit 1, que desenha a grade e, de quebra,
é o que responde `firstRect(forCharacterRange:)` e `lineFragmentRect(forGlyphAt:)`, que é
como este projeto mede o cursor sem lançar o app.

## Célula de tabela mora na **quebra** do parágrafo, não no primeiro caractere

Cada célula é um parágrafo, e o atributo que diz "linha 1, coluna 0" precisa de um portador
estável. O primeiro caractere não serve: o AppKit dá ao texto digitado os atributos do
caractere **à esquerda** do ponto de inserção, e no começo de uma célula vazia esse caractere
é a quebra da célula **anterior**. Digitar na célula (1,0) escreveria texto marcado como
(0,1).

A quebra do próprio parágrafo não sofre disso, e num parágrafo vazio ela é o único caractere
que existe. Pela mesma razão `RichBody.align` escreve no parágrafo **e** na quebra: escrever
num intervalo vazio de `AttributedString` não faz nada, e sem a quebra a linha em branco
entre dois parágrafos ficaria sem alinhamento e sem altura de linha — que é o defeito do
"cursor gigante" reentrando por outra porta.

## Ponte de ida e volta precisa de uma régua só

`AttributedString.Index` conta caracteres; `NSAttributedString` conta UTF-16. Converter por
`distance(from:to:)` bate enquanto o texto é ASCII e desalinha no primeiro emoji, e o sintoma
é a seleção pulando sozinha. A conversão correta passa pela `String` que os dois partilham:
`String.Index(_:within:)` e `AttributedString.Index(_:within:)`, mais `NSRange(_:in:)`. Há
teste com `"bom 😀 dia"` justamente para isso.

## Painel que abre perto da borda direita abre para a esquerda

O painel de hyperlink nasceu ancorado em `topLeading`, como as amostras de cor — mas o `↗`
fica a ~180pt da borda da janela de 820 e o painel mede 268. O botão "Aplicar" saía decepado
pela borda.

O que isso ensina sobre teste: contar a caixa do painel não pega o defeito — ela continua
existindo do mesmo tamanho, fora da tela. Pega-se medindo o **bitmap**, e a cor a procurar
não pode ser a de dentro do campo: em `tinta`, `btn` e `surface` diferem 0,02 e qualquer
tolerância razoável junta as duas. A borda, em `btn-line`, separa.

## Uma célula de tabela é uma **instância** de `NSTextTableBlock`, não uma coordenada

O `NSTextTable` junta numa célula só os parágrafos que partilham a **mesma instância** de
`NSTextTableBlock`. Dois blocos com `startingRow` e `startingColumn` iguais não são a mesma
célula: são duas células empilhadas na mesma coordenada, e a linha inteira recalcula as
larguras.

Isso não aparece enquanto cada célula tem um parágrafo só. Aparece no primeiro Enter dentro
de uma célula — que é o gesto mais comum que existe numa tabela. Medido, com uma grade 2×2 e
uma quebra no meio de uma célula: o desenho saía com **quatro** colunas (`minX` em 9, 162,
239, 315) no lugar de duas (9, 239). Foi o "ao dar enter ele quebra a tabela toda" que o dono
relatou usando.

O conserto é cachear o bloco por (tabela, linha, coluna) na hora de projetar. O modelo já
estava certo o tempo todo — dois parágrafos com a mesma coordenada — e é por isso que um
teste sobre o **atributo** teria passado com o defeito no lugar. Só a régua do desenho pega.

## Enter dentro de uma célula tem dois caminhos, e eles falham em lugares diferentes

Depois do bloco partilhado, Enter **no meio** de uma célula já funcionava: o
`NSTextStorage` uniformiza o estilo de parágrafo ao arrumar os atributos e o parágrafo novo
herda os blocos do vizinho. **No começo** da célula, não: medido, o parágrafo novo saía sem
célula nenhuma e ia para a largura toda (`colunas` em 0, 9, 239), partindo a tabela em duas.

Por isso existem dois guardas, e não um: `insertNewline(_:)` força o estilo de parágrafo
corrente na quebra, e os atributos de digitação carregam os `textBlocks` do parágrafo do
cursor. Cada um sozinho basta para o caso do meio; só o par cobre a borda.

Lição de método: ao consertar comportamento de tecla, o caso do **meio** e o das **pontas**
são dois testes, não um. Um conserto que passa nos dois pode ter duas causas independentes,
e desligar um guarda de cada vez é o que revela qual delas o teste está de fato provando.

## Painel atrás de uma linha é `background`, não irmão de `ZStack`

Mesma família da `Rectangle` irmã num `HStack`, achada de novo no arraste lateral da lista. O
painel de ações fica **atrás** da linha e precisa preencher a altura dela, o que pede
`maxHeight: .infinity`. Como irmão num `ZStack`, esse `maxHeight` deixa de descrever "preencha
a linha" e passa a dizer "tome tudo o que houver": a pilha cresce até o que o pai oferecer e a
linha só se descobre esticada.

Medido, com um palco de 140pt e uma linha de 106: com o painel irmão, a linha passava a ocupar
os 140 inteiros, com o conteúdo centrado e 17pt de painel sobrando em cima e embaixo. Em
lista, isso é a linha **mudando de altura no instante em que o arraste começa** — o "a lista
não pode pular" do brief, entrando por uma porta que nenhuma medida de largura pega.

Como `.background { … }` o painel é medido pelo conteúdo: ele preenche e não opina. E o
`.offset` que desliza a linha não mexe no quadro de layout, então o fundo fica parado enquanto
ela passa por cima — que é exatamente o efeito desejado.

Régua que pega: contar as **colunas de pixel** que são fundo de painel, numa varredura
horizontal. Com o painel irmão a contagem dá a largura inteira da lista (370) em vez das duas
colunas (168), porque a varredura cai acima da linha, onde só o painel esticado desenha.

## Folga contra a borda não prova que o rótulo cabe

Num painel de colunas fixas, a tentação é medir a distância entre o glifo mais externo e a
divisória da coluna. Ela não pega truncamento — `Text` com `lineLimit(1)` corta e escreve as
reticências **dentro** do quadro, então a folga continua boa com "Arquiva…" na tela.

Pior: a medida de pixel só enxerga os rótulos que **aquela linha** desenha. "Não lida" só
aparece em mensagem lida; o painel direito de uma mensagem arquivada nunca mostra "Arquivar".
Provado quebrando, com o corpo do rótulo a 22pt: "Arquivar" passou a pedir 85pt numa coluna de
84 e o teste de folga do painel **direito** continuou passando, porque nem "Depois" (70) nem
"Hoje" (46) estouram ali.

O que prova é medir a largura que cada rótulo pede **solto**, sem quadro, contra a literal da
coluna — e percorrer todos os rótulos que existem, nos dois estados de leitura. As duas
medidas convivem: a de pixel prova que o rótulo foi desenhado e está centrado, a de largura
prova que ele cabe.

## Controle desabilitado não é o mesmo cinza que o token diz

`ink4` é `rgb(168,166,158)` e some no meio de qualquer corte de luminância calibrado para
texto. Mas o `.disabled()` do SwiftUI **escurece de novo** o que já está desenhado: a coluna
morta do painel de arraste saiu com fundo `rgb(237,235,229)` onde o token `surface2` é
`rgb(241,239,234)`, e o rótulo em `rgb(202,200,193)` onde `ink4` é `rgb(168,166,158)`.

Consequência para quem mede: um teste que classifique pixel por proximidade a token erra nos
dois lados num controle desabilitado — o fundo dele cai a 5 níveis de `surface3`, que é o fundo
de uma coluna **viva**, e a medida passa por acidente. A saída foi tirar o estado desabilitado
da medida de geometria (usar uma mensagem em que as duas colunas fazem algo) e provar o
apagamento à parte, comparando o pixel mais escuro de uma coluna com o da vizinha em vez de
cravar um corte.

## A revisão final provou os defeitos por mutação, não por leitura (2026-08-27)

Cinco frentes revisaram a branch inteira em `ae439e1`: UNICore, caixa de
entrada, composer/janelas, moldura/agenda, e uma auditoria dedicada aos ~605
testes. O método da auditoria — introduzir o defeito que o teste diz guardar e
ver se ele cai — condenou 12 testes e achou 5 defeitos críticos que a suíte
verde escondia: o negrito que não mudava a face desenhada, o "⤢" que perdia
cc/anexos, a trilha de agenda sem filtro de caixa, as duas últimas bordas
`.stroke` borradas em 1×, e o seletor de data que ignorava a navegação.

O padrão que fica: **todo defeito crítico sobrevivente morava atrás de um
teste decorativo.** A regra derivada, já aplicada nas quatro tasks de conserto
(AJ, AK, AL, AM): um teste novo só conta depois de confirmado vermelho com o
defeito reintroduzido. As provas estão nos relatórios em
`.superpowers/sdd/2026-08-26-okamiuni-shell/` (fora do versionamento).

Duas decisões de produto tomadas no caminho: "Reagendar" saiu da janela de
compromisso em vez de ficar mudo (volta no Marco 4, com EventKit), e a
sugestão de contato tem uma máquina só — a do `ContactDirectory`, com dobra
de acento, que também passou a valer para a busca da lista ("Revisao" acha
"Revisão").

## O dia de um compromisso guardado é uma data civil, nunca um deslocamento (2026-08-29, M3-11)

`AgendaItem.dayOffset` é um inteiro relativo ao "hoje" da tela, e isso é certo
para a tela: é o que deixa uma lista só alimentar a trilha do dia, a Semana e o
Mês sem nenhuma conversão de fuso. Para o disco é errado, e de um jeito que só
aparece no dia seguinte: com conta conectada o "hoje" é o relógio da máquina
(`AgendaClock.live`), então um compromisso gravado como `+1` seria "amanhã"
hoje, "amanhã" amanhã, e "amanhã" na semana que vem — fugindo um dia a cada
abertura, para sempre.

A tabela `created_agenda_item` (migração v5) guarda `day` como texto
`"AAAA-MM-DD"`. Três inteiros não têm fuso, não andam, e sobrevivem a uma
viagem. A tradução nos dois sentidos mora num lugar só, `CivilDay`, e é a única
fronteira: quem grava converte deslocamento em dia, quem lê converte de volta
contra o "hoje" daquela abertura. O `MailStore` recebe esse "hoje" injetado
(`agendaReferenceDay`), com `Fixtures.today` por padrão — é o que mantém as
capturas e os retratos do Marco 1 byte a byte iguais.

Tabela nova, e não a `agenda_item` da v1, por uma razão que decide sozinha:
`agenda_item.accountID` tem `REFERENCES account(id)`, e as chaves estrangeiras
estão ligadas. **Sem conta conectada não haveria onde gravar** — a mensagem de
exemplo tem `accountID` de fixture, e o `INSERT` seria recusado. Um compromisso
criado sem conta é da pessoa do mesmo jeito. A prova está em
`DatabaseAgendaStoreTests`: reintroduzir a chave estrangeira derruba cinco
testes com `FOREIGN KEY constraint failed`.

## Clique de `View` se prova com clique, e a janela do harness precisa ser ordenada (2026-08-29, M3-11)

O defeito "clicar na mensagem recolhida não abre nada" não era alcançável por
teste de lógica: a lógica da pilha estava certa, e o que faltava era o pedido de
corpo que só a `View` dispara. `ConversationStackView` nasceu com fronteira
própria para poder ser hospedada sozinha numa janela fora da tela e receber um
evento sintético dentro do processo.

Duas coisas medidas no caminho, e as duas contraintuitivas:

1. **Uma `NSWindow` nunca ordenada não processa mouse.** O `hitTest` acha a
   `View` certa e o `Button` do SwiftUI não dispara. `orderBack(nil)` numa
   janela a −50.000pt resolve sem tirar o foco de ninguém — ela continua fora
   de qualquer monitor e atrás de tudo.
2. **`NSApp.postEvent` mata o processo de teste.** `RehearsalDriver.hit` põe a
   soltura na fila do `NSApp` de propósito (os laços de rastreio do AppKit a
   procuram lá), e isso é indispensável no app; num processo de teste, mexer
   nessa fila termina o laço de drenagem da `main` e o processo **sai com 0 no
   meio do teste**, sem uma linha de relatório — rastreado até `exit` dentro de
   `swift_task_asyncMainDrainQueue`. Um `Button` do SwiftUI não usa laço de
   rastreio, então o par `sendEvent` direto basta.

E uma terceira, sobre o instrumento: o `.task` de uma `View` é agendado pelo
laço de execução. Esperar com `Task.sleep` deixa-o por correr, e o ensaio mede
um app que não existe — a espera tem de ser `RunLoop.run`, como o `Render` já
fazia.

---

## O prefixo "OnDevice" mentia (2026-09-01, SP1)

`OnDeviceTextAssisting`, `OnDeviceAssistantMailContext`, `LocalAssistantPanel` — o nome do
tipo e a cópia da tela diziam "local" incondicionalmente, desde antes de o provedor virar
configurável. Depois que Grok, LiteLLM, Codex e um CLI instalado passaram a poder receber o
mesmo conteúdo, frases como "Usa todas as caixas e a agenda carregadas neste Mac" e "Lendo o
contexto local…" continuavam no ar com qualquer um deles selecionado. Ninguém mudou essas
strings de propósito; elas só nunca foram escritas pensando em provedor remoto.

A correção não foi trocar a frase — foi tirar a decisão da pessoa que escreve a tela.
`AssistantDestination` carrega `isLocal: Bool`, e é a única fonte de verdade sobre para onde o
conteúdo vai: `ReaderPane`, `AssistantPanel`, `FolderSidebar` e `SettingsSections` perguntam a
ele antes de qualquer palavra que implique "aqui" ou "fora". A regra que fica: nenhuma frase no
app afirma processamento local sem checar `AssistantDestination.isLocal` primeiro — nunca por
convenção de nome de tipo.

## Timeout de 30 s era errado para prompt de 400 mil caracteres (2026-09-01, SP1)

O roteador nasceu com 30 s para API/LiteLLM, 60 s (teto 120 s) para CLI e 120 s só para OAuth
direto. Enquanto o orçamento do prompt era o da Foundation Models (8 mil caracteres), 30 s
bastava. Quando o email inteiro passou a entrar no prompt do provedor configurado (até 400 mil
caracteres), a mesma pergunta virou uma geração de minutos — e o dono viu o Grok morrer por
tempo, não por erro de API.

Duas coisas foram corrigidas, não só o número:

1. `URLRequest.timeoutInterval` não é o tempo total da chamada — é o teto entre pacotes. Uma
   geração que demora a começar estoura mesmo com a rede boa, e uma resposta longa que chega aos
   poucos pode nunca estourar por aí. O que fecha a conta é
   `URLSessionConfiguration.timeoutIntervalForResource`, que não estava configurado em lugar
   nenhum; agora toda sessão HTTP do assistente recebe os dois valores iguais.
2. O tempo do CLI tem piso, não só teto: um `codex` frio demora a subir. `cliRequestTimeout`
   passou a valer 120 s por padrão, com a faixa clampada em 30–300 s (era 60 com faixa 5–120).

`AssistantRouter.requestTimeout` e `cliRequestTimeout` foram para 120 s por padrão; `.providerOAuth`
mantém `max(requestTimeout, 120)`. `AssistantCLIAuthenticationProbe`, que só sonda presença e
não gera nada, fica com o próprio timeout de 4 s — não é o mesmo problema.

## Orçamento tem de atravessar tudo, não só o caminho que alguém lembrou de tocar (2026-09-01, SP1)

Um commit anterior (`0a6330a`) levou `Budget` até o contexto de um único email
(`AssistantPrompt.render(email:)`), e isso bastou para calar o sintoma mais visível: o email
inteiro ia para o provedor configurado. Mas `AssistantPrompt.transform` continuava cortando todo
texto em 8 000 caracteres fixos, e `render(_ workspace:)` — o prompt do briefing e das perguntas
sobre o ambiente — ignorava o orçamento e fixava 24 emails e 32 itens de agenda, provedor remoto
ou não. Corrigir um caminho e deixar os outros dois com constante fixa não é meio-caminho: é dois
bugs disfarçados de um só resolvido.

`Budget` ganhou `maximumTextCharacters` (8 000 em `.onDevice`, 400 000 em `.configured`),
`maximumWorkspaceEmails` (24 / 256) e `maximumWorkspaceAgendaItems` (32 / 128), e os três novos
consumidores (`transform`, `render(workspace:)`) leem os campos em vez de literal. A regra que
fica: `Budget` é um valor só, passado até a última função que monta texto para o prompt — nenhuma
função de renderização de contexto tem permissão para um número fixo próprio. Qualquer caminho
novo de prompt (uma faixa de briefing, uma nova superfície) recebe `budget` no parâmetro, ponto.

## Sem fallback silencioso de provedor (2026-09-01, SP1)

A tentação era óbvia: falhou no Grok, resume no Mac. É exatamente o que não pode acontecer. A
pessoa escolheu um provedor por uma razão — custo, qualidade, ou justamente privacidade — e um
fallback automático toma essa decisão por ela, em silêncio, no pior momento possível: bem quando
o provedor escolhido está com problema.

Nem a rota interativa (`AssistantConversation.ask/draftReply/...`) nem a fila de análise
automática (`MessageIntelligenceCoordinator.processPending`) caem para
`FoundationModelsMessageAnalyzer` quando o provedor configurado falha. A fila **pausa** depois de
três falhas de ambiente seguidas (auth, rede, CLI ausente — não uma só, que é ruído de rede
normal), grava o estado em `analysis_queue_state` (tabela nova de linha única, migração `v15`) e
mostra "Análise pausada · Tentar de novo" na barra lateral, com o motivo.

A tabela é própria, e não `sync_state`, pelo mesmo motivo de `created_agenda_item` na v5:
`sync_state.accountID` tem `REFERENCES account(id)` e as chaves estrangeiras estão ligadas — sem
conta conectada não haveria onde gravar. A fila é global, não por conta.

## Codex por assinatura roda pelo CLI, não por chave de API (2026-09-01, SP1)

A assinatura ChatGPT não vira crédito de API. O caminho que funciona é o runtime oficial do
Codex já instalado no Mac: o OkamiUNI executa o binário num processo isolado, e a sessão continua
sendo do CLI — nenhum token do ChatGPT passa pelo app, nem é lido, nem é serializado.

Consequência prática: `AssistantAvailability` para `.providerOAuth` com `kind == .codex` precisa
checar duas coisas — sessão presente **e** binário encontrado. Faltando o binário, o estado é
`.needsSetup`, não `.needsSignIn`; mandar a pessoa fazer login de novo não resolveria nada, porque
a sessão já existe.

E a sonda de presença não é de graça: `codexRuntime.isSignedIn()` sobe o app-server do Codex por
processo e faz um JSON-RPC local — não é rede, mas também não é instantâneo, e era chamada a cada
`save` de preferências. `AssistantProviderOAuthCoordinator` guarda `(signedIn, measuredAt)` com
TTL de 30 s para `.codex` (xAI e LiteLLM continuam lendo Keychain direto, sem cache — é leitura
local, já é barata). `AssistantAvailabilityModel.refresh()` também coalesce chamadas
concorrentes: nunca duas sondas em paralelo, e uma mudança que chega durante uma medida em
andamento não se perde — refaz a sonda ao terminar em vez de descartar o pedido.

## Dado não confiável vai entre delimitadores escapados, e só dois caracteres (2026-09-01, SP1)

Todo email, conta, caixa, agenda e turno de histórico entra no prompt dentro de
`<untrusted-app-context>` / `<untrusted-assistant-history>`, com `<` e `>` escapados por
`AssistantPrompt.escapedData`. Só esses dois: `&` é dado comum em assunto e link, e escapá-lo
faria o rascunho voltar com `&amp;` literal no corpo do email — a defesa contra injeção de
delimitador não pode quebrar o produto que ela protege.

A instrução personalizada da pessoa tem camada própria (`<user-configured-assistant-instructions>`),
abaixo da política fixa e explicitamente marcada como preferência secundária: ela ajusta forma e
especialidade, nunca revoga uma regra de segurança.

O golden `Packages/UNISync/Tests/UNISyncTests/Golden/workspace-prompt.txt` existe para que
acrescentar um campo ao contexto do ambiente seja uma decisão, e não um efeito colateral — e
pegou um bug de verdade na primeira geração: `<workspace-pending-items>` saiu como a descrição de
depuração de um `GRDB.SQL` (`SQL(elements: [GRDB.SQL.Element.sql("- [", []), ...])`) em vez do
texto esperado. O fechamento que monta essa seção tem duas `let` antes do `return`, e sem anotação
explícita `-> String` o solver do Swift 6 preferiu a conformação de `GRDB.SQL` a
`ExpressibleByStringInterpolation` à de `StringProtocol` que `.joined(separator:)` pedia —
ambiguidade silenciosa, sem erro de compilação, porque o resultado só era consumido por
interpolação padrão dentro do template final. Um vazamento real de estrutura interna de query
para dentro do prompt entregue à IA configurada, e só o golden — comparando texto contra texto —
tinha como flagrar.

## Opt-in para análise remota, e a porta usa um carimbo que o app controla (2026-09-01, SP1)

`AssistantSettings.automaticAnalysis` nasce `.onDeviceOnly`; ligar o provedor configurado nela é
opt-in explícito, com a frase "Cada mensagem recebida sai deste Mac para {label}." no toggle. Mas
a primeira versão do portão media a janela de consentimento contra `receivedAt` — o cabeçalho
`Date:` de quem mandou o email, não um carimbo que o app controla. Uma mensagem datada no futuro
(relógio do remetente errado, ou spammer de propósito) passava `receivedAt >= since` e saía para o
provedor no clique do opt-in, mesmo estando na caixa havia meses: a promessa "só mensagens que
chegarem depois" dependia de um dado que qualquer remetente escreve.

A migração `v16` acrescenta `message.firstSeenAt` (nova, não uma edição da `v15` já aplicada em
bancos existentes) com backfill no instante da migração — conservador de propósito: tudo que já
está na caixa é, por definição, anterior a qualquer opt-in futuro. `savePreservingIntelligenceProjection`,
o único caminho de gravação de mensagem em produção, guarda `min(atual, novo)`, para um re-sync
não fazer uma mensagem antiga parecer recém-chegada. A porta passou a comparar contra
`min(receivedAt, firstSeenAt ?? receivedAt)` — nunca `receivedAt` sozinho, que continua intocado
onde importa de verdade: é ele que dá sentido a "amanhã às 15h" na detecção de compromisso, e
clampá-lo ali estragaria a leitura da data real da mensagem.

## Uma máquina de estado só (2026-09-01, SP1)

`DashboardScreen` chegou a reimplementar a máquina de `AssistantConversation` por conta própria —
o próprio motor virou uma segunda fonte de verdade paralela à que a tela desenhava, e as duas
divergiram sem ninguém perceber até a revisão: o CTA do dashboard liberava rascunho checando
`mailInFocus(focus) != nil`, que caía em `focus.mail.first` na ausência de seleção, enquanto o
motor de verdade resolvia o escopo só pela seleção real (`.workspace` sem ela). Sem nenhum email
selecionado o botão dizia "Gerar rascunho", ficava habilitado, e falhava com "Criar uma resposta
requer contexto de e-mail." — e o briefing, que é o que deveria rodar ali, ficava inalcançável. O
painel do leitor tinha a mesma classe de defeito: o chip "Gerar resposta" chamava `ask()` com uma
pergunta livre em vez de `transform(.draftReply)`, então o rascunho saía formatado como resposta a
uma pergunta, não como prosa de email.

A correção não foi consertar cada predicado separadamente — foi tirar a permissão de qualquer
superfície ter predicado próprio. `DashboardScreen.run/runDraft/runSuggestion` foram removidos;
`DashboardScreen`, `AssistantPanel`, `MessageWindow` e o popover do leitor recebem uma instância
de `AssistantConversation` por injeção e chamam `ask/draftReply/briefing` nela, nunca decidem
sozinhas se um contexto "pode" rascunho. A regra que fica: uma superfície consome
`AssistantConversation`; ela nunca reimplementa um pedaço da lógica que já mora lá — nem para um
rótulo de botão.
