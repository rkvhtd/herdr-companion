import Foundation
import CryptoKit
import HerdrKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

func secureAPNSPrivateKeyData(at path: String) throws -> Data {
    let descriptor = open(path, O_RDONLY | O_NOFOLLOW)
    guard descriptor >= 0 else { throw APNSError.invalidSigningKey }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    var info = stat()
    guard fstat(descriptor, &info) == 0,
          (info.st_mode & S_IFMT) == S_IFREG,
          info.st_uid == getuid(),
          (info.st_mode & 0o077) == 0,
          info.st_size > 0, info.st_size <= 16 * 1024,
          let data = try? handle.readToEnd(), !data.isEmpty, data.count <= 16 * 1024 else {
        throw APNSError.invalidSigningKey
    }
    return data
}

public protocol APNSAuthorizationProviding: Sendable {
    func bearerToken(nowUnixSeconds: UInt64) async throws -> String
}

public actor APNSProviderToken: APNSAuthorizationProviding {
    private let configuration: APNSConfiguration
    private var cached: (token: String, issuedAt: UInt64)?

    public init(configuration: APNSConfiguration) { self.configuration = configuration }

    public func bearerToken(nowUnixSeconds: UInt64) async throws -> String {
        if let cached, nowUnixSeconds >= cached.issuedAt,
           nowUnixSeconds - cached.issuedAt < 50 * 60 {
            return cached.token
        }
        let keyData = try secureAPNSPrivateKeyData(at: configuration.privateKeyPath)
        guard let pem = String(data: keyData, encoding: .utf8) else {
            throw APNSError.invalidSigningKey
        }
        let key = try P256.Signing.PrivateKey(pemRepresentation: pem)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let header = try Self.base64URL(encoder.encode([
            "alg": "ES256", "kid": configuration.keyID,
        ]))
        let claims = try Self.base64URL(encoder.encode(Claims(
            iss: configuration.teamID, iat: nowUnixSeconds)))
        let unsigned = header + "." + claims
        let signature = try key.signature(for: Data(unsigned.utf8)).rawRepresentation
        let token = unsigned + "." + Self.base64URL(signature)
        cached = (token, nowUnixSeconds)
        return token
    }

    private struct Claims: Codable { let iss: String; let iat: UInt64 }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public protocol APNSRequestTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionAPNSTransport: APNSRequestTransport {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        self.session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APNSError.invalidResponse }
        return (data, http)
    }
}

public enum APNSDeliveryResult: Equatable, Sendable {
    case delivered
    case permanentlyRejectedToken(String)
    case rejected(String)
    case authenticationFailed(String)
    case retryExhausted(String)
}

public enum APNSError: Error {
    case invalidSigningKey
    case invalidResponse
    case invalidPayload
}

