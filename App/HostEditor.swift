// Modified from Herdrup https://github.com/jerryfane/herdrup commit 93c6578666e656c3206661389e81853bcc0b88da by Elysium Technologies.
import HerdrKit
import SwiftUI
import UIKit

/// What the `HostEditor` sheet is working on: a brand-new host, or an existing one.
enum HostEditorTarget: Identifiable {
    case add
    case edit(SavedHost)
    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let h): return h.id.uuidString
        }
    }
}

/// Add or edit a saved host: nickname + host(:port) + user + private key. Saving records
/// the non-secret fields in UserDefaults and the key in the Keychain (via `SavedHostsStore`).
/// Adding also offers Save & Connect. A saved key is never redisplayed: on edit the field
/// starts blank and the stored key is kept unless a replacement is imported or pasted.
struct HostEditor: View {
    let target: HostEditorTarget
    @ObservedObject var store: SavedHostsStore
    /// Save & Connect (add mode): build credentials and hand them up to connect.
    var onConnect: (SSHCredentials) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var nickname: String
    @State private var host: String
    @State private var username: String
    @State private var session: String
    @State private var keyPEM = ""
    @State private var showingKeySheet = false
    /// Whether this host authenticates with a key or a password (segmented picker).
    @State private var authKind: SavedAuthKind
    /// The password (password mode). Masked by a SecureField, so unlike the key it can
    /// be entered inline; write-only on edit (blank keeps the stored one).
    @State private var password = ""
    @State private var error: String?
    @State private var keyError: String?
    /// "Choose key file…" imports a key already made available through the iOS Files picker.
    @State private var showingKeyImporter = false
    /// Manual paste, shown ALONGSIDE the file picker rather than behind a disclosure.
    /// Starts empty and is cleared the instant a key is accepted, so the only thing ever
    /// on screen is what the person just put there.
    @State private var manualKey = ""

    private let editing: SavedHost?

    init(target: HostEditorTarget, store: SavedHostsStore, onConnect: @escaping (SSHCredentials) -> Void) {
        self.target = target
        self.store = store
        self.onConnect = onConnect
        switch target {
        case .add:
            editing = nil
            _nickname = State(initialValue: "")
            _host = State(initialValue: "")
            _username = State(initialValue: "")
            _session = State(initialValue: OfficialHerdrSession.defaultName)
            _authKind = State(initialValue: .key)
        case .edit(let h):
            editing = h
            _nickname = State(initialValue: h.nickname ?? "")
            _host = State(initialValue: h.host)
            _username = State(initialValue: h.username)
            _session = State(initialValue: h.herdrSession)
            _authKind = State(initialValue: h.auth)
        }
    }

