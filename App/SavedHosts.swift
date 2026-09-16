// Modified from Herdrup https://github.com/jerryfane/herdrup commit 93c6578666e656c3206661389e81853bcc0b88da by Elysium Technologies.
import Foundation
import Security
import HerdrKit

/// Which credential a saved host authenticates with.
enum SavedAuthKind: String, Codable {
    case key
    case password
}

/// The secret half of a saved host, routed to the matching Keychain store by the
/// store's add/update. Keeps one code path for both auth kinds.
enum HostSecret {
    case key(String)
    case password(String)
}

enum SavedHostUpdateResult: Equatable {
    case updated
    case invalidFields
    case credentialPersistenceFailed
    case notificationRouteMustBeDisabled

    var succeeded: Bool { self == .updated }
}

/// The remote identity whose notification route is keyed by a saved-host UUID.
/// Nicknames and authentication material are intentionally absent: both can change
/// without moving the route. `HostKey.canonical` folds ordinary DNS case/trailing-dot
/// spellings and explicit default ports after `HostEndpoint` has parsed the endpoint.
private struct SavedHostTargetIdentity: Equatable {
    let endpoint: String
    let username: String
    let session: String

    init?(host: String, username: String, session: String) {
        guard let endpoint = HostEndpoint.parse(host),
              let session = OfficialHerdrSession(name: session) else { return nil }
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else { return nil }
        self.endpoint = HostKey.canonical(host: endpoint.host, port: endpoint.port)
        self.username = username
        self.session = session.name
    }

    init?(_ host: SavedHost) {
        self.init(host: host.host, username: host.username, session: host.herdrSession)
    }
}

/// A saved connection target for one-tap reconnect. Holds ONLY the non-secret
/// fields (host — which may include ":port" — and username). The private key or
/// password is NEVER stored here; it lives in the Keychain (`KeychainCredentialStore`),
/// keyed by `id`. So the on-disk (UserDefaults) list can be read without exposing a secret.
struct SavedHost: Codable, Identifiable, Hashable {
    let id: UUID
    var host: String
    var username: String
    /// Optional friendly label ("My Mac"). Legacy saved hosts predate this field, so it
    /// is OPTIONAL — old JSON without the key decodes to `nil` (no migration needed).
    var nickname: String?
    /// Which credential this host uses. OPTIONAL for migration exactly like `nickname`:
    /// JSON written before password auth has no `authKind`, decodes to nil, and resolves
    /// to `.key` via `auth` — so every legacy host stays key-based.
    var authKind: SavedAuthKind?
    /// Official Herdr session. Optional so existing saved hosts migrate to `default`.
    var session: String?

    /// The resolved auth kind for callers — a legacy (nil) host is key-based.
    var auth: SavedAuthKind { authKind ?? .key }
    var herdrSession: String { session ?? OfficialHerdrSession.defaultName }

    /// The primary display label: the nickname if set, else the host itself.
    var label: String {
        if let n = nickname?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty { return n }
        return host
    }
}

/// Persists saved hosts: the host+username list in UserDefaults, each host's
/// private key in the Keychain (device-local, unlock-gated). The two are kept in
/// lockstep — `save` only records a host once its key persists, and `delete`
/// removes both — so a listed host is always one-tap reconnectable.
final class SavedHostsStore: ObservableObject {
    static let shared = SavedHostsStore()

    private let defaultsKey = "dev.herdr.savedHosts.v1"
    private let defaults: UserDefaults
    private let keychain: KeychainCredentialStore
    /// A host's password lives in its own Keychain service so a host's key and
    /// password never collide on the same account id. Same device-only discipline.
    private let passwordKeychain: KeychainCredentialStore

    @Published private(set) var hosts: [SavedHost]

    init(
        defaults: UserDefaults = .standard,
        credentialService: String = "dev.herdr.credentials",
        passwordCredentialService: String = "dev.herdr.credentials.password"
    ) {
        self.defaults = defaults
        keychain = KeychainCredentialStore(service: credentialService)
        passwordKeychain = KeychainCredentialStore(service: passwordCredentialService)
        if let data = defaults.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([SavedHost].self, from: data) {
            hosts = decoded
        } else {
            hosts = []
        }
    }

    /// Adds a NEW saved host (its own id) and stores its secret (key or password) in
    /// the Keychain. Returns false — WITHOUT recording the host — if a required field
    /// is missing or the secret could not be persisted, so the UI never offers a
    /// one-tap host it cannot open.
    @discardableResult
    func add(
        nickname: String, host: String, username: String,
        session: String = OfficialHerdrSession.defaultName, secret: HostSecret
    ) -> Bool {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let u = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let n = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty, !u.isEmpty, let sessionTarget = OfficialHerdrSession(name: session) else {
            return false
        }
        let id = UUID()
        // Persist the secret FIRST; only record the host if it actually stuck.
        let kind: SavedAuthKind
        switch secret {
        case .key(let pem):
            let key = pem.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, keychain.save(account: id.uuidString, secret: key) else { return false }
            kind = .key
        case .password(let password):
            // A password is NOT trimmed — leading/trailing spaces can be significant.
            guard !password.isEmpty,
                  passwordKeychain.save(account: id.uuidString, secret: password) else { return false }
            kind = .password
        }
        hosts.insert(
            SavedHost(
                id: id, host: h, username: u, nickname: n.isEmpty ? nil : n,
                authKind: kind, session: sessionTarget.name),
            at: 0)
        persist()
        return true
    }

