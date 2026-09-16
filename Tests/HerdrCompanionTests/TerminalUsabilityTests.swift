import XCTest
import UIKit
import SwiftTerm
import HerdrKit
@testable import HerdrCompanion

@MainActor
final class TerminalUsabilityTests: XCTestCase {
    func testTerminalLifecycleWaitsForActiveWhenFirstPresentedInBackground() {
        var lifecycle = CompanionTerminalAttachmentLifecycle()

        lifecycle.appeared(in: .background)
        XCTAssertFalse(lifecycle.attachmentEnabled)
        XCTAssertFalse(lifecycle.hasStarted)

        XCTAssertFalse(lifecycle.sceneChanged(to: .inactive),
                       "no controller close should be queued before an attachment starts")
        XCTAssertFalse(lifecycle.attachmentEnabled)
        XCTAssertFalse(lifecycle.sceneChanged(to: .active))
        XCTAssertTrue(lifecycle.attachmentEnabled)
        XCTAssertTrue(lifecycle.hasStarted)
    }

    func testBackgroundInvalidatesPendingTerminalReconnect() throws {
        var lifecycle = CompanionTerminalAttachmentLifecycle()
        lifecycle.appeared(in: .active)
        let reconnect = try XCTUnwrap(lifecycle.beginReconnect(in: .active))

        XCTAssertTrue(lifecycle.sceneChanged(to: .background))

        XCTAssertFalse(lifecycle.finishReconnect(reconnect, in: .background))
        XCTAssertFalse(lifecycle.attachmentEnabled)
    }

    func testFingerDeltaQuantizesToOfficialWheelEventsInNaturalDirection() {
        var quantizer = CompanionScrollQuantizer()

        XCTAssertTrue(quantizer.consume(deltaY: 21).isEmpty)
        XCTAssertEqual(quantizer.consume(deltaY: 23), [.up, .up],
                       "dragging content down must request older remote history")
        quantizer.reset()
        XCTAssertEqual(quantizer.consume(deltaY: -44), [.down, .down],
                       "dragging content up must return toward the live bottom")
        XCTAssertEqual(
            CompanionRemoteScrollEncoder.sgrWheel(.up, column: 0, row: 0),
            Array("\u{1b}[<64;1;1M".utf8))
        let scrolledCell = CompanionRemoteScrollEncoder.cell(
            at: CGPoint(x: 140, y: 260), viewportOrigin: CGPoint(x: 100, y: 200),
            cellSize: CGSize(width: 10, height: 20), columns: 80, rows: 24)
        XCTAssertEqual(scrolledCell.column, 5)
        XCTAssertEqual(scrolledCell.row, 4,
                       "SGR coordinates must be viewport-relative even with local scrollback offset")
    }

    func testSyntheticKeysUseCursorModeAndSupportAllFunctionKeys() {
        let (view, capture) = terminal()

        view.sendKeyPress(.up)
        XCTAssertEqual(capture.takeLast(), Array("\u{1b}[A".utf8))

        view.feed(text: "\u{1b}[?1h")
        view.sendKeyPress(.up)
        XCTAssertEqual(capture.takeLast(), Array("\u{1b}OA".utf8))

        view.sendKeyPress(.function(10))
        XCTAssertEqual(capture.takeLast(), Array("\u{1b}[21~".utf8))
        view.sendKeyPress(.function(12))
        XCTAssertEqual(capture.takeLast(), Array("\u{1b}[24~".utf8))

        view.sendKeyPress(.left, modifiers: .option)
        XCTAssertEqual(capture.takeLast(), Array("\u{1b}[1;3D".utf8))
        view.sendKeyPress(.right, modifiers: .control)
        XCTAssertEqual(capture.takeLast(), Array("\u{1b}[1;5C".utf8))
        view.sendKeyPress(.left, modifiers: [.option, .control])
        XCTAssertEqual(capture.takeLast(), Array("\u{1b}[1;7D".utf8))
    }

    func testCombinedOneShotControlOptionIsConsumedByOneKey() {
        let (view, capture) = terminal()
        view.controlModifier = true
        view.metaModifier = true

        view.sendKeyPress(.text("c"))

        XCTAssertEqual(capture.takeLast(), [0x1b, 0x03])
        XCTAssertFalse(view.controlModifier)
        XCTAssertFalse(view.metaModifier)
    }

