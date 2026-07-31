# Bento Landing Page — Content Blueprint

Target: `bento.novashang.com`. Single page, English (a `/cn` mirror can reuse
the structure with README_CN.md's voice). Every media slot is specified but
left empty — see the Asset Production List at the bottom.

**Goals, in order:**
1. Download for Mac (primary CTA, repeated 3×: hero / after pillar 3 / final)
2. iOS waitlist email (secondary CTA, one placement — inside the continuity pillar)
3. GitHub star (nav, passive)

**Tone:** the README's voice — confident, concrete, zero hype-words ("AI-powered",
"revolutionary" are banned). Every claim on the page is true today.

---

## 0. Meta / SEO

- `<title>`: Bento — the terminal for AI coding agents
- Description: Run a team of coding agents on your own machine. See who needs
  you at a glance. Answer with your voice — from anywhere. Free & open source,
  for macOS.
- OG image: `[ASSET-og]`

## 1. Nav

Logo (bento-icon.svg) · GitHub (with star count) · Changelog (→ releases) ·
**Download** (button, right-aligned)

## 2. Hero

**H1:** The terminal for AI coding agents

**Sub:** Run a team of coding agents on your own machine. See who needs you at
a glance. Answer with your voice — from anywhere.

**CTA row:**
- `[Download for Mac]` → https://github.com/NovaShang/bento/releases/latest/download/BentoTerm-macos-arm64.zip
- caption under button: Free & open source · macOS 14+ · Apple Silicon
- text link: `View on GitHub →`

**Media:** `[ASSET-hero]` — the product IS the pitch; this slot carries the page.

## 3. Trust strip

One quiet line, monochrome:

> Open source (Apache-2.0) · Signed & notarized · No accounts · Works with
> Claude Code, Codex, Gemini CLI + 7 more

## 4. Problem (3 sentences, no header image)

**H2:** Five agents. One of them needs you. Which one?

Coding now means supervising agents that work in parallel — while you review,
unblock, and decide. A classic terminal fights you the whole way: every tab
looks identical, you poll each one asking "done yet?", and the whole thing
dies with your SSH connection. Bento was built from scratch for exactly this
job.

## 5. Pillar 1 — states (kicker: YOUR AGENT TEAM)

**H2:** See who needs you — at a glance

Every pane knows its agent's state — **working**, **waiting for you**,
**done**, or idle — as one color-and-glyph language on title bars and in the
sidebar. Ten agents understood out of the box: Claude Code, Codex, Gemini CLI,
OpenCode, Cursor Agent, Copilot CLI, Amp, OpenClaw, Hermes, Antigravity — plus
plain shells and anything custom.

Bullets:
- **Parallel and Focus** — every pane tiled, or one thing full-size with the
  rest listed. Toggling restructures, never destroys.
- **Jump between agent turns** with one click instead of scrubbing scrollback.
- No SDK hooks, no agent cooperation needed — detection is pure observation.

**Media:** `[ASSET-states]`

## 6. Pillar 2 — voice (kicker: VOICE INPUT)

**H2:** Speak instead of type

Hold and speak, anywhere in the terminal. Release to drop the transcript in —
or slide to send it as-is, polish it with a bigger model, or turn plain
language into a shell command.

Bullets:
- **Knows your screen.** Recognition is biased by on-screen context; mixed
  Chinese/English just works.
- **Zero configuration.** Works out of the box. Bring your own API keys for
  direct calls if you prefer — Apple on-device, OpenAI, and Qwen engines.

**Media:** `[ASSET-voice]`

## 7. Pillar 3 — continuity (kicker: IT FOLLOWS YOU)

**H2:** Close the laptop. Keep the agents.

Your workspace lives in persistent tmux sessions — tmux is bundled, invisible
if you don't care, and seamlessly attached if you already live in it. Quit the
app, lose Wi-Fi, walk away: your agents keep working.

Bullets:
- **SSH quick-connect** from your existing `~/.ssh/config`; full features over
  plain SSH, nothing to install server-side.
- **Already a tmux user?** Bento attaches to your existing server — your
  sessions appear as-is, other clients stay in sync.

**iOS teaser box (inside this section):**
> **📱 iOS is coming.** Scan-to-pair, end-to-end encrypted, no accounts —
> answer your agent from your pocket while your Mac keeps working.
> `[email input] [Join the TestFlight waitlist]`

**Media:** `[ASSET-continuity]`

## 8. Feature grid (6 cards, one line each)

