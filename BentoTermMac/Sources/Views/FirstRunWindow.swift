import SwiftUI
import AppKit
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import BentoTerminalCore

/// FirstRunWindow is the macOS onboarding wizard (design doc §4): a five-step
/// environment-preparation flow shown on first launch INSTEAD of dropping the
/// user at an app they haven't set up yet. Its two jobs are the design doc's
/// two: get the environment actually ready (daemon, agent, account), and teach
/// the concepts the user will need (host vs. remote, agents, workspaces).
///
/// Gate: `UserDefaults firstRunCompleted_v1`, forced by BENTO_FORCE_FIRST_RUN=1
/// for testing. Skipping counts as completing (pros hate being taught).
struct FirstRunWindow: View {
    static let completedKey = "firstRunCompleted_v1"

    @EnvironmentObject var bento: BentoCLI
    @Environment(\.dismiss) private var dismiss

    private enum Step: Int { case welcome, checklist, workspace, voice, done }
    /// BENTO_FIRST_RUN_STEP=0…4 jumps straight to a step — walkthrough /
    /// screenshot hook for testing, inert in production.
    @State private var step: Step = ProcessInfo.processInfo
        .environment["BENTO_FIRST_RUN_STEP"]
        .flatMap(Int.init).flatMap(Step.init) ?? .welcome

    // Checklist state. Presets come from the CORE AgentPreset (it carries the
    // install catalog); the app's local AgentPreset remains the wizard's
    // launch picker.
    @State private var daemonOK = false
    @State private var agentPreset: BentoTerminalCore.AgentPreset?
    @State private var checkingAgent = true
    @State private var chosenAgent: BentoTerminalCore.AgentPreset = .claudeCode
    @State private var nodeFound = false
    @State private var copiedInstall = false

    // Workspace state
    @State private var workingDir: String = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Bento Projects/My First Project").path
    @State private var launchError: String?
    @State private var launched = false

    // Voice state
    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @AppStorage("speech_engine") private var speechEngine = "apple"

