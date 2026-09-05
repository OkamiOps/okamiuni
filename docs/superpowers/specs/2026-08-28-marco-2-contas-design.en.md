# Milestone 2 — Real accounts: Google OAuth, IMAP, Keychain, and the local database

> **Historical design and implementation record.** This document preserves the decisions made on its stated date and is not evidence of current behavior. [Leia o original em Português](2026-08-28-marco-2-contas-design.md).

Approved on 2026-08-28. Decisions made with the project owner: OAuth **only for Google** for now (Microsoft Graph is out of scope); IMAP covers everything else; the local cache uses **SQLite through GRDB**; the IMAP client is built on **swift-nio-imap**; the architecture is **local-first** (the database is the UI’s source of truth). Milestone 3 (incremental sync, outbox, sending, and triage mirroring) has its own specification; this milestone ends with the app **showing real email** from connected accounts.

## Objective

Move beyond fixtures: the user connects any account (Google through OAuth; the rest through IMAP with an app password), secrets live in the Keychain, the initial read load is stored in a GRDB database, and the Milestone 1 shell reads from that database — without changing its form.

## Inherited constraints (apply verbatim)

- **Nothing limits provider, domain, or number of accounts.** `Account.Provider` remains open; `imap` is the general case.
- Swift 6.3, `SWIFT_STRICT_CONCURRENCY: complete`, macOS 26. Swift Testing, never XCTest. Keep pure logic outside `View`.
- No silent control; errors are never swallowed (`try?` on a network path is a defect).
- Time zones do not cross the model: minute-of-day plus day offset; use `Date` only at the edges.
- A new test only counts after it was proven red with the defect reintroduced.
- New UI is proven by rehearsal in the real app whenever it involves interaction (`--ensaiar-*` instruments).

## New dependencies (the only ones)

| Package | Purpose |
|---|---|
| `GRDB.swift` | SQLite: message cache, FTS5, `ValueObservation` |
| `swift-nio` + `swift-nio-ssl` | IMAP transport: event loops, TLS, and our logical-line decoder |

> **Amendment (Task 10):** the original specification declared `swift-nio-imap`, but the real 0.4.0 does not expose `ResponseDecoder` (it is `internal`), and the literal framing we needed ended up being written and proven with a probe inside `CRLFLineDecoder`/`ImapResponseAdapter`. The library had no remaining job in the data path and was removed; SwiftNIO, which had always done the work, became the declared direct dependency.

No others. OAuth uses `ASWebAuthenticationSession` + `URLSession`, both provided by the system. Keychain uses `Security.framework`.

## Architecture

New **`Packages/UNISync`** package, between `UNICore` and the outside world:

```
App ──▶ UNIShell ──▶ UNICore  ◀── UNISync ──▶ (Keychain · GRDB · Gmail API · IMAP)
```

- `UNISync` **imports** `UNICore` (the `Account`, `Message`, and `TriageBucket` types are its currency) and **does not import SwiftUI**.
- `UNIShell` only knows `UNISync` through ports: `MailSource` (reading) and a new `AccountDirector` (account management). `MailStore` remains the UI’s only port.
- The database is the source of truth: the UI never waits for the network.

### `UNISync` components

| Component | Role |
|---|---|
| `SyncDatabase` | GRDB opening/migration, `DatabasePool`, observations |
| `SecretStore` | Keychain: save/read/delete a secret by account (protocol + real implementation + in-memory fake for tests) |
| `GoogleAuth` | PKCE, code exchange, token refresh, revocation |
| `ProviderDetector` | address → route (`.google` \| `.imap(preset)`) — pure |
| `ImapPresets` | table of known providers (iCloud, Zoho, Hostinger, Fastmail, …) — pure, open, with manual entry always available |
| `ImapSession` | session over swift-nio-imap: connect, authenticate, list folders, download envelopes and bodies |
| `GmailClient` | typed `URLSession` wrapper over the Gmail API: profile, labels, `messages.list/get` |
| `AccountDirector` | actor: add/test/remove an account, trigger initial load, publish state by account |
| `InitialLoader` | initial read load (90 days) into the database, per account |
| `DatabaseMailSource` | implements `MailSource` by reading the database (replaces fixtures when an account exists) |

## The database (GRDB)

File at `Application Support/OkamiUNI/mail.sqlite` (inside the sandbox container). Versioned migrations begin at v1.

v1 tables (Milestone 3 adds its own):

- `account` — id, address, display name, provider, IMAP host/port, color/tint, state (`ativa`, `erroDeAutenticacao`, `carregando`), dates. **No secret at all** — the secret is in Keychain.
- `folder` — per account: server id, role (`inbox`, `archive`, `trash`, `sent`, `depois`, `outra`), name.
- `message` — our id, account, server id (Gmail id / IMAP UID + folder UIDVALIDITY), sender, recipients (`to`/`cc` in JSON), subject, preview, received date (UTC epoch), flags (read, flagged), `bucket` (the triage projection), folder.
- `message_body` — body per message (paragraph text, as `Message.body` is today) + external **FTS5** kept in sync by trigger, with tokenizer `unicode61 remove_diacritics 2` — accent folding for search moves into the database.
- `agenda_item` — what "Colocar na agenda" creates becomes persistent (the `AgendaItem` fields, including `dayOffset`).
- `sync_state` — per account: `historyId` (Gmail), `uidvalidity`/`highestUid` per folder (IMAP), timestamp of the last sync. (Created in v1; actually used in Milestone 3.)

