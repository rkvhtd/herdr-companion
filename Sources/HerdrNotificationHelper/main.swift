import Foundation
import Dispatch
import HerdrKit
import HerdrNotificationHelperCore

@main
enum HerdrNotificationHelperMain {
    static func main() async {
        let mode = CommandLine.arguments.dropFirst().first ?? "run"
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let store = NotificationHelperStateStore(
            paths: NotificationHelperPaths.standard(home: home))
        switch mode {
        case "rpc":
            await runRPC(store: store)
        case "run":
            await runDaemon(store: store)
        default:
            writeResponse(NotificationHelperResponse(
                ok: false, code: "invalid_mode", message: "Use run or rpc."))
            Foundation.exit(64)
        }
    }

    private static func runRPC(store: NotificationHelperStateStore) async {
        do {
            let input = try readRequestLine()
            let response = await NotificationHelperRPCService(store: store).handle(input)
            writeResponse(response)
            if !response.ok { Foundation.exit(1) }
        } catch {
            writeResponse(NotificationHelperResponse(
                ok: false, code: "invalid_input", message: "Could not read a bounded request."))
            Foundation.exit(1)
        }
    }

    private static func runDaemon(store: NotificationHelperStateStore) async {
        do {
            guard let configuration = try store.loadConfiguration() else {
                FileHandle.standardError.write(Data(
                    "Herdr notification helper is not configured.\n".utf8))
                Foundation.exit(78)
            }
            let sender = APNSClient(configuration: configuration)
            let environment = ProcessInfo.processInfo.environment
            let home = environment["HOME"] ?? NSHomeDirectory()
            let configRoot = environment["XDG_CONFIG_HOME"] ?? "\(home)/.config"
            let daemon = NotificationHelperDaemon(store: store) { session in
                let socketPath: String
                if session == OfficialHerdrSession.defaultName {
                    socketPath = "\(configRoot)/herdr/herdr.sock"
                } else {
                    socketPath = "\(configRoot)/herdr/sessions/\(session)/herdr.sock"
                }
                return HerdrNotificationSessionWatcher(
                    session: session, store: store,
                    clientFactory: {
                        HerdrClient(transport: UnixSocketTransport(path: socketPath))
                    }, sender: sender)
            }

            let task = Task { try await daemon.run() }
            let signals = [SIGTERM, SIGINT].map { signalNumber -> DispatchSourceSignal in
                signal(signalNumber, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: signalNumber)
                source.setEventHandler { task.cancel() }
                source.resume()
                return source
            }
            _ = signals
            FileHandle.standardError.write(Data("Herdr notification helper started.\n".utf8))
            try await task.value
        } catch is CancellationError {
            return
        } catch {
            FileHandle.standardError.write(Data("Herdr notification helper stopped.\n".utf8))
            Foundation.exit(1)
        }
    }

    private static func readRequestLine() throws -> Data {
        var data = Data()
        while data.count <= NotificationHelperProtocol.maximumRequestBytes {
            // Darwin's `readData(ofLength:)` waits for the requested byte count
            // or EOF. Reading one byte makes newline itself the frame boundary,
            // so a short SSH request is handled while the channel stdin remains
            // open instead of deadlocking until a 1 KiB buffer fills.
            let chunk = FileHandle.standardInput.readData(ofLength: 1)
            if chunk.isEmpty { break }
            data.append(chunk)
            if let newline = data.firstIndex(of: 0x0a) {
                data = data[..<newline]
                break
            }
        }
        guard !data.isEmpty, data.count <= NotificationHelperProtocol.maximumRequestBytes else {
            throw InputError.invalid
        }
        return data
    }

    private static func writeResponse(_ response: NotificationHelperResponse) {
        guard let data = try? JSONEncoder().encode(response),
              data.count <= NotificationHelperProtocol.maximumResponseBytes else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0a]))
    }

    private enum InputError: Error { case invalid }
}
