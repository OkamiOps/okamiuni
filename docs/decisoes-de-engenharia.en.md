# Engineering decisions — OkamiUNI

[Português (Brasil)](decisoes-de-engenharia.md) · **English**

> Historical engineering record. Each entry describes evidence and decisions at the time it was written. Test counts, implementation stages and early AI consent rules are historical; the [v0.5.4 README](../README.md) describes current behavior. In particular, v0.5.3 superseded the separate remote-analysis opt-in described below. Original code examples and identifiers are preserved.

A record of what **cannot** be inferred by reading the code. Each entry exists because the choice was costly, or the obvious alternative was wrong.

The detailed execution journal lives in `.superpowers/sdd/<plano>/progress.md`, which Git ignores by convention. This file contains the part that must outlive it.

---

## A “today” fixture is wall-clock time, not an instant

`Fixtures.today` was once pinned to `America/Sao_Paulo`. Everything reading it formats with `Calendar.current`. On a Berlin machine, noon became 17:00 and the calendar marked “now” on the wrong appointment; in Tokyo, the header rendered the following day.

**Pinning the time zone was the defect, not the solution.** Without it, `today` is local noon on August 25 on every machine, which is what the fixture means. Two `UNICore` tests lock that invariant and fail if someone pins it again.

For the same reason, `AgendaItem` stores minutes since midnight and `dayOffset: Int`, never `Date`: a date there would reintroduce time-zone conversion. Milestone 4 replaces it with a real date when EventKit arrives — deliberate debt, not an oversight.

## `View` is implicitly `@MainActor` in Swift 6

Pure logic in a `static` inside a `View` **inherits isolation** and traps at runtime (SIGTRAP) when called by a nonisolated test. This cost an entire investigation in `AgendaRail`.

That is why `AgendaSummary`, `PaneLayout` and similar types live in `UNICore`, outside any `View`.

## A test that passes with broken code is worthless

Seven were rejected in this project. The most common pattern is not an empty test: it is an assertion linking two things where **one is derived from the other**:

```swift
// eventLeading é DEFINIDO como labelGutter + gutterGap.
// Isto é verdadeiro por construção e passaria com a calha errada.
#expect(layout.eventLeading >= layout.labelGutter + layout.gutterGap)
```

Assert the literal value. After writing a test, deliberately break the code and confirm that it fails.

Corollary: a test that can loop needs a bound and an assertion about that bound. An unbounded `while let` exceeded the 600-second timeout instead of failing.

## CSS-to-SwiftUI conversions that already cost review rounds

- `.tracking()` uses **points**; CSS `letter-spacing` uses **em**. `0.06em` at 8.5pt = 0.51pt.
- `.lineSpacing()` is **extra** space: `line-height: 1.55` at 15pt → `1.55×15−15 = 8.25`.
- `.shadow(radius:)` is approximately **half** the CSS blur.
- `box-shadow` with **spread** is a border, not a shadow. `.shadow(radius: 0, x: 0, y: 0)` draws nothing — use `strokeBorder`.
- `soft(c, p)` in the prototype is approximately `.opacity(p/100)`.
- **The prototype's `width` is not always the box width.** There is no global `box-sizing: border-box`: the author declares it per element, and undeclared elements use `content-box`, with `padding` added **outside**. SwiftUI's `.frame(width:)` is the whole box. Copying the CSS number into the outer frame shrinks the content by both insets: a date picker with `width: 244px; padding: 12px` measures 268, not 244. At 244, its 33.1pt cells became 30.3. Read the **computed** `box-sizing` before copying a width.
- **A sibling `Rectangle` in an `HStack` has no height of its own** — it requests all available height. As a card's color strip, this goes unnoticed only while the card height is imposed externally; in a cell with spare height, that same strip stretched a 16pt pill beyond 50pt. An edge strip belongs in `.overlay(alignment:)`, not as a sibling.
- **`flex: 1` with `min-height: 0` is not `.frame(maxHeight: .infinity)`.** CSS lets the row ignore content size; SwiftUI still respects the intrinsic minimum, so the fullest row steals height from others. For N equal rows, put content in an `.overlay` on `Color.clear`, which has no intrinsic size, with `.clipped()`.

## User intent is separate from what fits in the window

`wantsSidebar` / `wantsAgenda` represent **intent**; actual visibility requires intent **and** enough width. Without this separation, the classic bug occurs: the user opens the sidebar, narrows the window, it closes automatically, and widening the window does not restore it.

Dragging a divider is another input to the same model, never a bypass.

## Native traffic lights can be recentered

