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
