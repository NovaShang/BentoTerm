import Foundation
import GhosttyKit
import os
import BentoFoundationKit

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif
#if canImport(Carbon)
import Carbon
#endif

public extension Notification.Name {
    /// Posted (object = the surface view) when libghostty reports the
    /// background color it is actually rendering — the window chrome
    /// listens so the titlebar band always wears the terminal's true color.
    static let ghosttySurfaceBackgroundChanged =
        Notification.Name("bento.ghosttySurfaceBackgroundChanged")
}

/// Process-wide libghostty runtime. `ghostty_init` and the `ghostty_app` are
/// global singletons; every surface is created against this one app. Mirrors
/// the lifecycle Ghostty's own apprt uses (init → config → app_new → tick loop).
@MainActor
public final class GhosttyRuntime {
    public static let shared = GhosttyRuntime()

    public private(set) var app: ghostty_app_t?
    private let baseConfig: ghostty_config_t?
    private var tickTimer: Timer?

    /// The surface that should answer the next clipboard-read (paste) request.
    /// Set by a surface immediately before it triggers ghostty's paste action,
    /// so the app-level `read_clipboard_cb` knows which surface to complete the
    /// request on. (Paste runs the request synchronously, so this is unambiguous.)
    /// A platform-neutral `ghostty_surface_t` keeps this shared runtime free of
    /// any AppKit/UIKit surface type. nil → `read_clipboard_cb` declines.
    public var pasteSurface: ghostty_surface_t?

    /// Wired by the macOS app: invalidate the surface's cached input-source
    /// layout. The runtime keeps the AppKit keyboard-layout observer (below)
    /// but the surface class now lives in the app target — this closure is the
    /// seam (see `GhosttySurfaceUserdata` for the same pattern in action
    /// routing).
    public static var invalidateInputSourceCache: @MainActor () -> Void = {}

    /// When set, the next clipboard-read (paste) request is answered with THIS
    /// text instead of the system pasteboard, then cleared. Lets scroll-review-
    /// compose inject a committed draft through ghostty's paste pipeline (so it
    /// gets bracketed-paste wrapping) without clobbering the user's clipboard.
    public var pendingPasteText: String?