    func testVisibleOptionOneShotSurvivesPhysicalOptionPreferenceInKittyMode() {
        let (view, capture) = terminal()
        view.feed(text: "\u{1b}[>1u")
        view.optionAsMetaKey = false
        view.metaModifier = true

        view.sendKeyPress(.text("x"))

        XCTAssertEqual(capture.takeLast(), Array("\u{1b}[120;3u".utf8))
        XCTAssertFalse(view.metaModifier)
    }

    func testSyntheticKittyTapReportsReleaseInOneTransaction() {
        let (view, capture) = terminal()
        view.feed(text: "\u{1b}[>2u")

        view.sendKeyPress(.up)
        view.sendKeyPress(.escape)
        view.sendKeyPress(.enter)

        XCTAssertEqual(capture.calls[0], Array("\u{1b}[A\u{1b}[1;1:3A".utf8))
        XCTAssertEqual(capture.calls[1], Array("\u{1b}\u{1b}[27;1:3u".utf8),
                       "Escape keeps its legacy press and reports its release in the same transaction")
        XCTAssertEqual(capture.calls[2], [0x0d],
                       "Enter release stays suppressed without reportAllKeys")
    }

    func testSyntheticKittyReportAllTapIncludesEnterRelease() {
        let (view, capture) = terminal()
        view.feed(text: "\u{1b}[>10u")

        view.sendKeyPress(.enter)

        XCTAssertEqual(capture.calls.count, 1)
        XCTAssertEqual(capture.takeLast(), Array("\u{1b}[13u\u{1b}[13;1:3u".utf8))
    }

    func testAttachmentPasteIsOneOrderedBracketedTransactionAndDoesNotSubmit() {
        let (view, capture) = terminal()
        view.feed(text: "\u{1b}[?2004h")
        view.controlModifier = true
        view.metaModifier = true
        let path = "/Users/fixture/.herdr-companion/image.png"

        view.sendPaste(path)

        XCTAssertEqual(capture.calls.count, 1,
                       "attach parsing requires one complete bracketed-paste write")
        XCTAssertEqual(capture.takeLast(), Array("\u{1b}[200~\(path)\u{1b}[201~".utf8))
        XCTAssertFalse(capture.calls.last?.contains(0x0d) == true,
                       "inserting an attachment must not press Return")
        XCTAssertFalse(view.controlModifier)
        XCTAssertFalse(view.metaModifier)
    }

