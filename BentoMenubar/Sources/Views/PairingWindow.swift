import SwiftUI
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// PairingWindow exposes the two values the iPhone needs to type to pair:
/// the daemon ID (long, copy-only) and the 6-digit code (short, copy or
/// type). The layout is two stacked "card" rows so the user has a clear
/// 1-2-3 mental model: copy the ID, copy or type the code, encrypt.
struct PairingWindow: View {
    @EnvironmentObject var bento: BentoCLI
    @State private var code: String?
    @State private var error: String?
    @State private var remainingSec: Int = 60
    @State private var daemonID: String = ""
    @State private var copiedID: Bool = false
    @State private var copiedCode: Bool = false
    @State private var showManual = false
    /// Device count when the window opened — a later increase means a pairing
    /// just landed, which flips the window into its success state. Pairing
    /// must end with a visible ✓ on BOTH screens (design doc §4.4).
    @State private var baselineDevices: Int?
    @State private var pairedSuccess = false
    @Environment(\.dismiss) private var dismiss

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            content
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 16)

            Spacer(minLength: 0)

            Divider()

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 440, height: 600)
        .task { await fetch() }
        .onReceive(timer) { _ in
            guard !pairedSuccess else { return }
            guard code != nil else { return }
            if remainingSec > 1 {
                remainingSec -= 1
            } else {
                Task { await fetch() }
            }
            // Poll for the success signal every 2s (device count increase).
            if remainingSec % 2 == 0 {
                Task { await checkPaired() }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if pairedSuccess {
            successContent
        } else {
            VStack(alignment: .leading, spacing: 16) {
                Text("On your iPhone: install Bento, choose **“I have a Mac”**, and scan this code — or use the iPhone Camera app.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let err = error {
                    errorCard(err)
                } else if code == nil {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    qrCard
                    codeCard
                    manualDisclosure
                }

                footnote
            }
        }
    }

    /// The success state: check, device name, and what to do next — then the
    /// window excuses itself.
    private var successContent: some View {
        VStack(spacing: 18) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.15))
                    .frame(width: 96, height: 96)
                Image(systemName: "checkmark")
                    .font(.system(size: 42, weight: .bold))
                    .foregroundStyle(.green)
            }
            Text("iPhone connected")
                .font(.system(size: 22, weight: .bold))
            Text("Open Bento on the phone — your sessions are already waiting there. This window will close itself.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .task {
            try? await Task.sleep(for: .seconds(3))
            dismiss()
        }
    }

    /// Manual entry values, folded away — novices scan; the daemon ID only
    /// matters when scanning isn't possible (design doc §4.4).
    private var manualDisclosure: some View {
        DisclosureGroup(isExpanded: $showManual) {
            daemonIDCard
                .padding(.top, 8)
        } label: {
            Text("Can't scan? Enter manually instead")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var pairURL: URL? {
        guard let code, !daemonID.isEmpty else { return nil }
        var comps = URLComponents()
        comps.scheme = "bento"
        comps.host = "pair"
        comps.queryItems = [
            URLQueryItem(name: "d", value: daemonID),
            URLQueryItem(name: "c", value: code),
        ]
        return comps.url
    }

    private var qrCard: some View {
        Card(title: "Scan with iPhone Camera") {
            HStack {
                Spacer()
                if let url = pairURL, let img = QRCodeImage.make(url.absoluteString, size: 180) {
                    Image(nsImage: img)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 180, height: 180)
                        .padding(8)
                        .background(Color.white)
                        .cornerRadius(8)
                } else {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.1))
                        .frame(width: 180, height: 180)
                        .overlay(ProgressView())
                }
                Spacer()
            }
        }
    }

    private var daemonIDCard: some View {
        Card(title: "Daemon ID") {
            HStack(spacing: 8) {
                Text(daemonID.isEmpty ? "—" : daemonID)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                CopyButton(copied: copiedID) {
                    copy(daemonID) { copiedID = $0 }
                }
                .disabled(daemonID.isEmpty)
            }
        }
    }

    private var codeCard: some View {
        // The countdown is a quiet ring, not a readable deadline — the code
        // renews itself seamlessly, so there is nothing for the user to race.
        Card(title: "Pairing code", trailing: AnyView(
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: CGFloat(remainingSec) / 60)
                    .stroke(Color.green, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: remainingSec)
            }
            .frame(width: 16, height: 16)
            .help("The code renews automatically")
        )) {
            HStack(spacing: 8) {
                Text(code ?? "")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .tracking(8)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .center)
                CopyButton(copied: copiedCode) {
                    if let c = code { copy(c) { copiedCode = $0 } }
                }
                .disabled(code == nil)
            }
        }
    }

    private var footnote: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "link").foregroundStyle(.secondary)
                Text("Pairing introduces your iPhone to this Mac — you only do it once. Afterwards they find each other from any network.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "lock.shield").foregroundStyle(.green)
                Text("End-to-end encrypted. The relay only forwards encrypted SSH bytes — it cannot read or modify your terminal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func errorCard(_ msg: String) -> some View {
        GroupBox {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(msg).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Retry") { Task { await fetch() } }
            }
        }
    }

    private func fetch() async {
        do {
            code = nil
            error = nil
            remainingSec = 60
            daemonID = bento.currentDaemonID()
            if baselineDevices == nil {
                baselineDevices = await bento.status()?.pairedDevices
            }
            code = try await bento.pair()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    /// Success signal: the daemon reports one more paired device than when
    /// this window opened.
    private func checkPaired() async {
        guard let baseline = baselineDevices,
              let now = await bento.status()?.pairedDevices,
              now > baseline else { return }
        withAnimation(.spring(duration: 0.4)) { pairedSuccess = true }
    }

    private func copy(_ s: String, setFlag: @escaping (Bool) -> Void) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        setFlag(true)
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            setFlag(false)
        }
    }
}

// MARK: - Building blocks

/// Card is a lightweight bordered container with a small title label and an
/// optional trailing accessory in the header row. Matches Apple's "labeled
/// content cell" style without depending on a list.
private struct Card<Content: View>: View {
    let title: String
    var trailing: AnyView? = nil
    @ViewBuilder var content: () -> Content

    init(title: String, trailing: AnyView? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.trailing = trailing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Spacer()
                trailing
            }
            content()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)
                )
        )
    }
}

private struct CopyButton: View {
    let copied: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .foregroundStyle(copied ? .green : .accentColor)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.borderless)
        .help(copied ? "Copied" : "Copy to clipboard")
    }
}