The UI reads through `ValueObservation` → `AsyncSequence`; `MailStore` gains a `load()` that subscribes instead of fetching once. With no account connected, the app remains on fixtures — rehearsals and captures do not change.

## Google OAuth

- **Project-owner prerequisite** (the plan’s first task, with a step-by-step guide): create the project in Google Cloud Console, enable the Gmail API, configure the consent screen (an app in test mode is sufficient), and create a **desktop-app OAuth Client ID**. The client ID enters the app through configuration (`Info.plist`/xcconfig), never hardcoded.
- Flow: `ASWebAuthenticationSession` with **PKCE (S256)** and the custom-scheme redirect `com.okamiops.okamiuni:/oauth`; exchange and refresh the code through `URLSession` directly against the token endpoint (no Google SDK).
- Scopes: `gmail.modify` (read + change flags/labels — already covers Milestone 3), `gmail.send` (requested together, so it does not require renewed consent in Milestone 3), `userinfo.email` (identify the account).
- Tokens in Keychain (`kSecClassGenericPassword`, service `com.okamiops.okamiuni`, account = account id). Refresh is transparent with a single flight per account; a failed refresh marks the account `erroDeAutenticacao` and the UI offers reconnection — never a silent error.

## IMAP

- Session over swift-nio-imap: `LOGIN` (app password) over implicit TLS (993) or STARTTLS according to the preset; `LIST`/`SELECT`; envelopes fetched in batches; body on demand with database cache.
- Detect folder role with `SPECIAL-USE` when the server provides it; otherwise by name (a pure, testable table).
- `ProviderDetector`: a Google domain → OAuth; otherwise a known preset; otherwise a manual form (host, port, TLS). MX lookup is **not** in v1 (network on the typing path adds latency; the table + manual entry cover it).

## The Accounts window

New scene (`UNIWindow.accounts`), opened from the app menu and the "Contas…" item in the sidebar context menu. In the design language (tokens, 26 themes, 1× hairlines):

- List: each account with address, provider, state (synced at HH:MM · loading · error with cause), message count in the database; remove button with confirmation (deletes the account database + Keychain).
- Add: address field → detected route → OAuth opens the browser OR IMAP form (address, app password with an "o que é isto?" link, prefilled host and port) → **"Testar e adicionar"** with the test result explained (authentication ✗, network ✗, TLS ✗ — distinct messages).
- While the initial load runs: per-account progress in the window itself and on the account row in the sidebar.

## Initial read load

- **Gmail**: paginated `messages.list` (`newer_than:90d`) + `messages.get` (`metadata` format for the list, `full` body for the 50 most recent; the rest on demand) + `labels.list`; saves the profile `historyId` so Milestone 3 can start incrementally.
- **IMAP**: `SELECT` folders by role, `UID SEARCH SINCE` 90 days, envelopes in batches of 200; bodies for the 50 most recent per folder, the rest on demand.
- Projection into `TriageBucket` on input (pure, tested): inbox → `today`, folder/label `OkamiUNI/Depois` → `later` (if it exists from an earlier installation), Archive/All Mail → `archived`, Trash → `trash`, Sent remains out of triage (v1 does not show Sent; Milestone 3 brings it with sending).
- Interruptible and resumable: stopping midway does not corrupt data (batch transactions); reopening continues where it stopped.

## What changes in existing packages

- `UNICore`: `Account` gains the real fields (optional host/port/tls for IMAP, state, last sync); `Message` gains optional opaque server ids. Fixtures remain valid (new fields have defaults).
- `UNIShell`: Accounts window; account row in the sidebar shows state; `InboxScreen` receives the real source when an account exists.
- `App`: composition — open the database, build `AccountDirector`, choose `DatabaseMailSource` versus fixtures.

## Errors

One `SyncError` type with distinct cases (network, TLS, authentication, revoked authorization, quota, server) and a Portuguese message for each. Every surface that shows an account shows its error with an action (reconnect, try again). Structured logging per account (the system `logger`, category by component).

## Tests

- In-memory fake `SecretStore`; real-store tests sit behind a local mark (Keychain is hostile in CI).
- `GoogleAuth` against a **local** token server (`URLProtocol` stub): exchange, refresh, failed refresh, single refresh flight.
- `ImapSession` against an **in-memory fake IMAP server** over NIO (response scripts per test): successful/failed login, list, batch fetch, changed UIDVALIDITY.
- `GmailClient` against recorded responses (real API JSON fixtures).
- Database: v1 migration, FTS with an accent ("Revisao" finds "Revisão" in the body), observation fires on write, triage projection at boundaries.
- `ProviderDetector`/`ImapPresets`/role detection: pure, boundary cases.
- Accounts UI: rehearsal in the real app (`--ensaiar-contas`) with a local fake IMAP — add → test → load flow without an external network.
- **No test touches the external network.** A real account is only used manually by the project owner.

## Out of scope (recorded)

Microsoft Graph; sending; incremental sync and the outbox (Milestone 3); triage mirroring on the server (Milestone 3 — this milestone only **reads** the `OkamiUNI/Depois` folder if it exists); threads/conversations; per-account signature synchronization; MX lookup in detection.

## Milestone acceptance criterion

With a Google account and an IMAP account from any provider connected: the app opens **offline** showing the last 90 days of messages from both, with search (including body and folded accents), account filtering reaching the list and agenda, and the Accounts window reporting state and error with an action. Fixtures continue to serve the app with no account at all.
