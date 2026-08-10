# Bento — the terminal for AI coding agents

English | [简体中文](README_CN.md)

Run a team of coding agents on your own machine. See who needs you at a glance. Answer with your voice — from anywhere.

<!-- hero: drop a screenshot or short GIF here before publishing.
     Suggested shot: a Parallel window with 4 agent panes in mixed states
     (working / waiting / done), sidebar visible, voice overlay active.
<p align="center"><img src="docs/hero-mac.png" width="720" alt="Bento running four agents in parallel"></p>
-->

Modern coding is several agents working in parallel while you review, unblock, and decide. A classic terminal makes that miserable: every pane looks the same, you tab around asking "are you done yet?", and the whole thing dies with your SSH connection. Bento is a native macOS terminal built for exactly this workflow — with an iOS companion on the way, so your agent team follows you out the door.

## An agent team, at a glance

- **Every pane knows its agent's state** — working, waiting for you, done, or idle — shown as a consistent color-and-glyph language on pane title bars and in the sidebar. No more polling your own terminal.
- **Ten agents understood out of the box:** Claude Code, Codex, Gemini CLI, OpenCode, Cursor Agent, Copilot CLI, Amp, OpenClaw, Hermes, and Antigravity — plus plain shells and custom commands.
- **Two readings of the same workspace:** Parallel (every pane tiled, states everywhere) and Focus (one thing full-size, the rest listed). Toggling is lossless — it restructures, never destroys.

## Speak instead of type

- **Hold and speak, anywhere in the terminal.** Release to drop the transcript in; slide to send as-is, refine it with a better model, or turn plain language into a shell command.
- **Recognition that knows your screen.** Vocabulary is biased by on-screen context, and mixed Chinese/English input just works.
- **Zero configuration.** Voice works out of the box through the Bento relay. Bring your own API keys if you prefer direct calls — Apple on-device, OpenAI, and Qwen engines are all supported.

## Sessions that outlive everything

- Your workspace lives in **persistent tmux sessions** (tmux is bundled — nothing to install). Quit the app; your agents keep working.
- **Already live in tmux?** Bento attaches straight to your existing tmux server: the sessions, windows, and panes you have right now appear as-is, and every other tmux client stays perfectly in sync.
- **SSH quick-connect** from your existing `~/.ssh/config`, with full features over plain SSH. The only thing a remote machine needs is `sshd` and `tmux` — no agent, no daemon, nothing to install.

## A terminal that reads its own output

- **⌘-click any file path** — even ones a TUI wrapped or truncated — for an instant rich preview: syntax highlighting, rendered Markdown, jump-to-line.
- **⌘-click URLs** to open them.
- **Drag panes** to split, dock, or swap with VS Code-style drop zones; move panes and windows across sessions.
- **Light, dark, or follow-system** appearance, terminal themes included.

## Install

**Requirements:** macOS 14+ on Apple Silicon.

With Homebrew:

```sh
brew install --cask NovaShang/tap/bento-term
```

Or by hand:

1. Download `BentoTerm-macos-arm64.zip` from the [latest release](https://github.com/NovaShang/BentoTerm/releases/latest).
2. Unzip and drag `BentoTerm.app` into `/Applications`. The app is signed and notarized — it opens without warnings.

Either way, first run walks you through creating your first agent session, including one-command installers for any agent you don't have yet.

The Mac app is fully self-contained — tmux is bundled, and there is nothing to install alongside it.

To use a remote machine, it needs `sshd` running and `tmux` installed. Getting that machine reachable from yours (NAT, VPN, Tailscale, a jump host) is up to you and your `~/.ssh/config`; Bento does not ship a relay or a host-side component.

## Privacy

- **No accounts.** Nothing to sign up for.
- **Telemetry is off by default** and strictly opt-in — a closed set of feature counters, no terminal content, ever.
- **Voice audio** goes to the speech provider through the Bento relay (keys live server-side); with your own key it goes directly to the provider. Terminal output never leaves your machine except to power the features you invoke.

## Under the hood

| Layer | Choice |
|---|---|
| Terminal rendering | [libghostty](https://ghostty.org) — every pane is a real GPU-accelerated terminal surface (GhosttyKit xcframework), not a webview or a from-scratch emulator |
| Multiplexing | tmux control mode (`-CC`), with tmux bundled and [`BentoTmuxKit`](Modules/BentoTmuxKit/) as our own strict, heavily-tested protocol client |
| Apps | Native Swift end to end — AppKit/SwiftUI on macOS, UIKit/SwiftUI on iOS — as thin shells over the shared [`Modules/`](Modules/) packages |
| Agent state detection | Client-side heuristics over pane output, titles, and process info — per-agent profiles, no SDK hooks, no cooperation from the agent required |
| SSH | macOS rides your system OpenSSH, so `~/.ssh/config`, ControlMaster, and jump hosts all just work; a remote host needs only `sshd` + `tmux` |
| Voice | A `SpeechEngine` abstraction over Apple on-device, OpenAI, and Qwen realtime ASR, with on-screen-context vocabulary biasing |

Two design rules shape everything:

1. **tmux is the source of truth.** The app renders and edits tmux state; it never owns a private copy. That's why sessions outlive the app and why any other tmux client agrees with what Bento shows.
2. **Transport is dumb, clients are smart.** Everything works over a plain local shell or vanilla SSH. Agent detection and terminal intelligence live entirely in the client and never move server-side.

## Repository layout

| Directory | What it is |
|---|---|
| `BentoTermMac/` | macOS app — AppKit/SwiftUI shell |
| `BentoTermiOS/` | iOS / iPadOS app — UIKit/SwiftUI shell |
| `Modules/BentoTmuxKit/` | tmux control-mode (`-CC`) protocol client |
| `Modules/BentoGhosttyKit/` | Terminal surfaces over libghostty |
| `Modules/BentoAgentKit/` | Agent detection rules and pane state |
| `Modules/BentoSessionKit/` | Session, window and pane logic |
| `Modules/BentoVoiceKit/` | Speech engines and the voice controller |
| `Modules/BentoFilePreviewKit/` | Path resolution and rich file preview |
| `Modules/BentoUISharedKit/` | UI shared across both platforms |
| `Modules/BentoFoundationKit/` | Logging and low-level shared utilities |
| `Modules/GhosttyKit/` | libghostty as a binary xcframework target |
| `docs/` | PRD, design docs, bug tracker |

## Building from source

You need Xcode 26+. GhosttyKit — libghostty packaged as an xcframework — is fetched automatically as a Swift Package binary target. A build-phase script runs `scripts/fetch-bundled-tmux.sh` to pull the prebuilt tmux pinned in `scripts/bundled-tmux.version` and embeds it at `BentoTerm.app/Contents/MacOS/helpers/tmux`; it needs the `gh` CLI, and without it the app falls back to a system tmux.

```sh
git clone https://github.com/NovaShang/BentoTerm.git && cd BentoTerm
xcodebuild -project BentoTerm.xcodeproj -scheme BentoTermMac -configuration Release build
```

The `BentoTermMac` scheme is the macOS app; the `BentoTermiOS` scheme is iOS. If you change `project.yml`, regenerate the project with [XcodeGen](https://github.com/yonaskolb/XcodeGen).

## License

[Apache-2.0](LICENSE)
