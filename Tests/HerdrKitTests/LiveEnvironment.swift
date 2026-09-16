// Modified from Herdrup https://github.com/jerryfane/herdrup commit 93c6578666e656c3206661389e81853bcc0b88da by Elysium Technologies.
import XCTest
import Foundation
@testable import HerdrKit

/// Opt-in disposable-fixture gate for tests that would otherwise touch a real SSH
/// server or Herdr socket. Default `swift test` must never read workstation SSH
/// keys, login names, port 22, or the official default session socket.
enum LiveEnvironment {
    struct Fixture {
        let credentials: SSHCredentials
        let socketPath: String
    }

    struct Parsed: Equatable {
        let keyURL: URL
        let host: String
        let port: UInt16
        let username: String
        let sessionName: String
        let socketPath: String
    }

    enum Refusal: Error, Equatable, CustomStringConvertible {
        case missingOptIn
        case missingField(String)
        case invalidFixtureRoot
        case invalidKeyPath
        case nonLoopbackHost
        case defaultSSHPort
        case defaultSession
        case socketOutsideFixture
        case unreadableKey

        var description: String {
            switch self {
            case .missingOptIn:
                return "set HERDR_COMPANION_LIVE_SSH=1 with disposable fixture variables"
            case .missingField(let name):
                return "missing required \(name)"
            case .invalidFixtureRoot:
                return "fixture root must be an isolated /private/tmp/herdr-companion-ssh-fixture.* directory"
            case .invalidKeyPath:
                return "only the fixture client_ed25519 key inside that directory is allowed"
            case .nonLoopbackHost:
                return "live SSH host must be loopback"
            case .defaultSSHPort:
                return "fixture port must be explicit and non-default"
            case .defaultSession:
                return "refusing a default Herdr session"
            case .socketOutsideFixture:
                return "fixture socket must live inside the isolated fixture directory"
            case .unreadableKey:
                return "fixture private key is unreadable"
            }
        }
    }

    static func parse(env: [String: String]) throws -> Parsed {
        guard env["HERDR_COMPANION_LIVE_SSH"] == "1" else {
            throw Refusal.missingOptIn
        }
        func required(_ name: String) throws -> String {
            guard let value = env[name], !value.isEmpty else {
                throw Refusal.missingField(name)
            }
            return value
        }

        let root = URL(fileURLWithPath: try required("HERDR_COMPANION_FIXTURE_ROOT"))
            .standardizedFileURL
        let fixtureParent = root.deletingLastPathComponent().path
        guard root.lastPathComponent.hasPrefix("herdr-companion-ssh-fixture."),
              fixtureParent == "/private/tmp" || fixtureParent == "/tmp" else {
            throw Refusal.invalidFixtureRoot
        }
        let key = root.appendingPathComponent("client_ed25519")
        let rootPath = root.path
        // Compare paths, not URL values: `deletingLastPathComponent()` is a
        // directory URL and is not Equal to a non-directory root URL.
        guard key.lastPathComponent == "client_ed25519",
              key.path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/"),
              key.deletingLastPathComponent().path == rootPath else {
            throw Refusal.invalidKeyPath
        }
        let host = try required("HERDR_COMPANION_FIXTURE_HOST")
        guard host == "127.0.0.1" else { throw Refusal.nonLoopbackHost }
        guard let port = UInt16(try required("HERDR_COMPANION_FIXTURE_PORT")), port != 22 else {
            throw Refusal.defaultSSHPort
        }
        let username = try required("HERDR_COMPANION_FIXTURE_USER")
        let sessionName = try required("HERDR_COMPANION_FIXTURE_SESSION")
        guard sessionName != OfficialHerdrSession.defaultName,
              sessionName.hasPrefix("hc-companion-test-"),
              OfficialHerdrSession(name: sessionName) != nil else {
            throw Refusal.defaultSession
        }
        let socketPath = URL(fileURLWithPath: try required("HERDR_COMPANION_FIXTURE_SOCKET"))
            .standardizedFileURL.path
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard socketPath.hasPrefix(prefix) else {
            throw Refusal.socketOutsideFixture
        }
        return Parsed(
            keyURL: key, host: host, port: port, username: username,
            sessionName: sessionName, socketPath: socketPath)
    }

    static func requireFixture() throws -> Fixture {
        let parsed: Parsed
        do {
            parsed = try parse(env: ProcessInfo.processInfo.environment)
        } catch let refusal as Refusal {
            throw XCTSkip(refusal.description)
        }
        let resolvedKey = parsed.keyURL.resolvingSymlinksInPath()
        let prefix = parsed.keyURL.deletingLastPathComponent().path + "/"
        guard resolvedKey.path.hasPrefix(prefix),
              FileManager.default.isReadableFile(atPath: resolvedKey.path),
              let keyText = try? String(contentsOf: resolvedKey, encoding: .utf8),
              !keyText.isEmpty else {
            throw XCTSkip(Refusal.unreadableKey.description)
        }
        return Fixture(
            credentials: SSHCredentials(
                host: parsed.host, port: parsed.port, username: parsed.username,
                privateKeyPEM: keyText, remoteSocketPath: parsed.socketPath,
                herdrSession: parsed.sessionName),
            socketPath: parsed.socketPath)
    }

    static func requireLiveCredentials() throws -> SSHCredentials {
        try requireFixture().credentials
    }

    /// Unix-socket live tests: validated fixture socket path only. Does not
    /// read SSH private-key bytes.
    static func requireFixtureSocket() throws -> String {
        let parsed: Parsed
        do {
            parsed = try parse(env: ProcessInfo.processInfo.environment)
        } catch let refusal as Refusal {
            throw XCTSkip(refusal.description)
        }
        return parsed.socketPath
    }
}
