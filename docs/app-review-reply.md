# Reply to Guideline 2.1 — Information Needed

Apple did not find a bug; they could not exercise the app. BentoTerm needs an
SSH host before it shows anything, and this submission went in without a demo
host or review notes — which is the exact rejection `app-review-notes.md`
predicted. The fix is information, not code.

Two things go into App Store Connect:

- **Resolution Center** → reply with the seven answers below.
- **App Review Information → Notes** → paste the same answers (items 3–7 plus
  the credentials) so future submissions never ask again.

Fill every `<…>` before sending. Nothing below should be sent as-is.

---

## Before you can send it

| Needed | Why | Status |
|---|---|---|
| A demo SSH host | Item 4. Public IP, `sshd` on 22, `tmux` installed, throwaway account with **password auth** (key auth means walking a reviewer through importing a key). | `<you>` |
| The device list you really tested on | Item 2 is a factual claim to Apple — do not let me guess it. Paired to this Mac: iPhone 17 Pro Max (iPhone18,2), iPhone 16, iPhone 14 Pro, iPad Air 11-inch (M2). | `<confirm>` |
| A screen recording | Item 1. Shot list below. | `<record>` |
| A contact phone with country code | The App Review Information form requires it (`+86…`), and the API refuses to create the record without one. | `<you>` |

---

## 1. Screen recording — shot list

One take, physical device, current iOS, no cuts. Apple wants the app launched
from the home screen and driven through its core flow.

1. Home screen → tap the icon (launch from cold, not from the switcher).
2. Welcome screen → **Connect over SSH**.
3. Type the demo host, username and password. Tap Save and connect.
4. The tmux session attaches: show the pane grid, tap between panes, type a
   command (`ls -la`, then `top` for something live), press Return.
5. Split a pane; switch between the **Parallel** and **Focus** layouts.
6. Tap the microphone button → **the microphone and speech-recognition prompts
   appear on camera** (this is the only permission the app requests, and it is
   requested only here). Grant, dictate a short command, release to insert it.
7. Lock the device, unlock, return to the app — the session is still attached.
   (This is the app's whole point and worth showing.)
8. Settings → **Privacy**: the "Share anonymous usage statistics" toggle is
   off. Settings → **Speech**: the engine picker is on Apple's on-device
   recognizer.

Say in the reply what the recording does **not** contain and why — Apple asked
about four things this app has none of:

> The app has no account registration, login or account deletion, no purchases
> or subscriptions, no user-generated content shared between users, and does not
> use App Tracking Transparency. The only permission prompts are microphone and
> speech recognition, both shown in the recording.

---

## 2. Devices and operating systems tested

> `<confirm each line before sending>`
>
> - iPhone 17 Pro Max (iPhone18,2) — iOS `<version>`
> - iPhone 14 Pro (iPhone15,2) — iOS `<version>`
> - iPad Air 11-inch (M2) — iPadOS `<version>`
>
> Minimum supported version is iOS 17.0. The app is universal (iPhone + iPad).

---

## 3. What the app does and who it is for

> BentoTerm is an SSH client built around tmux, for developers and system
> administrators who already work in a terminal.
>
> The problem it solves: a terminal session on a phone dies the moment the
> screen locks, the network changes, or the app is backgrounded — which is
> exactly when a long-running build, deployment, or command-line AI agent is
> still working. BentoTerm connects over SSH to a machine the user already
> administers and attaches to a tmux session there. The work runs on that
> machine, not on the phone, so it survives disconnection; reopening the app
> reattaches to the same session with its output intact.
>
> Because tmux organizes work into panes, the app renders them as a grid: a
> Parallel layout showing several panes at once, and a Focus layout for one pane
> at a time. Each pane shows whether the program in it is working, waiting for
> input, or finished, so a user running several command-line agents can see at a
> glance which one needs them.
>
> The audience is professional developers. The app ships no server, installs
> nothing on the remote machine, and provides no content of its own — everything
> on screen comes from the user's own computer.

---

## 4. How to set up and reach every feature

> The app cannot show anything without a computer to connect to, so a test host
> is provided:
>
>     Host:     <hostname or IP>
>     Port:     22
>     Username: <user>
>     Password: <password>
>
> 1. Launch the app and tap **Connect over SSH**.
> 2. Enter the host, username and password above; tap **Save and connect**.
> 3. The app attaches to a tmux session on that machine and shows its panes.
>    Tap a pane to focus it and type with the on-screen keyboard.
> 4. Split a pane from the pane menu, and switch between the Parallel and Focus
>    layouts from the toolbar.
> 5. Voice input (optional): hold the microphone button, speak, and release to
>    insert the text. iOS asks for microphone and speech-recognition permission
>    the first time. Swiping while holding chooses what happens on release
>    (insert, send, cancel, or convert to a shell command).
>
> No account is required and none exists — the app has no sign-up, no login and
> no server-side user record. There is nothing to purchase.
>
> The host above is a disposable virtual machine created for this review.

---

## 5. External services used

> - **Apple Speech framework (on-device)** — the default speech engine. Audio
>   does not leave the device in the shipping default configuration.
> - **bentoai.dev** (our own Cloudflare Worker) — used only for the optional
>   cloud features below, so that they work without the user holding an API key.
>   It forwards requests and stores neither audio nor transcripts.
> - **OpenAI API** (`gpt-4o-mini`, chat completions) — converts a dictated
>   sentence into a shell command, on request, when the user swipes to that
>   action while dictating. Reached through our relay, or directly if the user
>   supplies their own key.
> - **Alibaba Cloud DashScope** (`qwen3-asr-flash`) — an optional alternative
>   speech engine the user can select in Settings, for better Chinese and
>   mixed-language recognition. Not the default.
> - **The user's own SSH server** — the app's core function. We operate no part
>   of it and it is chosen entirely by the user.
>
> There are no third-party analytics, advertising or attribution SDKs. Usage
> counters are first-party and anonymous (event names only — never terminal
> content, commands, transcripts, paths or hostnames), off by default, and
> controlled by a single switch in Settings → Privacy.

---

## 6. Regional differences

> None. The app has the same features and the same content everywhere, contains
> no region-locked or licensed content, and applies no geographic restriction.
> Everything the user sees comes from the computer they connect to.

---

## 7. Regulated industries and third-party material

> The app is not in a regulated industry and carries no protected third-party
> material. It is a developer tool that displays output from the user's own
> computer.
>
> Its third-party components are open-source and acknowledged in the app
> (Settings → Privacy → Acknowledgements): the terminal renderer (libghostty,
> MIT), the SSH stack (SwiftNIO SSH and swift-crypto, Apache 2.0), and the
> bundled monospace typeface (Maple Mono, SIL Open Font License). Encryption is
> limited to standard SSH and TLS from those libraries; export compliance is
> declared accordingly in the build
> (`ITSAppUsesNonExemptEncryption = true`).

---

## Worth fixing before the next round

Apple's "prevent common issues" section flags 5.1.1 purpose strings, and ours
are thin — they name the capability without explaining the use or giving an
example:

- current: *"Bento needs microphone access for voice input to terminal."*
- better: *"BentoTerm records audio only while you hold the microphone button,
  to turn what you say into text or a shell command in your terminal session —
  for example, saying 'run the tests' types that into the pane."*

Same for the speech-recognition string. Changing them means a new build, so it
is only worth doing if a new build is going up anyway.
