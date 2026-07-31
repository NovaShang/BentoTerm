# Bento Design Language

> Like a real terminal, but warm enough to live in.

Bento targets **vibe coders** — developers who want the productivity and aesthetic of hardcore senior engineers without paying the tool-learning tax (no dotfiles, no tmux cheatsheet, no vim config). The design must read as *a serious tool*, but the interactions must remain *gentle and modern*.

## Core implementation rule

**Use native iOS chrome, recolor with bento tokens. Do not invent custom card geometries.**

Concretely: every list, every form, every settings screen, every picker, every host row uses the standard SwiftUI `Form` / `List` with `Section` + `NavigationLink` / `Picker` / `Toggle` / `TextField`. The brand layer is **color and typography**, applied via the modifiers in this doc — never a parallel UI kit of hand-rolled rounded cards. The home page is a `Form` with sections, not a stack of bordered tiles.

This rule exists because we tried both directions. The custom card stack diverged from the rest of the app, and the rest of the app diverged from the card stack — there was no way to make them consistent without picking one. We picked native, because (a) it scales: every new screen automatically inherits the language without designing a new card pattern, (b) it preserves iOS affordances (chevrons, swipe actions, search, separators) that users already know.

---

## 1. Source of truth: the Bento icon

The icon at `docs/bento-icon.svg` is the canonical brand artifact. Everything in this doc — palette, geometry, metaphor — derives from it. **Do not invent colors, shapes, or marks that contradict the icon.** If a design choice can't be traced back to the icon, treat it with suspicion.

The icon encodes three ideas:

1. **分格便当 = 多 pane 终端.** Four unequal compartments with outer corners rounded and inner intersections sharp. This is the multi-pane terminal model made visible. The shape language belongs to the *product structure* (terminal grid, session picker, app icon), not to UI chrome.
2. **冷外壳 + 暖内.** Cold IDE-grey shell wraps warm content (emerald prompt, salmon, rice-white, veg-green). The tool feels professional from the outside, lived-in on the inside. This tension drives the whole palette.
3. **`>_` 是品牌 mark.** The emerald arrow + cursor block inside the top-left cell is the wordmark companion. It appears **once** — in the toolbar logo lockup. Not as decoration sprinkled across the UI.

---

## 2. Five principles

**P1. Bento metaphor lives in shape and palette, not in text.**
The split-pane geometry, the icon colors, the wordmark — these carry the brand. Section headers, status lines, and empty-state copy stay in plain prose. Never write `$ bento ls hosts → (no hosts paired)` as a fake terminal prompt; write `No hosts yet`.

**P2. Chrome is a clean modern GUI.**
SF Pro for headings and body. Real semantic hierarchy (`title3`, `subheadline`, `caption`). Linear/Arc/Things-style precision: confident typography, strict spacing, restrained color. The "硬核感" comes from the *quality of the GUI*, not from cosplaying a CLI.

**P3. Monospace is semantic, not decorative.**
Use SF Mono only where the content is literally a terminal string: `user@host:port`, command output, latency numbers, log lines, file paths. Anywhere it's prose ("Connected", "Active Sessions", "Welcome to Bento"), use SF Pro. If you're tempted to mono a label for "vibes," stop.

**P4. State is rendered with icon + label + color, not character art.**
A connection is `● Connected` (emerald dot + emerald pill + emerald text), not `[+] connected · 23ms ✓`. Status is information; make it scannable.

**P5. One brand mark, used once.**
The BentoMark (4-cell SVG-geometry view) appears in the toolbar wordmark and in the empty-state hero. That is the entire budget. Do not sprinkle mini bento marks as section ornaments.

---

## 3. Color tokens

All tokens live in `BentoTermiOS/Sources/Views/Common/BentoTheme.swift` under `BentoBrand` (UIColor) and `Color.bento*` (SwiftUI). **Dark-mode only** — Bento ships dark-locked via `.preferredColorScheme(.dark)` on the root.

### Frame (cold)

| Token             | Hex       | Role                                              |
| ----------------- | --------- | ------------------------------------------------- |
| `bentoShell`      | `#16181D` | Page background — straight from icon outer shell  |
| `bentoSurface`    | `#1E222B` | Card / elevated surface                           |
| `bentoSurfaceHi`  | `#262B36` | Inner chip, hover state                           |
| `bentoInset`      | `#0D0F13` | Recessed surface — icon's prompt cell, terminal bg |
| `bentoBorder`     | `#2A2E38` | 1px subtle card border                            |
| `bentoBorderHi`   | `#363B47` | Stronger divider                                  |

