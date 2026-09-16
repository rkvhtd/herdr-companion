// Modified from Herdrup https://github.com/jerryfane/herdrup commit 93c6578666e656c3206661389e81853bcc0b88da by Elysium Technologies.
import XCTest

/// README relative links and the named companion sources must exist.
final class ReadmeLayoutTests: XCTestCase {
    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testReadmeRelativeLinksExist() throws {
        let root = repoRoot()
        let readme = try String(
            contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)
        var named: [String] = []
        var cursor = readme.startIndex
        while let start = readme[cursor...].range(of: "](") {
            let after = start.upperBound
            guard let end = readme[after...].firstIndex(of: ")") else { break }
            let target = String(readme[after..<end])
            cursor = end
            guard !target.hasPrefix("http"), !target.hasPrefix("mailto:"),
                  !target.hasPrefix("#") else { continue }
            let path = String(target.split(separator: "#", maxSplits: 1).first ?? "")
            if !path.isEmpty { named.append(path) }
        }
        XCTAssertFalse(named.isEmpty, "README has no relative links to check")
        let missing = named.filter {
            !FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path)
        }
        XCTAssertTrue(missing.isEmpty,
                      "README relative links that do not exist: \(missing.joined(separator: ", "))")
    }

    func testReadmeNamedCompanionSourcesExist() throws {
        let root = repoRoot()
        let required = [
            "LICENSE",
            "NOTICE",
            "project.yml",
            "Package.swift",
            "docs/notifications-setup.md",
            "docs/notifications-protocol.md",
            "App/CompanionApp.swift",
            "App/Assets.xcassets/ATTRIBUTION.md",
            "Sources/HerdrKit",
            "Sources/HerdrNotificationHelper",
            "Sources/HerdrNotificationHelperCore",
            "Tests/HerdrCompanionTests",
            "Tests/HerdrCompanionUITests",
            "Tests/HerdrNotificationHelperTests",
            "Vendor/SwiftTerm/LICENSE",
        ]
        let missing = required.filter {
            !FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path)
        }
        XCTAssertTrue(missing.isEmpty,
                      "README-named paths missing: \(missing.joined(separator: ", "))")
    }
}
