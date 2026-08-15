# Bento Term — a terminal for watching and talking to your agents

English | [简体中文](README_CN.md)

[![Release](https://img.shields.io/github/v/release/NovaShang/BentoTerm)](https://github.com/NovaShang/BentoTerm/releases/latest)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS%2014%2B%20·%20iPhone%20·%20iPad-lightgrey)

<p align="center"><img src="docs/media/hero-parallel.webp" width="820" alt="Bento Term running five agents in parallel, each pane tinted by what its agent is doing"></p>

Agents run autonomously for forty minutes at a stretch now. Watching one run is a
waste of you — so you run several, and the problem becomes keeping track of them
all. Bento Term is a terminal built for exactly that: every agent in its own pane,
tinted by what it's doing, in one window that reads like a bento box.

**[bentoai.dev/term](https://bentoai.dev/term/)** · `brew install --cask NovaShang/tap/bento-term` · iPhone & iPad: App Store shortly

## A whole team, one screen

- **Every pane knows its agent's state** — 🔵 working, 🟠 waiting for you, 🟢 done-and-unread, ⚪ idle — as a consistent color-and-glyph language on title bars and in the sidebar. You read the room instead of visiting each one.
- **Ten agents understood out of the box:** Claude Code, Codex, Gemini CLI, OpenCode, Cursor Agent, Copilot CLI, Amp, OpenClaw, Hermes, Antigravity — plus plain shells and any command you type. Every profile is editable, so a tool nobody has heard of yet is one profile away.
- **Two readings of the same workspace:** Parallel (everything tiled) and Focus (one thing full-size, the rest listed). Switching moves the real panes — it restructures, never destroys.
- **Nothing in your shell.** No init line, nothing for the agent to cooperate with — states come from what the pane already prints, detected on your device.

## Say it, don't type it

- **Hold right-click on a pane and talk.** You speak about three times faster than you type. Release to drop the transcript in; slide up to send, down to cancel — or turn plain language into a shell command.
- **Recognition that reads the screen.** Vocabulary is biased by on-screen context, so file names, jargon and even identifiers from your code come out right — mixed Chinese/English included.
- **Three engines, zero configuration.** Apple on-device, Qwen, OpenAI — through the Bento relay out of the box, or direct with your own key.

## Leave the desk, not the work

- The work lives in **real tmux sessions** on your machine, not in the app. Quit the app, close the laptop, lose Wi-Fi — nothing stops.
- **Already live in tmux?** Bento attaches to the sessions you have right now via control mode (`-CC`); every other tmux client stays perfectly in sync. Never used tmux? It's bundled and stays out of the way.
- **Anything with `sshd` and `tmux` works:** your Mac, a Linux server, WSL on a Windows box. Plain SSH from your existing `~/.ssh/config`, nothing of ours installed on the other end.
- **Same panes on your phone.** The native iPhone and iPad app attaches mid-run — see the same states, answer the amber one, and put the phone back in your pocket.

## Things you'll use every day

- **See the files, not just the output.** Every pane carries its working directory's file tree — any depth, search included. Click a printed path and it opens with syntax highlighting and a line gutter, even at `:42`, even if a TUI truncated it. PDFs and images go to Quick Look.
- **Panes move like windows.** Split right or down, drag a pane by its title bar into any drop zone — including another session. Every drop is a real tmux move.
- **Never type a command again.** Pick a folder, pick an agent, pick a layout — Bento opens the panes and starts the agent in each. Everything else is one <kbd>⌘P</kbd> away.
- **⌘F in the scrollback** (search runs in the terminal engine, matches highlight in place), any iTerm2 color scheme, any monospaced font you own, light/dark/follow-system.

## Install

**Requirements:** macOS 14+ on Apple Silicon.

```sh
brew install --cask NovaShang/tap/bento-term
```

Or download `BentoTerm-macos-arm64.zip` from the [latest release](https://github.com/NovaShang/BentoTerm/releases/latest) and drag `BentoTerm.app` into `/Applications` — signed and notarized, opens without warnings.

The app is fully self-contained: tmux is bundled, and first run walks you through
your first agent session, including one-command installers for any agent you don't
have yet. A remote machine needs only `sshd` and `tmux`; reaching it (NAT, VPN,
Tailscale, jump hosts) is your `~/.ssh/config`'s business — Bento ships no relay
and no host-side component.

## Privacy

- **No accounts.** Nothing to sign up for.
- **Your terminal output never leaves your machines.** The connection is plain SSH with nothing of ours in between.
- **Telemetry is off by default** and strictly opt-in — a closed set of event names, never terminal content, commands, paths or hostnames.
- **Voice audio** goes to the speech provider through the Bento relay (keys live server-side), or directly with your own key. Details: [privacy page](https://bentoai.dev/privacy/).

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