    private var endpoint: HostEndpoint? { HostEndpoint.parse(host) }
    private var trimmedUser: String { username.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedKey: String { keyPEM.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var sessionTarget: OfficialHerdrSession? { OfficialHerdrSession(name: session) }
    private var hostInvalid: Bool {
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && endpoint == nil
    }
    /// Add requires the chosen secret; edit keeps the existing one when the field is
    /// left blank (whichever auth kind).
    private var canSave: Bool {
        guard endpoint != nil, !trimmedUser.isEmpty, sessionTarget != nil else { return false }
        if let editing, authKind == editing.auth { return true }
        return authKind == .key ? !trimmedKey.isEmpty : !password.isEmpty
    }

    /// The secret to persist, or nil when the field is blank (edit keeps the current one).
    private func currentSecret() -> HostSecret? {
        switch authKind {
        case .key: return trimmedKey.isEmpty ? nil : .key(trimmedKey)
        case .password: return password.isEmpty ? nil : .password(password)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Palette.ground.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 10) {
                        fieldRow("Name", text: $nickname, placeholder: "My Mac")
                        fieldRow("Host", text: $host, placeholder: "mac.example.ts.net")
                        if hostInvalid { caption("check host or host:port", color: Palette.died) }
                        fieldRow("User", text: $username, placeholder: "mac-user")
                        fieldRow("Herdr session", text: $session, placeholder: "default")
                        if sessionTarget == nil {
                            caption("use 1–64 letters, numbers, dots, underscores or hyphens", color: Palette.died)
                        }
                        authPicker
                        if authKind == .key { keyRow } else { passwordRow }
                        if let error { caption(error, color: Palette.died) }

                        if editing == nil {
                            primaryButton("Save & Connect") { saveAndConnect() }
                            Button("Save without connecting") { if save() { dismiss() } }
                                .font(Typography.app(14)).foregroundStyle(Palette.textDim)
                                .disabled(!canSave).padding(.top, 2)
                        } else {
                            primaryButton("Save") { if save() { dismiss() } }
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle(editing == nil ? "Add Mac" : "Edit Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundStyle(Palette.textDim)
                }
            }
        }
        .sheet(isPresented: $showingKeySheet) { keySheet }
    }

    // MARK: - actions

    /// Persist the host (add or update). Returns success; sets `error` on failure.
    @discardableResult
    private func save() -> Bool {
        let secret = currentSecret()
        let ok: Bool
        if let editing {
            // nil secret = keep the stored one (blank field on edit).
            let result = store.update(
                editing, nickname: nickname, host: host, username: trimmedUser,
                session: session, secret: secret)
            if result == .notificationRouteMustBeDisabled {
                error = "Turn off notifications for this saved host and let the Mac confirm removal before changing its host, port, user, or Herdr session. You can still update its nickname or credentials for the same target."
                return false
            }
            ok = result.succeeded
        } else if let secret {
            ok = store.add(
                nickname: nickname, host: host, username: trimmedUser,
                session: session, secret: secret)
        } else {
            ok = false  // add needs a secret; canSave already prevents this — defensive.
        }
        if !ok {
            error = "Couldn't save this host. Check the fields (a key or password is required) and try again."
        } else {
            error = nil
        }
        return ok
    }

    private func saveAndConnect() {
        guard let ep = endpoint, let sessionTarget, save() else { return }
        // Add mode requires the secret, so it is in hand here — connect straight away.
        let creds: SSHCredentials
        switch authKind {
        case .key:
            creds = SSHCredentials(host: ep.host, port: ep.port, username: trimmedUser,
                                   privateKeyPEM: trimmedKey,
                                   remoteSocketPath: sessionTarget.socketPath,
                                   herdrSession: sessionTarget.name)
        case .password:
            creds = SSHCredentials(host: ep.host, port: ep.port, username: trimmedUser,
                                   password: password,
                                   remoteSocketPath: sessionTarget.socketPath,
                                   herdrSession: sessionTarget.name)
        }
        onConnect(creds)
        dismiss()
    }

    // MARK: - rows

    private func fieldRow(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        HStack {
            Text(label).font(Typography.app(15)).foregroundStyle(Palette.textDim)
            TextField(placeholder, text: text)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .font(Typography.machine(15)).foregroundStyle(Palette.text)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(Palette.surface).clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// Choose how this host authenticates. Switching hides/shows the key vs password row.
    private var authPicker: some View {
        Picker("Auth", selection: $authKind) {
            Text("Key").tag(SavedAuthKind.key)
            Text("Password").tag(SavedAuthKind.password)
        }
        .pickerStyle(.segmented)
        .padding(.vertical, 2)
    }

    /// The password field. A SecureField masks the value, so unlike the key it is safe
    /// to enter inline; on edit it starts blank and the stored password is kept unless a
    /// new one is typed. Stored in the Keychain (device-only), same as the key.
    private var passwordRow: some View {
        HStack {
            Text("Password").font(Typography.app(15)).foregroundStyle(Palette.textDim)
            SecureField(editing == nil ? "password" : "saved · type to replace", text: $password)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .font(Typography.machine(15)).foregroundStyle(Palette.text)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(Palette.surface).clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// The key row NEVER renders the key itself — only whether one is set (the connect
    /// screen is screenshotted onto an open port, so the PEM must not be on screen).
    private var keyRow: some View {
        Button { showingKeySheet = true } label: {
            HStack {
                Text("Key").font(Typography.app(15)).foregroundStyle(Palette.textDim)
                Spacer()
                if !keyPEM.isEmpty {
                    Text(editing == nil ? "ed25519 key" : "new key")
                        .font(Typography.machine(15)).foregroundStyle(Palette.text)
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Palette.done)
                } else if editing != nil {
                    Text("saved · tap to replace").font(Typography.app(15)).foregroundStyle(Palette.textFaint)
                } else {
                    Text("Add private key").font(Typography.app(15)).foregroundStyle(Palette.textFaint)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .background(Palette.surface).clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    /// Saved key material is never redisplayed. Files and the system PasteButton ingest it
    /// without rendering it; the manual editor is an explicit fallback whose visible copy
    /// is cleared immediately after acceptance.
    private var keySheet: some View {
        NavigationStack {
            ZStack {
                Palette.ground.ignoresSafeArea()
                // Scrolled, matching the main form above. With two routes on screen —
                // file button, caption, PasteButton, rule, a 110pt editor, accept button,
                // the "Key set" row and an error line — this overflows a small iPhone,
                // and raising the keyboard for the paste field guarantees it.
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        // The old copy said the key comes from the clipboard and is "never
                        // displayed". Both stopped being true here: there are two routes now,
                        // and the paste field shows the key while it is being pasted. A
                        // security claim left standing after the property it described is gone
                        // is worse than no claim, so it says what is actually true instead.
                        Text("Choose your ed25519 private key from Files, or paste it below. It stays in the Keychain on this device and signs SSH authentication.")
                            .font(Typography.app(13)).foregroundStyle(Palette.textDim)

                        // Put the Files route first because it avoids displaying key material
                        // in an editor. The user may save or share a key into Files before
                        // opening this picker; the app does not assume a Mac filesystem path.
                        Button { showingKeyImporter = true } label: {
                            Label("Choose key file…", systemImage: "folder")
                                .font(Typography.app(16, .semibold))
                                .frame(maxWidth: .infinity).padding(.vertical, 15)
                                .background(Palette.accent).foregroundStyle(Palette.accentOn)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)

                        caption("Save or share the key into Files first if it is not already available in the picker.", color: Palette.textFaint)

                        // System PasteButton, NOT a programmatic UIPasteboard read: the tap
                        // itself is the paste consent, so it never shows the "Allow Paste"
                        // permission prompt (which was the iPad App Review failure) and still
                        // hands us the key WITHOUT rendering it. Auto-disables when the
                        // clipboard holds no text.
                        PasteButton(payloadType: String.self) { items in
                            // The action can run off the main actor; hop before touching @State.
                            Task { @MainActor in ingestKey(items.first) }
                        }
                        .labelStyle(.titleAndIcon)
                        .tint(Palette.accent)
                        .buttonBorderShape(.roundedRectangle(radius: 12))
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)

                        // The second route, a PEER of the file picker rather than something
                        // hidden behind a disclosure. Pasting into a field the user focused is
                        // their own action, so it triggers no "Allow Paste" prompt — what got
                        // this app rejected under 2.1a was a PROGRAMMATIC pasteboard read, not
                        // a person using the field's explicit paste action.
                        HStack(spacing: 10) {
                            Rectangle().fill(Palette.surface).frame(height: 1)
                            Text("or paste it").font(Typography.app(12))
                                .foregroundStyle(Palette.textFaint)
                            Rectangle().fill(Palette.surface).frame(height: 1)
                        }
                        .padding(.vertical, 2)

                        TextEditor(text: $manualKey)
                            .font(Typography.machine(12))
                            .frame(height: 110)
                            .scrollContentBackground(.hidden)
                            .background(Palette.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)

                        Button("Use pasted key") {
                            ingestKey(manualKey)
                            // Drop the visible copy as soon as it is accepted.
                            if keyError == nil { manualKey = "" }
                        }
                        .font(Typography.app(15, .semibold))
                        .foregroundStyle(manualKey.isEmpty ? Palette.textFaint : Palette.text)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(Palette.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .disabled(manualKey.isEmpty)

                        if !keyPEM.isEmpty {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.seal.fill").foregroundStyle(Palette.done)
                                Text("Key set").font(Typography.app(15)).foregroundStyle(Palette.text)
                                Spacer(minLength: 8)
                                Button("Clear") { keyPEM = ""; keyError = nil }
                                    .font(Typography.app(14)).foregroundStyle(Palette.died)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 12)
                            .background(Palette.surface).clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        if let keyError { caption(keyError, color: Palette.died) }
                        Spacer(minLength: 0)
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Private key")
            .fileImporter(
                isPresented: $showingKeyImporter,
                allowedContentTypes: [.item],  // an SSH key has no UTType and no extension
                allowsMultipleSelection: false
            ) { result in
                importKeyFile(result)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showingKeySheet = false }.foregroundStyle(Palette.textDim)
                }
            }
        }
    }

    /// Read a private key the user picked in the file browser.
    ///
    /// The file is read and discarded — nothing is copied into the app's container, and
    /// the key is not rendered by the import route.
    private func importKeyFile(_ result: Result<[URL], Swift.Error>) {
        switch result {
        case .failure(let err):
            keyError = "Couldn't open that file: \(err.localizedDescription)"
        case .success(let urls):
            guard let url = urls.first else { return }
            // A file picked outside the sandbox is security-scoped; without this the read
            // fails with a permission error that reads like a missing file.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                // A public key is the easy mistake to make here (id_ed25519.pub sits right
                // next to the private one and sorts adjacent in the picker), and the
                // generic "expected a PEM block" message would not explain it.
                if text.hasPrefix("ssh-") || url.pathExtension == "pub" {
                    keyError = "That's the PUBLIC key. Pick the file WITHOUT the .pub "
                        + "ending — usually id_ed25519."
                    return
                }
                ingestKey(text)
            } catch {
                keyError = "Couldn't read that file: \(error.localizedDescription)"
            }
        }
    }

    /// Accept a PEM key from ANY of the three routes: the file picker, the system
    /// `PasteButton`, or the manual paste field.
    ///
    /// Loosely sanity-checks that it looks like a PEM private key, so a stray string
    /// isn't stored as a key. Note what is NOT here: a programmatic `UIPasteboard` read.
    /// That triggers the system paste-permission prompt, which is what failed iPad App
    /// Review under 2.1a — every route above hands the string in instead.
    private func ingestKey(_ raw: String?) {
        // Source-agnostic wording: a message naming the clipboard would be wrong for two
        // of the three callers.
        guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            keyError = "That was empty. Choose your private key file, or paste the key."
            return
        }
        guard s.contains("PRIVATE KEY") else {
            keyError = "That doesn't look like a private key. It should start with "
                + "-----BEGIN OPENSSH PRIVATE KEY-----."
            return
        }
        keyPEM = s
        keyError = nil
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Typography.app(16, .semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 15)
                .background(canSave ? Palette.accent : Palette.surfaceRaised)
                .foregroundStyle(canSave ? Palette.accentOn : Palette.textFaint)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .disabled(!canSave)
        .padding(.top, 6)
    }

    private func caption(_ text: String, color: Color) -> some View {
        Text(text)
            .font(Typography.app(12)).foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
    }
}