An earlier report concluded this was impossible after testing `NSTitlebarAccessoryViewController` in a `.hiddenTitleBar` window. **It is possible** by repositioning the `NSButton` instances returned by `window.standardWindowButton(_:)`. A 13.5pt mismatch became 0.5pt.

Process lesson: “impossible” must state *what was tried and measured*, or it closes a door that was open.

## When the prototype contradicts itself, it cannot decide

`RAIL` places five appointments on Tuesday the 25th; `WEEK` places three, with shortened titles. “The prototype wins” assumes it has **one** answer.

With two answers, the product becomes the criterion: the same Tuesday cannot differ between two views of the same app. Short titles in a narrow column are **rendering**, not data — shorten when drawing, rather than storing two titles.

## Never limit accounts

The four fixture inboxes are a design example. The app accepts any provider and domain. `Provider.imap` is the **general case** and deliberately comes first in the enum; Gmail and Graph are shortcuts above it. Never `switch` over fixture accounts.

## Parallel implementation needs commit boundaries, not just editing boundaries

Telling each agent which files it may **edit** is insufficient. A `git add -A` swept another task's files into an unrelated commit whose message did not mention them — correct content, misleading history.

Every parallel dispatch must specify explicit paths, never `-A` or `.`, and require `git status --short` before each commit.

## Never drive the user's interface with synthetic events

The app runs on its owner's **work** computer. `CGEvent`, System Events `keystroke` and anything that moves the pointer **take over the machine** while it is being used. This is not a matter of taste: it happened, the owner objected, and it must not happen again.

Use these alternatives:

- **Appearance and layout:** `Render` in `UNIShellTests/RenderHarness.swift`. It draws the SwiftUI hierarchy in an `NSWindow` 50,000pt outside the visible area, never brought to the front. AppKit renders everything, including `ScrollView`, `TextField` and native-backed controls. Nothing appears onscreen or receives focus. `UNI_RENDER_DIR=<pasta>` writes PNGs for inspection. (`ImageRenderer` alone **does not work**: it leaves lists and text fields blank.)
- **Behavior:** exercise `MailStore` and pure types directly. Most “does this work?” questions concern the model, not pixels.
- **Window geometry**, when unavoidable: `open -g` launches **without** foregrounding, and accessibility reads do not change anything. Reading is allowed; synthesizing events is not.

Harness trap: some code formats dates with fixed `pt_BR`, while other code uses `Locale.current`, which resolves against bundle localizations. The test bundle has none, so dates appear in English there and Portuguese in the app. Injecting `\.locale` does not fix formatters that bypass the environment. This was a real inconsistency marked for repair, not an appearance defect to report.

## The system focus ring is invisible to the harness by design

Three reports showed “double outlines” on buttons: a crisp border, a **gap**, then a second ring on all four sides. One cause was an `inset` shadow drawn outside (`4993e2e`). The remaining cause was the **macOS focus ring**, which AppKit draws with a gap around the control.

It never appeared in our renders, and not through carelessness: AppKit draws it only when the window is the **key window** of an **active** app. The `Render` window is 50,000pt offscreen and is neither.

**Method consequence:** “not reproduced in the harness” does not disprove a defect triggered by focus, key-window or active-app state. In those cases, use the same approach as `debugOpenPanel`: an internal parameter forcing the state, then compare both renders.

The prototype has no focus ring (`cursor: default`, no `outline`), but removing it without replacement blinds keyboard users. `Support/FocusRing.swift` suppresses the system ring with `focusEffectDisabled()` and draws our ring **inside** the control's shape, against its border. The gap is the defect's signature, not the second line.

A trap found by deliberately breaking the test: in `tinta`, `surface` and `btn` differ by 0.02. A test looking for “the background reappears between border and ring” passes with a 3pt gap because both colors fall within tolerance. Measure **distance**, not color equality.

## SwiftUI `Font` is opaque — rich text needs its own underlying attribute

`AttributedString` in a `TextEditor` accepts `\.font`, but `Font` is **write-only**: it cannot tell you whether it is bold, its size or its family. A toolbar that only writes would be incomplete — selecting bold text would not activate B.

The composer body therefore stores `BodyStyleAttribute` (family, size, bold, italic, underline, strikethrough, color and highlight) as its **source of truth**. SwiftUI attributes are a **projection**, rewritten on every command. Reading selection state reads the attribute, not the font.

The required consequence is `.attributedTextFormattingDefinition(AttributeScopes.UNIComposerAttributes.self)`. Without declaring the scope, `TextEditor` discards the unknown attribute and the model dies on the first typed character. A test proves this by calling `constrain(_:)`, as the editor does, with both the correct scope and the plain SwiftUI scope.