| | |
|---|---|
| **⌘-click any path** — instant rich preview: highlighting, Markdown, jump-to-line. Even TUI-truncated paths. | **⌘P command palette** — fuzzy-open any file or command from anywhere. |
| **Drag panes like VS Code** — split, dock, swap with drop zones; move panes across sessions. | **Light, dark, follow-system** — chrome and terminal themes included. |
| **A real terminal underneath** — GPU-accelerated libghostty rendering; your TUIs, vim, and ssh all just work. | **Voice → shell** — say what you want; a model writes the command, you press enter. |

## 9. Under the hood (for the terminal-literate reader)

**H2:** Built like a terminal, not a wrapper

- Rendering is **libghostty** — every pane is a real GPU-accelerated terminal
  surface, not a webview.
- **tmux is the source of truth.** Bento renders and edits tmux state, never a
  private copy — that's why sessions outlive the app and other tmux clients
  always agree with it.
- **Transport stays dumb, clients stay smart.** Plain SSH gives you
  everything; the optional daemon/relay only add reachability. Terminal
  intelligence never moves server-side.

Link: `Read the architecture notes →` (README#under-the-hood)

## 10. Privacy (short, boxed)

**H2:** Yours, on your machine

No accounts — pairing is the only identity. Telemetry is off by default and
strictly opt-in: a closed set of feature counters, never terminal content.
Voice audio goes to the speech provider through the Bento relay (keys live
server-side), or directly with your own key. Terminal output never leaves
your machine except to power the features you invoke.

## 11. FAQ

- **Which agents does it understand?** Ten presets (listed above) with
  live state detection, plus plain shells and custom commands — anything runs,
  known agents also get states.
- **Do I need to know tmux?** No. It's bundled and invisible. If you *do* use
  tmux, Bento attaches to your existing sessions seamlessly.
- **Intel Macs?** Not currently — Apple Silicon, macOS 14+.
- **What does it cost?** The app is free and open source (Apache-2.0). Hosted
  conveniences (like the zero-config voice relay) are free while in beta;
  optional paid services may come later. BYOK always stays free.
- **When is iOS coming?** TestFlight beta is in preparation — join the
  waitlist above.
- **Where do I report bugs?** GitHub issues. The bug tracker is public — you
  can watch fixes land.

## 12. Final CTA

**H2:** Your agents are already working. Stop tab-hunting them.

`[Download for Mac]` — Free & open source · macOS 14+ · Apple Silicon
`brew install NovaShang/bento/bento-terminal` shown small underneath for the
CLI/daemon (labelled: "CLI + daemon for headless hosts").

## 13. Footer

Bento 🍱 · GitHub · Releases · README (中文) · Apache-2.0 · Built by
[@NovaShang](https://github.com/NovaShang)

---

# Asset Production List

| Slot | Type | Spec |
|---|---|---|
| `[ASSET-hero]` | 20–30s autoplay loop (muted, no audio needed) or static PNG fallback | THE money shot: Parallel 2×2, four agents in four states (amber "waiting" is the eye magnet), sidebar visible, dark theme, Retina. If video: amber pane appears → user holds voice → transcript → send → pane turns blue. Same staging rules as docs/hero-mac.png (real repos, real tasks, no secrets). |
| `[ASSET-states]` | Static PNG (annotated) | Close crop of 4 title bars showing the four state glyphs + the sidebar with state dots. Callout labels: working / waiting for you / done / idle. |
| `[ASSET-voice]` | 10–15s loop | One pane, hold-to-talk overlay: speak (mixed zh/en line), transcript appears, slide-to-send. Big font size so the transcript is legible at 720px. |
| `[ASSET-continuity]` | 10s loop or 2-frame before/after | Mac window with running agent → app quits → reopen → session intact (timestamp/output continuity visible). Phone handoff visual is Phase 2 — do NOT fake it now. |
| `[ASSET-og]` | 1200×630 PNG | Logo + tagline + the 4-state pane strip. Dark. |

# Implementation notes

- Host: Cloudflare Pages (same account as relay); static, no framework needed.
- Waitlist: add a `POST /v1/waitlist` route to the existing relay worker (KV
  or D1, email + timestamp, rate-limited like other routes) — no third-party
  form service, consistent with the privacy story.
- Download button hits the `releases/latest/download/...` permalink — no
  per-release page edits needed.
- Analytics: Cloudflare's built-in only. No third-party trackers — the privacy
  section is a product claim, the site must live by it.
- The `/ios` path already referenced in-app (`bento.novashang.com/ios`) should
  redirect to the waitlist section anchor until TestFlight exists.
