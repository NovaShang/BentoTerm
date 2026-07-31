# Path Preview (tap/⌘click a file path → quick preview)

Terminal output is full of file paths. This feature recognizes them and lets
you peek at the file without leaving the session — on iOS (tap → chip →
sheet) and macOS (⌘hover underline → ⌘click panel, also on the right-click
menu). Works across local and SSH panes, inside and outside tmux.

## Architecture

Detection is **entirely client-side** (transport-independence rule: the
transport stays dumb plumbing). Fetch is a per-transport "dumb pipe":

| Pane | Fetch path |
|---|---|
| macOS (all panes on this base) | `LocalFileSource` — direct FileManager |
| iOS direct SSH | `CitadelSFTPFileSource` — SFTP subsystem channel on the existing Citadel connection (any sshd serves it) |

### Detection pipeline (bento-terminal-core)

1. `PathDetector` (PathDetection.swift) — pure regex/token scan of one
   logical line: absolute `/…`, `~/…`, `./…`/`../…`, quoted paths with
   spaces, bare relatives (`src/main.rs`, `README.md`), `:line[:col]`
   suffixes, trailing-punctuation stripping, URL exclusion. Bare relatives
   are `explicit == false` → callers stat-verify before showing UI.
2. `PathHitTester` — maps a tap in **visual-row space** to the logical line
   + cell offset, using the same `ceil(displayCells/cols)` wrap math
   TurnNavigator validated on device (`read_text(SCREEN)` returns logical
   lines; SCROLLBAR offset/total are visual rows).
3. `SurfacePathHitEngine` — per-surface façade: point → cell → candidate +
   highlight rects, with a short-lived snapshot cache for ⌘hover storms.

Wrap width: tmux panes use `pane.width` (host passes it via `pathWrapCols`);
plain panes use ghostty's grid columns.

### cwd resolution (relative paths)

- tmux pane: `display-message -p #{pane_current_path}` at tap time
  (`PaneViewModel.currentWorkingDirectory()`) — rides the control channel,
  never stale, any transport.
- non-tmux: the surface's OSC 7 report (`GHOSTTY_ACTION_PWD`, now handled in
  GhosttyRuntime → `surface.reportedPwd`). Remote shells without shell
  integration don't emit it → only absolute/`~` paths resolve there.

## UX

- **iOS**: tap on a path → floating chip (filename ›) above the finger +
  brief underline highlight; tap the chip → sheet (`.medium`/`.large`
  detents) with header (name · path · size · mtime · host), mono text /
  image / binary / directory body, Copy Path. Bare relatives only show the
  chip after a successful stat (no phantom chips), guarded by a tap serial.
  Chip auto-dismisses in 4 s and hides on scroll.
- **macOS**: ⌘hover underlines the token (accent wash + underline,
  `PathHighlightView`); ⌘click opens a floating panel (Esc closes, Copy
  Path / Reveal in Finder / Open for local); right-click menu gains
  "Preview …" / "Copy Path" when the click lands on a path.

## Limits & flags

- Text preview: first 256 KB (truncation banner). Images: ≤ 20 MB. Binary
  (NUL in head) and directories: info card only.
- Feature flag `path_preview_enabled` (default ON), iOS Settings → "Tap to
  Preview Files". Checked in `SurfacePathHitEngine` so both platforms obey.

## Files

- Core: `PathDetection.swift`, `SurfacePathHitEngine.swift`,
  `FilePreviewCore.swift`, `FilePreviewPanel_macOS.swift`, surface edits in
  `GhosttyTerminalSurface(.swift|_macOS.swift)`, `GhosttyRuntime.swift`
  (PWD action), `PaneViewModel.currentWorkingDirectory()`.
- iOS app: `Services/FilePreviewSources.swift`, `Views/Terminal/
  PathPreviewUI.swift`, wiring in `TerminalContainerVC` +
  `TerminalWrapperView`, `SSHService.filePreviewSource()`.

## Known gaps / follow-ups

- `:line` is parsed and shown in the header but there's no "open in editor
  at line" action yet.
- No syntax highlighting (deliberate: no new dependency in v1).
- Directory tap shows an info card; a listing view is a v2 candidate.
- macOS ssh-subprocess panes (quick-connect, not on this base yet) have no
  fetch path — wire a `ControlMaster`-backed source when that lands.
- End-to-end validation on a real device pending (unit tests cover
  detection + wrap math).