Alignment was the exception, stored in the CoreText attribute that already has a paragraph boundary. **This applied while the editor was a `TextEditor`**; a later entry records its replacement with `NSTextView`.

## Writing an attribute invalidates `AttributedTextSelection`

Measured on this machine: writing an attribute over a range splits runs, after which `AttributedTextSelection.indices(in:)` returns an **insertion point** instead of the former range. Losing the selection does not require changing the text.

If ignored, the user selects text, clicks **B**, then **I**, and italic applies to typing attributes rather than the selection. Nothing changes onscreen and no error appears. Thus **every** body mutation goes through `text.transform(updating: &selection)`, including attribute-only changes.

## A status label must not share the toolbar's row

The prototype hangs “N words · unsaved” at the end of screen 03's formatting toolbar. At 820pt it takes approximately 150pt; the seven groups no longer fit, `FlowLayout` wraps into two rows and the strip frame becomes twice the border's height — the “the boxes aren't right” defect reported by the owner.

The toolbar row belongs to the toolbar. Word count moved to the title bar and save status to the footer in both windows. The test measures `NSHostingView.fittingSize.height` at 820, 1100 and 1440, and also at 420, where the row **must** grow; otherwise a fixed measurement could pass the height ceiling.

## A hairline is one device pixel, and `strokeBorder` does not round itself

The prototype specifies `0.5px`. A browser **does not draw half a pixel**: at 1× it rounds to one; at 2× half a CSS pixel already *is* one device pixel. Both show **one solid pixel**. A literal half **point** is different: at 1× it is a half-painted pixel. Therefore `Hairline.thickness(_ displayScale:)` = `1 / displayScale`, read from the environment by every border-drawing `View`.

Measurement revealed that **the two drawing paths did not fail in the same way**:

- `Rectangle().frame(height: 0.5)` — divider — was already **correct**. SwiftUI aligns a filled shape's frame to the pixel grid, producing a whole pixel despite the 0.5 value. Measured in `tinta` with broken code: `rgb(235,232,226)`, exactly the token.
- `strokeBorder(…, lineWidth: 0.5)` — border — was **washed out**. The stroke uses partial alpha instead of rounding: `rgb(239,237,234)` where the token is `rgb(218,214,206)`, a 28-level difference.

This was exactly the asymmetry reported four times: strong divider, ghost border, and the eye confusing one for the other. **“The hairline is wrong” is not a single question**: measure every drawing path, because the same number yields different results for a filled shape and a stroke.

Two consequences affected tests because the drawing **improved**:

- `FocusRingMetrics.inset` had to become scale-dependent alongside the border. A fixed half-point inset against a one-point border places the ring underneath rather than beside it.
- `ComposerToolbarCapsuleTests` measured capsules by luminance and merged gaps smaller than 5px. With a half-point border, the outermost pixel fell **below** detection, leaving a measured 5px gap; with a solid border it counted, making the same gap 3px. The threshold became 2px: a hole inside a capsule remains 1px and those two numbers never approached each other. This is how literals calibrated against wrong drawings become stale.

A harness trap found before measurements were valid: `Render` rendered at `scale: 2`, but the environment's `displayScale` remained the machine monitor's scale (1× here). Scale-based thickness decisions measured the wrong screen, and the 2× test verified an enlarged 1× drawing. `Render` now injects `\.displayScale` equal to the requested `scale`.

## `file` does not verify binary asset integrity

A truncated PNG (6,738 bytes, without `IEND`) passed two agents who ran `file`, which reads only the 33-byte header. SwiftUI renders a missing `Image` as **nothing**, silently.

Check the end marker and size. Base64 of approximately 50,000 characters does not survive transport between agents: download from the source.

## Comparing the whole box hides stacking defects

The harness **can see** drawing order: removing the formatting bar's `zIndex` immediately fails `ToolbarPanelTests`. It fails to see it only when the **measurement** is wrong, and the wrong approach was natural enough to pass my review.

The contact list measures approximately 280pt and the bar covering it approximately 50pt. When covered, it still draws fully **above** the bar (in the field row) and **below** it (over the editor, because the row is drawn later). The bounding box of the difference measured 312pt in both cases, so the test passed with the defect present. Measured inside the toolbar strip: **0** pixels versus 13,718.

When an obstruction is a **strip** crossed by the obscured content, measure **inside the strip**, not the whole box. Locate the strip in the drawing itself: fixed coordinates start measuring elsewhere when a header row is added. The anchor used there is the font/size capsule, the only toolbar part painted in `btn`.

A related corollary found in the palette card: **a shadow is not a card**. The `box-shadow: 0 10px 12px` extends the difference box by approximately 30pt — enough for “the card grew” to pass with the custom-color item removed (80pt versus 117). Count **opaque** rows in a column crossing the card: 38 without the item, 66 with it.

