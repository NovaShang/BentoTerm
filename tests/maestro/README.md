# iOS self-debug loop (simulator)

The loop that lets Claude validate iOS fixes **without the user retesting each round**.
Driver script: [`scripts/ios-dev.sh`](../../scripts/ios-dev.sh).

## Why it works

Host setup is done **once by the user**. `simctl install` over the same bundle id
preserves the app's data container (`Documents/`, `Preferences/`), so the saved SSH
host survives every rebuild. → rebuild / reinstall / relaunch freely; the app
reconnects on its own. (The data-container *UUID* can change on reinstall; the driver
re-resolves it every call, so that's transparent.)

## The loop

```sh
scripts/ios-dev.sh doctor         # sim + install + host + log state
scripts/ios-dev.sh run            # build (Debug, incremental ~40s) + install + relaunch
scripts/ios-dev.sh shot           # screenshot → /tmp/bento_shot.png   (Read it)
scripts/ios-dev.sh log [N]        # last N debug.log lines, Live-Activity spam filtered
scripts/ios-dev.sh log -f         # follow the log live
scripts/ios-dev.sh oslog [cat]    # stream os_log (subsystem com.novashang.bento)
scripts/ios-dev.sh maestro <flow> # drive the UI
scripts/ios-dev.sh attach [sess]  # Maestro-navigate into a session terminal (default bentotest)
scripts/ios-dev.sh send <cmd…>    # inject a line into the test tmux session (Mac side)
scripts/ios-dev.sh pane           # dump the test tmux pane (rendering ground truth)
```

Observation surfaces:
- **File log** — `dlog()` → `Documents/debug.log`, **truncated on every launch**, so
  after `run` it holds exactly this session. `log` drops the sim-only
  `Failed to start aggregate Live Activity` spam by default (`--all` keeps it).
- **os_log** — `Logger(subsystem: "com.novashang.bento", category: "TerminalVM")`
  and `com.bento.terminalcore`. Stream with `oslog`.
- **Screenshot / Maestro hierarchy** — visual + tappable-element assertions.

## Getting into the terminal

After a cold launch the app lands on the **host list**, not a terminal. Use the
dedicated throwaway session `bentotest` (never `main`):

```sh
# one-time: create bentotest and land in its terminal
scripts/ios-dev.sh maestro tests/maestro/new-session.yaml
# thereafter: reattach after any rebuild
scripts/ios-dev.sh attach            # = maestro attach.yaml, SESSION=bentotest
```

`_peek-sessions.yaml` just screenshots the session picker (read-only).

## Driving the terminal: use tmux, not Maestro keystrokes

The saved host Mac is **this machine**, so `bentotest` is a real local tmux session.
Inject input from the Mac side and observe how the app renders it:

```sh
scripts/ios-dev.sh send 'echo hello'   # tmux send-keys -t bentotest … Enter
scripts/ios-dev.sh shot                # verify the app rendered it
scripts/ios-dev.sh pane                # tmux capture-pane → text ground truth to diff against
```

Prefer this over Maestro `inputText` into the terminal: the terminal is a custom
`UITextInput` with **no software keyboard**, so Maestro keystrokes are swallowed.
(Maestro `inputText` works fine for normal fields like the new-session name.)
`tmux send-keys` is also deterministic — ideal for reproducing render/parse bugs.

## Gotcha: the "Create" button has no accessible text

On the session picker, the green **Create** pill exposes no a11y label, so
`tapOn: "Create"` fails. `new-session.yaml` taps it by position (`point: "91%,42%"`).

## Hard rules

- **Never re-add the host.** The user adds it once; it persists. No Maestro host-setup steps.
- **Never attach to / send to `main`.** That is the user's live working session; the
  driver refuses it. Use the dedicated throwaway `bentotest` (what the user chose);
  `bento` and `voltreality` are the user's own and off-limits for typing.
- Prefer **local Swift scripts** for parser/logic bugs (paste captured bytes from
  `debug.log`, iterate in ms) over UI round-trips — see project memory.

## Stale flows

`full-suite.yaml`, `smoke-test.yaml`, `split-test.yaml`, etc. predate the
SpeakTerm→Bento rename (they reference `com.speakterm.app`). Treat as historical;
`attach.yaml` / `_peek-sessions.yaml` are the current-correct patterns.