    private init() {
        ComposeDebug.reset()
        ComposeDebug.log("runtime init")
        guard ghostty_init(0, nil) == GHOSTTY_SUCCESS else {
            assertionFailure("ghostty_init failed")
            self.baseConfig = nil
            return
        }

        #if canImport(AppKit) || canImport(UIKit)
        // The prebuilt GhosttyKit has no palette-setter API, so terminal colors
        // are set via a config file: point ghostty at a Bento-private XDG dir and
        // write the active theme's palette there (verified to recolor cells).
        // `load_default_files` below picks it up; theme changes rewrite + reload.
        GhosttyRuntime.writeColorConfig(theme: ThemeStore.shared.current)
        #endif

        let config = ghostty_config_new()
        ghostty_config_load_default_files(config)
        ghostty_config_finalize(config)
        GhosttyRuntime.logConfigDiagnostics(config)
        // Held for the process lifetime (effectiveBackgroundRGB reads it), so
        // unlike reapplyColors' temporary this one is deliberately never freed.
        self.baseConfig = config

        var runtime = ghostty_runtime_config_s(
            userdata: nil,
            supports_selection_clipboard: false,
            wakeup_cb: { _ in GhosttyRuntime.handleWakeup() },
            action_cb: { app, target, action in GhosttyRuntime.handleAction(app, target, action) },
            read_clipboard_cb: { _, _, state in GhosttyRuntime.handleReadClipboard(state) },
            confirm_read_clipboard_cb: { _, _, _, _ in },
            write_clipboard_cb: { _, _, _, _, _ in },
            write_to_host_cb: { userdata, bytes, count in
                GhosttyRuntime.handleWriteToHost(userdata, bytes, count)
            },
            close_surface_cb: { _, _ in }
        )

        self.app = ghostty_app_new(&runtime, config)
        // ghostty only renders/ticks surfaces of a focused app. Without this the
        // surface stays blank (notably on macOS).
        if let app { ghostty_app_set_focus(app, true) }
        startTickLoop()

        #if canImport(AppKit) || canImport(UIKit)
        // Re-apply the palette live when the user picks a different theme.
        for name in [Notification.Name.terminalThemeChanged, .terminalFontChanged] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in GhosttyRuntime.shared.reapplyColors() }
            }
        }
        #endif

        // ghostty builds its keycode→character translation table from the ACTIVE
        // keyboard layout and caches it. Switching input source (US → Dvorak,
        // ABC → Pinyin, …) invalidates that table, and nothing tells the engine —
        // so keys keep translating through the layout that was live at launch.
        // This is the only way to invalidate it.
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        NotificationCenter.default.addObserver(
            forName: NSTextInputContext.keyboardSelectionDidChangeNotification,
            object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                // The surface caches whether the active source is a plain layout
                // (it decides whether a keystroke may skip the IME); that answer
                // just changed. The surface class lives in the app target now,
                // so the app wires this closure (GhosttySurfaceUserdata exists
                // for exactly this decoupling).
                GhosttyRuntime.invalidateInputSourceCache()
                guard let app = GhosttyRuntime.shared.app else { return }
                ghostty_app_keyboard_changed(app)
            }
        }
        #elseif canImport(UIKit)
        NotificationCenter.default.addObserver(
            forName: UITextInputMode.currentInputModeDidChangeNotification,
            object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                guard let app = GhosttyRuntime.shared.app else { return }
                ghostty_app_keyboard_changed(app)
            }
        }
        #endif
    }

    deinit {
        tickTimer?.invalidate()
    }

    #if canImport(AppKit) || canImport(UIKit)
    /// Write the theme's palette into a private XDG ghostty config and point
    /// ghostty at it via `XDG_CONFIG_HOME`. (No palette-setter API in the
    /// prebuilt binary, so a config file is the only route to custom colors.)
    /// The "system" theme writes no colors → ghostty uses its built-in defaults.
    private static func writeColorConfig(theme: TerminalColorTheme) {
        let fm = FileManager.default
        guard let appSup = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let xdg = appSup.appendingPathComponent("Bento/xdg", isDirectory: true)
        let ghosttyDir = xdg.appendingPathComponent("ghostty", isDirectory: true)
        try? fm.createDirectory(at: ghosttyDir, withIntermediateDirectories: true)

        var lines: [String] = []
        // Zero the terminal padding so a surface sized to exactly N×cell renders
        // an N-cell grid. ghostty computes its grid as floor((px − padding)/cell);
        // with the default padding the floor drops one cell in each axis, which
        // (in the macOS native tiled layout) made every pane 1 row short and 1
        // column narrow than tmux assigned — the cursor sat a row low and TUIs
        // wrapped wrong. With padding 0 the grid matches the tmux pane exactly.
        lines.append("window-padding-x = 0")
        lines.append("window-padding-y = 0")
        lines.append("window-padding-balance = false")
        if theme.id != TerminalColorTheme.systemID {
            lines.append(String(format: "background = %06X", theme.bg))
            lines.append(String(format: "foreground = %06X", theme.fg))
            lines.append(String(format: "cursor-color = %06X", theme.cursor))
            for (i, c) in theme.ansi.prefix(16).enumerated() {
                lines.append(String(format: "palette = %d=#%06X", i, c))
            }
        }
        // Font family is app-wide (no per-surface family field); font SIZE stays
        // per-surface (cfg.font_size). nil token → ghostty's default font.
        if let family = ThemeStore.shared.ghosttyFontFamily {
            lines.append("font-family = \(family)")
        }
        let content = lines.joined(separator: "\n") + "\n"
        try? content.write(to: ghosttyDir.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        setenv("XDG_CONFIG_HOME", xdg.path, 1)
    }

    /// Rewrite the color config for the current theme and push it to the running
    /// app so open surfaces recolor live (no relaunch).
    private func reapplyColors() {
        guard let app else { return }
        GhosttyRuntime.writeColorConfig(theme: ThemeStore.shared.current)
        let cfg = ghostty_config_new()
        ghostty_config_load_default_files(cfg)
        // ghostty_app_update_config propagates this config to every LIVE
        // surface, but the user's font size exists only in each surface's
        // creation config (cfg.font_size) — the XDG file doesn't carry it. An
        // update without it resets every open terminal to ghostty's default
        // size, desyncing the ghostty grid from tmux (TUIs misrender). iOS hit
        // this on EVERY app switch: backgrounding renders both light/dark
        // app-switcher snapshots, and that trait flip posts terminalThemeChanged
        // in follow-system mode.
        let size = ThemeStore.shared.fontSize
        if size > 0 { ghostty_config_set_font_size(cfg, Float(size)) }
        ghostty_config_finalize(cfg)
        GhosttyRuntime.logConfigDiagnostics(cfg)
        // App-level light/dark, so config values that resolve per-scheme pick the
        // right side. Per-surface reporting (what programs inside the terminal
        // actually query) is `syncColorScheme` on each surface.
        ghostty_app_set_color_scheme(
            app,
            ThemeStore.shared.current.isDark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
        ghostty_app_update_config(app, cfg)
        // `ghostty_app_update_config` takes `*const Config` — it clones what it
        // needs and never takes ownership, so this one is ours to release. It
        // used to leak a whole config on every theme/font change (and follow-
        // system mode fires that on every app-switch appearance flip).
        ghostty_config_free(cfg)
    }

    #endif

    /// Surface parse errors in the config we GENERATE ourselves (writeColorConfig).
    /// ghostty silently ignores bad lines, so a malformed palette entry would just
    /// quietly not apply.
    private static func logConfigDiagnostics(_ cfg: ghostty_config_t?) {
        guard let cfg else { return }
        let count = ghostty_config_diagnostics_count(cfg)
        guard count > 0 else { return }
        for i in 0..<count {
            let d = ghostty_config_get_diagnostic(cfg, i)
            let msg = d.message.map { String(cString: $0) } ?? "(no message)"
            Logger(subsystem: "com.novashang.bento", category: "ghostty")
                .error("config diagnostic: \(msg, privacy: .public)")
        }
    }

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    /// ghostty's EFFECTIVE background color (r,g,b, 0–255) from the finalized base
    /// config — including ghostty's built-in default when the active theme writes
    /// no explicit `background` (the dark "System" theme). Chrome beside the
    /// terminal reads this so it fuses with what ghostty actually renders.
    public func effectiveBackgroundRGB() -> (r: UInt8, g: UInt8, b: UInt8)? {
        guard let baseConfig else { return nil }
        var color = ghostty_config_color_s()
        let key = "background"
        let ok = key.withCString {
            ghostty_config_get(baseConfig, &color, $0, UInt(key.utf8.count))
        }
        return ok ? (color.r, color.g, color.b) : nil
    }

    private func startTickLoop() {
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
            // The timer fires on the main run loop, so tick synchronously instead
            // of hopping through a per-frame Task{@MainActor}. Under profiling that
            // per-frame Task.init churn sat on the main thread and starved keystroke
            // (IMK/TSM) handling — visible as input stutter.
            MainActor.assumeIsolated { GhosttyRuntime.shared.tick() }
        }
        // This is only a backstop (wakeup_cb drives the latency-sensitive ticks),
        // so let the OS coalesce it with other timers instead of waking the CPU
        // on an exact 16.7ms cadence.
        tickTimer?.tolerance = 1.0 / 60.0
    }

    // MARK: - C callbacks (non-capturing)

    /// Coalesces libghostty wakeups. `wakeup_cb` can fire from any thread and
    /// very frequently under output; the old `Task{@MainActor}`-per-wakeup flooded
    /// the main actor and added keystroke latency. We collapse a burst into a
    /// single main-thread tick (the 60fps timer is the backstop, so a dropped
    /// wakeup is at most one frame late).
    nonisolated(unsafe) private static let wakeupScheduled =
        OSAllocatedUnfairLock(initialState: false)

    private static func handleWakeup() {
        let shouldSchedule = wakeupScheduled.withLock { scheduled -> Bool in
            if scheduled { return false }
            scheduled = true
            return true
        }
        guard shouldSchedule else { return }
        DispatchQueue.main.async {
            wakeupScheduled.withLock { $0 = false }
            GhosttyRuntime.shared.tick()
        }
    }

    /// Open a clicked terminal link in the user's default app. Restricted to
    /// web/mail schemes so terminal output can't auto-launch `file://` or custom
    /// app schemes by emitting a crafted "link".
    /// Open a URL in the system browser/handler, gated to safe schemes.
    /// Internal so the surfaces' link-activation paths (iOS tap probe, macOS
    /// ⌘-click) share the one allowlist with the OPEN_URL action.
    public static func openExternalURL(_ string: String) {
        guard let url = URL(string: string),
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto", "ftp", "ftps"].contains(scheme) else { return }
        DispatchQueue.main.async {
            #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            NSWorkspace.shared.open(url)
            #elseif canImport(UIKit)
            UIApplication.shared.open(url)
            #endif
        }
    }

    /// Terminal bell (BEL / OSC). Audible system beep.
    private static func ringBell() {
        DispatchQueue.main.async {
            #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            NSSound.beep()
            #endif
        }
    }

    /// OSC 9 / 777 desktop notification from the running program.
    private static func postDesktopNotification(title: String, body: String) {
        guard !title.isEmpty || !body.isEmpty else { return }
        #if canImport(UserNotifications)
        DispatchQueue.main.async {
            let content = UNMutableNotificationContent()
            content.title = title.isEmpty ? "Bento" : title
            content.body = body
            let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(req)
        }
        #endif
    }

    #if canImport(Carbon)
    /// Tracked so EnableSecureEventInput / DisableSecureEventInput stay balanced.
    nonisolated(unsafe) private static var secureInputEnabled = false
    #endif

    /// Password-entry secure input: blocks other processes from reading keystrokes.
    private static func setSecureInput(_ mode: ghostty_action_secure_input_e) {
        #if canImport(Carbon)
        DispatchQueue.main.async {
            let want: Bool
            switch mode {
            case GHOSTTY_SECURE_INPUT_ON: want = true
            case GHOSTTY_SECURE_INPUT_OFF: want = false
            default: want = !secureInputEnabled   // TOGGLE
            }
            guard want != secureInputEnabled else { return }
            secureInputEnabled = want
            if want { EnableSecureEventInput() } else { DisableSecureEventInput() }
        }
        #endif
    }

    /// libghostty apprt action dispatch. Invoked during `ghostty_app_tick` (main
    /// thread). We currently only consume SCROLLBAR to learn each surface's
    /// scroll position (offset within scrollback) for the scroll-review-compose
    /// feature; everything else is a no-op. Always returns true to match the
    /// previous stub (the app worked with every action "handled").
    private static func handleAction(
        _ app: ghostty_app_t?,
        _ target: ghostty_target_s,
        _ action: ghostty_action_s
    ) -> Bool {
        // App-level effects (no surface needed). The core delegates these to the
        // apprt; unhandled = silently swallowed (which is how click-to-open links,
        // the bell, the cursor shape, etc. were all dead before this).
        switch action.tag {
        case GHOSTTY_ACTION_OPEN_URL:
            let ou = action.action.open_url
            if let cstr = ou.url, ou.len > 0,
               let s = String(bytes: UnsafeRawBufferPointer(start: cstr, count: Int(ou.len)), encoding: .utf8) {
                openExternalURL(s)
            }
            return true
        case GHOSTTY_ACTION_RING_BELL:
            ringBell()
            return true
        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            // Copy the C strings synchronously (they don't outlive the callback).
            let dn = action.action.desktop_notification
            let title = dn.title.map { String(cString: $0) } ?? ""
            let body = dn.body.map { String(cString: $0) } ?? ""
            postDesktopNotification(title: title, body: body)
            return true
        case GHOSTTY_ACTION_SECURE_INPUT:
            setSecureInput(action.action.secure_input)
            return true
        case GHOSTTY_ACTION_RENDER:
            // ghostty's per-surface dirty signal. The prebuilt libghostty we link
            // doesn't actually emit it (verified — it's pull-model, expecting the
            // apprt to draw on its own vsync), so the surface's display link uses a
            // low idle-rate fallback for cursor blink. Honor RENDER anyway in case
            // a future build emits it — marking dirty is cheap and thread-safe.
            if target.tag == GHOSTTY_TARGET_SURFACE,
               let surface = target.target.surface,
               let userdata = ghostty_surface_userdata(surface) {
                (Unmanaged<AnyObject>.fromOpaque(userdata).takeUnretainedValue()
                    as! any GhosttySurfaceUserdata).setNeedsDraw()
            }
            return true
        case GHOSTTY_ACTION_SCROLLBAR, GHOSTTY_ACTION_MOUSE_SHAPE,
             GHOSTTY_ACTION_MOUSE_OVER_LINK, GHOSTTY_ACTION_MOUSE_VISIBILITY,
             GHOSTTY_ACTION_COLOR_CHANGE, GHOSTTY_ACTION_PWD,
             GHOSTTY_ACTION_START_SEARCH, GHOSTTY_ACTION_END_SEARCH,
             GHOSTTY_ACTION_SEARCH_TOTAL, GHOSTTY_ACTION_SEARCH_SELECTED,
             GHOSTTY_ACTION_RENDERER_HEALTH:
            routeToSurface(target, action)
            return true
        case GHOSTTY_ACTION_SET_TITLE:
            // DELIBERATELY IGNORED. A tmux pane's title has exactly one owner —
            // tmux's own `pane_title`, which is what the pane chrome renders and
            // what the state pipeline classifies on. Honoring the engine's OSC
            // 0/2 title here would give the same label two sources that disagree
            // (tmux rewrites titles on its own schedule), and the pane header
            // would flicker between them. Non-tmux surfaces are the only place
            // this would be the honest source, and they don't show a title today.
            return true
        default:
            return true
        }
    }

    /// Deliver a per-surface action to the owning view. Runs synchronously on the
    /// caller (main) thread so any pointers in `action` are still valid.
    private static func routeToSurface(_ target: ghostty_target_s, _ action: ghostty_action_s) {
        guard target.tag == GHOSTTY_TARGET_SURFACE,
              let surface = target.target.surface,
              let userdata = ghostty_surface_userdata(surface) else { return }
        MainActor.assumeIsolated {
            let view = Unmanaged<AnyObject>.fromOpaque(userdata).takeUnretainedValue() as! any GhosttySurfaceUserdata
            switch action.tag {
            case GHOSTTY_ACTION_SCROLLBAR:
                let sb = action.action.scrollbar
                view.handleScrollbar(total: sb.total, offset: sb.offset, len: sb.len)
            case GHOSTTY_ACTION_MOUSE_SHAPE:
                view.handleMouseShape(action.action.mouse_shape)
            case GHOSTTY_ACTION_MOUSE_OVER_LINK:
                let l = action.action.mouse_over_link
                let url: String? = (l.url != nil && l.len > 0)
                    ? String(bytes: UnsafeRawBufferPointer(start: l.url!, count: Int(l.len)), encoding: .utf8)
                    : nil
                view.handleMouseOverLink(url)
            case GHOSTTY_ACTION_MOUSE_VISIBILITY:
                view.handleMouseVisibility(action.action.mouse_visibility == GHOSTTY_MOUSE_VISIBLE)
            case GHOSTTY_ACTION_COLOR_CHANGE:
                // The engine reporting an ACTUALLY-rendered color (initial theme
                // resolution, config reload, or a runtime OSC 10/11/12) — the
                // only honest source for chrome that must match the terminal.
                let c = action.action.color_change
                view.handleColorChange(kind: c.kind, red: c.r, green: c.g, blue: c.b)
            case GHOSTTY_ACTION_PWD:
                // OSC 7 working-directory report (shell integration). Stashed on
                // the surface so path-preview can resolve relative paths in
                // non-tmux panes.
                view.handlePwd(action.action.pwd.pwd.map { String(cString: $0) })
            case GHOSTTY_ACTION_START_SEARCH:
                // The ENGINE asking us to open the find bar (its own search
                // keybind fired). `needle` is a prefill, typically the selection.
                let needle = action.action.start_search.needle.map { String(cString: $0) }
                view.handleStartSearch(needle: needle)
            case GHOSTTY_ACTION_END_SEARCH:
                view.handleEndSearch()
            case GHOSTTY_ACTION_SEARCH_TOTAL:
                // -1 = "none" on the wire for both counts (see apprt.action).
                let t = action.action.search_total.total
                view.handleSearchTotal(t < 0 ? nil : Int(t))
            case GHOSTTY_ACTION_SEARCH_SELECTED:
                let s = action.action.search_selected.selected
                view.handleSearchSelected(s < 0 ? nil : Int(s))
            case GHOSTTY_ACTION_RENDERER_HEALTH:
                view.handleRendererHealth(
                    healthy: action.action.renderer_health == GHOSTTY_RENDERER_HEALTH_OK)
            default:
                break
            }
        }
    }

    /// ghostty asks the apprt for clipboard content during a paste action (and
    /// for OSC 52 reads). Answer with the system pasteboard and complete the
    /// request on the surface that initiated it — ghostty then inserts the text
    /// through its paste pipeline, applying bracketed-paste wrapping when the
    /// focused app has enabled it (so multi-line pastes don't fire Enter per
    /// line). Returns false when no surface opted in (e.g. iOS, which pastes via
    /// `ghostty_surface_text` directly and never triggers this).
    private static func handleReadClipboard(_ state: UnsafeMutableRawPointer?) -> Bool {
        MainActor.assumeIsolated {
            guard let surface = shared.pasteSurface else { return false }
            // A queued draft injection (scroll-review-compose) takes precedence
            // over the system pasteboard, and is one-shot.
            let text: String
            if let pending = shared.pendingPasteText {
                text = pending
                shared.pendingPasteText = nil
            } else {
                text = TerminalClipboard.read() ?? ""
            }
            text.withCString { ptr in
                ghostty_surface_complete_clipboard_request(surface, ptr, state, true)
            }
            return true
        }
    }

    private static func handleWriteToHost(
        _ userdata: UnsafeMutableRawPointer?,
        _ bytes: UnsafePointer<UInt8>?,
        _ count: Int
    ) {
        guard let userdata, let bytes, count > 0 else { return }
        let data = Data(bytes: bytes, count: count)
        // Resolve the surface NOW — ghostty guarantees it's alive for the
        // duration of this callback. Capturing the strong reference holds it
        // across the main-actor hop, so a concurrent teardown can't free it
        // before the block runs. (Previously the pointer was resolved INSIDE
        // the async block; if the surface was torn down in between,
        // takeUnretainedValue ran on a freed object → objc_retain crash.)
        let surface = Unmanaged<AnyObject>.fromOpaque(userdata).takeUnretainedValue() as! any GhosttySurfaceUserdata
        DispatchQueue.main.async {
            surface.handleHostWrite(data)
        }
    }
}