## The menu opened by a `<select>` is not part of the prototype

Before specifying “draw the menu like the prototype”, note that the four `.dc.html` `<select>` elements — font, size, account and suggested draft — style the **closed control** (`appearance: none`) but use the **system menu**. `appearance: none` does not affect the popup in any browser.

The design's custom menu is the theme selector (line 328): a `div` trigger with the same `▼` and an absolute panel with `max-height: 420px; overflow-y: auto`. That supplies both the panel and the scroll-height ceiling for hundreds of fonts.

The owner's “system dropdown” complaint concerned the **closed control**: a `Picker(.menu)` is an `NSPopUpButton` and paints a macOS frame over the design capsule. This is measurable: the prototype's control is flat, so every interior pixel outside glyphs should use `btn`. Measured: 0.002 with `Picker`, 0.77 with our control.

## The context menu stopped being a system menu (2026-08-27, Task AN)

**Decision revoked.** This file and `ContextMenuHost.swift` previously said “the context menu belongs to the system, and the prototype draws none”. The owner sent a screenshot: the gray macOS `NSMenu`, with pink system highlighting, over an interface that draws all its own dropdowns, and reported that actions still used the system style instead of a custom one. That decision no longer applies.

The following replaced SwiftUI's `contextMenu` without changing a line of menu **content** (`UNICore.ContextMenus` remains the model, with the same tests):

- `RightClickCatcher`: an `NSView` that **exists for the mouse only when the current event is a right-click** (or Control-click). For every other event, `hitTest` returns `nil` and AppKit keeps searching, reaching `NSHostingView`. This preserves click, double-click and row swipe: SwiftUI has no right-click gesture, and an opaque `NSView` overlay would steal all three. It must be an `overlay`, never a `background`: AppKit hit testing runs front to back, so only the frontmost view can return `nil`.
- `ContextMenuPanel` + `MenuSurface`: the panel follows `ComposerSelect`: `surface`, `--r3` radius, one-device-pixel `strokeBorder` in `line`, `accentSoft` highlighting with `accentInk` text, and a `line2` divider. Divider and highlighting are extracted from `ComposerSelect` and shared; duplicating the visual language is how two blurred `.stroke` borders survived an entire milestone.
- `ContextMenuPresenter`: one borderless window per level, one open menu at a time in the app. A window rather than an `overlay` for the same reason already recorded for `popover`: overlays are clipped to the window, so a menu on the last list row would be cut off at the bottom.
- `UNICore.MenuPlacement`: submenu flipping/anchoring arithmetic in AppKit screen coordinates (y upwards), with tests measuring the flip boundary **to one point**.

**Deliberate exception: the composer editor keeps the system menu.** `ComposerTextView` *adds* items to AppKit's `NSMenu` (see `augment(_:)`), which also supplies spelling, substitutions and services. Redrawing it would cost these features, for which we have no equivalent. Changing that too requires a separate discussion with the owner.

Two measured traps involved the system silently deciding appearance:

1. **`.disabled` dims the button by itself.** With it present, the disabled-item pixel test passed even with `ink4` **removed**, because SwiftUI opacity dimmed the label anyway. Disable clicks through `allowsHitTesting` and the action guard; let the token determine dimming so the test can assert something meaningful.
2. **The theme shadow passes exactly through `line2`.** Counting the whole bitmap, a panel without any separator reported 4,454 divider pixels in `tinta`: the shadow gradient over `paper` falls within the 0.02 tolerance. Every panel token count must use a window **inside** the panel.

## What looked like an “SDK limit” was a `TextEditor` limit

Tables, hyperlinks and justified alignment remained disabled for an entire milestone, with reasons in `help`. Those reasons were correct **for the type in use**: `AttributedString` has no table model, and `AttributeScopes.CoreTextAttributes.TextAlignmentAttribute` has three cases.

The conclusion was wrong. Replacing the editor with `NSTextView` makes all three available through `NSParagraphStyle`: `textBlocks` for tables and `.justified` for alignment; Foundation's `\.link` is drawn and clicked by `NSTextView` itself.

The same correction applies to line height. Earlier, `NSParagraphStyle` was ruled out because its `Sendable` conformance is unavailable on macOS. True, but the `Sendable` requirement comes from **SwiftUI's** `AttributedTextValueConstraint`. Without `TextEditor`, that restriction disappears, and `minimumLineHeight`/`maximumLineHeight` become the normal approach again.

A broader lesson: **“this SDK cannot do it” often means “this type cannot do it”.** Before making that claim, identify which type blocks the feature and whether that type is mandatory.

