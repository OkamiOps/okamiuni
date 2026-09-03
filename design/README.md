# OkamiUNI — Design de referência

Origem: Claude Design, projeto **"Unibox: email e agenda integrados"**
`https://claude.ai/design/p/40478c81-e3be-42cc-aad1-f0c2d28d292c`

Baixado em 2026-08-26.

## Arquivos

| Arquivo | O quê |
|---|---|
| `design/tokens.json` | Fonte canônica estruturada dos valores de cor e tokens do tema (26 temas + fallback `base`) |
| `OkamiUNI - Mail + Agenda.dc.html` | Referência visual do protótipo; fornece nomes, notas, estados e proporções para conferência |
| `07-dashboard.html` | A tela 07 (tríptico), substituída pela 08; fica como registro |
| `08-dashboard-ia.dc.html` | **A tela do dia vigente**, aprovada em 2026-09-03: herói "Comece por aqui", filtro em texto, linhas com a proposta da IA, prévia com o rascunho antes do email, dia com bloco sugerido, botão do chat. Tabela de medidas no topo |
| `09-assistente-gaveta.dc.html` | O chat aberto em gaveta por cima da borda direita (⌘J) |
| `10-assistente-janela.dc.html` | O chat destacado em janela própria |
| `assets/uni-lockup-light.png` | Lockup da marca (tema claro) |

Assets ainda não baixados do projeto: `uni-lockup-dark.png`, `uni-mark-light.png`, `uni-mark-dark.png`.

## Telas (`data-screen-label`)

1. **01 Caixa unificada** — três painéis: lista de pastas/contas (370px de lista), leitura, coluna de agenda (262px)
2. **02 Agenda semanal** — visão de semana + coluna lateral 250px
3. **03 Composer em janela** — 820×660
4. **04 Detalhe do compromisso** — 560px, com campo de encaminhar
5. **05 Email em janela** — 800×600
6. **06 Nova mensagem** — 820×620
8. **08 Dashboard com a IA trabalhando** — substitui a 07. Em `design/08-dashboard-ia.dc.html`, com a gaveta (09) e a janela (10) do assistente. A IA propõe uma ação por linha e escreve a resposta antes de você abrir; nada executa sem clique.
7. **07 Dashboard** (substituída) — a tela do dia, em `design/07-dashboard.html` (arquivo próprio, não está no `.dc.html`): 1440×916, chrome de 64px com as abas Dashboard/Caixa/Agenda, prioridades em coluna única, trilha de agenda de 300px, pendências e o campo do assistente no rodapé. Quatro estados (cheio, vazio, com briefing, com transcript) e seletor de tema embutidos para conferência.

Janela principal: **1440×916**, chrome de macOS (semáforo), barra de 58px.

## Sistema de temas

São 26 temas. Cada tema resolve os mesmos **29 tokens**: **19 tokens visuais
por tema** e **10 tokens de tipografia/métrica** vindos do bloco `base` quando
o tema não os sobrescreve.

`--paper --surface --surface2 --surface3` · superfícies
`--ink --ink2 --ink3 --ink4` · texto
`--line --line2` · divisórias
`--accent --accent-ink --accent-soft --accent-line --on-accent` · destaque e tinta sobre destaque
`--btn --btn-line --btn-shadow --shadow` · controles

Tokens base de tipografia/métrica (10): `--serif` (Newsreader), `--sans` (SF Pro),
`--mono` (IBM Plex Mono), `--r2` 8px, `--r3` 10px, `--caps` 0.12em,
`--rowpad`, `--subj-weight`, `--subj-size`, `--body-font`. `--on-accent` também
existe no `base` como fallback de cor; temas que precisam de tinta escura sobre
o destaque o sobrescrevem.

`design/tokens.json` é a fonte canônica estruturada das cores e dos tokens. O HTML é
referência visual e de nomes/notas; não é a fonte estruturada dos valores de
cor.

Temas: tinta, linho, barro, noite, grafite, okami, brutal, vapor, papel, neon, clinico,
nexus, sinal, aura, whitex, blackbox, magenta, neural, corsa, corsaluz, brutalnoite,
contraste, reboot, comando, override, ambar.

## Funcionalidades visíveis no protótipo

- Caixa unificada sobre **4 contas** (busca "Buscar nas 4 caixas…", ⌘K)
- Abas **Caixa / Agenda** no chrome
- Triagem: Hoje / Depois / Tudo / Arquivado
- Tags por mensagem, remetentes agrupados
- Detecção de compromisso no corpo do email → "Colocar na agenda"
- Composer inline + em janela, com campos To/Cc/Bcc com autocomplete
- "Enviar e arquivar", "Salvar", rascunho sugerido
- Seletor de tema no chrome (popover com previews)