    func testAcknowledgedAttachmentPayloadUsesBracketedPasteWithoutReturn() {
        let view = CompanionInteractiveTerminalView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 600),
            font: UIFont.monospacedSystemFont(ofSize: 12, weight: .regular))
        view.feed(text: "\u{1b}[?2004h")
        let path = "/Users/fixture/.herdr-companion/image.png"

        let data = view.attachmentPasteData(path)

        XCTAssertEqual(data, Data("\u{1b}[200~\(path)\u{1b}[201~".utf8))
        XCTAssertFalse(data.contains(UInt8(ascii: "\r")))
    }

    func testAttachmentInsertionRejectsAChangedTargetIdentity() async throws {
        let view = CompanionInteractiveTerminalView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 600),
            font: UIFont.monospacedSystemFont(ofSize: 12, weight: .regular))
        let capture = TerminalCapture()
        view.terminalDelegate = capture
        view.feed(text: "\u{1b}[?2004h")
        let controller = CompanionTerminalController()
        let identity = controller.targetIdentity
        controller.adopt(view: view, identity: identity)
        controller.receivedOutput(identity: identity)

        let inserted = try await controller.insertAttachment(
            path: "/Users/fixture/image.png", identity: UUID())
        XCTAssertFalse(inserted)
        XCTAssertTrue(capture.calls.isEmpty)
    }

    func testImageNormalizationAppliesOrientationAndBoundsOutput() throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 40))
        let base = renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
        }
        let cgImage = try XCTUnwrap(base.cgImage)
        let rotated = UIImage(cgImage: cgImage, scale: 1, orientation: .right)

        let prepared = try CompanionImageNormalizer.prepare(image: rotated, preferPNG: true)

        XCTAssertEqual(prepared.image.imageOrientation, .up)
        XCTAssertEqual(prepared.image.size,
                       CGSize(width: cgImage.height, height: cgImage.width))
        XCTAssertLessThanOrEqual(prepared.data.count, 12 * 1_024 * 1_024)
        XCTAssertEqual(prepared.fileExtension, "png")
    }

    func testCompressedSourceDimensionsAreRejectedBeforeDecode() throws {
        let compressedWidePNG = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAQAEAAAABCAIAAABGP0oxAAAAR0lEQVR4nO3BMQEAAADCoPVPbQ0PoAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA4MMAwAQAAR2eTDAAAAAASUVORK5CYII="))
        XCTAssertLessThan(compressedWidePNG.count, 200)

        XCTAssertThrowsError(try CompanionImageNormalizer.prepare(
            data: compressedWidePNG, contentType: .png)) { error in
            XCTAssertEqual(
                error as? CompanionImagePreparationError,
                .sourceDimensionsTooLarge)
        }
    }

    func testLocalCopyAndSelectAllClearOneShotModifiers() {
        let view = CompanionInteractiveTerminalView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 600),
            font: UIFont.monospacedSystemFont(ofSize: 12, weight: .regular))
        let controller = CompanionTerminalController()
        let identity = controller.targetIdentity
        controller.adopt(view: view, identity: identity)
        controller.receivedOutput(identity: identity)

        controller.toggleControl()
        controller.toggleOption()
        controller.selectAll()
        XCTAssertFalse(controller.controlArmed)
        XCTAssertFalse(controller.optionArmed)

        controller.toggleControl()
        controller.toggleOption()
        view.copy(nil) // Same override used by hardware Command-C.
        XCTAssertFalse(controller.controlArmed)
        XCTAssertFalse(controller.optionArmed)
    }

    func testDiscardRecoveryRetriesExactAttachmentAndCanLeaveWithoutDeletion() throws {
        let remote = RemoteAttachment(
            path: "/Users/fixture/.herdr-companion-attachments-0123456789abcdef0123456789abcdef/attachment-7553a209-41f8-493c-aeac-4edb2aad7efa.png",
            byteCount: 42)
        let identity = UUID()
        let disposal = CompanionAttachmentDisposal(
            resource: .completed(remote), targetIdentity: identity,
            dismissAfterSuccess: true)
        let state = CompanionAttachmentState.discardFailed(disposal, "offline")
        var retried: [CompanionAttachmentDisposal] = []
        var closeCount = 0

        state.recoveryEffect(for: .retryDiscard)?.perform(
            retryDiscard: { retried.append($0) },
            closeWithoutDeletion: { closeCount += 1 })
        XCTAssertEqual(retried, [disposal], "retry must use the exact retained cleanup resource")
        XCTAssertEqual(closeCount, 0)

        let retained = try XCTUnwrap(retried.first)
        let failedAgain = CompanionAttachmentState.discardFailed(retained, "still offline")
        XCTAssertEqual(
            failedAgain.recoveryEffect(for: .retryDiscard),
            .retryDiscard(disposal),
            "another failure must preserve the same retry resource")

        failedAgain.recoveryEffect(for: .leavePrivateFile)?.perform(
            retryDiscard: { retried.append($0) },
            closeWithoutDeletion: { closeCount += 1 })
        XCTAssertEqual(retried, [disposal],
                       "leaving the private file must not issue another deletion")
        XCTAssertEqual(closeCount, 1, "leave must close the current preview flow")
    }

    private func terminal() -> (TerminalView, TerminalCapture) {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 390, height: 600),
                                font: UIFont.monospacedSystemFont(ofSize: 12, weight: .regular))
        let capture = TerminalCapture()
        view.terminalDelegate = capture
        return (view, capture)
    }
}

private final class TerminalCapture: NSObject, TerminalViewDelegate {
    private(set) var calls: [[UInt8]] = []

    func takeLast() -> [UInt8]? { calls.last }
    func send(source: TerminalView, data: ArraySlice<UInt8>) { calls.append(Array(data)) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