## `NSTextTable` belongs to TextKit 1

The convenience `NSTextView()` produces TextKit 2 (`textLayoutManager` populated, `layoutManager` nil), where `textBlocks` are unavailable. Constructing the view manually with `NSTextStorage` + `NSLayoutManager` + `NSTextContainer` restores TextKit 1, which draws the grid and supports `firstRect(forCharacterRange:)` and `lineFragmentRect(forGlyphAt:)`, used here to measure the cursor without launching the app.

## A table cell belongs to the paragraph break, not its first character

Each cell is a paragraph, and the attribute identifying “row 1, column 0” needs a stable carrier. The first character does not work: AppKit assigns typed text the attributes of the character **left** of the insertion point; at the beginning of an empty cell, that is the **previous** cell's break. Typing in cell (1,0) would mark text as (0,1).

The paragraph's own break avoids this and is the only character in an empty paragraph. For the same reason, `RichBody.align` writes to the paragraph **and** its break: writing to an empty `AttributedString` range does nothing. Without the break, an empty line between paragraphs has neither alignment nor line height — the “giant cursor” defect returning through another path.

## A round-trip bridge needs one measurement system

`AttributedString.Index` counts characters; `NSAttributedString` counts UTF-16. Conversion using `distance(from:to:)` works for ASCII and goes out of alignment on the first emoji, making the selection jump. Correct conversion passes through the shared `String`: `String.Index(_:within:)`, `AttributedString.Index(_:within:)` and `NSRange(_:in:)`. A test uses `"bom 😀 dia"` for exactly this reason.

## A panel near the right edge opens to the left

The hyperlink panel was initially anchored at `topLeading`, like the color samples. However, `↗` sits approximately 180pt from the edge of an 820pt window and the panel is 268pt wide. The “Apply” button was cut off.

Counting the panel's box does not catch this: it still exists at full size outside the screen. Measure the **bitmap**, and do not search for the field's interior color: in `tinta`, `btn` and `surface` differ by 0.02, so any reasonable tolerance merges them. The `btn-line` border distinguishes them.

## A table cell is an `NSTextTableBlock` instance, not a coordinate

`NSTextTable` combines paragraphs into one cell only when they share the **same instance** of `NSTextTableBlock`. Two blocks with identical `startingRow` and `startingColumn` are not one cell: they are two cells stacked at the same coordinate, making the entire row recalculate widths.

This stays hidden while each cell has one paragraph. It appears on the first Enter inside a cell, the most common table gesture. Measured with a 2×2 grid and a break in the middle of a cell, the drawing produced **four** columns (`minX` at 9, 162, 239, 315) instead of two (9, 239). The owner reported that pressing Enter broke the whole table.

The fix caches the block by (table, row, column) when projecting. The model was already correct — two paragraphs with the same coordinate — so an **attribute** test would have passed with the defect present. Only measuring the drawing catches it.

## Enter inside a cell has two paths, which fail in different places

After sharing blocks, Enter **in the middle** of a cell worked: `NSTextStorage` normalizes paragraph styles when fixing attributes, and the new paragraph inherits neighboring blocks. **At the beginning**, it did not: the new paragraph had no cell and expanded to full width (`colunas` at 0, 9, 239), splitting the table.

Two guards are therefore needed: `insertNewline(_:)` forces the current paragraph style onto the break, and typing attributes carry the cursor paragraph's `textBlocks`. Either alone handles the middle; only both handle the edge.

When fixing key behavior, the **middle** and **ends** are separate tests. A fix passing both can have two independent causes; disabling each guard separately reveals what the test actually proves.

## A panel behind a row is a `background`, not a `ZStack` sibling

This is the same family as the sibling `Rectangle` in an `HStack`, rediscovered in list swipes. The action panel sits **behind** a row and must fill its height, requiring `maxHeight: .infinity`. As a `ZStack` sibling, that stops meaning “fill the row” and becomes “take all available space”: the stack grows to the parent's offer and the row stretches.

Measured on a 140pt stage with a 106pt row, the sibling panel made the row occupy all 140pt, centering content with 17pt of spare panel above and below. In a list, the row **changes height the moment swiping starts** — the brief's “the list must not jump” requirement violated in a way no width measurement catches.

As `.background { … }`, the panel is measured by the content: it fills without influencing layout. The row's `.offset` leaves the layout frame untouched, so the background stays still while the row moves over it.

The measurement that catches it counts **pixel columns** containing panel background in a horizontal scan. With a sibling panel, the count becomes the full list width (370) rather than the two action columns (168), because the scan lands above the row where only the stretched panel draws.

## Edge clearance does not prove a label fits