### Ink (warm)

| Token            | Hex       | Role                                |
| ---------------- | --------- | ----------------------------------- |
| `bentoInk`       | `#F0EAD8` | Primary text — rice-white, warm     |
| `bentoInkDim`    | `#9CA0AB` | Secondary text                      |
| `bentoInkMute`   | `#5A5F6B` | Disabled / least-prominent          |

Note: primary ink is **not** pure white. It carries the icon's rice color, which is what gives the whole UI its temperature. Do not replace it with `#FFFFFF` or `#E6E8EE` "for clarity" — the warmth is the point.

### Brand cells (state-as-decoration)

| Token            | Hex       | Semantic role                                            |
| ---------------- | --------- | -------------------------------------------------------- |
| `bentoEmerald`   | `#4ADE80` | **Primary.** Connected / live / prompt / cursor / CTA    |
| `bentoSalmon`    | `#E89B7C` | Awaiting input / voice action / warm secondary           |
| `bentoRice`      | `#F0EAD8` | Same as `bentoInk` — used when "rice" cell is rendered   |
| `bentoVeg`       | `#6FA254` | Category — relay/Mac, "my computers" group               |
| `bentoVegDeep`   | `#4D7C3F` | Veg shadow / depth                                       |
| `bentoRed`       | `#FF5A52` | Error / ended session                                    |

### Rules

- **No invented colors.** If a UI element needs a color, it must be one of the above (or `.opacity()` of one). No purple, no system blue, no Tailwind colors outside the icon set.
- **No iOS system tints.** `tint(.bentoEmerald)` is applied at app root so default `accentColor` usages render correctly.
- **Opacity for halos and backgrounds.** Connected card border: `bentoEmerald.opacity(0.35)`. Awaiting pill bg: `bentoSalmon.opacity(0.14)`. Avoid blending colors directly.

---

## 4. Typography

| Slot               | Spec                                          | Used for                              |
| ------------------ | --------------------------------------------- | ------------------------------------- |
| Hero title         | SF Pro 26 Bold                                | Empty-state "Welcome to Bento"        |
| Title              | SF Pro 17 Semibold                            | Toolbar wordmark, sheet titles        |
| Body emphasis      | SF Pro 16 Semibold                            | List row primary (host name)          |
| Section header     | SF Pro 13 Semibold                            | "Active", "My Computers", "SSH Hosts" |
| Body               | SF Pro 15 Regular                             | Paragraph text                        |
| Subheadline        | SF Pro 13 Regular                             | Card subtitles ("Paired 2m ago")      |
| Caption            | SF Pro 12 Regular                             | Last-seen times                       |
| **Mono — small**   | SF Mono 12 Regular                            | `user@host:port` strings              |
| Mono — terminal    | Maple NF CN / JetBrains Mono (user choice)    | Terminal panes only                   |

**`.textCase(nil)`** on section headers — never uppercase tracking. ALL CAPS belongs to terminal output, not GUI labels.

---

## 5. Components

### `.bentoForm()` — apply once per top-level Form/List

```swift
Form {
    Section { ... } header: { BentoFormHeader("Server") }
        .bentoSectionStyle()
    Section { ... } header: { BentoFormHeader("Authentication") }
        .bentoSectionStyle()
}
.bentoForm()
```

`.bentoForm()` hides the system scroll background and paints `bentoShell`. `.bentoSectionStyle()` paints rows on `bentoSurface` and tints separators in `bentoBorder`. This is the only chrome work you need on a new screen.

### `BentoFormHeader` / `BentoFormFooter`

Drop into a `Section`'s `header:` / `footer:` closures. `BentoFormHeader("Title")` renders SF Pro 13 Semibold, sentence case, ink primary. `BentoFormFooter("Hint…")` renders footnote in ink-dim. They replace iOS's default UPPERCASE gray.

### Row content

Rows go inside Sections as plain `HStack`s — no own surface or border (the Section supplies that). Pattern: 34×34 rounded icon plate (12pt corner) on the left, two-line title/subtitle in the middle, status pill or relative-time on the right. See `HostRow`, `RelayDaemonRow`, `ActiveSessionRow` in `HostListView.swift` for the reference implementation.

### `StatusPill`

Capsule with `color.opacity(0.12)` fill, 6pt colored dot + label. Used for "Connected", "3 waiting", etc.

### BentoMark (`BentoTermiOS/Sources/Views/Common/BentoMark.swift`)

