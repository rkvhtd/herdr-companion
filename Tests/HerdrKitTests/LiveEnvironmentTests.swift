import XCTest
@testable import HerdrKit

final class LiveEnvironmentTests: XCTestCase {
    private let fixtureRoot = "/private/tmp/herdr-companion-ssh-fixture.example"

    private func env(_ extra: [String: String] = [:]) -> [String: String] {
        var values: [String: String] = [
            "HERDR_COMPANION_LIVE_SSH": "1",
            "HERDR_COMPANION_FIXTURE_ROOT": fixtureRoot,
            "HERDR_COMPANION_FIXTURE_HOST": "127.0.0.1",
            "HERDR_COMPANION_FIXTURE_PORT": "2222",
            "HERDR_COMPANION_FIXTURE_USER": "fixture",
            "HERDR_COMPANION_FIXTURE_SESSION": "hc-companion-test-session",
            "HERDR_COMPANION_FIXTURE_SOCKET": "\(fixtureRoot)/herdr.sock",
        ]
        extra.forEach { values[$0.key] = $0.value }
        return values
    }

    func testIsolatedFixtureParsesWithoutReadingWorkstationKeys() throws {
        let parsed = try LiveEnvironment.parse(env: env())
        XCTAssertEqual(parsed.host, "127.0.0.1")
        XCTAssertEqual(parsed.port, 2222)
        XCTAssertEqual(parsed.username, "fixture")
        XCTAssertEqual(parsed.sessionName, "hc-companion-test-session")
        XCTAssertEqual(parsed.socketPath, "\(fixtureRoot)/herdr.sock")
        XCTAssertEqual(parsed.keyURL.lastPathComponent, "client_ed25519")
        XCTAssertTrue(parsed.keyURL.path.hasPrefix(fixtureRoot + "/"))
    }

    func testMissingOptInIsRefused() {
        XCTAssertThrowsError(try LiveEnvironment.parse(env: [:])) { error in
            XCTAssertEqual(error as? LiveEnvironment.Refusal, .missingOptIn)
        }
    }

    func testAmbientSocketPathIsNotAnOptIn() {
        XCTAssertThrowsError(try LiveEnvironment.parse(env: [
            "HERDR_SOCKET_PATH": "/private/tmp/not-a-reason-to-connect.sock",
        ])) { error in
            XCTAssertEqual(error as? LiveEnvironment.Refusal, .missingOptIn)
        }
    }

    func testPort22IsRefused() {
        XCTAssertThrowsError(try LiveEnvironment.parse(env: env([
            "HERDR_COMPANION_FIXTURE_PORT": "22",
        ]))) { error in
            XCTAssertEqual(error as? LiveEnvironment.Refusal, .defaultSSHPort)
        }
    }

    func testNonLoopbackHostIsRefused() {
        XCTAssertThrowsError(try LiveEnvironment.parse(env: env([
            "HERDR_COMPANION_FIXTURE_HOST": "example.invalid",
        ]))) { error in
            XCTAssertEqual(error as? LiveEnvironment.Refusal, .nonLoopbackHost)
        }
    }

    func testDefaultSessionIsRefused() {
        XCTAssertThrowsError(try LiveEnvironment.parse(env: env([
            "HERDR_COMPANION_FIXTURE_SESSION": "default",
        ]))) { error in
            XCTAssertEqual(error as? LiveEnvironment.Refusal, .defaultSession)
        }
    }

    func testWorkstationSSHKeyPathIsRefused() {
        XCTAssertThrowsError(try LiveEnvironment.parse(env: env([
            "HERDR_COMPANION_FIXTURE_ROOT": "/Users/fixture/.ssh",
        ]))) { error in
            XCTAssertEqual(error as? LiveEnvironment.Refusal, .invalidFixtureRoot)
        }
    }

    func testDefaultHerdrSocketIsRefused() {
        XCTAssertThrowsError(try LiveEnvironment.parse(env: env([
            "HERDR_COMPANION_FIXTURE_SOCKET": "/Users/fixture/.config/herdr/herdr.sock",
        ]))) { error in
            XCTAssertEqual(error as? LiveEnvironment.Refusal, .socketOutsideFixture)
        }
    }

    func testRequireLiveCredentialsSkipsWithoutOptIn() {
        do {
            _ = try LiveEnvironment.parse(env: ProcessInfo.processInfo.environment)
            if ProcessInfo.processInfo.environment["HERDR_COMPANION_LIVE_SSH"] != "1" {
                XCTFail("parse must refuse when the opt-in is unset")
            }
        } catch LiveEnvironment.Refusal.missingOptIn {
            XCTAssertNotEqual(ProcessInfo.processInfo.environment["HERDR_COMPANION_LIVE_SSH"], "1")
        } catch {
            if ProcessInfo.processInfo.environment["HERDR_COMPANION_LIVE_SSH"] != "1" {
                XCTFail("expected missingOptIn, got \(error)")
            }
        }
    }
}