In a panel with fixed columns, measuring the distance between the outermost glyph and the divider is tempting. It misses truncation: `Text` with `lineLimit(1)` cuts text and draws ellipses **inside** the frame, so clearance remains good with “Arquiva…” onscreen.

Pixel measurements only see labels drawn by **that row**. “Não lida” appears only on read messages; an archived message's right panel never shows “Arquivar”. Proven by breaking it with 22pt labels: “Arquivar” needed 85pt in an 84pt column, but the **right** panel's clearance test still passed because neither “Depois” (70) nor “Hoje” (46) overflowed there.

Measure each label's unconstrained requested width against the column literal, covering every label and both read states. The measurements complement each other: pixels prove the label was drawn and centered; width proves it fits.

## A disabled control is not the gray specified by its token

`ink4` is `rgb(168,166,158)` and disappears within luminance thresholds calibrated for text. SwiftUI's `.disabled()` then **dims the drawing again**: the disabled swipe column had background `rgb(237,235,229)` instead of `surface2`'s `rgb(241,239,234)`, and text `rgb(202,200,193)` instead of `ink4`'s `rgb(168,166,158)`.

Token-proximity tests misclassify both sides of a disabled control. Its background is within five levels of `surface3`, the background of an **active** column, so the measurement passes accidentally. The solution excludes disabled state from geometry measurements (use a message where both columns act), then verifies dimming separately by comparing the darkest pixel of neighboring columns rather than a fixed threshold.

## The final review proved defects through mutation, not reading (2026-08-27)

Five tracks reviewed the whole branch at `ae439e1`: UNICore, inbox, composer/windows, chrome/calendar and a dedicated audit of approximately 605 tests. Introducing the defect each test claimed to guard rejected 12 tests and found five critical defects hidden by a green suite: bold did not change the rendered face; “⤢” lost cc/attachments; the calendar rail ignored inbox filtering; two remaining `.stroke` borders blurred at 1×; and the date picker ignored navigation.

**Every surviving critical defect hid behind a decorative test.** The resulting rule, applied in repair tasks AJ, AK, AL and AM: a new test counts only after it is confirmed red with the defect reintroduced. Evidence is in `.superpowers/sdd/2026-08-26-okamiuni-shell/` reports (not versioned).

Two product decisions followed: “Reschedule” was removed from the appointment window instead of remaining inert (returning in Milestone 4 with EventKit), and contact suggestions use one engine, `ContactDirectory`, whose accent folding also powers list search (“Revisao” finds “Revisão”).

## A persisted appointment day is a civil date, never an offset (2026-08-29, M3-11)

`AgendaItem.dayOffset` is relative to the screen's “today”, which is correct for display: one list feeds the day rail, Week and Month without time-zone conversion. It is wrong for storage in a way that appears only the following day. With a connected account, “today” uses the machine clock (`AgendaClock.live`), so an appointment stored as `+1` would mean “tomorrow” today, tomorrow and next week — drifting forever at every launch.

`created_agenda_item` (migration v5) stores `day` as `"AAAA-MM-DD"` text. Three integers have no time zone, do not drift and survive travel. `CivilDay` is the single conversion boundary: writing converts offset to day; reading converts back relative to that launch's “today”. `MailStore` receives it through injected `agendaReferenceDay`, defaulting to `Fixtures.today`, preserving Milestone 1 captures byte for byte.

It is a new table rather than v1's `agenda_item` because `agenda_item.accountID` has `REFERENCES account(id)` and foreign keys are enabled. **Without a connected account there would be nowhere to save**: sample messages carry fixture account IDs, so `INSERT` would fail. An appointment created without an account still belongs to the person. `DatabaseAgendaStoreTests` proves it: reintroducing the foreign key fails five tests with `FOREIGN KEY constraint failed`.

## View clicks need click tests, and the harness window must be ordered (2026-08-29, M3-11)

“Clicking a collapsed message opens nothing” was unreachable through logic tests: stack logic was correct, but the body request triggered only by the `View` was missing. `ConversationStackView` gained its own boundary so it could be hosted alone in an offscreen window and receive an in-process synthetic event.

Two counterintuitive measurements followed:

1. **An `NSWindow` that was never ordered does not process mouse events.** `hitTest` finds the right `View`, yet the SwiftUI `Button` does not fire. `orderBack(nil)` on a window at −50,000pt resolves it without taking anyone's focus: it remains outside every monitor and behind everything.
2. **`NSApp.postEvent` kills the test process.** `RehearsalDriver.hit` deliberately queues mouse-up in `NSApp`, where AppKit tracking loops seek it; this is essential in the app. In a test process, touching that queue terminates the `main` drain loop and **exits with 0 in the middle of the test**, without a report line. This was traced to `exit` inside `swift_task_asyncMainDrainQueue`. A SwiftUI `Button` does not use a tracking loop, so direct paired `sendEvent` calls suffice.

