import Foundation
import Security
import Darwin
import HerdrKit

/// Device-local, cross-launch TOFU. A changed SSH host key fails closed before
/// authentication; fingerprints contain no credential material.
final class CompanionHostKeyPolicy: HostKeyPolicy, @unchecked Sendable {
    static let shared = CompanionHostKeyPolicy()

    private let lock = NSLock()
    let service: String

    init(service: String = "com.elysium.herdrcompanion.hostkeys") {
        self.service = service
    }

    func evaluate(host: String, port: UInt16, presented: String) -> HostKeyDecision {
        lock.lock()
        defer { lock.unlock() }
        let account = accountKey(host: host, port: port)
        switch lookup(account: account) {
        case .found(let existing): return existing == presented ? .trust : .reject
        case .notFound: return store(account: account, fingerprint: presented) ? .trust : .reject
        case .error: return .reject
        }
    }

    func pinnedFingerprint(host: String, port: UInt16) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard case .found(let fingerprint) = lookup(account: accountKey(host: host, port: port))
        else { return nil }
        return fingerprint
    }

    /// Replaces a changed pin only after the UI has shown both values and the
    /// person explicitly approves. The expected old value makes confirmation
    /// race-safe if trust changes while the alert is open.
    func replacePin(
        host: String, port: UInt16, expected: String, presented: String
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let account = accountKey(host: host, port: port)
        guard case .found(let current) = lookup(account: account), current == expected else {
            return false
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let values = [kSecValueData as String: Data(presented.utf8)]
        return SecItemUpdate(query as CFDictionary, values as CFDictionary) == errSecSuccess
    }

    private func accountKey(host: String, port: UInt16) -> String {
        var host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if let canonical = canonicalIPv6(host) {
            host = canonical
        } else {
            host = host.lowercased()
            while host.hasSuffix(".") { host.removeLast() }
        }
        return "\(host):\(port)"
    }

    private func canonicalIPv6(_ value: String) -> String? {
        let parts = value.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
        var address = in6_addr()
        guard String(parts[0]).withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else {
            return nil
        }
        var result = String(cString: buffer)
        if parts.count == 2 { result += "%" + parts[1].lowercased() }
        return result
    }

    private enum Lookup { case found(String), notFound, error }

    private func lookup(account: String) -> Lookup {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &item) {
        case errSecSuccess:
            guard let data = item as? Data,
                  let value = String(data: data, encoding: .utf8) else { return .error }
            return .found(value)
        case errSecItemNotFound: return .notFound
        default: return .error
        }
    }

    private func store(account: String, fingerprint: String) -> Bool {
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(fingerprint.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }
}
