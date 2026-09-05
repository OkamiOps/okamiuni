# OkamiUNI — Design reference

[Português (Brasil)](README.md) · **English**

Source: Claude Design, project **“Unibox: email e agenda integrados”** (“Unibox: integrated email and calendar”). [Claude Design project](https://claude.ai/design/p/40478c81-e3be-42cc-aad1-f0c2d28d292c).

Downloaded on 2026-08-26.

## Files

| File | Purpose |
|---|---|
| `design/tokens.json` | Canonical structured source for colors and theme tokens (26 themes plus the `base` fallback). |
| `OkamiUNI - Mail + Agenda.dc.html` | Visual prototype reference; provides names, notes, states and proportions for comparison. |
| `07-dashboard.html` | Screen 07 (three-column dashboard), superseded by 08; retained as a historical record. |
| `11-painel-do-dia.dc.html` | **Current dashboard** (approved on the afternoon of 2026-09-03): today's plan as a timeline with proposed blocks, “Waiting for you”, “You are waiting” (from sent messages), “You promised”, business filters, money and deadlines. |
| `08-dashboard-ia.dc.html` | Previous screen (superseded by 11), approved on 2026-09-03: “Start here” hero, text filter, rows with AI proposals, draft before the message in the preview, suggested day block and chat button. Measurements appear at the top. |
| `09-assistente-gaveta.dc.html` | Chat open in a drawer over the right edge (`⌘J`). |
| `10-assistente-janela.dc.html` | Chat detached into its own window. |
| `assets/uni-lockup-light.png` | Brand lockup for light themes. |

The light/dark lockups and marks used by the app are in [`App/Resources/Assets.xcassets`](../App/Resources/Assets.xcassets). Use the original assets; do not redraw the brand.

## Screens (`data-screen-label`)

1. **01 Unified inbox** — three panes: folders/accounts and message list (370px list), reader and calendar column (262px).
2. **02 Weekly calendar** — week view and 250px sidebar.
3. **03 Composer window** — 820×660.
4. **04 Appointment detail** — 560px, with a forwarding field.
5. **05 Email window** — 800×600.
6. **06 New message** — 820×620.
7. **08 Dashboard with AI at work** (superseded by 11) — replaced 07. In `design/08-dashboard-ia.dc.html`, with the assistant drawer (09) and window (10). AI proposes one action per row and writes a reply before opening; proposed actions require a click to execute.
8. **07 Dashboard** (superseded) — the daily screen in `design/07-dashboard.html` (a separate file, not part of the `.dc.html`): 1440×916, 64px chrome with Dashboard/Inbox/Calendar tabs, single-column priorities, 300px calendar rail, pending items and an assistant field in the footer. Four states (populated, empty, with briefing, with transcript) and a built-in theme selector support comparison.

Main window: **1440×916**, macOS chrome (traffic lights), 58px bar.

## Theme system

There are 26 themes. Each resolves the same **29 tokens**: **19 visual tokens per theme** and **10 typography/metric tokens** inherited from `base` unless overridden.

- `--paper --surface --surface2 --surface3` — surfaces.
- `--ink --ink2 --ink3 --ink4` — text.
- `--line --line2` — dividers.
- `--accent --accent-ink --accent-soft --accent-line --on-accent` — accents and text on accents.
- `--btn --btn-line --btn-shadow --shadow` — controls.

The ten base typography/metric tokens are `--serif` (Newsreader), `--sans` (SF Pro), `--mono` (IBM Plex Mono), `--r2` 8px, `--r3` 10px, `--caps` 0.12em, `--rowpad`, `--subj-weight`, `--subj-size` and `--body-font`. `--on-accent` also exists in `base` as a color fallback; themes requiring dark text over the accent override it.

`design/tokens.json` is the canonical structured source of colors and tokens. The HTML is a visual reference for names and notes; it is not the structured source of color values.

Theme identifiers: tinta, linho, barro, noite, grafite, okami, brutal, vapor, papel, neon, clinico, nexus, sinal, aura, whitex, blackbox, magenta, neural, corsa, corsaluz, brutalnoite, contraste, reboot, comando, override, ambar.

## Features visible in the prototype

- Unified inbox across **four accounts** (“Search the 4 inboxes…”, `⌘K`).
- **Inbox / Calendar** tabs in the chrome.
- Triage: Today / Later / All / Archived.
- Message tags and grouped senders.
- Appointment detection in an email body → “Add to calendar”.
- Inline and separate-window composers, with autocomplete in To/Cc/Bcc fields.
- “Send and archive”, “Save” and suggested drafts.
- Theme selector in the chrome (popover with previews).

The four prototype addresses are sample data, not an account limit. Earlier prototypes remain historical records; screen 11 is the current dashboard reference. Documentation has an English version, while prototype copy and token identifiers retain their originals.