A third lesson concerns the instrument: a view's `.task` is scheduled through the run loop. Waiting with `Task.sleep` leaves it unexecuted and measures an app state that does not exist. The wait must use `RunLoop.run`, as `Render` already did.

---

## The “OnDevice” prefix was misleading (2026-09-01, SP1)

`OnDeviceTextAssisting`, `OnDeviceAssistantMailContext`, `LocalAssistantPanel`: type names and UI copy unconditionally said “local” before the provider became configurable. Once Grok, LiteLLM, Codex and an installed CLI could receive the same content, wording such as “Uses all inboxes and calendar loaded on this Mac” and “Reading local context…” remained with any provider selected. Nobody changed those strings intentionally; they had never considered remote providers.

The fix removed the decision from individual screen authors. `AssistantDestination` carries `isLocal: Bool` and is the only source of truth about content destination. `ReaderPane`, `AssistantPanel`, `FolderSidebar` and `SettingsSections` consult it before wording implying “here” or “outside”. No app text may assert local processing without checking `AssistantDestination.isLocal`, regardless of type-name conventions.

## A 30-second timeout was wrong for 400,000-character prompts (2026-09-01, SP1)

The router began with 30 seconds for API/LiteLLM, 60 seconds (120 maximum) for CLI and 120 only for direct OAuth. Thirty seconds sufficed with Foundation Models' 8,000-character budget. When full emails entered configured-provider prompts (up to 400,000 characters), the same question became a minutes-long generation; the owner saw Grok fail through timeout rather than API error.

Two things changed, not just the number:

1. `URLRequest.timeoutInterval` is not total call duration: it limits gaps between packets. A slow-starting generation can time out on a healthy network, while a long response arriving gradually may never hit it. The total boundary comes from `URLSessionConfiguration.timeoutIntervalForResource`, previously unset everywhere. Assistant HTTP sessions now receive both values equally.
2. CLI time needs a floor as well as a ceiling: a cold `codex` takes time to start. `cliRequestTimeout` became 120 seconds by default, clamped to 30–300 seconds (formerly 60 with a 5–120 range).

`AssistantRouter.requestTimeout` and `cliRequestTimeout` now default to 120 seconds; `.providerOAuth` keeps `max(requestTimeout, 120)`. `AssistantCLIAuthenticationProbe` only checks presence and generates nothing, retaining its separate four-second timeout.

## Budgets must reach every path, not just the one someone remembered (2026-09-01, SP1)

An earlier commit (`0a6330a`) propagated `Budget` into single-email context (`AssistantPrompt.render(email:)`), fixing the most visible symptom: the configured provider received the whole email. Yet `AssistantPrompt.transform` still truncated text at a fixed 8,000 characters, and `render(_ workspace:)`, used for briefings and workspace questions, ignored the budget and fixed limits at 24 emails and 32 agenda items regardless of provider. Fixing one path while two retain constants leaves two bugs concealed by one apparent fix.

`Budget` gained `maximumTextCharacters` (8,000 for `.onDevice`, 400,000 for `.configured`), `maximumWorkspaceEmails` (24 / 256) and `maximumWorkspaceAgendaItems` (32 / 128). The new consumers (`transform`, `render(workspace:)`) read fields instead of literals. One `Budget` value must reach the final prompt-building function; no context renderer may invent its own fixed limit. Every new prompt path, such as a briefing strip or new surface, receives a `budget` parameter.

## No silent provider fallback (2026-09-01, SP1)

The obvious temptation was “Grok failed, summarize on the Mac”. The person chose a provider for cost, quality or privacy; automatic fallback silently takes that decision away precisely when the chosen provider has a problem.

Neither interactive calls (`AssistantConversation.ask/draftReply/...`) nor automatic analysis (`MessageIntelligenceCoordinator.processPending`) falls back to `FoundationModelsMessageAnalyzer` when the configured provider fails. The queue **pauses** after three consecutive environment failures (authentication, network, missing CLI — not a single ordinary network hiccup), persists state in `analysis_queue_state` (new single-row table, migration `v15`) and shows “Analysis paused · Try again” in the sidebar with the reason.

It uses its own table rather than `sync_state` for the same reason as v5's `created_agenda_item`: `sync_state.accountID` references `account(id)` with foreign keys enabled, leaving nowhere to persist without a connected account. This queue is global, not per account.

## Subscription Codex runs through the CLI, not an API key (2026-09-01, SP1)

