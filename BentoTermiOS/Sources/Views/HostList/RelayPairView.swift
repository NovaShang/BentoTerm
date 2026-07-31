import SwiftUI
import BentoTerminalCore

/// RelayPairView is the sheet shown when the user taps "Pair via Bento Relay".
///
/// Default mode is the camera QR scanner — the Mac pairing window renders a
/// QR encoding `bento://pair?d=…&c=…`, and a single scan auto-fills both
/// fields and kicks off the pair request. The user can fall back to manual
/// entry via the "Enter manually" button (the only path when scanning isn't
/// supported, e.g. on the simulator or after the user denied camera access).
struct RelayPairView: View {
    @EnvironmentObject private var store: RelayDaemonStore
    @EnvironmentObject private var sessionManager: SessionManager
    @Environment(\.dismiss) private var dismiss

    /// Values delivered by the `bento://pair?d=&c=&l=` deep link. Applied
    /// on appear (alongside the UserDefaults test hook). Nil when the user
    /// opened the sheet manually from the + menu.
    let prefill: PendingRelayPair?

    private enum Mode { case scan, manual }

    @State private var mode: Mode
    @State private var daemonID: String = ""
    @State private var code: String = ""
    @State private var label: String = ""
    @State private var error: String?
    @State private var working: Bool = false
    @State private var scanHint: String?
    /// Set on success → swaps the sheet to the confirmation page. Pairing must
    /// never end with "nothing happened" (design doc P5): the user sees the ✓,
    /// the host's name, and a one-tap way into its workspaces.
    @State private var paired: RelayDaemon?

