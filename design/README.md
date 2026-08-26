# OkamiUNI — Design de referência

Origem: Claude Design, projeto **"Unibox: email e agenda integrados"**
`https://claude.ai/design/p/40478c81-e3be-42cc-aad1-f0c2d28d292c`

Baixado em 2026-08-26.

## Arquivos

| Arquivo | O quê |
|---|---|
| `OkamiUNI - Mail + Agenda.dc.html` | Protótipo completo (fonte da verdade: cores, espaçamentos, tipografia, estados) |
| `tokens.json` | 26 temas extraídos + tokens base |
| `assets/uni-lockup-light.png` | Lockup da marca (tema claro) |

Assets ainda não baixados do projeto: `uni-lockup-dark.png`, `uni-mark-light.png`, `uni-mark-dark.png`.

## Telas (`data-screen-label`)

1. **01 Caixa unificada** — três painéis: lista de pastas/contas (370px de lista), leitura, coluna de agenda (262px)
2. **02 Agenda semanal** — visão de semana + coluna lateral 250px
3. **03 Composer em janela** — 820×660
4. **04 Detalhe do compromisso** — 560px, com campo de encaminhar
5. **05 Email em janela** — 800×600
6. **06 Nova mensagem** — 820×620

Janela principal: **1440×916**, chrome de macOS (semáforo), barra de 58px.

## Sistema de temas

26 temas, cada um definindo os mesmos 18 tokens:

`--paper --surface --surface2 --surface3` · superfícies
`--ink --ink2 --ink3 --ink4` · texto
`--line --line2` · divisórias
`--accent --accent-ink --accent-soft --accent-line` · destaque
`--btn --btn-line --btn-shadow --shadow` · controles

Tokens base (comuns): `--serif` (Newsreader), `--sans` (SF Pro), `--mono` (IBM Plex Mono),
`--r2` 8px, `--r3` 10px, `--caps` 0.12em, `--rowpad`, `--subj-weight`, `--subj-size`, `--body-font`.

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