A ChatGPT subscription does not become API credit. The working path uses the official Codex runtime already installed on the Mac: OkamiUNI launches its binary in an isolated process, and the session stays with the CLI. No ChatGPT token passes through the app or is read or serialized by it.

For `.providerOAuth` with `kind == .codex`, `AssistantAvailability` must check both session presence **and** binary availability. A missing binary means `.needsSetup`, not `.needsSignIn`; signing in again cannot repair an absent executable when a session already exists.

Presence checks also have a cost. `codexRuntime.isSignedIn()` starts the Codex app-server in a process and performs local JSON-RPC. It uses no network, but is not instant, and previously ran on every preferences `save`. `AssistantProviderOAuthCoordinator` caches `(signedIn, measuredAt)` for 30 seconds for `.codex`. xAI and LiteLLM continue reading Keychain directly without caching, since those local reads are cheap. `AssistantAvailabilityModel.refresh()` coalesces concurrent calls: never two probes at once; changes arriving during a probe trigger another after completion rather than being discarded.

## Untrusted data uses escaped delimiters — only two characters (2026-09-01, SP1)

Every email, account, inbox, agenda item and history turn enters the prompt inside `<untrusted-app-context>` / `<untrusted-assistant-history>`, with `<` and `>` escaped by `AssistantPrompt.escapedData`. Only those two: `&` is ordinary subject/link data, and escaping it would return drafts containing literal `&amp;`. Protection against delimiter injection must not break the product it protects.

The person's custom instructions have their own layer (`<user-configured-assistant-instructions>`), below fixed policy and explicitly marked as secondary preferences: they adjust form and expertise, never revoke security rules.

The golden file `Packages/UNISync/Tests/UNISyncTests/Golden/workspace-prompt.txt` makes adding a workspace-context field a deliberate decision instead of a side effect. It caught a real defect immediately: `<workspace-pending-items>` contained a `GRDB.SQL` debug description (`SQL(elements: [GRDB.SQL.Element.sql("- [", []), ...])`) instead of expected text. The section-building closure has two `let` statements before `return`; without explicit `-> String`, Swift 6's solver preferred `GRDB.SQL`'s `ExpressibleByStringInterpolation` conformance over the `StringProtocol` required by `.joined(separator:)`. The ambiguity compiled silently because the result was consumed through ordinary interpolation in the final template. Internal query structure leaked into the configured AI's prompt; only a golden comparing actual text could catch it.

## Remote-analysis opt-in used an app-controlled timestamp (2026-09-01, SP1)

`AssistantSettings.automaticAnalysis` initially defaults to `.onDeviceOnly`; enabling the configured provider was explicit opt-in, with “Every received message leaves this Mac for {label}” beside the toggle. The first gate, however, measured consent against `receivedAt`, the sender's `Date:` header rather than an app-controlled timestamp. A future-dated message (incorrect sender clock or deliberate spam) passed `receivedAt >= since` and left for the provider at opt-in even if it had been in the inbox for months. “Only messages arriving afterwards” depended on sender-controlled data.

Migration `v16` adds `message.firstSeenAt` — a new migration, not an edit to `v15` already applied to existing databases — with backfill at migration time. This is deliberately conservative: everything already in the inbox precedes future opt-in. `savePreservingIntelligenceProjection`, the sole production message-write path, preserves `min(atual, novo)` so resync cannot make an old message appear newly arrived. The gate compares `min(receivedAt, firstSeenAt ?? receivedAt)`, never `receivedAt` alone. That original timestamp remains unchanged where it matters: interpreting “tomorrow at 15:00” when detecting appointments. Clamping it there would corrupt the message's actual date interpretation.

## One state machine (2026-09-01, SP1)

`DashboardScreen` once reimplemented `AssistantConversation`'s state machine. The real engine became a second source of truth beside the screen's version, and they diverged until review. The dashboard CTA enabled drafts by checking `mailInFocus(focus) != nil`, which fell back to `focus.mail.first` when nothing was selected; the real engine resolved scope only from actual selection (`.workspace` without one). With no selected email, “Generate draft” was enabled but failed with “Creating a reply requires email context”, while the briefing that should have run was unreachable. The reader had a related defect: its “Generate reply” chip called `ask()` with a freeform question instead of `transform(.draftReply)`, producing question-answer formatting instead of email prose.

The fix removed surfaces' ability to define their own predicates. `DashboardScreen.run/runDraft/runSuggestion` were removed. `DashboardScreen`, `AssistantPanel`, `MessageWindow` and the reader popover receive an injected `AssistantConversation` and call its `ask/draftReply/briefing`, never independently deciding whether context permits drafting. A surface consumes `AssistantConversation`; it must not reimplement any logic already there, even for a button label.
