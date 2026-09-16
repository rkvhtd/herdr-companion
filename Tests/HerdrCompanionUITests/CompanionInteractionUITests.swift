import XCTest

final class CompanionInteractionUITests: XCTestCase {
    private let draftID = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    private let uploadID = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
    private let unknownID = "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"
    private let studioID = "11111111-1111-1111-1111-111111111111"

    override func setUp() {
        continueAfterFailure = false
    }

    /// File dumps are off unless `HERDR_COMPANION_UI_EVIDENCE_DIR` is set.
    /// XCTest attachments remain the default evidence surface.
    private var evidenceDirectory: URL? {
        guard let raw = ProcessInfo.processInfo.environment["HERDR_COMPANION_UI_EVIDENCE_DIR"],
              !raw.isEmpty else { return nil }
        return URL(fileURLWithPath: raw, isDirectory: true)
    }

    private func launch(_ fixture: String, largeText: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--companion-visual-fixture=\(fixture)"]
        if largeText {
            app.launchArguments += [
                "-UIPreferredContentSizeCategoryName",
                "UICTContentSizeCategoryAccessibilityL"
            ]
        }
        app.launch()
        dismissSystemBanners()
        return app
    }

    private func dismissSystemBanners() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let look = springboard.otherElements["NotificationShortLookView"]
            if look.exists {
                look.swipeUp()
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                continue
            }
            let intelligence = springboard.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS[c] %@", "Intelligence")
            ).firstMatch
            if intelligence.exists {
                intelligence.swipeUp()
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                continue
            }
            break
        }
    }

    private func tapRecoveryEntry(_ app: XCUIApplication, stage: String) {
        dismissSystemBanners()
        let entry = waitUnique(app, "companion-recovery-entry", timeout: 8, stage: stage)
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline, !entry.isHittable {
            dismissSystemBanners()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertTrue(entry.isHittable, "\(stage) recovery entry must be hittable")
        entry.tap()
    }

    private func dumpStage(_ app: XCUIApplication, _ stage: String, extra: String = "") {
        let blob = "stage=\(stage)\n\(extra)\nconnection=\(probeDisplay(app, "companion-fixture-connection"))\nhost=\(probeDisplay(app, "companion-fixture-host"))\ngeneration=\(probeDisplay(app, "companion-fixture-generation"))\nreceipts=\(probeDisplay(app, "companion-fixture-receipts"))\nupload=\(probeDisplay(app, "companion-fixture-upload"))\ncleanup=\(probeDisplay(app, "companion-fixture-cleanup"))\nsessions=\(probeDisplay(app, "companion-fixture-sessions"))\nsession-target=\(probeDisplay(app, "companion-fixture-session-target"))\npresenting=\(probeDisplay(app, "companion-fixture-presenting"))\n\(app.debugDescription)"
        print(blob)
        let attachment = XCTAttachment(string: blob)
        attachment.name = stage
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = evidenceDirectory {
            let fileStage = stage.replacingOccurrences(of: "/", with: "-")
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? blob.write(
                to: directory.appendingPathComponent("ui-\(fileStage).txt"),
                atomically: true,
                encoding: .utf8)
        }
    }

    private enum ProbeRead: Equatable {
        case unavailable(String)
        case value(String)
    }

    private func readProbe(_ app: XCUIApplication, _ identifier: String) -> ProbeRead {
        let query = app.descendants(matching: .any).matching(identifier: identifier)
        let count = query.count
        guard count == 1 else { return .unavailable("count=\(count)") }
        let element = query.element(boundBy: 0)
        guard element.exists else { return .unavailable("missing") }
        guard let value = element.value as? String else { return .unavailable("unreadable") }
        return .value(value)
    }

    private func probeDisplay(_ app: XCUIApplication, _ identifier: String) -> String {
        switch readProbe(app, identifier) {
        case .unavailable(let reason):
            return "unavailable(\(reason))"
        case .value(let value):
            return value
        }
    }

    private func waitUnique(
        _ app: XCUIApplication, _ identifier: String, timeout: TimeInterval, stage: String
    ) -> XCUIElement {
        waitUniqueQuery(
            app.descendants(matching: .any).matching(identifier: identifier),
            identifier: identifier, timeout: timeout, stage: stage, app: app)
    }

    private func waitUniqueButton(
        _ app: XCUIApplication, _ identifier: String, timeout: TimeInterval, stage: String
    ) -> XCUIElement {
        waitUniqueQuery(
            app.buttons.matching(identifier: identifier),
            identifier: identifier, timeout: timeout, stage: stage, app: app)
    }

    private func waitUniqueQuery(
        _ query: XCUIElementQuery, identifier: String, timeout: TimeInterval, stage: String,
        app: XCUIApplication
    ) -> XCUIElement {
        let first = query.element(boundBy: 0)
        if !first.waitForExistence(timeout: timeout) {
            dumpStage(app, stage)
            XCTFail(stage)
        }
        let count = query.count
        if count != 1 {
            dumpStage(app, "\(stage)-not-unique", extra: "count=\(count)")
            XCTFail("\(stage) expected unique \(identifier), found \(count)")
        }
        return first
    }

    private func waitProbe(
        _ app: XCUIApplication, _ identifier: String, timeout: TimeInterval, stage: String,
        _ match: @escaping (String) -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if case .value(let value) = readProbe(app, identifier), match(value) {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }
        dumpStage(app, stage, extra: "read=\(probeDisplay(app, identifier))")
        XCTFail(stage)
    }

    private func requireProbeValue(
        _ app: XCUIApplication, _ identifier: String, stage: String
    ) -> String {
        switch readProbe(app, identifier) {
        case .value(let value):
            return value
        case .unavailable(let reason):
            dumpStage(app, stage, extra: "unavailable=\(reason)")
            XCTFail(stage)
            return ""
        }
    }
    private func toolbarClose(_ app: XCUIApplication) -> XCUIElement {
        let bar = app.navigationBars["Kept items"]
        let identified = bar.buttons["companion-recovery-close"]
        if identified.exists { return identified }
        return bar.buttons["Close"]
    }

    private func studioHost(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier == %@ AND label == %@",
                "companion-connect-host", "Example Mac")
        ).element(boundBy: 0)
    }

    func testRecoveryCloseReconnectAndRetryDiscard() {
        let app = launch("interaction-recovery")
        waitProbe(app, "companion-fixture-presenting", timeout: 8, stage: "recovery-idle") {
            $0 == "dismissed"
        }
        waitProbe(app, "companion-fixture-receipts", timeout: 8, stage: "recovery-seeded") {
            $0.localizedCaseInsensitiveContains(self.uploadID) && $0.localizedCaseInsensitiveContains(self.draftID)
        }
        tapRecoveryEntry(app, stage: "recovery-entry-control")
        XCTAssertEqual(
            app.descendants(matching: .any).matching(identifier: "companion-recovery-entry").count, 1)
        let sheet = waitUnique(app, "companion-recovery-sheet", timeout: 8, stage: "recovery-sheet-presented")
        waitProbe(app, "companion-fixture-presenting", timeout: 8, stage: "recovery-presented") {
            $0 == "presented"
        }
        let close = toolbarClose(app)
        if !close.waitForExistence(timeout: 8) {
            dumpStage(app, "close-control-ready")
            XCTFail("close-control-ready")
        }
        close.tap()
        waitProbe(app, "companion-fixture-presenting", timeout: 8, stage: "close-dismissed") {
            $0 == "dismissed"
        }
        XCTAssertFalse(sheet.waitForExistence(timeout: 1), "close-dismissed-sheet")
        waitProbe(app, "companion-fixture-receipts", timeout: 8, stage: "receipts-kept-after-close") {
            $0.localizedCaseInsensitiveContains(self.uploadID) && $0.localizedCaseInsensitiveContains(self.draftID)
        }
        let host = studioHost(app)
        if !host.waitForExistence(timeout: 10) {
            dumpStage(app, "saved-host-control-ready")
            XCTFail("saved-host-control-ready")
        }
        XCTAssertEqual(
            app.descendants(matching: .any).matching(
                NSPredicate(
                    format: "identifier == %@ AND label == %@",
                    "companion-connect-host", "Example Mac")
            ).count,
            1,
            "saved-host-not-unique")
        host.tap()
        waitProbe(app, "companion-fixture-connection", timeout: 12, stage: "original-host-connected") {
            $0 == "connected"
        }
        waitProbe(app, "companion-fixture-host", timeout: 8, stage: "original-host-identity") {
            $0.localizedCaseInsensitiveCompare(self.studioID) == .orderedSame
        }
        tapRecoveryEntry(app, stage: "recovery-reopen-entry")
        _ = waitUnique(app, "companion-recovery-sheet", timeout: 8, stage: "recovery-reopened")
        var retry = app.buttons["companion-recovery-retry"]
        if !retry.waitForExistence(timeout: 3) {
            let sheet = app.descendants(matching: .any)["companion-recovery-sheet"]
            if sheet.exists {
                sheet.swipeUp()
                sheet.swipeUp()
            } else {
                app.swipeUp()
            }
            retry = app.buttons["companion-recovery-retry"]
        }
        if !retry.waitForExistence(timeout: 8) {
            dumpStage(app, "retry-control-ready")
            XCTFail("retry-control-ready")
        }
        XCTAssertEqual(app.buttons.matching(identifier: "companion-recovery-retry").count, 1)
        retry.tap()
        waitProbe(app, "companion-fixture-cleanup", timeout: 10, stage: "cleanup-finished") {
            $0.contains("removed=1")
        }
        waitProbe(app, "companion-fixture-receipts", timeout: 8, stage: "upload-receipt-removed") {
            !$0.localizedCaseInsensitiveContains(self.uploadID)
                && $0.localizedCaseInsensitiveContains(self.draftID)
        }
    }

    func testPendingUploadCancelUsesPreviewControl() {
        let app = launch("interaction-cancel")
        waitProbe(app, "companion-fixture-upload", timeout: 12, stage: "upload-started") {
            $0.contains("started=1") && $0.contains("terminal=uploading")
        }
        waitProbe(app, "companion-fixture-receipts", timeout: 8, stage: "upload-receipt-pending") {
            $0.contains("|uploading|pending|")
        }
        let before = requireProbeValue(app, "companion-fixture-receipts", stage: "upload-receipt-value")
        let flowID = before.split(separator: "|").first.map(String.init) ?? ""
        XCTAssertFalse(flowID.isEmpty, "missing uploading flow id")
        let cancel = waitUniqueButton(
            app, "companion-attachment-cancel", timeout: 12, stage: "preview-cancel-control")
        cancel.tap()
        waitProbe(app, "companion-fixture-upload", timeout: 12, stage: "upload-task-cancelled") {
            $0.contains("cancelled=1") && $0.contains("terminal=cancelled")
        }
        waitProbe(app, "companion-fixture-receipts", timeout: 8, stage: "pending-receipt-removed") {
            $0 == "empty" || !$0.localizedCaseInsensitiveContains(flowID)
        }
        let preview = app.navigationBars["Image attachment"]
        let gone = NSPredicate(format: "exists == false")
        let previewGone = expectation(for: gone, evaluatedWith: preview, handler: nil)
        wait(for: [previewGone], timeout: 8)
    }

    func testPendingUploadCancelCleanupRequiredKeepsRetry() {
        let app = launch("interaction-cancel-cleanup")
        waitProbe(app, "companion-fixture-upload", timeout: 12, stage: "cleanup-upload-started") {
            $0.contains("started=1") && $0.contains("terminal=uploading")
        }
        waitProbe(app, "companion-fixture-receipts", timeout: 8, stage: "cleanup-upload-receipt") {
            $0.contains("|uploading|pending|")
        }
        let before = requireProbeValue(app, "companion-fixture-receipts", stage: "upload-receipt-value")
        let flowID = before.split(separator: "|").first.map(String.init) ?? ""
        XCTAssertFalse(flowID.isEmpty, "missing uploading flow id")
        let cancel = waitUniqueButton(
            app, "companion-attachment-cancel", timeout: 12, stage: "preview-cancel-cleanup-control")
        cancel.tap()
        waitProbe(app, "companion-fixture-upload", timeout: 12, stage: "cleanup-upload-cancelled") {
            $0.contains("cancelled=1") && $0.contains("terminal=cleanupRequired")
        }
        waitProbe(app, "companion-fixture-receipts", timeout: 8, stage: "incomplete-cleanup-receipt") {
            $0.localizedCaseInsensitiveContains(flowID)
                && $0.contains("|resolved|incomplete|confirmed")
        }
        waitProbe(app, "companion-fixture-cleanup", timeout: 8, stage: "no-accidental-deletion") {
            $0.contains("removed=0") && $0.contains("retried=0")
        }
        let retry = app.buttons["Retry Discard"]
        if !retry.waitForExistence(timeout: 8) {
            dumpStage(app, "cancel-cleanup-required")
            XCTFail("cancel-cleanup-required")
        }
    }

    func testSceneBackgroundThenReconnectRestoresTerminal() {
        let app = launch("interaction-terminal")
        let connected = app.staticTexts["Connected · drag to scroll"]
        if !connected.waitForExistence(timeout: 12) {
            dumpStage(app, "scene-session-started")
            XCTFail("scene-session-started")
        }
        waitProbe(app, "companion-fixture-connection", timeout: 8, stage: "scene-model-connected") {
            $0 == "connected"
        }
        waitProbe(app, "companion-fixture-sessions", timeout: 8, stage: "scene-session-open") {
            $0.contains("|started") && !$0.contains("|closed")
        }
        let beforeSessions = requireProbeValue(app, "companion-fixture-sessions", stage: "scene-session-value")
        let oldID = beforeSessions.split(separator: "|").first.map(String.init) ?? ""
        XCTAssertFalse(oldID.isEmpty)
        XCUIDevice.shared.press(.home)
        sleep(2)
        app.activate()
        waitProbe(app, "companion-fixture-sessions", timeout: 12, stage: "scene-old-session-closed") {
            $0.localizedCaseInsensitiveContains(oldID) && $0.contains("|closed")
        }
        let reconnect = waitUniqueButton(
            app, "companion-terminal-reconnect", timeout: 10, stage: "scene-reconnect-control")
        reconnect.tap()
        if !connected.waitForExistence(timeout: 12) {
            dumpStage(app, "scene-new-session")
            XCTFail("scene-new-session")
        }
        waitProbe(app, "companion-fixture-sessions", timeout: 12, stage: "scene-replacement-session") {
            $0.contains("|started")
                && $0.contains("|closed")
                && !$0.split(separator: ";").filter { $0.contains("|started") }.joined()
                    .localizedCaseInsensitiveContains(oldID)
        }
    }

    func testDiscardKeptDraftRemovesExactReceipt() {
        let app = launch("interaction-discard-draft")
        waitProbe(app, "companion-fixture-receipts", timeout: 8, stage: "draft-seeded") {
            $0.localizedCaseInsensitiveContains(self.draftID) && $0.contains("|draft|")
        }
        tapRecoveryEntry(app, stage: "draft-entry")
        _ = waitUnique(app, "companion-recovery-sheet", timeout: 8, stage: "draft-sheet")
        var discard = app.buttons["companion-recovery-discard-draft"]
        if !discard.waitForExistence(timeout: 3) {
            app.swipeUp()
            discard = app.buttons["companion-recovery-discard-draft"]
        }
        if !discard.waitForExistence(timeout: 8) {
            dumpStage(app, "discard-draft-control")
            XCTFail("discard-draft-control")
        }
        discard.tap()
        waitProbe(app, "companion-fixture-receipts", timeout: 8, stage: "draft-removed") {
            $0 == "empty" || !$0.localizedCaseInsensitiveContains(self.draftID)
        }
    }

    func testFailingRetryShowsErrorAndKeepsReceipt() {
        let app = launch("interaction-retry-fail")
        tapRecoveryEntry(app, stage: "fail-entry")
        _ = waitUnique(app, "companion-recovery-sheet", timeout: 8, stage: "fail-sheet")
        toolbarClose(app).tap()
        waitProbe(app, "companion-fixture-presenting", timeout: 8, stage: "fail-closed") {
            $0 == "dismissed"
        }
        let host = studioHost(app)
        if !host.waitForExistence(timeout: 10) {
            dumpStage(app, "fail-saved-host")
            XCTFail("fail-saved-host")
        }
        host.tap()
        waitProbe(app, "companion-fixture-connection", timeout: 12, stage: "fail-connected") {
            $0 == "connected"
        }
        tapRecoveryEntry(app, stage: "fail-reopen-entry")
        _ = waitUnique(app, "companion-recovery-sheet", timeout: 8, stage: "fail-reopened")
        var retry = app.buttons["companion-recovery-retry"]
        if !retry.waitForExistence(timeout: 3) {
            app.swipeUp()
            retry = app.buttons["companion-recovery-retry"]
        }
        if !retry.waitForExistence(timeout: 8) {
            dumpStage(app, "fail-retry-control")
            XCTFail("fail-retry-control")
        }
        retry.tap()
        let error = app.descendants(matching: .any)["companion-recovery-error"]
        let errorText = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Cleanup failed")
        ).firstMatch
        if !error.waitForExistence(timeout: 8) && !errorText.waitForExistence(timeout: 4) {
            dumpStage(app, "fail-error-row")
            XCTFail("fail-error-row")
        }
        waitProbe(app, "companion-fixture-receipts", timeout: 8, stage: "fail-receipt-kept") {
            $0.localizedCaseInsensitiveContains(self.uploadID)
        }
        waitProbe(app, "companion-fixture-cleanup", timeout: 8, stage: "fail-no-successful-removal") {
            $0.contains("removed=0") && $0.contains("retried=0")
        }
    }

    func testUnknownLeaveForgetsWithoutCleanup() {
        let app = launch("interaction-unknown-leave")
        waitProbe(app, "companion-fixture-receipts", timeout: 8, stage: "unknown-seeded") {
            $0.localizedCaseInsensitiveContains(self.unknownID) && $0.contains("|unknown")
        }
        tapRecoveryEntry(app, stage: "unknown-entry")
        _ = waitUnique(app, "companion-recovery-sheet", timeout: 8, stage: "unknown-sheet")
        var leave = app.buttons["companion-recovery-leave-unknown"]
        if !leave.waitForExistence(timeout: 3) {
            app.swipeUp()
            leave = app.buttons["companion-recovery-leave-unknown"]
        }
        if !leave.waitForExistence(timeout: 8) {
            dumpStage(app, "unknown-leave-control")
            XCTFail("unknown-leave-control")
        }
        leave.tap()
        waitProbe(app, "companion-fixture-receipts", timeout: 8, stage: "unknown-removed") {
            $0 == "empty" || !$0.localizedCaseInsensitiveContains(self.unknownID)
        }
        waitProbe(app, "companion-fixture-cleanup", timeout: 8, stage: "unknown-no-delete") {
            $0.contains("removed=0") && $0.contains("retried=0")
        }
    }

    func testIPadTerminalHidesBothColumnsAndKeepsSession() {
        let app = launch("interaction-terminal")
        let connected = app.staticTexts["Connected · drag to scroll"]
        if !connected.waitForExistence(timeout: 12) {
            dumpStage(app, "ipad-session-started")
            XCTFail("ipad-session-started")
        }
        waitProbe(app, "companion-fixture-sessions", timeout: 8, stage: "ipad-session-open") {
            $0.contains("|started") && !$0.contains("|closed")
        }
        let before = requireProbeValue(app, "companion-fixture-sessions", stage: "ipad-session-value")
        let sessionID = before.split(separator: "|").first.map(String.init) ?? ""
        XCTAssertFalse(sessionID.isEmpty)
        let surface = waitUnique(app, "companion-terminal-surface", timeout: 8, stage: "ipad-terminal-surface")
        recordEvidence(app, "ipad-focused-portrait", extra: "session=\(before)")

        guard UIDevice.current.userInterfaceIdiom == .pad else {
            assertDockTargets(app, stage: "phone-smoke-dock")
            return
        }

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 4))
        assertCustomOwnsSplit(app, stage: "ipad-initial-focused", browsing: false)
        let focusedRatio = surface.frame.width / max(1, window.frame.width)
        XCTAssertGreaterThan(
            focusedRatio, 0.82,
            "focused terminal should use near-full width, ratio=\(focusedRatio) surface=\(surface.frame) window=\(window.frame)")
        XCTAssertFalse(
            agentHittable(app, "pane-reviewer"),
            "both navigation columns must be hidden while the terminal is focused")
        XCTAssertFalse(agentHittable(app, "pane-mystery"))

        let browse = waitUniqueButton(
            app, "companion-split-browser", timeout: 8, stage: "ipad-browse-control")
        XCTAssertEqual(browse.label, "Show browser")
        browse.tap()
        let reviewer = waitUniqueButton(
            app, "companion-agent-pane-reviewer", timeout: 8, stage: "ipad-browser-reviewer")
        XCTAssertTrue(reviewer.isHittable)
        waitProbe(app, "companion-fixture-sessions", timeout: 8, stage: "ipad-same-session-while-browsing") {
            $0.localizedCaseInsensitiveContains(sessionID)
                && $0.contains("|started")
                && !$0.contains("|closed")
                && $0.split(separator: ";").count == 1
        }
        recordEvidence(app, "ipad-browsing-portrait", extra: "session=\(probeDisplay(app, "companion-fixture-sessions"))")
        assertCustomOwnsSplit(app, stage: "ipad-browsing", browsing: true)

        let focus = waitUniqueButton(
            app, "companion-split-browser", timeout: 8, stage: "ipad-focus-control")
        XCTAssertEqual(focus.label, "Focus terminal")
        XCTAssertTrue(focus.isHittable, "Focus must be visible in the browser chrome")
        focus.tap()
        waitProbe(app, "companion-fixture-sessions", timeout: 8, stage: "ipad-same-session-after-focus") {
            $0.localizedCaseInsensitiveContains(sessionID)
                && $0.contains("|started")
                && !$0.contains("|closed")
                && $0.split(separator: ";").count == 1
        }
        let focusedSurface = waitUnique(
            app, "companion-terminal-surface", timeout: 8, stage: "ipad-refocused-surface")
        XCTAssertGreaterThan(
            focusedSurface.frame.width / max(1, window.frame.width), 0.82)
        XCTAssertFalse(agentHittable(app, "pane-mystery"))
        assertCustomOwnsSplit(app, stage: "ipad-refocused", browsing: false)

        waitUniqueButton(app, "companion-split-browser", timeout: 8, stage: "ipad-browse-again").tap()
        waitUniqueButton(app, "companion-agent-pane-mystery", timeout: 8, stage: "ipad-other-agent").tap()
        waitProbe(app, "companion-fixture-sessions", timeout: 12, stage: "ipad-switched-target") {
            $0.localizedCaseInsensitiveContains(sessionID)
                && $0.contains("|closed")
                && $0.contains("|started")
                && $0.split(separator: ";").count >= 2
        }
        let switched = requireProbeValue(app, "companion-fixture-sessions", stage: "ipad-switched-value")
        let started = switched.split(separator: ";").filter { $0.contains("|started") && !$0.contains("|closed") }
        XCTAssertEqual(started.count, 1)
        XCTAssertFalse(started[0].localizedCaseInsensitiveContains(sessionID))
        let liveID = started[0].split(separator: "|").first.map(String.init) ?? ""
        XCTAssertFalse(liveID.isEmpty)
        let switchedSurface = waitUnique(
            app, "companion-terminal-surface", timeout: 8, stage: "ipad-switched-surface")
        XCTAssertGreaterThan(
            switchedSurface.frame.width / max(1, window.frame.width), 0.82,
            "selecting another agent must focus it at full width")
        XCTAssertFalse(agentHittable(app, "pane-reviewer"))
        recordEvidence(app, "ipad-focused-other-portrait", extra: "session=\(switched)")
        assertCustomOwnsSplit(app, stage: "ipad-switched-focused", browsing: false)

        assertDockTargets(app, stage: "ipad-portrait-dock")
        assertKeyboardToggle(app, stage: "ipad-portrait-keyboard")

        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(1)
        let landscapeSurface = waitUnique(
            app, "companion-terminal-surface", timeout: 8, stage: "ipad-landscape-surface")
        let landscapeWindow = app.windows.element(boundBy: 0)
        XCTAssertGreaterThan(
            landscapeSurface.frame.width / max(1, landscapeWindow.frame.width), 0.82)
        waitProbe(app, "companion-fixture-sessions", timeout: 8, stage: "ipad-rotate-keeps-session") {
            $0.localizedCaseInsensitiveContains(liveID)
                && $0.contains("|started")
        }
        let rotated = requireProbeValue(app, "companion-fixture-sessions", stage: "ipad-rotate-session-value")
        let liveAfterRotate = rotated.split(separator: ";").filter {
            $0.contains("|started") && !$0.contains("|closed")
        }
        XCTAssertEqual(liveAfterRotate.count, 1)
        XCTAssertTrue(
            liveAfterRotate[0].localizedCaseInsensitiveContains(liveID),
            "rotation must keep UUID \(liveID) live, sessions=\(rotated)")
        assertDockTargets(app, stage: "ipad-landscape-dock")
        recordScreen(app, "ipad-focused-landscape")
        recordEvidence(app, "ipad-focused-landscape", extra: "session=\(rotated)")
        assertCustomOwnsSplit(app, stage: "ipad-landscape-focused", browsing: false)
        XCUIDevice.shared.orientation = .portrait

        assertCustomOwnsSplit(app, stage: "ipad-final-focused", browsing: false)
        if let native = nativeSidebarControl(app), native.exists, native.isHittable {
            exerciseRemainingNativeSidebar(app, native: native, sessionID: liveID)
        }
    }

    func testIPadCompactOverrideAndNotificationKeepSingleSession() {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return }
        let app = launch("interaction-terminal")
        let connected = app.staticTexts["Connected · drag to scroll"]
        if !connected.waitForExistence(timeout: 12) {
            dumpStage(app, "compact-session-started")
            XCTFail("compact-session-started")
        }
        waitProbe(app, "companion-fixture-sessions", timeout: 8, stage: "compact-session-open") {
            $0.contains("|started") && !$0.contains("|closed")
        }
        let before = requireProbeValue(app, "companion-fixture-sessions", stage: "compact-session-value")
        let sessionID = before.split(separator: "|").first.map(String.init) ?? ""
        XCTAssertFalse(sessionID.isEmpty)
        exerciseCompactSizeClassOverride(app, sessionID: sessionID)
        exerciseNotificationThenManual(app)
    }

    func testTerminalDockFitsLargeTextAndReducedWidth() {
        let app = launch("interaction-terminal", largeText: true)
        let connected = app.staticTexts["Connected · drag to scroll"]
        if !connected.waitForExistence(timeout: 12) {
            dumpStage(app, "large-text-session-started")
            XCTFail("large-text-session-started")
        }
        _ = waitUnique(app, "companion-terminal-surface", timeout: 8, stage: "large-text-surface")
        waitProbe(app, "companion-fixture-sessions", timeout: 8, stage: "large-text-session-open") {
            $0.contains("|started") && !$0.contains("|closed")
        }
        let before = requireProbeValue(app, "companion-fixture-sessions", stage: "large-text-session-value")
        let sessionID = before.split(separator: "|").first.map(String.init) ?? ""
        assertDockTargets(app, stage: "large-text-focused-dock")
        recordEvidence(app, "large-text-focused", extra: "session=\(before)")
        if UIDevice.current.userInterfaceIdiom == .pad {
            waitUniqueButton(app, "companion-split-browser", timeout: 8, stage: "large-text-browse").tap()
            _ = waitUniqueButton(
                app, "companion-agent-pane-reviewer", timeout: 8, stage: "large-text-browser-row")
            waitProbe(app, "companion-fixture-sessions", timeout: 8, stage: "large-text-same-session") {
                $0.localizedCaseInsensitiveContains(sessionID)
                    && $0.contains("|started")
                    && !$0.contains("|closed")
                    && $0.split(separator: ";").count == 1
            }
            let focus = waitUniqueButton(
                app, "companion-split-browser", timeout: 8, stage: "large-text-focus")
            XCTAssertEqual(focus.label, "Focus terminal")
            XCTAssertTrue(focus.isHittable, "Focus must be uncovered in the browser chrome")
            focus.tap()
            XCTAssertFalse(agentHittable(app, "pane-reviewer"))
            assertDockTargets(app, stage: "large-text-refocused-dock")
            recordEvidence(app, "large-text-refocused", extra: "session=\(probeDisplay(app, "companion-fixture-sessions")) overlay-dismissed dock, not overlay-covered width")
        }
    }

    func testIPadSavedHostCenterTapConnects() {
        let app = launch("interaction-recovery")
        waitProbe(app, "companion-fixture-presenting", timeout: 8, stage: "center-recovery-idle") {
            $0 == "dismissed"
        }
        tapRecoveryEntry(app, stage: "center-recovery-entry")
        _ = waitUnique(app, "companion-recovery-sheet", timeout: 8, stage: "center-recovery-sheet")
        let close = toolbarClose(app)
        if !close.waitForExistence(timeout: 8) {
            dumpStage(app, "center-close-control")
            XCTFail("center-close-control")
        }
        close.tap()
        waitProbe(app, "companion-fixture-presenting", timeout: 8, stage: "center-close-dismissed") {
            $0 == "dismissed"
        }
        let host = studioHost(app)
        if !host.waitForExistence(timeout: 10) {
            dumpStage(app, "center-saved-host")
            XCTFail("center-saved-host")
        }
        host.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        waitProbe(app, "companion-fixture-connection", timeout: 12, stage: "center-host-connected") {
            $0 == "connected"
        }
        waitProbe(app, "companion-fixture-host", timeout: 8, stage: "center-host-identity") {
            $0.localizedCaseInsensitiveCompare(self.studioID) == .orderedSame
        }
        recordEvidence(app, "saved-host-center-tap", extra: "connected")
    }

    func testWorkspaceRowCenterTapOpensDetail() {
        let app = launch("workspaces")
        let row = app.descendants(matching: .any).matching(identifier: "workspaces-entry").firstMatch
        if !row.waitForExistence(timeout: 10) {
            dumpStage(app, "workspace-row")
            XCTFail("workspace-row")
        }
        XCTAssertGreaterThan(row.frame.width, 100)
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let pane = app.descendants(matching: .any)["companion-pane-pane-reviewer"]
        let shell = app.descendants(matching: .any)["companion-pane-pane-shell"]
        if !pane.waitForExistence(timeout: 8) && !shell.waitForExistence(timeout: 2) {
            dumpStage(app, "workspace-detail-after-center-tap")
            XCTFail("workspace-detail-after-center-tap")
        }
        recordEvidence(app, "workspace-center-tap", extra: "detail")
    }

    func testIPadWorkspacePaneTapFocusesTerminal() {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return }
        let app = launch("workspace")
        let pane = waitUnique(app, "companion-pane-pane-shell", timeout: 10, stage: "workspace-shell-pane")
        XCTAssertTrue(pane.isHittable)
        pane.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        waitProbe(app, "companion-fixture-sessions", timeout: 12, stage: "workspace-pane-session") {
            $0.contains("|started") && !$0.contains("|closed")
        }
        let surface = waitUnique(app, "companion-terminal-surface", timeout: 8, stage: "workspace-pane-surface")
        let window = app.windows.firstMatch
        XCTAssertGreaterThan(surface.frame.width / max(1, window.frame.width), 0.82)
        XCTAssertFalse(agentHittable(app, "pane-shell") || pane.isHittable)
        let browse = waitUniqueButton(app, "companion-split-browser", timeout: 8, stage: "workspace-pane-browse")
        XCTAssertEqual(browse.label, "Show browser")
        recordEvidence(app, "workspace-pane-focused", extra: probeDisplay(app, "companion-fixture-sessions"))
        assertCustomOwnsSplit(app, stage: "workspace-pane-focused", browsing: false)
    }

    func testDraftAndImageSheetsShowMacWorkspaceTerminal() {
        let draft = launch("draft")
        _ = waitUnique(draft, "companion-draft-editor", timeout: 12, stage: "draft-editor")
        let draftContext = waitUnique(
            draft, "companion-destination-context", timeout: 8, stage: "draft-destination")
        XCTAssertTrue(
            draftContext.label.contains("Example Mac") || draft.staticTexts["Example Mac"].exists,
            "draft destination \(draftContext.label)")
        recordEvidence(draft, "draft-destination", extra: draftContext.label)

        let image = launch("attachment")
        _ = waitUnique(image, "companion-attachment-upload", timeout: 12, stage: "image-upload")
        let imageContext = waitUnique(
            image, "companion-destination-context", timeout: 8, stage: "image-destination")
        XCTAssertTrue(
            imageContext.label.contains("Example Mac") || image.staticTexts["Example Mac"].exists,
            "image destination \(imageContext.label)")
        recordEvidence(image, "image-destination", extra: imageContext.label)
    }

    func testNewTabShowsWorkspaceThenFocusesCreatedTerminal() {
        let app = launch("workspace")
        let newTab = waitUnique(app, "new-terminal-tab-button", timeout: 10, stage: "new-tab-button")
        newTab.tap()
        let context = waitUnique(
            app, "companion-destination-context", timeout: 8, stage: "new-tab-destination")
        XCTAssertTrue(
            context.label.contains("Companion App") || app.staticTexts["Companion App"].exists,
            "new tab destination \(context.label)")
        recordEvidence(app, "new-tab-destination", extra: context.label)
        let create = app.descendants(matching: .any).matching(identifier: "create-terminal-tab-submit").element(boundBy: 0)
        if !create.waitForExistence(timeout: 8) {
            dumpStage(app, "new-tab-create")
            XCTFail("new-tab-create")
        }
        create.tap()
        waitProbe(app, "companion-fixture-sessions", timeout: 12, stage: "new-tab-session") {
            $0.contains("|started") && !$0.contains("|closed")
        }
        _ = waitUnique(app, "companion-terminal-surface", timeout: 8, stage: "new-tab-surface")
        recordEvidence(app, "new-tab-focused", extra: probeDisplay(app, "companion-fixture-sessions"))
    }

    func testSplitShowsPaneThenFocusesCreatedTerminal() {
        let app = launch("workspace")
        _ = waitUnique(app, "companion-pane-pane-shell", timeout: 10, stage: "split-shell-pane")
        let actions = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Actions for")).firstMatch
        if !actions.waitForExistence(timeout: 8) {
            dumpStage(app, "split-actions")
            XCTFail("split-actions")
        }
        actions.tap()
        let splitItem = app.buttons["Split Pane"].firstMatch.exists ? app.buttons["Split Pane"] : app.menuItems["Split Pane"]
        if !splitItem.waitForExistence(timeout: 8) {
            dumpStage(app, "split-menu-item")
            XCTFail("split-menu-item")
        }
        splitItem.tap()
        let context = waitUnique(
            app, "companion-destination-context", timeout: 8, stage: "split-destination")
        XCTAssertTrue(
            context.label.contains("zsh") || context.label.contains("pane-shell")
                || app.staticTexts["zsh"].exists,
            "split destination \(context.label)")
        recordEvidence(app, "split-destination", extra: context.label)
        let submit = app.descendants(matching: .any).matching(identifier: "split-pane-submit").element(boundBy: 0)
        if !submit.waitForExistence(timeout: 8) {
            dumpStage(app, "split-submit")
            XCTFail("split-submit")
        }
        submit.tap()
        waitProbe(app, "companion-fixture-sessions", timeout: 12, stage: "split-session") {
            $0.contains("|started") && !$0.contains("|closed")
        }
        _ = waitUnique(app, "companion-terminal-surface", timeout: 8, stage: "split-surface")
        recordEvidence(app, "split-focused", extra: probeDisplay(app, "companion-fixture-sessions"))
    }

    func testWideGlyphCollidingRowsStayDistinctAndSelectExactPanes() {
        let app = launch("interaction-collision")
        assertCollisionDeskRows(app, stage: "desk-collision-normal")
        selectCollisionRow(
            app, identifier: "companion-agent-pane-wide-a",
            expected: "WWWWWWWWWA terminal", expectedPaneID: collisionPaneID(from: "companion-agent-pane-wide-a"),
            stage: "desk-select-a")
        leaveCollisionTerminal(app, stage: "desk-back-a")
        selectCollisionRow(
            app, identifier: "companion-agent-pane-wide-b",
            expected: "WWWWWWWWWB terminal", expectedPaneID: collisionPaneID(from: "companion-agent-pane-wide-b"),
            stage: "desk-select-b")
        leaveCollisionTerminal(app, stage: "desk-back-b")
        openCollisionWorkspace(app)
        assertCollisionPaneRows(app, stage: "workspace-collision-normal")
        selectCollisionRow(
            app, identifier: "companion-pane-pane-wide-a",
            expected: "WWWWWWWWWA terminal", expectedPaneID: collisionPaneID(from: "companion-pane-pane-wide-a"),
            stage: "workspace-select-a")
        leaveCollisionTerminal(app, stage: "workspace-back-a")
        if UIDevice.current.userInterfaceIdiom == .pad {
            openCollisionWorkspace(app)
        }
        selectCollisionRow(
            app, identifier: "companion-pane-pane-wide-b",
            expected: "WWWWWWWWWB terminal", expectedPaneID: collisionPaneID(from: "companion-pane-pane-wide-b"),
            stage: "workspace-select-b")
    }

    func testWideGlyphCollidingRowsStayDistinctAtAccessibilitySize() {
        let app = launch("interaction-collision", largeText: true)
        assertCollisionDeskRows(app, stage: "desk-collision-accessibility")
        openCollisionWorkspace(app)
        assertCollisionPaneRows(app, stage: "workspace-collision-accessibility")
    }

    func testLongPathRowsStayDistinctAndSelectExactPanes() {
        let app = launch("interaction-collision")
        let token = String(repeating: "a", count: 32)
        assertLongPair(
            app, prefix: "companion-agent-pane-long-parent",
            needleA: "\(token)A/src", needleB: "\(token)B/src",
            expectedTitle: "long-parent", stage: "desk-long-parent")
        assertLongPair(
            app, prefix: "companion-agent-pane-long-leaf",
            needleA: "\(token)A", needleB: "\(token)B",
            expectedTitle: "long-leaf", stage: "desk-long-leaf")
        openCollisionWorkspace(app)
        assertLongPair(
            app, prefix: "companion-pane-pane-long-parent",
            needleA: "\(token)A/src", needleB: "\(token)B/src",
            expectedTitle: "long-parent", stage: "workspace-long-parent")
        if UIDevice.current.userInterfaceIdiom == .pad {
            openCollisionWorkspace(app)
        }
        assertLongPair(
            app, prefix: "companion-pane-pane-long-leaf",
            needleA: "\(token)A", needleB: "\(token)B",
            expectedTitle: "long-leaf", stage: "workspace-long-leaf")
    }

    func testLongPathRowsStayDistinctAtAccessibilitySize() {
        let app = launch("interaction-collision", largeText: true)
        let token = String(repeating: "a", count: 32)
        let leafA = revealRow(app, "companion-agent-pane-long-leaf-a", stage: "a11y-desk-long-leaf-a")
        let leafB = revealRow(app, "companion-agent-pane-long-leaf-b", stage: "a11y-desk-long-leaf-b")
        XCTAssertTrue(collisionRowText(leafA).contains("\(token)A"))
        XCTAssertTrue(collisionRowText(leafB).contains("\(token)B"))
        recordEvidence(app, "desk-long-leaf-accessibility", extra: "A=\(collisionRowText(leafA)) B=\(collisionRowText(leafB)) Aframe=\(NSCoder.string(for: leafA.frame)) Bframe=\(NSCoder.string(for: leafB.frame))")
        let parentA = revealRow(app, "companion-agent-pane-long-parent-a", stage: "a11y-desk-long-parent-a")
        let parentB = revealRow(app, "companion-agent-pane-long-parent-b", stage: "a11y-desk-long-parent-b")
        XCTAssertTrue(collisionRowText(parentA).contains("\(token)A/src"))
        XCTAssertTrue(collisionRowText(parentB).contains("\(token)B/src"))
        recordEvidence(app, "desk-long-parent-accessibility", extra: "A=\(collisionRowText(parentA)) B=\(collisionRowText(parentB)) Aframe=\(NSCoder.string(for: parentA.frame)) Bframe=\(NSCoder.string(for: parentB.frame))")
        openCollisionWorkspace(app)
        let paneParentA = revealRow(app, "companion-pane-pane-long-parent-a", stage: "a11y-pane-long-parent-a")
        let paneParentB = revealRow(app, "companion-pane-pane-long-parent-b", stage: "a11y-pane-long-parent-b")
        XCTAssertTrue(collisionRowText(paneParentA).contains("\(token)A/src"))
        XCTAssertTrue(collisionRowText(paneParentB).contains("\(token)B/src"))
        recordEvidence(app, "workspace-long-parent-accessibility", extra: "A=\(collisionRowText(paneParentA)) B=\(collisionRowText(paneParentB))")
        if UIDevice.current.userInterfaceIdiom == .pad {
            openCollisionWorkspace(app)
        }
        let paneLeafA = revealRow(app, "companion-pane-pane-long-leaf-a", stage: "a11y-pane-long-leaf-a")
        let paneLeafB = revealRow(app, "companion-pane-pane-long-leaf-b", stage: "a11y-pane-long-leaf-b")
        XCTAssertTrue(collisionRowText(paneLeafA).contains("\(token)A"))
        XCTAssertTrue(collisionRowText(paneLeafB).contains("\(token)B"))
        recordEvidence(app, "workspace-long-leaf-accessibility", extra: "A=\(collisionRowText(paneLeafA)) B=\(collisionRowText(paneLeafB))")
    }

    func testDeskRowsReadableAtAccessibilitySize() {
        let app = launch("overview", largeText: true)
        let connected = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Connected")).firstMatch
        if !connected.waitForExistence(timeout: 12) {
            dumpStage(app, "large-text-desk")
            XCTFail("large-text-desk")
        }
        XCTAssertTrue(
            app.staticTexts["Needs you"].exists || app.staticTexts["Needs You"].exists
                || app.otherElements.matching(NSPredicate(format: "label CONTAINS[c] %@", "Needs you")).firstMatch.exists,
            "status label must remain visible at accessibility size")
        recordEvidence(app, "desk-accessibility-rows", extra: "large-text")
    }

    private func collisionRowText(_ row: XCUIElement) -> String {
        let value = (row.value as? String) ?? ""
        return "\(row.label) \(value)"
    }

    private func assertCollisionDeskRows(_ app: XCUIApplication, stage: String) {
        let connected = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Connected")
        ).firstMatch
        if !connected.waitForExistence(timeout: 12) {
            dumpStage(app, "\(stage)-connected")
            XCTFail("\(stage)-connected")
        }
        let rowA = revealRow(app, "companion-agent-pane-wide-a", stage: "\(stage)-row-a")
        let rowB = revealRow(app, "companion-agent-pane-wide-b", stage: "\(stage)-row-b")
        XCTAssertTrue(rowA.isHittable, "\(stage) desk row A must be hittable before info")
        XCTAssertTrue(rowB.isHittable, "\(stage) desk row B must be hittable before info")
        let textA = collisionRowText(rowA)
        let textB = collisionRowText(rowB)
        XCTAssertTrue(textA.contains("a/src") && !textA.contains("b/src"),
            "\(stage) desk A row-scoped a/src, not b/src: \(textA)")
        XCTAssertTrue(textB.contains("b/src") && !textB.contains("a/src"),
            "\(stage) desk B row-scoped b/src, not a/src: \(textB)")
        XCTAssertNotEqual(textA, textB, "\(stage) desk row text must differ")
        let window = app.windows.firstMatch
        recordEvidence(
            app, stage,
            extra: "window=\(NSCoder.string(for: window.frame)) A=\(textA) B=\(textB) Aframe=\(NSCoder.string(for: rowA.frame)) Bframe=\(NSCoder.string(for: rowB.frame))")
    }

    private func assertCollisionPaneRows(_ app: XCUIApplication, stage: String) {
        let rowA = revealRow(app, "companion-pane-pane-wide-a", stage: "\(stage)-pane-a")
        let rowB = revealRow(app, "companion-pane-pane-wide-b", stage: "\(stage)-pane-b")
        XCTAssertTrue(rowA.isHittable, "\(stage) pane A must be hittable before info")
        XCTAssertTrue(rowB.isHittable, "\(stage) pane B must be hittable before info")
        let textA = collisionRowText(rowA)
        let textB = collisionRowText(rowB)
        XCTAssertTrue(textA.contains("a/src") && !textA.contains("b/src"),
            "\(stage) pane A row-scoped a/src, not b/src: \(textA)")
        XCTAssertTrue(textB.contains("b/src") && !textB.contains("a/src"),
            "\(stage) pane B row-scoped b/src, not a/src: \(textB)")
        XCTAssertNotEqual(textA, textB, "\(stage) pane row text must differ")
        recordEvidence(app, stage, extra: "A=\(textA) B=\(textB)")
    }

    private func selectCollisionRow(
        _ app: XCUIApplication, identifier: String, expected: String,
        expectedPaneID: String, stage: String
    ) {
        let row = revealRow(app, identifier, stage: "\(stage)-target")
        XCTAssertTrue(row.isHittable, "\(stage) target must be hittable")
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let context = waitUnique(
            app, "companion-terminal-context", timeout: 12, stage: "\(stage)-context")
        let contextText = "\(context.label) \((context.value as? String) ?? "") \(app.navigationBars.firstMatch.identifier)"
        XCTAssertTrue(
            context.label.contains(expected) || contextText.contains(expected)
                || app.staticTexts[expected].exists
                || app.navigationBars[expected].exists,
            "\(stage) must open \(expected), context=\(context.label)")
        waitProbe(app, "companion-fixture-sessions", timeout: 12, stage: "\(stage)-session") {
            $0.split(separator: ";").filter { part in
                part.contains("|started") && !part.contains("|closed")
            }.count == 1
        }
        let sessions = requireProbeValue(app, "companion-fixture-sessions", stage: "\(stage)-session-value")
        let live = sessions.split(separator: ";").filter {
            $0.contains("|started") && !$0.contains("|closed")
        }
        XCTAssertEqual(live.count, 1, "\(stage) must keep one live session: \(sessions)")
        let liveID = String(live[0].split(separator: "|", maxSplits: 1)[0])
        let expectedToken = "\(liveID)|agent:\(expectedPaneID)"
        waitProbe(app, "companion-fixture-session-target", timeout: 12, stage: "\(stage)-target-id") {
            $0.split(separator: ";").map(String.init).contains(expectedToken)
        }
        let targets = requireProbeValue(
            app, "companion-fixture-session-target", stage: "\(stage)-target-value")
        let observed = targets.split(separator: ";").map(String.init).first { $0.hasPrefix("\(liveID)|") }
        XCTAssertEqual(observed, expectedToken, "\(stage) live \(liveID) must be agent:\(expectedPaneID): \(targets)")
        recordEvidence(
            app, stage,
            extra: "expectedTitle=\(expected) expectedPaneID=\(expectedPaneID) observedTarget=\(observed ?? "nil") liveUUID=\(liveID) session=\(sessions) targets=\(targets) context=\(context.label)")
    }

    private func collisionPaneID(from identifier: String) -> String {
        if identifier.hasPrefix("companion-agent-") {
            return String(identifier.dropFirst("companion-agent-".count))
        }
        if identifier.hasPrefix("companion-pane-") {
            return String(identifier.dropFirst("companion-pane-".count))
        }
        return identifier
    }

    private func leaveCollisionTerminal(_ app: XCUIApplication, stage: String) {
        if UIDevice.current.userInterfaceIdiom == .pad {
            let keyboard = app.buttons.matching(identifier: "companion-dock-keyboard").firstMatch
            if keyboard.exists, keyboard.isHittable {
                keyboard.tap()
                RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            }
            let browse = app.buttons.matching(identifier: "companion-split-browser").firstMatch
            if browse.waitForExistence(timeout: 6), browse.label == "Show browser" {
                browse.tap()
            } else if browse.exists {
                dumpStage(app, "\(stage)-browse-label", extra: "label=\(browse.label)")
            }
        } else {
            let bar = app.navigationBars.firstMatch
            let back = bar.buttons.element(boundBy: 0)
            if back.waitForExistence(timeout: 6) {
                back.tap()
            } else {
                dumpStage(app, "\(stage)-back")
                XCTFail(stage)
            }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    }

    private func openCollisionWorkspace(_ app: XCUIApplication) {
        for _ in 0..<4 {
            app.swipeDown()
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        if UIDevice.current.userInterfaceIdiom == .pad {
            let browse = app.buttons.matching(identifier: "companion-split-browser").firstMatch
            if browse.waitForExistence(timeout: 2), browse.label == "Show browser" {
                browse.tap()
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            }
        }
        let workspaces = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "label == %@ AND identifier == %@",
                "Workspaces", "desk-destinations")
        ).firstMatch
        if !workspaces.waitForExistence(timeout: 8) {
            let fallback = app.buttons["Workspaces"]
            if fallback.waitForExistence(timeout: 2) {
                fallback.tap()
            } else {
                dumpStage(app, "collision-workspaces-tab")
                XCTFail("collision-workspaces-tab")
            }
        } else {
            workspaces.tap()
        }
        let row = app.descendants(matching: .any).matching(identifier: "workspaces-entry").firstMatch
        if !row.waitForExistence(timeout: 8) {
            dumpStage(app, "collision-workspace-row")
            XCTFail("collision-workspace-row")
        }
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        _ = waitUnique(app, "companion-pane-pane-wide-a", timeout: 10, stage: "collision-workspace-detail")
    }

    private func revealRow(
        _ app: XCUIApplication, _ identifier: String, stage: String
    ) -> XCUIElement {
        let query = app.descendants(matching: .any).matching(identifier: identifier)
        let row = query.element(boundBy: 0)
        let deadline = Date().addingTimeInterval(16)
        while Date() < deadline {
            if row.exists, row.isHittable { return row }
            if UIDevice.current.userInterfaceIdiom == .pad, app.windows.firstMatch.exists {
                let window = app.windows.firstMatch
                let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.78))
                let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.28))
                start.press(forDuration: 0.08, thenDragTo: end)
            } else {
                app.swipeUp()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        }
        if !row.exists {
            dumpStage(app, "\(stage)-missing")
            XCTFail("\(stage) missing \(identifier)")
        }
        return row
    }

    private func assertLongPair(
        _ app: XCUIApplication, prefix: String, needleA: String, needleB: String,
        expectedTitle: String, stage: String
    ) {
        let rowA = revealRow(app, "\(prefix)-a", stage: "\(stage)-a")
        let rowB = revealRow(app, "\(prefix)-b", stage: "\(stage)-b")
        XCTAssertTrue(rowA.isHittable, "\(stage) A hittable before info")
        XCTAssertTrue(rowB.isHittable, "\(stage) B hittable before info")
        let textA = collisionRowText(rowA)
        let textB = collisionRowText(rowB)
        XCTAssertTrue(
            textA.contains(needleA) && !textA.contains(needleB),
            "\(stage) A must contain \(needleA) not \(needleB): \(textA)")
        XCTAssertTrue(
            textB.contains(needleB) && !textB.contains(needleA),
            "\(stage) B must contain \(needleB) not \(needleA): \(textB)")
        XCTAssertNotEqual(textA, textB)
        recordEvidence(app, "\(stage)-rows", extra: "A=\(textA) B=\(textB)")
        selectCollisionRow(
            app, identifier: "\(prefix)-a", expected: expectedTitle,
            expectedPaneID: collisionPaneID(from: "\(prefix)-a"),
            stage: "\(stage)-select-a")
        leaveCollisionTerminal(app, stage: "\(stage)-back-a")
        if prefix.contains("companion-pane"), UIDevice.current.userInterfaceIdiom == .pad {
            openCollisionWorkspace(app)
        }
        let againB = revealRow(app, "\(prefix)-b", stage: "\(stage)-b-again")
        XCTAssertTrue(againB.isHittable)
        selectCollisionRow(
            app, identifier: "\(prefix)-b", expected: expectedTitle,
            expectedPaneID: collisionPaneID(from: "\(prefix)-b"),
            stage: "\(stage)-select-b")
        leaveCollisionTerminal(app, stage: "\(stage)-back-b")
    }

    private func recordScreen(_ app: XCUIApplication, _ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "\(name)-screen"
        attachment.lifetime = .keepAlways
        add(attachment)
        try? shot.pngRepresentation.write(
            to: URL(fileURLWithPath: "\(evidenceDirectory)/\(name)-screen.png"))
    }

    private func nativeSidebarControl(_ app: XCUIApplication) -> XCUIElement? {
        let query = app.buttons.matching(
            NSPredicate(
                format: "label == %@ OR label == %@ OR label == %@ OR identifier CONTAINS[c] %@",
                "Hide Sidebar", "Show Sidebar", "Toggle Sidebar", "Sidebar"))
        for index in 0..<query.count {
            let button = query.element(boundBy: index)
            if button.identifier == "companion-split-browser" { continue }
            if button.label == "Show browser" || button.label == "Focus terminal" { continue }
            if button.exists, button.isHittable { return button }
        }
        return nil
    }

    private func assertCustomOwnsSplit(
        _ app: XCUIApplication, stage: String, browsing: Bool
    ) {
        let custom = waitUniqueButton(
            app, "companion-split-browser", timeout: 8, stage: "\(stage)-custom")
        let expected = browsing ? "Focus terminal" : "Show browser"
        XCTAssertEqual(custom.label, expected, "\(stage) custom label")
        XCTAssertTrue(custom.isHittable, "\(stage) custom hittable")
        XCTAssertGreaterThanOrEqual(
            max(custom.frame.width, custom.frame.height), 44,
            "\(stage) custom target \(custom.frame)")
        let native = nativeSidebarControl(app)
        if let native, native.exists, native.isHittable {
            recordEvidence(
                app, "\(stage)-native-present",
                extra: "native remains label=\(native.label) hittable=\(native.isHittable) custom=\(custom.label)")
        } else {
            recordEvidence(
                app, "\(stage)-native-absent",
                extra: "custom \(expected) is the visible owner. session=\(probeDisplay(app, "companion-fixture-sessions"))")
            XCTAssertTrue(native == nil || native?.exists != true || native?.isHittable != true)
        }
    }

    private func exerciseRemainingNativeSidebar(
        _ app: XCUIApplication, native: XCUIElement, sessionID: String
    ) {
        native.tap()
        waitProbe(app, "companion-fixture-sessions", timeout: 8, stage: "native-show-keeps-session") {
            $0.localizedCaseInsensitiveContains(sessionID) && $0.contains("|started")
        }
        _ = waitUniqueButton(app, "companion-agent-pane-reviewer", timeout: 8, stage: "native-show-lists")
        assertCustomOwnsSplit(app, stage: "native-show-custom", browsing: true)
        let focus = waitUniqueButton(app, "companion-split-browser", timeout: 8, stage: "native-show-custom-label")
        XCTAssertEqual(
            focus.label, "Focus terminal",
            "after native Show Sidebar the custom control must offer Focus")
        recordEvidence(app, "native-show-coherent", extra: "label=\(focus.label)")
        focus.tap()
        XCTAssertFalse(agentHittable(app, "pane-reviewer"))
        waitProbe(app, "companion-fixture-sessions", timeout: 8, stage: "native-cycle-keeps-session") {
            $0.localizedCaseInsensitiveContains(sessionID)
                && $0.contains("|started")
                && $0.split(separator: ";").filter { $0.contains("|started") && !$0.contains("|closed") }.count == 1
        }
        assertCustomOwnsSplit(app, stage: "native-cycle-focused", browsing: false)
    }

    private func tapFixtureControl(_ app: XCUIApplication, _ identifier: String, stage: String) {
        let control = app.buttons[identifier]
        if !control.waitForExistence(timeout: 4) {
            dumpStage(app, stage)
            XCTFail(stage)
            return
        }
        if control.isHittable {
            control.tap()
        } else {
            control.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

    private func liveSessionIDs(_ snapshot: String) -> [String] {
        snapshot.split(separator: ";").compactMap { entry in
            guard entry.contains("|started"), !entry.contains("|closed") else { return nil }
            return entry.split(separator: "|").first.map(String.init)
        }
    }

    private func exerciseCompactSizeClassOverride(_ app: XCUIApplication, sessionID: String) {
        tapFixtureControl(app, "companion-fixture-force-compact", stage: "compact-force-control")
        waitProbe(app, "companion-fixture-size-class", timeout: 8, stage: "compact-override-applied") {
            $0 == "compact"
        }
        waitProbe(app, "companion-fixture-sessions", timeout: 8, stage: "compact-keeps-uuid") {
            $0.localizedCaseInsensitiveContains(sessionID)
                && $0.contains("|started")
                && self.liveSessionIDs($0) == [sessionID]
        }
        recordEvidence(
            app, "compact-override",
            extra: "DEBUG size-class override, not a window resize. probe=\(probeDisplay(app, "companion-fixture-size-class")) session=\(probeDisplay(app, "companion-fixture-sessions"))")
        tapFixtureControl(app, "companion-fixture-force-regular", stage: "regular-force-control")
        waitProbe(app, "companion-fixture-size-class", timeout: 8, stage: "regular-restore-applied") {
            $0 == "regular"
        }
        waitProbe(app, "companion-fixture-sessions", timeout: 8, stage: "regular-restore-uuid") {
            $0.localizedCaseInsensitiveContains(sessionID)
                && $0.contains("|started")
                && self.liveSessionIDs($0) == [sessionID]
        }
    }

    private func exerciseNotificationThenManual(_ app: XCUIApplication) {
        let before = requireProbeValue(app, "companion-fixture-sessions", stage: "notify-before-value")
        let originIDs = liveSessionIDs(before)
        XCTAssertEqual(originIDs.count, 1, "notify-before-live-count")
        let originID = originIDs[0]
        waitUniqueButton(app, "companion-split-browser", timeout: 8, stage: "same-target-browse").tap()
        _ = waitUniqueButton(app, "companion-agent-pane-reviewer", timeout: 8, stage: "same-target-lists")
        tapFixtureControl(app, "companion-fixture-notify-reviewer", stage: "notify-same-reviewer")
        waitProbe(app, "companion-fixture-sessions", timeout: 8, stage: "same-target-keeps-uuid") {
            self.liveSessionIDs($0) == [originID]
        }
        XCTAssertFalse(agentHittable(app, "pane-reviewer"), "same-target notification must Focus the open terminal")
        let browseAfterSame = waitUniqueButton(
            app, "companion-split-browser", timeout: 8, stage: "same-target-focused-browse")
        XCTAssertEqual(browseAfterSame.label, "Show browser")
        tapFixtureControl(app, "companion-fixture-notify-calendar", stage: "notify-calendar-control")
        waitProbe(app, "companion-fixture-sessions", timeout: 12, stage: "notify-calendar-live") {
            let live = self.liveSessionIDs($0)
            return live.count == 1 && live[0] != originID
        }
        let afterNotify = requireProbeValue(app, "companion-fixture-sessions", stage: "notify-calendar-value")
        let notifiedIDs = liveSessionIDs(afterNotify)
        XCTAssertEqual(notifiedIDs.count, 1)
        XCTAssertNotEqual(notifiedIDs[0], originID)
        waitUniqueButton(app, "companion-split-browser", timeout: 8, stage: "notify-browse").tap()
        waitUniqueButton(app, "companion-agent-pane-mystery", timeout: 8, stage: "notify-then-manual-c").tap()
        waitProbe(app, "companion-fixture-sessions", timeout: 12, stage: "manual-c-live") {
            let live = self.liveSessionIDs($0)
            return live.count == 1 && live[0] != notifiedIDs[0] && live[0] != originID
        }
        recordEvidence(app, "notify-then-manual", extra: "session=\(probeDisplay(app, "companion-fixture-sessions"))")
    }

    private func assertKeyboardToggle(_ app: XCUIApplication, stage: String) {
        var keyboard = app.buttons.matching(identifier: "companion-dock-keyboard").element(boundBy: 0)
        if !keyboard.waitForExistence(timeout: 4) {
            keyboard = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "keyboard")).element(boundBy: 0)
        }
        XCTAssertTrue(keyboard.waitForExistence(timeout: 8), "\(stage)-control")
        if keyboard.label.localizedCaseInsensitiveContains("Show"), keyboard.isHittable {
            keyboard.tap()
        }
        let presented = app.keyboards.firstMatch.waitForExistence(timeout: 6)
            || keyboard.label.localizedCaseInsensitiveContains("Hide")
        XCTAssertTrue(presented, "\(stage) keyboard should present")
        recordEvidence(
            app, stage,
            extra: "keyboard=\(app.keyboards.firstMatch.exists) label=\(keyboard.label)")
        assertDockTargets(app, stage: "\(stage)-dock")
        if keyboard.label.localizedCaseInsensitiveContains("Hide"), keyboard.isHittable {
            keyboard.tap()
        }
    }

    private func agentRow(_ app: XCUIApplication, _ paneID: String) -> XCUIElement {
        app.buttons.matching(identifier: "companion-agent-\(paneID)").element(boundBy: 0)
    }

    private func agentHittable(_ app: XCUIApplication, _ paneID: String) -> Bool {
        let query = app.buttons.matching(identifier: "companion-agent-\(paneID)")
        guard query.count > 0 else { return false }
        return query.element(boundBy: 0).isHittable
    }

    private func describeQuery(_ query: XCUIElementQuery) -> String {
        let count = query.count
        guard count > 0 else { return "count=0" }
        let element = query.element(boundBy: 0)
        return "exists=\(element.exists) label=\(element.label) value=\(element.value ?? "") count=\(count)"
    }

    private func assertDockTargets(_ app: XCUIApplication, stage: String, requireHittable: Bool = true) {
        let ids = [
            ("companion-dock-escape", "Escape"),
            ("companion-dock-tab", "Tab"),
            ("companion-dock-ctrl", "One-shot ctrl"),
            ("companion-dock-option", "One-shot option"),
            ("companion-dock-keyboard", "keyboard"),
            ("companion-dock-image", "Attach image"),
            ("companion-dock-draft", "Compose draft"),
            ("companion-dock-keys", "Open terminal keys"),
        ]
        var lines: [String] = []
        var collectedFrames: [CGRect] = []
        for (id, label) in ids {
            var query = app.buttons.matching(identifier: id)
            var button = query.element(boundBy: 0)
            if !button.waitForExistence(timeout: 2) {
                query = app.buttons.matching(NSPredicate(format: "label == %@ OR label CONTAINS[c] %@", label, label))
                button = query.element(boundBy: 0)
            }
            if !button.waitForExistence(timeout: 8) {
                dumpStage(app, "\(stage)-\(id)")
                XCTFail("\(stage)-\(id)")
            }
            var target = button
            for index in 0..<max(query.count, 1) {
                let candidate = query.element(boundBy: index)
                if candidate.isHittable {
                    target = candidate
                    break
                }
            }
            let frame = target.frame
            lines.append("\(id)=\(NSCoder.string(for: frame)) hittable=\(target.isHittable) count=\(query.count)")
            XCTAssertGreaterThanOrEqual(frame.width, 44, "\(stage) \(id) width \(frame)")
            XCTAssertGreaterThanOrEqual(frame.height, 44, "\(stage) \(id) height \(frame)")
            if requireHittable {
                XCTAssertTrue(target.isHittable, "\(stage) \(id) should be tappable")
            }
            for prior in collectedFrames {
                let overlap = frame.insetBy(dx: 1, dy: 1).intersects(prior)
                XCTAssertFalse(overlap, "\(stage) \(id) overlaps \(prior) with \(frame)")
            }
            collectedFrames.append(frame)
            let texts = target.descendants(matching: .staticText)
            for index in 0..<texts.count {
                let label = texts.element(boundBy: index)
                guard label.exists else { continue }
                let text = label.label
                XCTAssertNotEqual(text, "optio", "\(stage) \(id) wrapped option")
                XCTAssertFalse(text.contains("\n"), "\(stage) \(id) newline \(text)")
                XCTAssertLessThanOrEqual(
                    label.frame.maxX, frame.maxX + 1.5,
                    "\(stage) \(id) clips '\(text)' label=\(label.frame) button=\(frame)")
                XCTAssertGreaterThanOrEqual(
                    label.frame.minX, frame.minX - 1.5,
                    "\(stage) \(id) overflows '\(text)'")
            }
        }
        recordEvidence(app, stage, extra: lines.joined(separator: "\n"))
    }

    private func recordEvidence(_ app: XCUIApplication, _ name: String, extra: String = "") {
        let window = app.windows.element(boundBy: 0)
        let surfaceQuery = app.descendants(matching: .any).matching(identifier: "companion-terminal-surface")
        let dockQuery = app.descendants(matching: .any).matching(identifier: "companion-terminal-dock")
        let surfaceDesc = describeQuery(surfaceQuery)
        let dockDesc = describeQuery(dockQuery)
        let blob = [
            "name=\(name)",
            "idiom=\(UIDevice.current.userInterfaceIdiom == .pad ? "pad" : "phone")",
            "orientation=\(XCUIDevice.shared.orientation.rawValue)",
            "window=\(NSCoder.string(for: window.frame))",
            "surface=\(surfaceDesc)",
            "dock=\(dockDesc)",
            "browse=\(describeQuery(app.buttons.matching(identifier: "companion-split-browser")))",
            "reviewerHittable=\(agentHittable(app, "pane-reviewer"))",
            "mysteryHittable=\(agentHittable(app, "pane-mystery"))",
            "sessions=\(probeDisplay(app, "companion-fixture-sessions"))",
            extra
        ].joined(separator: "\n")
        print(blob)
        let text = XCTAttachment(string: blob)
        text.name = "\(name)-frames"
        text.lifetime = .keepAlways
        add(text)
        let shot = app.screenshot()
        let image = XCTAttachment(screenshot: shot)
        image.name = name
        image.lifetime = .keepAlways
        add(image)
        let directory = evidenceDirectory
        try? blob.write(toFile: "\(directory)/\(name).txt", atomically: true, encoding: .utf8)
        try? shot.pngRepresentation.write(to: URL(fileURLWithPath: "\(directory)/\(name).png"))
    }
}
