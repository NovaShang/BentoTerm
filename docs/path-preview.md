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
- **Quick Look tier** (`QuickLookRouting`): anything the system renders
  better than we do — PDF, Office/iWork, RTF, EPUB, video, audio, RAW/PSD,
  fonts, USDZ, archives — goes to `QLPreviewView` (macOS) /
  `QLPreviewController` (iOS) instead of the binary card. Text, code and
  Markdown deliberately stay on our web renderer, which has highlighting, a
  gutter and `path:42` jump that Quick Look's plain-text view lacks; `.ts`
  and `.bin` are pinned ours because their system UTIs are a video and an
  archive. Routing is extension-only, decided *before* any read, so a 40 MB
  PDF is never head-read first.
- Quick Look needs a real file, so a **remote** file downloads first via
  `FileFetch` (ranged/chunked over SFTP): > 25 MB asks first, 2 GB refused,
  progress + cancel, complete-or-nothing (writes to a hidden name, renamed
  only when the byte count matches the stat), cached 6 h per host+path+size+
  mtime. The same path backs the **Share** button, which is offered for every
  resolved file — including ones no preview could draw — and never exports
  the preview's capped head read.
- Feature flag `path_preview_enabled` (default ON), iOS Settings → "Tap to
  Preview Files". Checked in `SurfacePathHitEngine` so both platforms obey.

## Files

- Core: `PathDetection.swift`, `SurfacePathHitEngine.swift`,
  `FilePreviewCore.swift`, `QuickLookRouting.swift` (what leaves our
  renderer), `QuickLookPreview.swift` (the embedded system view + fetch
  gate), `FileFetch.swift` (remote → complete local copy),
  `FileShareButton.swift`, `FilePreviewPanel_macOS.swift`, surface edits in
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