The 4-cell logo geometry. Two variants:

- `BentoMark(size: 22)` — flat colored cells, used in toolbar wordmark.
- `BentoMarkHero(size: 96)` — adds the emerald `>` arrow and cursor block inside the top-left cell, on top of an `bentoInset` frame plate. Used as empty-state hero.

The shape uses `UnevenRoundedRectangle` (iOS 16.4+) with one large outer corner radius and three near-square inner corners per cell — matching the icon's "外角圆，内角直" rule. Cell proportions and offsets are normalized from the SVG (`docs/bento-icon.svg`).

### BentoWordmark

`HStack { BentoMark(size: 22); Text("Bento") }` in the navigation bar `principal` slot. Replaces the default nav title.

### NavigationLink

Use the native `NavigationLink(value: ...) { RowContent(...) }`. The system chevron is **welcome** — it tells the user the row is tappable and matches every other section in the app. Do not suppress it.

### Empty state hero

When all sections would be empty, swap the Form for a centered `BentoMarkHero(size: 96)` with title + body + two CTAs (`bentoPrimaryButton` emerald, `bentoSecondaryButton` outline). Reference: `EmptyHomeView` in `HostListView.swift`.

### Toast

`BentoToast` — capsule, `bentoSurface` fill, salmon `info.circle.fill` glyph, `bentoBorder` 1px stroke. Bottom-anchored, autodismisses after 3s.

---

## 6. Motion

- Default: SwiftUI's `.easeInOut(duration: 0.2)` for state changes. Linear-style restraint; no bouncy springs.
- Toast: `.move(edge: .bottom).combined(with: .opacity)` on enter/exit.
- No looping animations on idle UI. (No blinking cursors in chrome — the BentoMark prompt cursor is **static** in the icon and stays static in the hero.)
- Voice/ASR animations live in the terminal layer (`VoiceOverlayView`), not in the home page chrome.

---

## 7. Where the bento metaphor IS allowed

| Surface                                  | Manifestation                                                  |
| ---------------------------------------- | -------------------------------------------------------------- |
| App icon                                 | `docs/bento-icon.svg` directly                                 |
| Toolbar wordmark                         | `BentoMark(size: 22)` next to "Bento" text                     |
| Empty state hero                         | `BentoMarkHero` with prompt cell content                       |
| Terminal multi-pane layout (future)      | Pane geometry follows outer-rounded / inner-square rule        |
| Session picker cards (future)            | 2×2 bento-grid arrangement when 2–4 sessions exist             |

## 8. Where it's NOT allowed (anti-patterns)

| Don't                                              | Do instead                                  |
| -------------------------------------------------- | ------------------------------------------- |
| Hand-rolled rounded card stack for list pages      | Native `Form` / `List` + `Section` + `.bentoSectionStyle()` |
| Suppress system NavigationLink chevron             | Let it render — it's the affordance         |
| `> ACTIVE` mono section header                     | `BentoFormHeader("Active")` sentence case   |
| `$ bento ls hosts ▊` fake boot prompt              | Real empty state with hero + CTAs           |
| `grep '<query>' — no matches`                      | `No hosts match "query"`                    |
| Status chip salad `3 TARGETS · 1 LIVE · ASR OPENAI`| `StatusPill` on the relevant row            |
| Sprinkling mini `>_` marks as ornament             | One wordmark in toolbar, full mark in empty state |
| Purple/electric anything                           | Use the icon's 5-color palette only         |
| ALL CAPS + tracking on labels                      | `.textCase(nil)`, sentence case             |
| `Color.green` / `Color.orange` system tints        | `Color.bentoEmerald` / `Color.bentoSalmon`  |

---

## 9. Implementation pointers

| Concern                | File                                                   |
| ---------------------- | ------------------------------------------------------ |
| Color tokens & fonts   | `BentoTermiOS/Sources/Views/Common/BentoTheme.swift`          |
| Logo geometry          | `BentoTermiOS/Sources/Views/Common/BentoMark.swift`           |
| Home page reference    | `BentoTermiOS/Sources/Views/HostList/HostListView.swift`      |
| Active session cards   | `BentoTermiOS/Sources/Views/HostList/ActiveSessionsStrip.swift` |
| Dark mode + tint root  | `BentoTermiOS/Sources/App/BentoApp.swift`                     |

When in doubt, open `HostListView.swift` and copy the pattern — that file is the de facto reference implementation for cards, sections, empty state, and toolbar layout.
