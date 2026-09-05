# Changelog

[Português (Brasil)](CHANGELOG.pt-BR.md) · **English**

Versions correspond to [GitHub releases](https://github.com/OkamiOps/okamiuni/releases). All dates below are in 2026.

## 0.5.4 — September 5

- Portuguese, English, German and French interfaces, with a persisted language preference and an option to follow the system.
- Dates and numbers follow the interface language. AI response preferences also include French.
- Shared translation catalogs with coverage and interpolation checks; messages and internal values remain unchanged.
- Offline account help in Portuguese and English; English help is used by English, German and French interfaces.
- Full English and Portuguese versions of the README, changelog, guides, design reference, engineering decisions, plans and specifications, with a documentation index.
- OAuth and app-password guides corrected to match current implementation and provider compatibility.
- Fixes for reading IMAP messages with double or residual quoted-printable encoding, committed since v0.5.3.
- App version 0.5.4, build 9. [Release notes](docs/releases/v0.5.4.md).

## 0.5.3 — September 3

- Intentionally connecting a remote provider constitutes consent: automatic analysis and prepared replies follow that provider by default; the switch in Settings → AI restricts processing to this Mac. A migration enables this behavior for users who never changed the switch, covering the last seven days.

## 0.5.2 — September 3

- Today's plan uses a fixed density of 138 pt/hour, with the full day in a horizontal scroll opened near now; every block displays its name and overlapping blocks move to a sub-lane. Events mirrored by two accounts are coalesced at the source.

## 0.5.1 — September 3

- Dashboard content scrolls while the status bar stays at the bottom. Tiles use two lines. Accounts can be filtered by name. Tile labels are deterministic before model output. The header explains why no prepared replies are available; “Generate · Codex” provides an explicit action.

## 0.5.0 — September 3

- The daily dashboard (design 11): today's plan in two lanes, “Waiting for you” tiles, appointments, money and deadlines, business as a filter and a status bar. Machine senders never enter “Waiting for you”.

## 0.4.0 — September 3

- AI at work (design 08): replies prepared before opening a message, one proposal per row with its reason, “Archive and learn” with sender rules, an agent with actions (spec §4), validator and parser, assistant drawer (`⌘J`) and detachable window. A card's Undo reverses exactly that card's batch.

## 0.3.0 — September 3

- Three-column dashboard; readable email bodies with collapsible quotes, signatures and footers, structured lists/key-value blocks and HTML parsed as structure. Link confirmation highlights the real host; themed link menu; unified thin activity bar; reconnect an account without removing it; header-based bulk-mail guard; RFC 2047 without mojibake; 120-second AI timeout.

## 0.2.0 — September 1

- Dashboard, Gmail/Workspace sending aliases, Spam in triage, global search, themed HTML reader and RSVP through Google invitation buttons.