public actor APNSClient {
    public typealias Sleep = @Sendable (UInt64) async throws -> Void

    private let configuration: APNSConfiguration
    private let authorization: any APNSAuthorizationProviding
    private let transport: any APNSRequestTransport
    private let sleep: Sleep

    public init(
        configuration: APNSConfiguration,
        authorization: (any APNSAuthorizationProviding)? = nil,
        transport: any APNSRequestTransport = URLSessionAPNSTransport(),
        sleep: @escaping Sleep = { try await Task.sleep(nanoseconds: $0) }
    ) {
        self.configuration = configuration
        self.authorization = authorization ?? APNSProviderToken(configuration: configuration)
        self.transport = transport
        self.sleep = sleep
    }

    public func send(
        _ destination: NotificationDestination,
        nowUnixSeconds: UInt64
    ) async -> APNSDeliveryResult {
        var lastReason = "transport failure"
        for attempt in 0..<3 {
            do {
                let request = try await makeRequest(destination, nowUnixSeconds: nowUnixSeconds)
                let (data, response) = try await transport.send(request)
                let reason = Self.responseReason(data) ?? "HTTP \(response.statusCode)"
                switch response.statusCode {
                case 200:
                    return .delivered
                case 400 where ["BadDeviceToken", "DeviceTokenNotForTopic"].contains(reason),
                     410:
                    return .permanentlyRejectedToken(reason)
                case 403:
                    return .authenticationFailed(reason)
                case 429, 500, 503:
                    lastReason = reason
                    if attempt < 2 {
                        let delay = Self.retryDelayNanoseconds(response: response, attempt: attempt)
                        try await sleep(delay)
                        continue
                    }
                    return .retryExhausted(reason)
                default:
                    return .rejected(reason)
                }
            } catch is CancellationError {
                return .retryExhausted("cancelled")
            } catch APNSError.invalidSigningKey {
                return .authenticationFailed("InvalidProviderToken")
            } catch APNSError.invalidPayload {
                return .rejected("invalid payload")
            } catch {
                lastReason = "transport failure"
                if attempt < 2 {
                    try? await sleep(UInt64(1 << attempt) * 1_000_000_000)
                    continue
                }
            }
        }
        return .retryExhausted(lastReason)
    }

    public func makeRequest(
        _ destination: NotificationDestination,
        nowUnixSeconds: UInt64
    ) async throws -> URLRequest {
        let host = destination.environment == .production
            ? "api.push.apple.com" : "api.sandbox.push.apple.com"
        guard let url = URL(string: "https://\(host)/3/device/\(destination.token)") else {
            throw APNSError.invalidPayload
        }
        let route = CompanionNotificationRoute(
            kind: destination.event.kind,
            savedHostID: destination.savedHostID,
            workspaceID: destination.event.observation.workspaceID,
            paneID: destination.event.observation.paneID,
            terminalID: destination.event.observation.terminalID,
            agentInstanceBinding: destination.agentInstanceBinding,
            stateChangeSequence: destination.event.observation.stateChangeSequence,
            emittedAtUnixSeconds: nowUnixSeconds)
        let payload = Payload(
            aps: APS(alert: Alert(title: "Herdr Companion", body: destination.event.kind.message),
                     sound: "default", threadID: "herdr-agent"),
            herdr: route)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(payload)
        guard body.count <= 4_096 else { throw APNSError.invalidPayload }

        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("bearer \(try await authorization.bearerToken(nowUnixSeconds: nowUnixSeconds))",
                         forHTTPHeaderField: "authorization")
        request.setValue(configuration.topic, forHTTPHeaderField: "apns-topic")
        request.setValue("alert", forHTTPHeaderField: "apns-push-type")
        request.setValue("10", forHTTPHeaderField: "apns-priority")
        request.setValue(String(nowUnixSeconds + 15 * 60), forHTTPHeaderField: "apns-expiration")
        request.setValue(Self.collapseID(for: destination.event), forHTTPHeaderField: "apns-collapse-id")
        request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "apns-id")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        return request
    }

    private struct Payload: Encodable { let aps: APS; let herdr: CompanionNotificationRoute }
    private struct APS: Encodable {
        let alert: Alert
        let sound: String
        let threadID: String
        enum CodingKeys: String, CodingKey { case alert, sound; case threadID = "thread-id" }
    }
    private struct Alert: Encodable { let title: String; let body: String }
    private struct ErrorBody: Decodable { let reason: String }

    private static func responseReason(_ data: Data) -> String? {
        try? JSONDecoder().decode(ErrorBody.self, from: data).reason
    }

    private static func collapseID(for event: CompanionNotificationEvent) -> String {
        let digest = SHA256.hash(data: Data(event.eventID.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func retryDelayNanoseconds(response: HTTPURLResponse, attempt: Int) -> UInt64 {
        if let value = response.value(forHTTPHeaderField: "retry-after"),
           let seconds = UInt64(value), seconds <= 30 {
            return seconds * 1_000_000_000
        }
        return UInt64(1 << attempt) * 1_000_000_000
    }
}

public protocol CompanionNotificationSending: Sendable {
    func send(
        _ destination: NotificationDestination,
        nowUnixSeconds: UInt64
    ) async -> APNSDeliveryResult
}

extension APNSClient: CompanionNotificationSending {}
