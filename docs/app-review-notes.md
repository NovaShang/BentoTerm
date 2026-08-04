# iOS App Store submission — review notes and form answers

Working sheet for the App Store Connect submission. Everything here is either
text to paste into a form or a decision that has already been made in the
build; where a decision is still open it says so.

## 1. The demo host (the thing that gets this rejected without)

BentoTerm connects to a computer the user already reaches over SSH. It bundles
no server and installs nothing on the host, so **a reviewer with no SSH host
cannot see a single feature** — the first screen asks for one and that is as
far as they get. That is the classic Guideline 2.1 "unable to review" rejection
for terminal clients, and it is avoided only by handing them a working host.

Set up before submitting:

- A VPS reachable from the public internet (not LAN, not Tailscale — the
  reviewer's network reaches neither). Any $5 box does.
- `sshd` reachable on port 22, and `tmux` installed. Nothing else is required.
- A dedicated throwaway account with **password authentication enabled** —
  key-based auth means walking a reviewer through importing a private key.
- Worth doing: leave one agent CLI installed and a `tmux` session already
  running with a couple of panes, so agent status dots and the Parallel/Focus
  split are visible immediately rather than only after setup.
- Assume the credentials leak. Firewall the box, put nothing on it, and delete
  it after the review clears.

## 2. App Review Information → Notes (paste this, filling in the host)

> BentoTerm is an SSH client for tmux. It connects to a computer you already
> administer and attaches to a tmux session there, so that long-running
> terminal programs stay alive when the phone locks or the connection drops.
> The app runs no server of its own and installs nothing on the remote machine.
>
> A test host is provided because the app has nothing to show without one:
>
>   Host: <hostname or IP>
>   Port: 22
>   Username: <user>
>   Password: <password>
>
> To review:
> 1. Launch the app and tap "Connect over SSH".
> 2. Enter the host, username and password above, then tap Save and connect.
> 3. The app attaches to a tmux session on that machine. Panes can be split,
>    switched between the Parallel and Focus layouts, and typed into with the
>    on-screen keyboard.
>
> Voice input is optional and off by default. When used, it transcribes with
> Apple's on-device speech recognizer; no microphone access is requested until
> the microphone button is tapped.
>
> Usage analytics are opt-in and off by default (Settings → Privacy).

## 3. App Privacy (nutrition label)

Matches `BentoTermiOS/Resources/PrivacyInfo.xcprivacy`; keep the two in step.

| Question | Answer |
|---|---|
| Do you collect data? | Yes — only if the user turns on the optional analytics toggle |
| Usage Data → Product Interaction | Collected · Analytics · **not** linked to identity · **not** used for tracking |
| Identifiers → Device ID | Collected · Analytics · **not** linked to identity · **not** used for tracking — this is the random `install_id`, deleted the moment the toggle goes off |
| Audio Data | **Not** collected. Default recognition is Apple's on-device engine; the optional Qwen/OpenAI engines stream audio through a proxy that forwards in real time and retains nothing |
| Tracking | None. No third-party SDK, no ad identifier |

A privacy policy URL is mandatory on the App Store listing and must describe
the analytics toggle and the optional cloud speech engines. **If the ASR proxy
ever starts logging audio or transcripts, this table and the privacy manifest
both become false** — add Audio Data to each.

## 4. Export compliance

Already in the build: `INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: true`
(`project.yml`). Declared true, not false, because the app statically links
BoringSSL through swift-crypto and speaks SSH through NIOSSH — none of Apple's
exemptions (Apple-OS-only crypto, HTTPS-only, authentication-only) describe
that.

In the App Store Connect questionnaire: the algorithms are published standards,
not proprietary, which is the mass-market case under EAR 5D002 / License
Exception ENC. Claiming it carries one obligation — a self-classification
report to BIS each January. Confirm the specifics for your entity before
relying on this paragraph; it is engineering's reading, not legal advice.

## 5. Listing metadata still to produce

- Screenshots: 6.9" iPhone is required. **The app is a universal binary
  (iPhone + iPad), so iPad screenshots are required too** — and a reviewer will
  open it on an iPad.
- Description, keywords, support URL, privacy policy URL.
- Age rating questionnaire.
- Category: Developer Tools.

## 6. Known risk carried into review

The background→reopen hang and the surface-recreation crash were fixed on
2026-08-03 (`GhosttyTerminalSurface`: per-draw push budget, and detaching
ghostty's layer before freeing the surface). Both were device-only and timing
dependent, and neither reproduces in the simulator or in tests — so the only
real verification is using the app on a device across several
background/reopen cycles before uploading the build.