    init(prefill: PendingRelayPair? = nil) {
        self.prefill = prefill
        // If we already have prefill (deep link) or scanning isn't supported
        // (simulator, no camera), open straight to manual entry.
        let canScan = QRScannerView.isSupported
        _mode = State(initialValue: (prefill != nil || !canScan) ? .manual : .scan)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let daemon = paired {
                    successView(daemon)
                } else {
                    switch mode {
                    case .scan: scannerSurface
                    case .manual: manualForm
                    }
                }
            }
            .navigationTitle(paired == nil ? "Pair with your computer" : "Paired")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if paired == nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") { dismiss() }
                    }
                    if mode == .manual {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Pair") {
                                Task { await pair() }
                            }
                            .disabled(!canSubmit || working)
                        }
                    }
                }
            }
            .overlay {
                if working {
                    ProgressView("Pairing…")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .onAppear { applyPrefill() }
        }
    }

    // MARK: - Scanner surface

    private var scannerSurface: some View {
        ZStack(alignment: .bottom) {
            QRScannerView { payload in
                handleScan(payload)
            }
            .ignoresSafeArea()

            VStack(spacing: 12) {
                if let scanHint {
                    Text(scanHint)
                        .font(.callout)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.thinMaterial, in: Capsule())
                }
                Text("Point at the QR code in BentoTerm on your Mac")
                    .font(.callout)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.55), in: Capsule())

                Button {
                    mode = .manual
                } label: {
                    Label("Enter manually", systemImage: "keyboard")
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background(.regularMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 36)
        }
    }

    private func handleScan(_ payload: String) {
        guard let url = URL(string: payload),
              url.scheme == "bento",
              url.host == "pair",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            scanHint = "Not a BentoTerm pairing code"
            return
        }
        let items = comps.queryItems ?? []
        let d = items.first(where: { $0.name == "d" })?.value ?? ""
        let raw = items.first(where: { $0.name == "c" })?.value ?? ""
        let c = String(raw.filter(\.isNumber).prefix(6))
        guard !d.isEmpty, c.count == 6 else {
            scanHint = "QR is missing daemon ID or code"
            return
        }
        daemonID = d
        code = c
        if label.isEmpty, let l = items.first(where: { $0.name == "l" })?.value {
            label = l
        }
        Task { await pair() }
    }

    // MARK: - Manual form

    private var manualForm: some View {
        Form {
            Section {
                HStack {
                    TextField("daemon-id (paste from Mac)", text: $daemonID)
                        .font(.system(.callout, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("pair_daemon_id")
                    Button {
                        if let s = UIPasteboard.general.string {
                            daemonID = s.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                    }
                }
            } footer: {
                BentoFormFooter("The daemon ID identifies the BentoTerm host running on your Mac. Copy it there and paste it here.")
            }
            .bentoSectionStyle()

            Section {
                TextField("------", text: $code)
                    .keyboardType(.numberPad)
                    .font(.system(.title, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("pair_code")
                    .onChange(of: code) { _, new in
                        let filtered = new.filter(\.isNumber)
                        code = String(filtered.prefix(6))
                    }
            } header: {
                BentoFormHeader("6-digit code")
            }
            .bentoSectionStyle()

            Section {
                TextField("e.g. Office Mac mini", text: $label)
            } header: {
                BentoFormHeader("Label (optional)")
            }
            .bentoSectionStyle()

            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Color.bentoRed)
                }
                .bentoSectionStyle()
            }

            if QRScannerView.isSupported {
                Section {
                    Button {
                        error = nil
                        mode = .scan
                    } label: {
                        Label("Scan QR instead", systemImage: "qrcode.viewfinder")
                    }
                }
                .bentoSectionStyle()
            }

            Section {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(Color.bentoEmerald)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("End-to-end encrypted")
                            .font(.callout.weight(.medium))
                        Text("Your iPhone and Mac generate fresh Ed25519 keys at pairing time. All terminal traffic is encrypted under SSH between the two devices — the Bento relay only forwards encrypted bytes and cannot read or modify them.")
                            .font(.caption)
                            .foregroundStyle(Color.bentoInkDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
            }
            .bentoSectionStyle()
        }
        .bentoForm()
    }

    // MARK: - Success

    /// The pairing confirmation page: checkmark, the host's name, the concept
    /// in one line, and a single CTA straight into the host's workspaces —
    /// never a silent fall back to the list (design doc §5.3).
    private func successView(_ daemon: RelayDaemon) -> some View {
        VStack(spacing: 20) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.bentoEmerald.opacity(0.15))
                    .frame(width: 96, height: 96)
                Image(systemName: "checkmark")
                    .font(.system(size: 42, weight: .bold))
                    .foregroundStyle(Color.bentoEmerald)
            }
            .transition(.scale.combined(with: .opacity))

            VStack(spacing: 8) {
                Text("Connected to “\(daemon.displayName)”")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Color.bentoInk)
                    .multilineTextAlignment(.center)
                Text("This phone and your computer now know each other — you won't need to pair again. Your sessions are waiting.")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.bentoInkDim)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 32)

            Button {
                let host = Host.fromRelayDaemon(daemon)
                dismiss()
                sessionManager.navigationPath = [.sessions(host)]
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Open sessions")
                        .font(.system(size: 16, weight: .semibold))
                }
                .foregroundStyle(Color.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.bentoEmerald)
                )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 32)

            Button("Later") { dismiss() }
                .font(.system(size: 15))
                .foregroundStyle(Color.bentoInkDim)

            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.bentoShell)
    }

    // MARK: - Prefill

    /// Apply prefill from either the deep-link argument or the
    /// UserDefaults test hook (Maestro / smoke flows seed
    /// `pair_prefill_*` so the flow can be exercised without driving the
    /// on-screen keyboard).
    private func applyPrefill() {
        if let p = prefill {
            if daemonID.isEmpty { daemonID = p.daemonID }
            if code.isEmpty { code = String(p.code.filter(\.isNumber).prefix(6)) }
            if label.isEmpty, let l = p.label { label = l }
        }
        let d = UserDefaults.standard
        if daemonID.isEmpty, let s = d.string(forKey: "pair_prefill_daemon") {
            daemonID = s
        }
        if code.isEmpty, let s = d.string(forKey: "pair_prefill_code") {
            code = String(s.filter(\.isNumber).prefix(6))
        }
        if label.isEmpty, let s = d.string(forKey: "pair_prefill_label") {
            label = s
        }
    }

    // MARK: - Pair

    private var canSubmit: Bool {
        !daemonID.isEmpty && code.count == 6
    }

    private func pair() async {
        working = true
        error = nil
        defer { working = false }
        do {
            let daemon = try await RelayPairingService.shared.pair(
                daemonID: daemonID,
                code: code,
                label: label
            )
            store.add(daemon)
            TelemetryService.shared.record(.pairingSucceeded)
            withAnimation(.spring(duration: 0.4)) { paired = daemon }
        } catch {
            // Surface the failure in the manual form; flip mode so the user
            // can adjust the values they just entered (or re-scan). Classify
            // the two failure families a novice can actually act on.
            let raw = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            if raw.localizedCaseInsensitiveContains("code")
                || raw.localizedCaseInsensitiveContains("expired")
                || raw.localizedCaseInsensitiveContains("invalid") {
                self.error = "That code didn't work — it may have expired. Check your computer's screen for the fresh code (it renews every 60 seconds)."
            } else {
                self.error = "Couldn't reach the pairing service — both devices need to be online. (\(raw))"
            }
            mode = .manual
        }
    }
}
