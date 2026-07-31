import SwiftUI
import BentoTerminalCore
import UniformTypeIdentifiers

enum HostEditMode {
    case add
    case edit(Host)
}

struct HostEditView: View {
    @Environment(\.dismiss) private var dismiss

    let mode: HostEditMode
    let onSave: (Host) -> Void

    @State private var name: String = ""
    @State private var hostname: String = ""
    @State private var port: String = "22"
    @State private var username: String = "root"
    @State private var authType: Int = 0 // 0 = password, 1 = key
    @State private var password: String = ""
    @State private var importedKeyLabel: String?
    @State private var showKeyImporter = false
    @State private var unlockMacKeychain = false
    @State private var keychainPassword: String = ""
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var generatedPublicKey: String?

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    init(mode: HostEditMode, onSave: @escaping (Host) -> Void) {
        self.mode = mode
        self.onSave = onSave
        if case .edit(let host) = mode {
            _name = State(initialValue: host.name)
            _hostname = State(initialValue: host.hostname)
            _port = State(initialValue: String(host.port))
            _username = State(initialValue: host.username)
            switch host.authMethod {
            case .password:
                _authType = State(initialValue: 0)
            case .privateKey(let label):
                _authType = State(initialValue: 1)
                _importedKeyLabel = State(initialValue: label)
            }
            _unlockMacKeychain = State(initialValue: host.unlockMacKeychain)
        }
    }

    var body: some View {
        Form {
            Section {
                TextField("Display Name (optional)", text: $name)
                    .textContentType(.nickname)
                    .autocorrectionDisabled()

                TextField("Hostname or IP", text: $hostname)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()

                TextField("Port", text: $port)
                    .keyboardType(.numberPad)

                TextField("Username", text: $username)
                    .textContentType(.username)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
            } header: {
                BentoFormHeader("Server")
            }
            .bentoSectionStyle()

            Section {
                Picker("Method", selection: $authType) {
                    Text("Password").tag(0)
                    Text("Private Key").tag(1)
                }
                .pickerStyle(.segmented)

                if authType == 0 {
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                } else {
                    if let label = importedKeyLabel {
                        HStack {
                            Label(label, systemImage: "key.fill")
                                .lineLimit(1)
                            Spacer()
                            Button("Change") {
                                showKeyImporter = true
                            }
                            .font(.caption)
                        }
                    }

                    Button {
                        showKeyImporter = true
                    } label: {
                        Label("Import Private Key File", systemImage: "square.and.arrow.down")
                    }

                    Button {
                        generateNewKey()
                    } label: {
                        Label("Generate New Key Pair", systemImage: "key.horizontal")
                    }
                }
            } header: {
                BentoFormHeader("Authentication")
            } footer: {
                if authType == 1 {
                    BentoFormFooter("Only ed25519 keys (32-byte raw private key) are supported. Use \"Generate New Key Pair\" to make one — copy the public key onto the server's ~/.ssh/authorized_keys.")
                }
            }
            .bentoSectionStyle()

            Section {
                Toggle("Unlock Mac Keychain", isOn: $unlockMacKeychain)
                if unlockMacKeychain {
                    SecureField("Mac Login Password", text: $keychainPassword)
                        .textContentType(.password)
                }
            } header: {
                BentoFormHeader("macOS")
            } footer: {
                if unlockMacKeychain {
                    BentoFormFooter("Runs `security unlock-keychain` after connecting. Password is stored in the app's keychain.")
                }
            }
            .bentoSectionStyle()
        }
        .bentoForm()
        .navigationTitle(isEditing ? "Edit Host" : "Add Host")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(!isValid)
            }
        }
        .fileImporter(isPresented: $showKeyImporter, allowedContentTypes: [.data, .text]) { result in
            handleKeyImport(result)
        }
        .sheet(isPresented: Binding(
            get: { generatedPublicKey != nil },
            set: { if !$0 { generatedPublicKey = nil } }
        )) {
            if let key = generatedPublicKey {
                PublicKeyShareView(publicKey: key) {
                    generatedPublicKey = nil
                }
            }
        }
        .alert("Error", isPresented: $showError) {
            Button("OK") {}
        } message: {
            Text(errorMessage)
        }
    }

    private func generateNewKey() {
        let comment = "bento@\(hostname.isEmpty ? "host" : hostname)"
        let result = SSHKeyGenerator.generate(comment: comment)
        do {
            try KeychainService.shared.savePrivateKey(result.privateKeyData, label: result.label)
            importedKeyLabel = result.label
            generatedPublicKey = result.openSSHPublicKey
        } catch {
            errorMessage = "Failed to save generated key: \(error.localizedDescription)"
            showError = true
        }
    }

    private var isValid: Bool {
        !hostname.isEmpty && !username.isEmpty &&
        (authType == 0 ? !password.isEmpty : importedKeyLabel != nil)
    }

    private func save() {
        let portNum = UInt16(port) ?? 22

        var host: Host
        if case .edit(let existing) = mode {
            host = existing
        } else {
            host = Host()
        }

        host.name = name
        host.hostname = hostname
        host.port = portNum
        host.username = username

        if authType == 0 {
            host.authMethod = .password
            do {
                try KeychainService.shared.savePassword(password, for: host.id.uuidString)
            } catch {
                errorMessage = "Failed to save password: \(error.localizedDescription)"
                showError = true
                return
            }
        } else if let keyLabel = importedKeyLabel {
            host.authMethod = .privateKey(keyLabel: keyLabel)
        }

        host.unlockMacKeychain = unlockMacKeychain
        if unlockMacKeychain && !keychainPassword.isEmpty {
            do {
                try KeychainService.shared.savePassword(keychainPassword, for: "macKeychain:\(host.id.uuidString)")
            } catch {
                errorMessage = "Failed to save keychain password: \(error.localizedDescription)"
                showError = true
                return
            }
        }

        onSave(host)
        dismiss()
    }

    // MARK: - Public Key Sheet

    private struct PublicKeyShareView: View {
        let publicKey: String
        let onDone: () -> Void
        @State private var copied = false

        var body: some View {
            NavigationStack {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Add this line to ~/.ssh/authorized_keys on the server, then save the host.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    ScrollView {
                        Text(publicKey)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .frame(maxHeight: 220)

                    HStack(spacing: 12) {
                        Button {
                            UIPasteboard.general.string = publicKey
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                copied = false
                            }
                        } label: {
                            Label(copied ? "Copied" : "Copy",
                                  systemImage: copied ? "checkmark.circle.fill" : "doc.on.doc")
                        }
                        .buttonStyle(.borderedProminent)

                        ShareLink(item: publicKey) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.bordered)
                    }

                    Spacer()
                }
                .padding()
                .navigationTitle("Public Key")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: onDone)
                    }
                }
            }
        }
    }

    private func handleKeyImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            guard url.startAccessingSecurityScopedResource() else {
                errorMessage = "Cannot access the selected file."
                showError = true
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }

            do {
                let keyData = try Data(contentsOf: url)
                let label = url.lastPathComponent
                try KeychainService.shared.savePrivateKey(keyData, label: label)
                importedKeyLabel = label
            } catch {
                errorMessage = "Failed to import key: \(error.localizedDescription)"
                showError = true
            }

        case .failure(let error):
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}