    /// Updates an existing saved host IN PLACE (by id): host / username / nickname, and
    /// the secret only when `secret` is non-nil (nil = keep the current one, so an edit
    /// never forces re-entering it). Switching auth kind drops the now-stale other
    /// secret. Target identity changes are refused before any Keychain write while the
    /// notification record may still exist remotely; nickname and same-target credential
    /// recovery remain available. The result distinguishes that actionable refusal from
    /// ordinary validation/persistence failure.
    @discardableResult
    func update(
        _ existing: SavedHost, nickname: String, host: String, username: String,
        session: String = OfficialHerdrSession.defaultName, secret: HostSecret?
    ) -> SavedHostUpdateResult {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let u = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let n = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty, !u.isEmpty,
              let sessionTarget = OfficialHerdrSession(name: session),
              let candidateTarget = SavedHostTargetIdentity(
                host: h, username: u, session: sessionTarget.name) else {
            return .invalidFields
        }
        guard let i = hosts.firstIndex(where: { $0.id == existing.id }) else {
            return .invalidFields
        }
        let current = hosts[i]
        if SavedHostTargetIdentity(current) != candidateTarget,
           CompanionNotificationTargetEditPolicy.blocksTargetChange(
            savedHostID: current.id.uuidString, defaults: defaults) {
            return .notificationRouteMustBeDisabled
        }
        var newKind = current.auth
        // Replace the secret only if a new one was entered; a failed persist aborts the
        // whole update so the record never drifts out of lockstep with the Keychain.
        if let secret {
            switch secret {
            case .key(let pem):
                let key = pem.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty,
                      keychain.save(account: current.id.uuidString, secret: key) else {
                    return .credentialPersistenceFailed
                }
                newKind = .key
            case .password(let password):
                guard !password.isEmpty,
                      passwordKeychain.save(account: current.id.uuidString, secret: password) else {
                    return .credentialPersistenceFailed
                }
                newKind = .password
            }
            // Auth kind changed → best-effort drop the stale secret from the other store.
            if newKind != current.auth {
                switch current.auth {
                case .key: _ = keychain.delete(account: current.id.uuidString)
                case .password: _ = passwordKeychain.delete(account: current.id.uuidString)
                }
            }
        }
        hosts[i].host = h
        hosts[i].username = u
        hosts[i].nickname = n.isEmpty ? nil : n
        hosts[i].authKind = newKind
        hosts[i].session = sessionTarget.name
        persist()
        return .updated
    }

    /// The private key for a saved host, from the Keychain. Nil if missing/unreadable
    /// — the caller must treat that as "cannot reconnect", not "empty key".
    func key(for host: SavedHost) -> String? { keychain.load(account: host.id.uuidString) }

    /// The password for a saved host, from the Keychain. Nil if missing/unreadable.
    func password(for host: SavedHost) -> String? { passwordKeychain.load(account: host.id.uuidString) }

    /// Removes a saved host. Deletes the secret from BOTH stores first and drops the
    /// host record ONLY if both confirm it is gone — a failed Keychain delete must not
    /// leave a secret orphaned while the host vanishes from the UI. Each delete returns
    /// true on errSecItemNotFound, so a host with only one secret still deletes cleanly.
    /// Returns whether it removed; on false the row stays put so the user can retry.
    @discardableResult
    func delete(_ host: SavedHost) -> Bool {
        guard keychain.delete(account: host.id.uuidString),
              passwordKeychain.delete(account: host.id.uuidString) else { return false }
        hosts.removeAll { $0.id == host.id }
        persist()
        return true
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(hosts) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}

/// A Keychain store for per-host secrets (the private SSH key). Mirrors
/// `KeychainHostKeyPolicy`'s storage discipline — checked statuses, update-in-place
/// rather than delete-then-add — but is its own service and uses
/// `WhenUnlockedThisDeviceOnly`: a private key is more sensitive than a host-key
/// pin, so it is reachable only while the device is unlocked and NEVER syncs to
/// iCloud or another device. The secret is only ever returned by `load`; it is
/// never logged or surfaced elsewhere.
struct KeychainCredentialStore {
    let service: String

    @discardableResult
    func save(account: String, secret: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Update the value IN PLACE if the item exists (no window where the key is
        // absent); only add when there is nothing to update. Every status checked.
        let updated = SecItemUpdate(base as CFDictionary,
                                    [kSecValueData as String: Data(secret.utf8)] as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }
        var add = base
        add[kSecValueData as String] = Data(secret.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let secret = String(data: data, encoding: .utf8) else { return nil }
        return secret
    }

    /// Deletes the secret. Returns true only when it is actually GONE — errSecSuccess
    /// (deleted) or errSecItemNotFound (already absent). Any other OSStatus (e.g. the
    /// Keychain temporarily unavailable) returns false, so the caller does not drop the
    /// host record while the key still lives here.
    @discardableResult
    func delete(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
