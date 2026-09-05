# OkamiUNI documentation

[Português (Brasil)](README.pt-BR.md) · **English**

Current documentation covers **v0.5.4**. Every maintained Markdown document has an English and a Portuguese version. Source code examples, identifiers and historical command output retain their original spelling; screenshots and HTML design prototypes may show Portuguese sample content.

## Start here

| Document | English | Português (Brasil) |
|---|---|---|
| Product, setup, architecture and contribution | [README](../README.md) | [README](../README.pt-BR.md) |
| Release history | [Changelog](../CHANGELOG.md) | [Changelog](../CHANGELOG.pt-BR.md) |
| Version 0.5.4 | [Release notes](releases/v0.5.4.md) | [Notas da release](releases/v0.5.4.pt-BR.md) |
| Google account setup for developers | [Google OAuth](oauth-google.en.md) | [OAuth do Google](oauth-google.md) |
| IMAP sign-in and compatibility | [App passwords](senha-de-app.en.md) | [Senhas de app](senha-de-app.md) |
| Design references and tokens | [Design reference](../design/README.en.md) | [Referência de design](../design/README.md) |
| Engineering rationale and historical evidence | [Engineering decisions](decisoes-de-engenharia.en.md) | [Decisões de engenharia](decisoes-de-engenharia.md) |

The two account guides are also bundled inside the application for offline use. Portuguese interfaces open Portuguese help; English, German and French interfaces open English help.

## Historical plans and specifications

These are complete translations of implementation records, not new instructions or current product guarantees. Dates, task IDs, example code and recorded outcomes are preserved. In particular, the remote-AI consent rules in early plans predate v0.5.3; the current README describes the behavior shipped in v0.5.4.

| Record | English | Português (Brasil) |
|---|---|---|
| 2026-08-26 — Native shell plan | [Plan](superpowers/plans/2026-08-26-okamiuni-shell.en.md) | [Plano](superpowers/plans/2026-08-26-okamiuni-shell.md) |
| 2026-08-28 — Accounts plan | [Plan](superpowers/plans/2026-08-28-marco-2-contas.en.md) | [Plano](superpowers/plans/2026-08-28-marco-2-contas.md) |
| 2026-08-28 — Accounts specification | [Spec](superpowers/specs/2026-08-28-marco-2-contas-design.en.md) | [Spec](superpowers/specs/2026-08-28-marco-2-contas-design.md) |
| 2026-08-28 — Synchronization specification | [Spec](superpowers/specs/2026-08-28-marco-3-sincronizacao-design.en.md) | [Spec](superpowers/specs/2026-08-28-marco-3-sincronizacao-design.md) |
| 2026-09-01 — Assistant core plan | [Plan](superpowers/plans/2026-09-01-sp1-nucleo-do-assistente.en.md) | [Plano](superpowers/plans/2026-09-01-sp1-nucleo-do-assistente.md) |
| 2026-09-01 — AI and dashboard specification | [Spec](superpowers/specs/2026-09-01-ia-e-dashboard-design.en.md) | [Spec](superpowers/specs/2026-09-01-ia-e-dashboard-design.md) |
| 2026-09-03 — AI dashboard plan | [Plan](superpowers/plans/2026-09-03-dashboard-08-ia-trabalhando.en.md) | [Plano](superpowers/plans/2026-09-03-dashboard-08-ia-trabalhando.md) |

## Keeping both languages current

Update both files in a pair when changing maintained documentation, retain the reciprocal language links and check local links before publishing. Historical records should be annotated when superseded rather than rewritten as if they described today's implementation. Translation does not rename source files, API identifiers, database values or fixture literals.