    // Opt-in telemetry consent (done step). Default OFF, mirrors Settings.
    @ObservedObject private var telemetry = TelemetryService.shared

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(28)
            Divider()
            footer
        }
        .frame(width: 620, height: 700)
        .task {
            TelemetryService.shared.record(.firstRunStarted)
            await refreshChecklist()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: welcome
        case .checklist: checklist
        case .workspace: workspace
        case .voice: voice
        case .done: done
        }
    }

    // MARK: - Step 1 · Welcome + the architecture picture

    private var welcome: some View {
        VStack(spacing: 22) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 84, height: 84)
            VStack(spacing: 8) {
                Text("Welcome to BentoTerm")
                    .font(.system(size: 26, weight: .bold))
                Text("Run a team of AI agents. Speak to them.\nCommand them from anywhere.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            ArchitectureDiagramView(accent: .green)
                .padding(.horizontal, 12)
            Text("This Mac is the host — it runs the tmux server your agents live in. Every device you connect from, including a phone you pair later, is just another tmux client.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 20)
    }

    // MARK: - Step 2 · Environment checklist

    private var checklist: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepHeader("Check this Mac",
                       "Three things make this Mac an agent host. Anything already in place is checked off for you; only what's missing needs a minute.")

            checklistRow(
                ok: daemonOK,
                pending: false,
                title: "BentoTerm background service",
                detail: daemonOK
                    ? "Running — it keeps the connection to your phone alive, in the background, whether or not BentoTerm is open."
                    : "Starting… if this never turns green, click Retry."
            ) {
                if !daemonOK {
                    Button("Retry") { Task { await startDaemonAndRefresh() } }
                }
            }

            checklistRow(
                ok: agentPreset != nil,
                pending: checkingAgent,
                title: "An agent",
                detail: agentDetailText
            ) {
                if agentPreset == nil && !checkingAgent {
                    agentInstaller
                }
            }

            // NOT a checklist row: nothing here can verify that the agent is
            // signed in, and a green check for an unchecked thing is exactly the
            // kind of claim this app is trying to stop making. It's a heads-up
            // about what happens next, so it reads as one.
            if agentPreset != nil {
                Label("First launch, \(agentPreset?.rawValue ?? "the agent") will ask you to sign into its own account — follow the prompts on its screen. That's normal, not an error.",
                      systemImage: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if agentPreset == nil && !checkingAgent {
                Text("No agent yet? You can continue with a plain shell and install one later.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var agentDetailText: String {
        if checkingAgent { return "Looking for installed agents…" }
        if let preset = agentPreset { return "Found \(preset.rawValue) — ready to work." }
        return "None found. Pick one — each installs with its official one-line command, run right here in a Bento terminal so you can watch it work."
    }

    /// The agent chooser + one-command installer (design doc P2 #15, upgraded:
    /// every agent the state engine understands, not just Claude). The command
    /// runs in a VISIBLE native terminal tab — the user sees exactly what the
    /// line they approved does, and the tab drops into a shell afterwards for
    /// the agent's own sign-in flow.
    @ViewBuilder
    private var agentInstaller: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Agent", selection: $chosenAgent) {
                ForEach(BentoTerminalCore.AgentPreset.allCases.filter(\.isInstallableAgent)) { preset in
                    Text(preset == .claudeCode ? "\(preset.rawValue)  (recommended)" : preset.rawValue)
                        .tag(preset)
                }
            }
            .labelsHidden()
            .fixedSize()

            if let install = chosenAgent.install {
                HStack(spacing: 6) {
                    Text(install.command)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(install.command, forType: .string)
                        copiedInstall = true
                        Task { try? await Task.sleep(for: .seconds(1.5)); copiedInstall = false }
                    } label: {
                        Image(systemName: copiedInstall ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                }

                if install.requiresNode && !nodeFound {
                    Label("Needs Node.js, which isn't installed — pick a curl-based agent (like Claude Code), or install Node first.",
                          systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }

                HStack(spacing: 8) {
                    Button("Install in Bento terminal") { runInstall(chosenAgent) }
                        .disabled(install.requiresNode && !nodeFound)
                    Button("Re-check") { Task { await refreshChecklist() } }
                    Button("Docs") {
                        if let url = URL(string: install.docsURL) { NSWorkspace.shared.open(url) }
                    }
                    .buttonStyle(.link)
                }
            }
        }
    }

    /// Run the official installer in a visible plain terminal tab; on success
    /// the tab tells the user to come back and Re-check, then hands them a
    /// login shell (many agents want their sign-in run right after install).
    private func runInstall(_ preset: BentoTerminalCore.AgentPreset) {
        guard let install = preset.install else { return }
        let script = """
        \(install.command); status=$?; echo; \
        if [ $status -eq 0 ]; then \
          echo '✓ \(preset.rawValue) installed — return to Bento setup and click Re-check.'; \
        else \
          echo \"✗ Install failed (exit $status) — see the output above.\"; \
        fi; exec /bin/zsh -l
        """
        BentoTerminalWindow.newCommandWindow(
            command: ["/bin/zsh", "-lc", script],
            title: "Install \(preset.rawValue)"
        )
    }

    // MARK: - Step 3 · First workspace (zero-input)

    private var workspace: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepHeader("Start your first session",
                       "Pick a folder and an agent, and Bento starts a tmux session running it there. The session lives on this Mac — disconnect or walk away and it keeps going, and `tmux ls` will list it.")

            VStack(alignment: .leading, spacing: 8) {
                Text("FOLDER")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text(abbreviatedDir)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Choose…") { pickDirectory() }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
                Text("We'll create this folder if it doesn't exist. Working on a real project? Point it there instead.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            if let launchError {
                Label(launchError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }

            if launched {
                Label("Session started — check the terminal window that just opened.",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            }
        }
    }

    private var abbreviatedDir: String {
        (workingDir as NSString).abbreviatingWithTildeInPath
    }

    // MARK: - Step 4 · First voice command

    private var voice: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepHeader("Talk to your agent",
                       "Voice is the fastest way to give instructions — no window switching, no typing.")

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.green)
                    Text("Bento turns your speech into instructions on this Mac. Audio is used for transcription only — nothing is stored.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                switch micStatus {
                case .authorized:
                    Label("Microphone enabled", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .denied, .restricted:
                    Label("Microphone denied — enable it in System Settings → Privacy → Microphone", systemImage: "xmark.circle")
                        .foregroundStyle(.orange)
                        .font(.callout)
                default:
                    Button("Enable microphone") {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in
                            Task { @MainActor in
                                micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                            }
                        }
                    }
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))

            VStack(alignment: .leading, spacing: 8) {
                Text("Try it in the terminal window:")
                    .font(.system(size: 14, weight: .semibold))
                Label {
                    Text("**Hold right-click** on the terminal and speak. Release to send — slide up to send instantly, down to cancel.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "cursorarrow.click.badge.clock").foregroundStyle(.green)
                }
                Label {
                    Text("First mission idea: *“Build me a snake game as a single web page, then open it in the browser.”*")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "lightbulb").foregroundStyle(.green)
                }
                Label {
                    Text("While it works, the pane's title turns **blue**. **Amber** means it needs your answer. You watch colors, not text.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "circle.hexagongrid.fill").foregroundStyle(.blue)
                }
            }

            if Locale.preferredLanguages.first?.hasPrefix("zh") == true, speechEngine == "apple" {
                HStack(spacing: 10) {
                    Text("说中文?Qwen 引擎对中文和中英混说准得多 — 免费、免配置。")
                        .font(.system(size: 13))
                    Spacer()
                    Button("切换到 Qwen") { speechEngine = "qwen" }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.08)))
            }
        }
    }

    // MARK: - Step 5 · Done + cross-guidance

    private var done: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepHeader("You're set up",
                       "Your session is live. Two ways to level up from here:")

            doneCard(
                symbol: "square.grid.2x2",
                title: "Open a second agent",
                detail: "Agents work in parallel — one writes code while another researches. Each gets its own pane."
            ) {
                Button("New agent session…") { Windows.show(.wizard, env: bento) }
            }

            doneCard(
                symbol: "iphone",
                title: "Put BentoTerm in your pocket",
                detail: "Install BentoTerm on your iPhone or iPad and pair it — then command these same agents from the sofa, or anywhere."
            ) {
                HStack(alignment: .top, spacing: 16) {
                    if let qr = QRCodeImage.make("https://bento.novashang.com/ios", size: 96) {
                        Image(nsImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 96, height: 96)
                            .padding(4)
                            .background(Color.white)
                            .cornerRadius(6)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("1. Scan to get the app\n2. In the app choose “I have a Mac”\n3. Show it the pairing code:")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Button("Show pairing code…") { Windows.show(.pair, env: bento) }
                    }
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "dock.rectangle")
                    .foregroundStyle(.secondary)
                Text("BentoTerm stays in your **Dock**. Close every window — agents keep working in the background, and clicking the Dock icon (or ⌘N) brings your session right back.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 4)

            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: Binding(
                    get: { telemetry.enabled },
                    set: { telemetry.enabled = $0 }
                )) {
                    Text("Share anonymous usage statistics")
                        .font(.system(size: 12))
                }
                .toggleStyle(.checkbox)
                Text("No terminal content, commands, transcripts, paths, or hostnames — ever. Events go through the same Bento relay; no third-party SDKs. Change anytime in Settings.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)
            }
            .padding(.top, 2)
        }
    }

    private func doneCard(symbol: String, title: String, detail: String, @ViewBuilder accessory: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.green)
                    .frame(width: 24)
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
            }
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            accessory()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }

    // MARK: - Footer navigation

    private var footer: some View {
        HStack {
            if step == .welcome {
                Button("I'm a pro — skip the tour") { finish() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            } else if step != .done {
                Button("Back") { withAnimation { step = Step(rawValue: step.rawValue - 1) ?? .welcome } }
            }
            Spacer()
            stepDots
            Spacer()
            primaryButton
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var stepDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<5) { i in
                Circle()
                    .fill(i == step.rawValue ? Color.green : Color.secondary.opacity(0.3))
                    .frame(width: 6, height: 6)
            }
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch step {
        case .welcome:
            Button("Get started") { withAnimation { step = .checklist } }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        case .checklist:
            Button(agentPreset != nil ? "Continue" : "Continue with a plain shell") {
                withAnimation { step = .workspace }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(checkingAgent)
        case .workspace:
            Button(launched ? "Continue" : "Start my first session") {
                if launched {
                    withAnimation { step = .voice }
                } else {
                    Task { await launchFirstWorkspace() }
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        case .voice:
            Button("Continue") { withAnimation { step = .done } }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        case .done:
            Button("Finish") { finish() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func stepHeader(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 22, weight: .bold))
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A satisfied row collapses to one line: the point of a checklist is the
    /// items that still need you, and explaining something already true reads as
    /// being quizzed on it. Anything not yet OK (or still checking) stays open
    /// with its detail and actions.
    private func checklistRow(ok: Bool, pending: Bool, title: String, detail: String, @ViewBuilder actions: () -> some View) -> some View {
        let collapsed = ok && !pending
        return HStack(alignment: collapsed ? .firstTextBaseline : .top, spacing: 12) {
            Group {
                if pending {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18))
                        .foregroundStyle(ok ? .green : .secondary)
                }
            }
            .frame(width: 22, height: collapsed ? nil : 22)
            if collapsed {
                Text(title).font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 8)
                Text(collapsedNote(detail))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) { actions() }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(collapsed ? 10 : 12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    /// First clause of a satisfied row's detail — enough to say WHAT was found
    /// without re-teaching it ("Running", "Found Claude Code").
    private func collapsedNote(_ detail: String) -> String {
        let clause = detail.split(separator: "—", maxSplits: 1).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? detail
        return clause.split(separator: ".", maxSplits: 1).first
            .map { String($0).trimmingCharacters(in: .whitespaces) } ?? clause
    }

    // MARK: - Actions

    private func refreshChecklist() async {
        daemonOK = await bento.status() != nil
        if !daemonOK { await startDaemonAndRefresh() }
        checkingAgent = true
        agentPreset = await AgentDetector.firstInstalled()
        nodeFound = await AgentDetector.commandExists("node")
        checkingAgent = false
    }

    private func startDaemonAndRefresh() async {
        try? await bento.startDaemon(relay: nil)
        daemonOK = await bento.status() != nil
    }

    private func pickDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            workingDir = url.path
        }
    }

    private func launchFirstWorkspace() async {
        launchError = nil
        do {
            try FileManager.default.createDirectory(
                atPath: workingDir, withIntermediateDirectories: true)
        } catch {
            launchError = "Couldn't create the folder: \(error.localizedDescription)"
            return
        }
        let spec = BentoTerminalCore.AgentSpec(
            sessionName: "my-first-project",
            workingDir: workingDir,
            agentCommand: agentPreset?.command ?? "",
            layout: .solo
        )
        BentoTerminalWindow.newWindow(agent: spec)
        launched = true
        TelemetryService.shared.record(.workspaceCreated)
        withAnimation { step = .voice }
    }

    private func finish() {
        // finish() is reached two ways: the welcome step's "skip the tour"
        // escape hatch, or the done step's Finish button. Same completion
        // flag either way; different funnel event.
        TelemetryService.shared.record(step == .done ? .firstRunCompleted : .firstRunSkipped)
        UserDefaults.standard.set(true, forKey: Self.completedKey)
        dismiss()
    }
}

// MARK: - Agent detection

/// AgentDetector answers the checklist's central question: is any known agent
/// installed? Resolution runs through a login shell so the user's real PATH
/// (nvm, homebrew, ~/.local/bin) applies — the same environment their
/// workspaces will get. Uses the CORE preset list (the one that carries the
/// install catalog and matches the state-detection coverage).
enum AgentDetector {
    static func firstInstalled() async -> BentoTerminalCore.AgentPreset? {
        for preset in BentoTerminalCore.AgentPreset.allCases {
            guard let cmd = preset.command, !cmd.isEmpty else { continue }
            let word = cmd.split(separator: " ").first.map(String.init) ?? cmd
            if await which(word) { return preset }
        }
        return nil
    }

    /// Whether a binary resolves on the user's login-shell PATH (used for the
    /// Node.js prerequisite check on npm-based agent installs).
    static func commandExists(_ name: String) async -> Bool {
        await which(name)
    }

    private static func which(_ name: String) async -> Bool {
        await withCheckedContinuation { cont in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
            // Test hook: BENTO_DETECT_PATH replaces the login-shell PATH so a
            // bare machine ("no agent installed") can be simulated — and the
            // install→Re-check transition rehearsed by adding a dir to it
            // mid-flow. Unset in production → the user's real login PATH.
            if let override = ProcessInfo.processInfo.environment["BENTO_DETECT_PATH"] {
                proc.arguments = ["-c", "PATH=\(override) command -v \(name) >/dev/null 2>&1"]
            } else {
                proc.arguments = ["-lc", "command -v \(name) >/dev/null 2>&1"]
            }
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            proc.terminationHandler = { p in
                cont.resume(returning: p.terminationStatus == 0)
            }
            do {
                try proc.run()
            } catch {
                cont.resume(returning: false)
            }
        }
    }
}

// MARK: - QR helper

enum QRCodeImage {
    static func make(_ string: String, size: CGFloat) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let ci = filter.outputImage else { return nil }
        let scale = size / max(ci.extent.width, 1)
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}
