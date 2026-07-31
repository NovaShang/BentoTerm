# Telemetry

> **Status: the sink described below no longer exists.** The Cloudflare Worker
> relay (`relay/`) was deleted when Bento shrank to a plain-SSH tool, and it
> was the only endpoint client batches were ever POSTed to. Everything from
> "How it works" down describes that removed component. The client-side
> consent model and the closed event enum are the parts still worth keeping if
> telemetry is ever re-homed. Do not treat this as current architecture.

Bento's telemetry is designed to be consistent with the product's privacy
posture (no accounts, E2E-encrypted terminal traffic, nothing readable stored
server-side): **no third-party SDK, a collection surface small enough to
publish in full, events routed through the user's own trusted relay, and
default OFF behind an explicit consent toggle.**

## What is collected (the complete list)

Only bare event names from a closed enum, each with a Unix timestamp. There
are no associated payloads and no free-form strings — the relay rejects any
name not on this exact allowlist.

| Event | Fires when |
|---|---|
| `first_run_started` | macOS onboarding wizard opened (once) |
| `first_run_completed` | wizard finished via the last step (once) |
| `first_run_skipped` | wizard skipped from the welcome step (once) |
| `agent_wizard_launched` | New-agent-session wizard opened |
| `workspace_created` | an agent workspace was launched |
| `pairing_succeeded` | iPhone↔Mac pairing completed |
| `voice_send` | a voice utterance was sent to a pane |
| `voice_first_send` | the first-ever voice send (once) |
| `voice_swipe_left_llm` | voice + left-swipe (NL→shell command) |
| `voice_swipe_right_preview` | voice + right-swipe (preview/edit) |
| `second_agent_opened` | two agents first worked in parallel (once) |
| `mode_toggled` | the Parallel/Focus mode switch was first used |
| `state_awaiting_first_seen` | a pane first hit awaiting-input (once) |
| `reconnect_resumed` | a session resumed after a disconnect (first time) |
| `ssh_direct_connected` | a plain (non-relay) SSH connection succeeded |
| `app_active_day` | app became active — at most once per calendar day |

The enum lives in
`bento-terminal-core/Sources/BentoTerminalCore/Telemetry.swift`
(`TelemetryEvent`); the server-side mirror allowlist is
`relay/src/telemetry.ts` (`CLIENT_EVENTS`). The Settings consent UI renders
the list from the enum, so what users see is by construction what is sent.

## What is never collected

Terminal content, commands, transcripts, audio, file paths, hostnames,
usernames, IP addresses (not stored), SSH keys or fingerprints, session or
window names, or any content-derived value. Events carry no parameters, so
there is nowhere for such data to hide.

## Transport and storage

- Client batches are POSTed to `<relay>/v1/telemetry` — the **same Bento
  relay** the terminal traffic already trusts (a custom relay URL is honored).
  No third-party analytics SDK is linked into the apps.
- The relay writes each event as a data point into a **Cloudflare Workers
  Analytics Engine** dataset (`bento_telemetry`) — aggregate counters, queried
  with SQL, with Analytics Engine's built-in retention (~3 months). If the
  dataset binding is absent, all writes are no-ops.
- Sends are fire-and-forget: batches flush at ~20 events or on
  app-background/termination, and failures are dropped (never retried in a
  loop, never logged).
- The endpoint is strictly validated (UUID `install_id`, closed platform set,
  event-name allowlist, ≤50 events, ≤16 KB body) and per-IP rate-limited.

The relay additionally aggregates a few **server-side counters for requests
it already inherently serves** (daemon register/connect, pairing
success/failure, ASR mint/socket/batch calls, per engine). These involve no
client-side collection, store a hash of the daemon id rather than the id,
and never store IPs or content.

## Consent and `install_id` semantics

- **Default OFF.** Nothing is buffered, stored, or sent until the user turns
  on "Share anonymous usage statistics" (iOS Settings → Privacy; macOS
  Settings → General → Privacy; also offered, unchecked, on the last step of
  the macOS onboarding wizard).
- `install_id` is a **random UUID**, generated lazily after opt-in. It is not
  derived from any hardware, account, or network identifier and cannot be
  linked to one.
- Turning the toggle **OFF deletes** the `install_id`, the one-shot dedupe
  ledger, and any buffered events — an opted-out install holds no telemetry
  identifier at rest. Re-opting-in mints a fresh, unrelated UUID.

## App Store privacy label

With telemetry available (opt-in):

- **Identifiers** → "Other user ID" (the random `install_id`) — collected,
  **Data Not Linked to You**, not used for tracking.
- **Usage Data → Product Interaction** — collected, **Data Not Linked to
  You**, not used for tracking.
- **Tracking: No** (no cross-app/cross-site tracking, no ad networks, no
  data brokers).

## Deploy note

`wrangler.toml` declares the `TELEMETRY` Analytics Engine dataset binding and
the `RL_TELEMETRY` rate limit. Analytics Engine must be enabled on the
Cloudflare account for the binding to deploy; the dataset itself is created
implicitly on first write. All writes are guarded, so the relay behaves
identically if the binding is removed.
