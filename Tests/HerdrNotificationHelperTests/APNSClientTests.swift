import XCTest
import Foundation
import CryptoKit
import HerdrKit
@testable import HerdrNotificationHelperCore

final class APNSClientTests: XCTestCase {
    private let now: UInt64 = 1_800_000_000

    func testRequestUsesCorrectEndpointHeadersGenericPayloadAndOpaqueRouting() async throws {
        let transport = RecordingAPNSTransport(responses: [response(status: 200)])
        let client = APNSClient(
            configuration: configuration,
            authorization: FixedAuthorization(), transport: transport, sleep: { _ in })
        let destination = makeDestination(environment: .production)

        let result = await client.send(destination, nowUnixSeconds: now)
        XCTAssertEqual(result, .delivered)
        let recordedRequests = await transport.requests
        let request = try XCTUnwrap(recordedRequests.first)
        XCTAssertEqual(request.url?.host, "api.push.apple.com")
        XCTAssertEqual(request.url?.path, "/3/device/" + destination.token)
        XCTAssertEqual(request.value(forHTTPHeaderField: "authorization"), "bearer fixed.jwt")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apns-topic"), "com.elysium.herdrcompanion")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apns-push-type"), "alert")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apns-priority"), "10")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apns-expiration"), String(now + 900))
        XCTAssertEqual(request.value(forHTTPHeaderField: "apns-collapse-id")?.count, 64)

        let body = try XCTUnwrap(request.httpBody)
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("Needs your attention"))
        XCTAssertTrue(text.contains(destination.savedHostID.lowercased()))
        XCTAssertTrue(text.contains("terminal-1"))
        XCTAssertTrue(text.contains(destination.agentInstanceBinding))
        XCTAssertFalse(text.contains("/Users/fixture/.codex/sessions/private.jsonl"),
                       "raw official agent-session identity must not enter APNs")
        for forbidden in ["/Users/", "tailscale", "ssh", "prompt", "output", "private_key", "username"] {
            XCTAssertFalse(text.lowercased().contains(forbidden.lowercased()))
        }
    }

    func testSandboxEndpointAndBoundedRetry() async {
        let transport = RecordingAPNSTransport(responses: [
            response(status: 503, reason: "ServiceUnavailable"),
            response(status: 429, reason: "TooManyRequests"),
            response(status: 200),
        ])
        let delays = DelayRecorder()
        let client = APNSClient(
            configuration: configuration,
            authorization: FixedAuthorization(), transport: transport,
            sleep: { await delays.record($0) })
        let result = await client.send(
            makeDestination(environment: .development), nowUnixSeconds: now)
        XCTAssertEqual(result, .delivered)
        let recordedRequests = await transport.requests
        let recordedDelays = await delays.values
        XCTAssertEqual(recordedRequests.count, 3)
        XCTAssertEqual(recordedRequests.first?.url?.host, "api.sandbox.push.apple.com")
        XCTAssertEqual(recordedDelays.count, 2)
    }

    func testPermanentTokenRejectionDoesNotRetry() async {
        let transport = RecordingAPNSTransport(responses: [
            response(status: 410, reason: "Unregistered"), response(status: 200),
        ])
        let client = APNSClient(
            configuration: configuration,
            authorization: FixedAuthorization(), transport: transport, sleep: { _ in })
        let result = await client.send(makeDestination(), nowUnixSeconds: now)
        XCTAssertEqual(result, .permanentlyRejectedToken("Unregistered"))
        let recordedRequests = await transport.requests
        XCTAssertEqual(recordedRequests.count, 1)
    }

    func testProviderTokenRequiresPrivateUserOwnedSigningKey() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hc-companion-test-apns-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let keyURL = root.appendingPathComponent("AuthKey.p8")
        try Data(P256.Signing.PrivateKey().pemRepresentation.utf8)
            .write(to: keyURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        let privateConfiguration = APNSConfiguration(
            teamID: "YOURTEAMID", keyID: "ABCDEFGHIJ",
            topic: "com.elysium.herdrcompanion", privateKeyPath: keyURL.path)
        let token = try await APNSProviderToken(configuration: privateConfiguration)
            .bearerToken(nowUnixSeconds: now)
        XCTAssertEqual(token.split(separator: ".").count, 3)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: keyURL.path)
        do {
            _ = try await APNSProviderToken(configuration: privateConfiguration)
                .bearerToken(nowUnixSeconds: now)
            XCTFail("a group/world-readable signing key must be rejected")
        } catch APNSError.invalidSigningKey {
            // Expected.
        }
    }

    private var configuration: APNSConfiguration {
        APNSConfiguration(
            teamID: "YOURTEAMID", keyID: "ABCDEFGHIJ",
            topic: "com.elysium.herdrcompanion", privateKeyPath: "/private/test/key.p8")
    }

    private func makeDestination(
        environment: APNSEnvironment = .development
    ) -> NotificationDestination {
        let observation = NotificationAgentObservation(
            session: "default", workspaceID: "w1", paneID: "w1:p1",
            terminalID: "terminal-1", agentInstanceID: String(repeating: "c", count: 64),
            status: "blocked", stateChangeSequence: 8,
            agentSession: AgentSessionInfo(
                source: "herdr:test", agent: "codex", kind: "path",
                value: "/Users/fixture/.codex/sessions/private.jsonl"))
        return NotificationDestination(
            deviceID: UUID().uuidString, token: String(repeating: "ab", count: 32),
            environment: environment, savedHostID: UUID().uuidString.lowercased(),
            agentInstanceBinding: String(repeating: "d", count: 64),
            event: CompanionNotificationEvent(kind: .needsAttention, observation: observation))
    }

    private func response(status: Int, reason: String? = nil) -> RecordedResponse {
        let data = reason.map { try! JSONEncoder().encode(["reason": $0]) } ?? Data()
        let response = HTTPURLResponse(
            url: URL(string: "https://api.push.apple.com")!, statusCode: status,
            httpVersion: "HTTP/2", headerFields: nil)!
        return RecordedResponse(data: data, response: response)
    }
}

private struct FixedAuthorization: APNSAuthorizationProviding {
    func bearerToken(nowUnixSeconds: UInt64) async throws -> String { "fixed.jwt" }
}

private struct RecordedResponse: Sendable {
    let data: Data
    let response: HTTPURLResponse
}

private actor RecordingAPNSTransport: APNSRequestTransport {
    private var responses: [RecordedResponse]
    private(set) var requests: [URLRequest] = []

    init(responses: [RecordedResponse]) { self.responses = responses }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let next = responses.removeFirst()
        return (next.data, next.response)
    }
}

private actor DelayRecorder {
    private(set) var values: [UInt64] = []
    func record(_ value: UInt64) { values.append(value) }
}
