# Changelog

[Português (Brasil)](CHANGELOG.pt-BR.md) · **English**

Versions correspond to [GitHub releases](https://github.com/OkamiOps/okamiuni/releases). All dates below are in 2026.

## 0.6.1 — October 15

- Unread is easy to spot: only an unread email has the purple dot, with sender and subject in bold; read email is lighter.
- "All" is back in the sidebar, right below Later.
- App version 0.6.1, build 16. [Release notes](docs/releases/v0.6.1.md).

## 0.6.0 — October 15

- New **Glass** look: a rail on the left, a folder column and floating panels, in the Glass light and Glass night themes, plus an **Automatic** option that follows the Mac. All 26 classic themes get the same layout, without the glass.
- Day panel, Inbox, Calendar, Settings, the composer and every window redesigned. Inboxes from every account are unified, and accounts show as a tree.
- A reader that fits: the header is two lines, AI lives in the **✦ AI** button (⌥⌘J, with ⌥⌘S, ⌥⌘R and ⌥⌘E shortcuts), the summary collapses and the sender expands into the details, with a button to copy each address.
- **Desk** assistant and new **Intelligence** settings, with every provider in one place. Grok signs in through its official login.
- When you reply, the quote shows the original email formatted.
- App version 0.6.0, build 15. [Release notes](docs/releases/v0.6.0.md).

## 0.5.9 — October 14

- Installer for new users: each release now includes `OkamiUNI.dmg`, signed and notarized by Apple. It opens a window with the app, an arrow and the Applications folder; drag one onto the other. Fixed link to the latest version: https://github.com/OkamiOps/okamiuni/releases/latest/download/OkamiUNI.dmg
- If OkamiUNI is opened straight from the installer window, or from Downloads without moving it, the app offers **Move to Applications**. That is where automatic updates work.
- App version 0.5.9, build 14. [Release notes](docs/releases/v0.5.9.md).

## 0.5.8 — October 14

- A ready update now shows in the sidebar as a strip with "New version", the version number and an **Install** button, above "Accounts and providers". With nothing new, the update icon stays at the end of that row; one click checks right away.
- In Settings → General → Updates, a ready update gets an **Install X and reopen** button, with "What changed" next to it. Before, it was a line of text that did not look clickable.
- App version 0.5.8, build 13. [Release notes](docs/releases/v0.5.8.md).

## 0.5.7 — October 13

- Update icon always visible in the sidebar footer, next to "Accounts and providers". When a new version is ready it gets an orange dot and opens what changed; otherwise one click checks right away and shows the current version. No more trips to Settings.
- App version 0.5.7, build 12. [Release notes](docs/releases/v0.5.7.md).

## 0.5.6 — October 13

- Automatic updates: OkamiUNI checks for new versions at launch and every 6 hours, downloads them in the background and shows a small button in the sidebar with what changed. "Install and relaunch" updates on the spot; otherwise the update is installed when you quit the app.
- Silent mode for those who prefer it (Settings → General → Updates): installs on quit without any button, and the next launch shows once what changed.
- "Check for Updates…" in the app menu, and Settings shows the current version with a "Check now" button.
- Releases are now signed with Developer ID and notarized by Apple, so the app opens on any Mac without being blocked. Each update package is also signed with OkamiUNI's own key and is never installed if the signature does not match.
- App version 0.5.6, build 11. [Release notes](docs/releases/v0.5.6.md).

## 0.5.5 — October 13

- Accepting or answering a calendar invite no longer creates a copy of the event in Google Calendar. The reply is still sent to the organizer, but the event stays the organizer's: OkamiUNI keeps it only in its own agenda and recognizes the original that Google already shows, even after the organizer reschedules. Before, every accepted reschedule left an extra event owned by you, without guests and with its own Meet link.
- HTML emails with a tracking pixel before `<!DOCTYPE html>` (e.g. traceleads) or sent as a bare fragment (`<p>…</p>` without `<html>`) no longer open as source code. Bodies already stored this way are repaired automatically on the next launch.
- Tracking pixels (1×1 or hidden) stay blocked even when remote images are allowed, so a stalled tracker no longer keeps the reader from finishing its layout.
- Protocol-relative images (`//cdn…`) load over HTTPS, and the reader's height follows images that arrive late instead of clipping the end of the message.
- The assistant gets native draft tools and connects to external agents over ACP and A2A.
- Mail fixes: recipients, cursor-placed signatures, HTML fragments, missing attachments and a detached message window with the complete reader. The composer keeps the formatting selection and closes after an accepted send.
- Calendar fixes: event dates survive midnight and day rollover, and removing an imported cancelled occurrence sticks.
- The dashboard uses the current inbox state, with current, proactive priorities and an actionable AI briefing.
- ChatGPT subscription sign-in (direct OAuth) works again and the model list comes from the live catalog.
- App version 0.5.5, build 10. [Release notes](docs/releases/v0.5.5.md).

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
