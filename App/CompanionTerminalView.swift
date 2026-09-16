import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers
import ImageIO
import SwiftTerm
import HerdrKit

enum CompanionRemoteScrollDirection: Equatable { case up, down }

struct CompanionRemoteScrollEncoder {
    static func sgrWheel(_ direction: CompanionRemoteScrollDirection, column: Int, row: Int) -> [UInt8] {
        let button = direction == .up ? 64 : 65
        return Array("\u{1b}[<\(button);\(max(1, column));\(max(1, row))M".utf8)
    }

    static func cell(
        at point: CGPoint,
        viewportOrigin: CGPoint,
        cellSize: CGSize,
        columns: Int,
        rows: Int
    ) -> (column: Int, row: Int) {
        let x = point.x - viewportOrigin.x
        let y = point.y - viewportOrigin.y
        return (
            min(columns, max(1, Int(x / max(1, cellSize.width)) + 1)),
            min(rows, max(1, Int(y / max(1, cellSize.height)) + 1)))
    }
}

struct CompanionScrollQuantizer {
    static let pointsPerEvent: CGFloat = 22
    private(set) var remainder: CGFloat = 0

    mutating func consume(deltaY: CGFloat) -> [CompanionRemoteScrollDirection] {
        remainder += deltaY
        let count = min(8, Int(abs(remainder) / Self.pointsPerEvent))
        guard count > 0 else { return [] }
        let direction: CompanionRemoteScrollDirection = remainder > 0 ? .up : .down
        remainder -= CGFloat(count) * Self.pointsPerEvent * (remainder > 0 ? 1 : -1)
        return Array(repeating: direction, count: count)
    }

    mutating func reset() { remainder = 0 }
}

struct PreparedCompanionImage: Identifiable {
    let id = UUID()
    let image: UIImage
    let data: Data
    let fileExtension: String

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
    }
}

enum CompanionImagePreparationError: Error, Equatable, LocalizedError {
    case sourceTooLarge, sourceDimensionsTooLarge, unreadable, outputTooLarge

    var errorDescription: String? {
        switch self {
        case .sourceTooLarge: return "That image is over 30 MB. Choose a smaller photo or screenshot."
        case .sourceDimensionsTooLarge:
            return "That image has too many pixels to open safely. Choose a smaller photo or screenshot."
        case .unreadable: return "That file is not a readable image."
        case .outputTooLarge: return "The image is still over 12 MB after conversion. Crop it or choose a smaller image."
        }
    }
}

@MainActor
enum CompanionImageNormalizer {
    static let maximumSourceBytes = 30 * 1_024 * 1_024
    static let maximumSourceDimension: UInt64 = 16_384
    static let maximumSourcePixels: UInt64 = 64 * 1_024 * 1_024
    static let maximumDimension: CGFloat = 4_096

    static func prepare(data: Data, contentType: UTType?) throws -> PreparedCompanionImage {
        guard data.count <= maximumSourceBytes else { throw CompanionImagePreparationError.sourceTooLarge }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, options),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, options) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.uint64Value,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.uint64Value,
              width > 0, height > 0 else {
            throw CompanionImagePreparationError.unreadable
        }
        try validateSourceDimensions(width: width, height: height)

        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maximumDimension),
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, thumbnailOptions) else {
            throw CompanionImagePreparationError.unreadable
        }
        return try prepare(
            image: UIImage(cgImage: thumbnail, scale: 1, orientation: .up),
            preferPNG: contentType?.conforms(to: .png) == true)
    }

    static func prepare(image source: UIImage, preferPNG: Bool) throws -> PreparedCompanionImage {
        let pixelSize = source.cgImage.map {
            CGSize(width: $0.width, height: $0.height)
        } ?? CGSize(width: source.size.width * source.scale, height: source.size.height * source.scale)
        guard pixelSize.width.isFinite, pixelSize.height.isFinite,
              pixelSize.width > 0, pixelSize.height > 0 else {
            throw CompanionImagePreparationError.unreadable
        }
        guard pixelSize.width <= CGFloat(maximumSourceDimension),
              pixelSize.height <= CGFloat(maximumSourceDimension),
              pixelSize.width <= CGFloat(maximumSourcePixels) / pixelSize.height else {
            throw CompanionImagePreparationError.sourceDimensionsTooLarge
        }
        let orientedSize: CGSize
        switch source.imageOrientation {
        case .left, .leftMirrored, .right, .rightMirrored:
            orientedSize = CGSize(width: pixelSize.height, height: pixelSize.width)
        default:
            orientedSize = pixelSize
        }
        let longest = max(orientedSize.width, orientedSize.height)
        let initialScale = min(1, maximumDimension / max(1, longest))
        var size = CGSize(width: max(1, floor(orientedSize.width * initialScale)),
                          height: max(1, floor(orientedSize.height * initialScale)))
        let hasAlpha = source.cgImage.map {
            [.first, .last, .premultipliedFirst, .premultipliedLast].contains($0.alphaInfo)
        } ?? false
        let usePNG = preferPNG || hasAlpha

        for _ in 0..<9 {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = !hasAlpha
            let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                source.draw(in: CGRect(origin: .zero, size: size))
            }
            let encoded = usePNG ? rendered.pngData() : rendered.jpegData(compressionQuality: 0.86)
            guard let encoded else { throw CompanionImagePreparationError.unreadable }
            if encoded.count <= RemoteAttachment.maximumByteCount {
                return PreparedCompanionImage(image: rendered, data: encoded,
                                              fileExtension: usePNG ? "png" : "jpg")
            }
            size = CGSize(width: max(1, floor(size.width * 0.8)),
                          height: max(1, floor(size.height * 0.8)))
        }
        throw CompanionImagePreparationError.outputTooLarge
    }

    private static func validateSourceDimensions(width: UInt64, height: UInt64) throws {
        guard width <= maximumSourceDimension, height <= maximumSourceDimension,
              width <= maximumSourcePixels / height else {
            throw CompanionImagePreparationError.sourceDimensionsTooLarge
        }
    }
}

@MainActor
final class CompanionTerminalController: ObservableObject {
    enum State: Equatable { case connecting, connected, disconnected, failed(String) }

    @Published var state: State = .connecting
    @Published private(set) var controlArmed = false
    @Published private(set) var optionArmed = false
    @Published private(set) var keyboardVisible = false
    var suppressAutoKeyboard = false
    private(set) var targetIdentity = UUID()
    private var session: (any CompanionTerminalSessionHandle)?
    private weak var terminalView: CompanionInteractiveTerminalView?

    func adopt(view: CompanionInteractiveTerminalView, identity: UUID) {
        guard identity == targetIdentity else { return }
        terminalView = view
        view.localSelectionAction = { [weak self] in self?.clearModifiers() }
        syncModifiers()
    }

    func adopt(_ session: any CompanionTerminalSessionHandle, identity: UUID) -> Bool {
        guard identity == targetIdentity else { return false }
        self.session = session
        return true
    }

    func receivedOutput(identity: UUID) {
        guard identity == targetIdentity else { return }
        if state == .connecting { state = .connected }
    }

    func ended(_ endState: State, identity: UUID) {
        guard identity == targetIdentity else { return }
        _ = terminalView?.resignFirstResponder()
        clearModifiers()
        keyboardVisible = false
        state = endState
    }

    func sendKey(_ key: TerminalKeyPress, modifiers: TerminalKeyPressModifiers = []) {
        guard state == .connected, let terminalView else { return }
        terminalView.sendKeyPress(key, modifiers: modifiers)
        syncModifiers()
    }

    func toggleControl() {
        guard state == .connected, let terminalView else { return }
        terminalView.controlModifier.toggle()
        syncModifiers()
    }

    func toggleOption() {
        guard state == .connected, let terminalView else { return }
        terminalView.metaModifier.toggle()
        syncModifiers()
    }

    func modifierWasConsumed() { syncModifiers() }

    func copySelection() { terminalView?.copy(nil) }
    func pasteClipboardText() { guard state == .connected else { return }; clearModifiers(); terminalView?.paste(nil) }
    func selectAll() { terminalView?.selectAll(nil) }

    func toggleKeyboard() {
        guard state == .connected, let terminalView else { return }
        if terminalView.isFirstResponder { _ = terminalView.resignFirstResponder() }
        else { _ = terminalView.becomeFirstResponder() }
    }

    func responderChanged(_ visible: Bool) { keyboardVisible = visible }

    func insertAttachment(path: String, identity: UUID) async throws -> Bool {
        guard identity == targetIdentity, state == .connected, path.hasPrefix("/"),
              !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }),
              let terminalView, let session else { return false }
        let data = terminalView.attachmentPasteData(path)
        clearModifiers()
        try await session.sendAcknowledged(data)
        return true
    }

    /// Writes draft text through the same acknowledged input path as image insertion.
    /// Unsupported unbracketed multiline/control input is rejected before any write.
    func insertDraftText(_ text: String, identity: UUID) async throws -> CompanionDraftInsertResult {
        guard identity == targetIdentity, state == .connected, let terminalView, let session else {
            return .unavailable
        }
        let bracketed = terminalView.getTerminal().bracketedPasteMode
        switch CompanionDraftInsertion.validatedText(text, bracketedPaste: bracketed) {
        case .rejected(let reason):
            return .rejected(reason)
        case .accepted(let payload):
            let data = terminalView.attachmentPasteData(payload)
            clearModifiers()
            try await session.sendAcknowledged(data)
            return .written
        }
    }

    func beginReconnect() {
        terminalView?.localSelectionAction = nil
        targetIdentity = UUID()
        session = nil
        terminalView = nil
        controlArmed = false
        optionArmed = false
        keyboardVisible = false
        state = .connecting
    }

    func close() async {
        targetIdentity = UUID()
        _ = terminalView?.resignFirstResponder()
        clearModifiers()
        terminalView?.localSelectionAction = nil
        let held = session
        session = nil
        terminalView = nil
        keyboardVisible = false
        await held?.close()
    }

    private func clearModifiers() {
        terminalView?.controlModifier = false
        terminalView?.metaModifier = false
        controlArmed = false
        optionArmed = false
    }

    private func syncModifiers() {
        controlArmed = terminalView?.controlModifier ?? false
        optionArmed = terminalView?.metaModifier ?? false
    }

    var isReconnectable: Bool {
        switch state {
        case .disconnected, .failed: return true
        case .connecting, .connected: return false
        }
    }
}

final class CompanionInteractiveTerminalView: TerminalView {
    var responderChanged: ((Bool) -> Void)?
    var localSelectionAction: (() -> Void)?

    override init(frame: CGRect, font: UIFont?) {
        super.init(frame: frame, font: font)
    }

    override func becomeFirstResponder() -> Bool {
        let changed = super.becomeFirstResponder()
        if changed { responderChanged?(true) }
        return changed
    }

    override func resignFirstResponder() -> Bool {
        let changed = super.resignFirstResponder()
        if changed { responderChanged?(false) }
        return changed
    }

    @objc override func copy(_ sender: Any?) {
        super.copy(sender)
        localSelectionAction?()
    }

    @objc override func selectAll(_ sender: Any?) {
        super.selectAll(sender)
        localSelectionAction?()
    }

    func attachmentPasteData(_ text: String) -> Data {
        var bytes: [UInt8] = []
        if getTerminal().bracketedPasteMode { bytes += EscapeSequences.bracketedPasteStart }
        bytes += text.utf8
        if getTerminal().bracketedPasteMode { bytes += EscapeSequences.bracketedPasteEnd }
        return Data(bytes)
    }

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(input: "c", modifierFlags: .command, action: #selector(copy(_:)), discoverabilityTitle: "Copy"),
            UIKeyCommand(input: "v", modifierFlags: .command, action: #selector(paste(_:)), discoverabilityTitle: "Paste"),
            UIKeyCommand(input: "a", modifierFlags: .command, action: #selector(selectAll(_:)), discoverabilityTitle: "Select All"),
        ]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

enum CompanionAttachmentDisposalResource: Equatable {
    case completed(RemoteAttachment)
    case incomplete(RemoteAttachmentCleanup)
}

struct CompanionAttachmentDisposal: Equatable {
    let resource: CompanionAttachmentDisposalResource
    let targetIdentity: UUID
    let dismissAfterSuccess: Bool
}

enum CompanionAttachmentState: Equatable {
    case ready
    case uploading
    case cancellingUpload
    case uploaded(RemoteAttachment, UUID, String?)
    case inserting(RemoteAttachment, UUID)
    case discarding(CompanionAttachmentDisposal)
    case discardFailed(CompanionAttachmentDisposal, String)
    case unknownOutcome(RemoteAttachment, UUID)
    case failed(String)

    var requiresExplicitDismissal: Bool {
        switch self {
        case .ready, .failed: return false
        case .uploading, .cancellingUpload, .uploaded, .inserting, .discarding, .discardFailed, .unknownOutcome:
            return true
        }
    }
}

enum CompanionAttachmentRecoveryAction {
    case retryDiscard
    case leavePrivateFile
}

enum CompanionAttachmentRecoveryEffect: Equatable {
    case retryDiscard(CompanionAttachmentDisposal)
    case closeWithoutDeletion

    func perform(
        retryDiscard: (CompanionAttachmentDisposal) -> Void,
        closeWithoutDeletion: () -> Void
    ) {
        switch self {
        case .retryDiscard(let disposal): retryDiscard(disposal)
        case .closeWithoutDeletion: closeWithoutDeletion()
        }
    }
}

extension CompanionAttachmentState {
    var discardsOnCancel: Bool {
        switch self {
        case .uploaded, .discardFailed: return true
        case .ready, .uploading, .cancellingUpload, .inserting, .discarding, .unknownOutcome, .failed:
            return false
        }
    }

    var preservedOnTeardown: (payload: CompanionInsertionPayload, unknown: Bool)? {
        switch self {
        case .unknownOutcome(let remote, _):
            return (.uploaded(remote), true)
        case .uploaded(let remote, _, _):
            return (.uploaded(remote), false)
        case .discardFailed(let disposal, _), .discarding(let disposal):
            switch disposal.resource {
            case .completed(let remote):
                return (.uploaded(remote), false)
            case .incomplete(let cleanup):
                return (.incompleteCleanup(cleanup), false)
            }
        default:
            return nil
        }
    }

    func recoveryEffect(
        for action: CompanionAttachmentRecoveryAction
    ) -> CompanionAttachmentRecoveryEffect? {
        guard case .discardFailed(let disposal, _) = self else { return nil }
        switch action {
        case .retryDiscard: return .retryDiscard(disposal)
        case .leavePrivateFile: return .closeWithoutDeletion
        }
    }
}

struct CompanionTerminalAttachmentLifecycle {
    private(set) var attachmentEnabled = false
    private(set) var hasStarted = false
    private(set) var generation = UUID()

    mutating func appeared(in phase: ScenePhase) {
        guard phase == .active, !hasStarted else { return }
        hasStarted = true
        attachmentEnabled = true
    }

    mutating func sceneChanged(to phase: ScenePhase) -> Bool {
        if phase == .active {
            appeared(in: phase)
            return false
        } else {
            let shouldClose = hasStarted
            generation = UUID()
            attachmentEnabled = false
            return shouldClose
        }
    }

    mutating func beginReconnect(in phase: ScenePhase) -> UUID? {
        guard phase == .active else { return nil }
        generation = UUID()
        attachmentEnabled = false
        return generation
    }

    mutating func finishReconnect(_ token: UUID, in phase: ScenePhase) -> Bool {
        guard phase == .active, token == generation else { return false }
        hasStarted = true
        attachmentEnabled = true
        return true
    }

    mutating func disappeared() -> Bool {
        let shouldClose = hasStarted
        generation = UUID()
        attachmentEnabled = false
        return shouldClose
    }
}

struct CompanionTerminalScreen: View {
    let transport: CitadelTransport?
    let opener: CompanionTerminalOpener
    let title: String
    let target: OfficialTerminalAttachmentTarget
    var notice: String? = nil
    var location: CompanionTerminalLocation? = nil
    var initiallyShowKeys = false
    var initiallyShowDraft = false
    var initiallyShowAttachment = false
    var insertionModel: CompanionConnectionModel? = nil
    var insertionOwner: CompanionInsertionOwner? = nil
    @State private var capturedOwner: CompanionInsertionOwner?

    init(
        transport: CitadelTransport,
        title: String,
        target: OfficialTerminalAttachmentTarget,
        notice: String? = nil,
        location: CompanionTerminalLocation? = nil,
        opener: CompanionTerminalOpener? = nil,
        initiallyShowKeys: Bool = false,
        initiallyShowDraft: Bool = false,
        initiallyShowAttachment: Bool = false,
        insertionModel: CompanionConnectionModel? = nil,
        insertionOwner: CompanionInsertionOwner? = nil
    ) {
        self.transport = transport
        self.opener = opener ?? CompanionTerminalOpeners.official(transport)
        self.title = title
        self.target = target
        self.notice = notice
        self.location = location
        self.initiallyShowKeys = initiallyShowKeys
        self.initiallyShowDraft = initiallyShowDraft
        self.initiallyShowAttachment = initiallyShowAttachment
        self.insertionModel = insertionModel
        self.insertionOwner = insertionOwner
    }

    init(
        transport: CitadelTransport?,
        opener: @escaping CompanionTerminalOpener,
        title: String,
        target: OfficialTerminalAttachmentTarget,
        notice: String? = nil,
        location: CompanionTerminalLocation? = nil,
        initiallyShowKeys: Bool = false,
        initiallyShowDraft: Bool = false,
        initiallyShowAttachment: Bool = false,
        insertionModel: CompanionConnectionModel? = nil,
        insertionOwner: CompanionInsertionOwner? = nil
    ) {
        self.transport = transport
        self.opener = opener
        self.title = title
        self.target = target
        self.notice = notice
        self.location = location
        self.initiallyShowKeys = initiallyShowKeys
        self.initiallyShowDraft = initiallyShowDraft
        self.initiallyShowAttachment = initiallyShowAttachment
        self.insertionModel = insertionModel
        self.insertionOwner = insertionOwner
    }

    @StateObject private var controller = CompanionTerminalController()
    @State private var attachmentID = UUID()
    @State private var attachmentLifecycle = CompanionTerminalAttachmentLifecycle()
    @State private var terminalLifecycleTask: Task<Void, Never>?
    @State private var showKeys = false
    @State private var showAttachmentSources = false
    @State private var showPhotoPicker = false
    @State private var showFilePicker = false
    @State private var pasteImageAvailable = false
    @State private var photoItem: PhotosPickerItem?
    @State private var preparedImage: PreparedCompanionImage?
    @State private var attachmentFlowID: UUID?
    @State private var attachmentTargetIdentity: UUID?
    @State private var photoPickerFlowID: UUID?
    @State private var filePickerFlowID: UUID?
    @State private var attachmentState: CompanionAttachmentState = .ready
    @State private var attachmentTask: Task<Void, Never>?
    @State private var attachmentError: String?
    @State private var showDraft = false
    @State private var draftText = ""
    @State private var draftBusy = false
    @State private var draftError: String?
    @State private var draftFlowID = UUID()
    @State private var submittedDraftID: UUID?
    @State private var measuredDockItemWidths: [String: CGFloat] = [:]
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.companionSplitBrowser) private var splitBrowser

    private var terminalSceneIsActive: Bool {
        if scenePhase == .active { return true }
#if DEBUG
        return insertionModel?.testActivateTerminalScene == true
#else
        return false
#endif
    }

    private var showsReconnectControl: Bool {
        scenePhase == .active && controller.isReconnectable
    }

    @ToolbarContentBuilder
    private var reconnectToolbar: some ToolbarContent {
        if let splitBrowser, !splitBrowser.browsing {
            ToolbarItem(placement: .topBarLeading) {
                CompanionSplitBrowserControl(browsing: false, action: splitBrowser.toggle)
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if showsReconnectControl {
                Button("Reconnect") { reconnect() }
                    .font(Typography.app(14, .semibold))
                    .accessibilityIdentifier("companion-terminal-reconnect")
            }
        }
    }

    static func attachmentTarget(for agent: AgentInfo) -> String? {
        CompanionCreationContext.agentPaneID(for: agent)
    }

    var body: some View {
        VStack(spacing: 0) {
            terminalContext
            if attachmentLifecycle.attachmentEnabled, terminalSceneIsActive {
                CompanionTerminalRepresentable(opener: opener, target: target, controller: controller)
                    .id(attachmentID)
                    .background(Palette.groundMachine)
                    .accessibilityIdentifier("companion-terminal-surface")
            } else { Palette.groundMachine }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            inputDock
                .disabled(draftBusy)
        }
        .background(Palette.groundMachine.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { reconnectToolbar }
        .confirmationDialog("Attach an image", isPresented: $showAttachmentSources) {
            Button("Photos") {
                photoPickerFlowID = attachmentFlowID
                showPhotoPicker = true
            }
            Button("Image from Files") {
                filePickerFlowID = attachmentFlowID
                showFilePicker = true
            }
            if pasteImageAvailable { Button("Paste Image") { preparePastedImage() } }
            Button("Cancel", role: .cancel) { cancelAttachment() }
        } message: {
            Text("Choose one photo or screenshot. Nothing is submitted until you insert it.")
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in if let item { loadPhoto(item) } }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.image]) { loadFile($0) }
        .sheet(isPresented: $showKeys) {
            CompanionKeysPanel(controller: controller)
                .presentationDetents([.height(420), .medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showDraft) {
            CompanionDraftEditor(
                text: draftBinding,
                busy: draftBusy,
                error: draftError,
                location: location,
                onInsert: insertDraft,
                onCancel: { showDraft = false; draftError = nil })
            .interactiveDismissDisabled(draftBusy)
        }
        .sheet(item: $preparedImage, onDismiss: preserveOwnedUploadAcrossLifecycle) { image in
            CompanionAttachmentPreview(prepared: image, state: attachmentState,
                location: location,
                upload: { upload(image) }, insert: insertUploadedAttachment,
                retryDiscard: { performDiscardRecovery(.retryDiscard) },
                leavePrivateFile: { performDiscardRecovery(.leavePrivateFile) },
                cancel: cancelAttachment)
                .interactiveDismissDisabled(attachmentState.requiresExplicitDismissal)
        }
        .alert("Attachment", isPresented: Binding(get: { attachmentError != nil },
            set: { if !$0 { attachmentError = nil } })) {
                Button("OK", role: .cancel) { attachmentError = nil }
        } message: { Text(attachmentError ?? "") }
        .onAppear {
            attachmentLifecycle.appeared(in: terminalSceneIsActive ? .active : scenePhase)
            if capturedOwner == nil {
                capturedOwner = insertionOwner
                    ?? insertionModel?.recoveryOwner
                    ?? insertionModel?.connectedSavedHost.map(CompanionInsertionOwner.init)
            }
            insertionModel?.attachInsertController(controller)
            if initiallyShowKeys || initiallyShowDraft || initiallyShowAttachment {
                controller.suppressAutoKeyboard = true
            }
            if initiallyShowKeys { showKeys = true }
            if initiallyShowDraft { showDraft = true }
            if initiallyShowAttachment {
                preparedImage = PreparedCompanionImage(
                    image: UIImage(systemName: "photo") ?? UIImage(),
                    data: Data([0x89, 0x50, 0x4E, 0x47]),
                    fileExtension: "png")
                attachmentState = .ready
                attachmentFlowID = UUID()
                attachmentTargetIdentity = controller.targetIdentity
            }
            startFixtureAttachmentIfNeeded()
        }
#if DEBUG
        .background {
            if let insertionModel {
                CompanionDraftEditorCommandSeam(model: insertionModel, apply: applyEditorCommand)
            }
        }
#endif
        .onChange(of: scenePhase) { _, phase in
            let shouldClose = attachmentLifecycle.sceneChanged(to: phase)
            guard phase != .active else { return }
            preserveOwnedUploadAcrossLifecycle()
            if shouldClose { enqueueTerminalClose() }
        }
        .onChange(of: controller.state) { _, state in
            if state == .connected {
                startFixtureAttachmentIfNeeded()
            }
            guard state != .connected, preparedImage != nil else { return }
            preserveOwnedUploadAcrossLifecycle()
            if case .inserting = attachmentState {
                attachmentError = "The terminal disconnected while inserting. The preview will stay until the write outcome is known."
            }
        }
        .onDisappear {
            handOffInsertionOnTeardown()
            if attachmentLifecycle.disappeared() { enqueueTerminalClose() }
        }
    }

    @ViewBuilder private var terminalContext: some View {
        compactContextStrip
        if let notice, !notice.isEmpty { noticeBanner }
    }

    private var noticeBanner: some View {
        Label(notice ?? "", systemImage: "exclamationmark.triangle.fill")
            .font(Typography.app(12))
            .foregroundStyle(Palette.waiting)
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface)
            .accessibilityIdentifier("companion-terminal-notice")
    }

    private var compactContextStrip: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let location {
                    CompanionLocationBar(
                        mac: location.mac, session: location.session,
                        workspace: location.workspace, terminal: location.terminal,
                        compact: true)
                }
                compactStatusLabel
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 6)
            if case .failed(let message) = controller.state {
                Text(message)
                    .font(Typography.app(12))
                    .foregroundStyle(Palette.died)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 13)
                    .padding(.bottom, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(compactContextAccessibility)
        .accessibilityIdentifier("companion-terminal-context")
    }

    @ViewBuilder private var compactStatusLabel: some View {
        switch controller.state {
        case .connecting:
            HStack(spacing: 6) {
                ProgressView().tint(Palette.working).scaleEffect(0.8)
                Text("Connecting")
            }
            .font(Typography.app(12, .semibold))
            .foregroundStyle(Palette.working)
        case .connected:
            HStack(spacing: 6) {
                Circle().fill(Palette.done).frame(width: 6, height: 6)
                Text("Connected · drag to scroll")
            }
            .font(Typography.app(12, .semibold))
            .foregroundStyle(Palette.done)
        case .disconnected:
            Text("Disconnected")
                .font(Typography.app(12, .semibold))
                .foregroundStyle(Palette.textFaint)
        case .failed:
            Text("Disconnected")
                .font(Typography.app(12, .semibold))
                .foregroundStyle(Palette.died)
        }
    }

    private var compactContextAccessibility: String {
        var parts: [String] = []
        if let location {
            parts.append(location.mac)
            parts.append(location.session)
            if let workspace = location.workspace { parts.append(workspace) }
            if let terminal = location.terminal { parts.append(terminal) }
        }
        switch controller.state {
        case .connecting: parts.append("Connecting")
        case .connected: parts.append("Connected, drag to scroll")
        case .disconnected: parts.append("Disconnected")
        case .failed(let message): parts.append("Disconnected, \(message)")
        }
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private var inputDock: some View {
        ViewThatFits(in: .horizontal) {
            dockRow(items: Array(DockItem.allCases), fillsWidth: true)
                .frame(minWidth: dockRowMinWidth(Array(DockItem.allCases)))
            VStack(spacing: 6) {
                dockRow(items: Array(DockItem.allCases.prefix(5)), fillsWidth: true)
                dockRow(items: Array(DockItem.allCases.suffix(3)), fillsWidth: true)
            }
            .frame(minWidth: dockRowMinWidth(Array(DockItem.allCases.prefix(5))))
            CompanionWrappingHStack(spacing: 5) {
                ForEach(DockItem.allCases) { item in
                    dockControl(item, fillsWidth: false)
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 8).frame(maxWidth: .infinity)
        .onPreferenceChange(CompanionDockIntrinsicWidthKey.self) { measuredDockItemWidths = $0 }
        .background(Palette.surface)
        .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
        .overlay(alignment: .topLeading) {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityIdentifier("companion-terminal-dock")
                .accessibilityLabel("Terminal controls")
        }
    }

    private func dockRowMinWidth(_ items: [DockItem]) -> CGFloat {
        guard !items.isEmpty else { return 0 }
        let spacing = CGFloat(max(0, items.count - 1)) * 5
        return items.reduce(0) { $0 + dockItemIdealWidth($1) } + spacing
    }

    private func dockItemIdealWidth(_ item: DockItem) -> CGFloat {
        if let measured = measuredDockItemWidths[item.dockID], measured > 0 {
            return max(44, ceil(measured))
        }
        let label: String?
        var hasIcon = false
        switch item {
        case .escape: label = "esc"
        case .tab: label = "tab"
        case .control: label = "ctrl"
        case .option: label = "option"
        case .keyboard:
            label = nil
            hasIcon = true
        case .image:
            label = "image"
            hasIcon = true
        case .draft:
            label = "draft"
            hasIcon = true
        case .keys:
            label = "keys"
            hasIcon = true
        }
        let textWidth = label.map { dockLabelWidth($0) } ?? 0
        let iconWidth: CGFloat = hasIcon ? 22 : 0
        return max(44, max(textWidth, iconWidth) + 16)
    }

    private func dockLabelWidth(_ text: String) -> CGFloat {
        let base = UIFont(name: "IBMPlexMono-SmBld", size: 9)
            ?? UIFont(name: "IBMPlexMono-SemiBold", size: 9)
            ?? .monospacedSystemFont(ofSize: 9, weight: .semibold)
        let traits = UITraitCollection(preferredContentSizeCategory: Self.contentSizeCategory(dynamicTypeSize))
        let font = UIFontMetrics(forTextStyle: .body).scaledFont(for: base, compatibleWith: traits)
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: 44),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil)
        return ceil(bounds.width)
    }

    private static func contentSizeCategory(_ size: DynamicTypeSize) -> UIContentSizeCategory {
        switch size {
        case .xSmall: return .extraSmall
        case .small: return .small
        case .medium: return .medium
        case .large: return .large
        case .xLarge: return .extraLarge
        case .xxLarge: return .extraExtraLarge
        case .xxxLarge: return .extraExtraExtraLarge
        case .accessibility1: return .accessibilityMedium
        case .accessibility2: return .accessibilityLarge
        case .accessibility3: return .accessibilityExtraLarge
        case .accessibility4: return .accessibilityExtraExtraLarge
        case .accessibility5: return .accessibilityExtraExtraExtraLarge
        default: return .large
        }
    }

    private enum DockItem: String, CaseIterable, Identifiable {
        case escape, tab, control, option, keyboard, image, draft, keys
        var id: String { rawValue }
        var dockID: String {
            switch self {
            case .escape: return "companion-dock-escape"
            case .tab: return "companion-dock-tab"
            case .control: return "companion-dock-ctrl"
            case .option: return "companion-dock-option"
            case .keyboard: return "companion-dock-keyboard"
            case .image: return "companion-dock-image"
            case .draft: return "companion-dock-draft"
            case .keys: return "companion-dock-keys"
            }
        }
    }

    private func dockRow(items: [DockItem], fillsWidth: Bool) -> some View {
        HStack(spacing: 5) {
            ForEach(items) { item in
                dockControl(item, fillsWidth: fillsWidth)
            }
        }
    }

    @ViewBuilder
    private func dockControl(_ item: DockItem, fillsWidth: Bool) -> some View {
        switch item {
        case .escape:
            dockButton("Escape", text: "esc", identifier: "companion-dock-escape", fillsWidth: fillsWidth) {
                controller.sendKey(.escape)
            }
        case .tab:
            dockButton("Tab", text: "tab", identifier: "companion-dock-tab", fillsWidth: fillsWidth) {
                controller.sendKey(.tab)
            }
        case .control:
            modifierButton("ctrl", active: controller.controlArmed, identifier: "companion-dock-ctrl", fillsWidth: fillsWidth) {
                controller.toggleControl()
            }
        case .option:
            modifierButton("option", active: controller.optionArmed, identifier: "companion-dock-option", fillsWidth: fillsWidth) {
                controller.toggleOption()
            }
        case .keyboard:
            dockButton(
                controller.keyboardVisible ? "Hide keyboard" : "Show keyboard",
                systemImage: controller.keyboardVisible ? "keyboard.chevron.compact.down" : "keyboard",
                identifier: "companion-dock-keyboard", fillsWidth: fillsWidth) {
                controller.toggleKeyboard()
            }
        case .image:
            dockButton("Attach image", systemImage: "paperclip", text: "image",
                       identifier: "companion-dock-image", fillsWidth: fillsWidth) {
                attachmentFlowID = UUID()
                attachmentTargetIdentity = controller.targetIdentity
                pasteImageAvailable = UIPasteboard.general.hasImages
                showAttachmentSources = true
            }
            .disabled(controller.state != .connected || transport == nil)
        case .draft:
            dockButton("Compose draft", systemImage: "square.and.pencil", text: "draft",
                       identifier: "companion-dock-draft", fillsWidth: fillsWidth) {
                beginNewDraftIfCurrentFlowIsOwned()
                draftError = nil
                showDraft = true
            }
        case .keys:
            dockButton("Open terminal keys", systemImage: "square.grid.3x3", text: "keys",
                       identifier: "companion-dock-keys", fillsWidth: fillsWidth) {
                showKeys = true
            }
        }
    }

    private func dockButton(
        _ accessibilityLabel: String, systemImage: String? = nil,
        text: String? = nil, identifier: String, fillsWidth: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            dockLabel(systemImage: systemImage, text: text)
                .foregroundStyle(Palette.textDim)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: CompanionDockIntrinsicWidthKey.self,
                            value: [identifier: proxy.size.width])
                    }
                }
                .frame(minWidth: 44, maxWidth: fillsWidth ? .infinity : nil, minHeight: 44)
                .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(identifier)
        .disabled(controller.state != .connected)
    }

    private func modifierButton(
        _ label: String, active: Bool, identifier: String, fillsWidth: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label).font(Typography.machine(9, .semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: CompanionDockIntrinsicWidthKey.self,
                            value: [identifier: proxy.size.width])
                    }
                }
                .foregroundStyle(active ? Palette.groundMachine : Palette.textDim)
                .frame(minWidth: 44, maxWidth: fillsWidth ? .infinity : nil, minHeight: 44)
                .background(active ? Palette.accent : Palette.surfaceRaised,
                            in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("One-shot \(label)")
        .accessibilityIdentifier(identifier)
        .accessibilityValue(active ? "On" : "Off")
        .disabled(controller.state != .connected)
    }

    @ViewBuilder
    private func dockLabel(systemImage: String?, text: String?) -> some View {
        VStack(spacing: 2) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 15, weight: .semibold)) }
            if let text { Text(text).font(Typography.machine(9, .semibold)) }
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func reconnect() {
        cancelAttachment()
        guard let token = attachmentLifecycle.beginReconnect(in: scenePhase) else { return }
        let prior = terminalLifecycleTask
        let task = Task { @MainActor in
            _ = await prior?.value
            guard attachmentLifecycle.generation == token, scenePhase == .active else { return }
            await controller.close()
            guard attachmentLifecycle.generation == token, scenePhase == .active else { return }
            controller.beginReconnect()
            attachmentID = UUID()
            _ = attachmentLifecycle.finishReconnect(token, in: scenePhase)
        }
        terminalLifecycleTask = task
    }

    private func enqueueTerminalClose() {
        let token = attachmentLifecycle.generation
        let prior = terminalLifecycleTask
        let task = Task { @MainActor in
            _ = await prior?.value
            guard attachmentLifecycle.generation == token else { return }
            await controller.close()
            guard attachmentLifecycle.generation == token else { return }
            controller.state = .disconnected
        }
        terminalLifecycleTask = task
    }

    private func prepare(data: Data, contentType: UTType?, flowID: UUID) {
        guard flowID == attachmentFlowID else { return }
        guard attachmentTargetIdentity == controller.targetIdentity,
              controller.state == .connected else {
            attachmentError = "The terminal target changed while choosing the image. Reopen Attach and try again."
            return
        }
        do { preparedImage = try CompanionImageNormalizer.prepare(data: data, contentType: contentType); attachmentState = .ready }
        catch { attachmentError = error.localizedDescription }
    }

    private func loadPhoto(_ item: PhotosPickerItem) {
        guard let flowID = photoPickerFlowID else { return }
        Task {
            defer {
                if flowID == attachmentFlowID {
                    photoItem = nil
                    photoPickerFlowID = nil
                }
            }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw CompanionImagePreparationError.unreadable
                }
                guard flowID == attachmentFlowID else { return }
                prepare(data: data, contentType: item.supportedContentTypes.first, flowID: flowID)
            } catch {
                if flowID == attachmentFlowID { attachmentError = error.localizedDescription }
            }
        }
    }

    private func loadFile(_ result: Result<URL, Error>) {
        guard let flowID = filePickerFlowID else { return }
        Task {
            do {
                let url = try result.get()
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
                if let size = values.fileSize, size > CompanionImageNormalizer.maximumSourceBytes {
                    throw CompanionImagePreparationError.sourceTooLarge
                }
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                guard flowID == attachmentFlowID else { return }
                prepare(data: data, contentType: values.contentType, flowID: flowID)
            } catch {
                if flowID == attachmentFlowID { attachmentError = error.localizedDescription }
            }
        }
    }

    private func preparePastedImage() {
        guard let flowID = attachmentFlowID else { return }
        guard let image = UIPasteboard.general.image else {
            attachmentError = "The clipboard no longer contains an image."; return
        }
        guard flowID == attachmentFlowID,
              attachmentTargetIdentity == controller.targetIdentity,
              controller.state == .connected else {
            attachmentError = "The terminal target changed. Reopen Attach and try again."
            return
        }
        do { preparedImage = try CompanionImageNormalizer.prepare(image: image, preferPNG: true); attachmentState = .ready }
        catch { attachmentError = error.localizedDescription }
    }

    private func upload(_ image: PreparedCompanionImage) {
        switch attachmentState {
        case .ready, .failed: break
        default: return
        }
        guard let flowID = attachmentFlowID,
              let identity = attachmentTargetIdentity,
              identity == controller.targetIdentity, controller.state == .connected else {
            attachmentState = .failed("The terminal target changed. Reopen Attach and upload again.")
            return
        }
        if let insertionModel, let owner = capturedOwner {
            insertionModel.beginAttachmentFlow(
                id: flowID, owner: owner, target: target, title: title)
        }
        attachmentState = .uploading
        attachmentTask = Task {
            defer {
                if flowID == attachmentFlowID { attachmentTask = nil }
            }
            do {
                let remote = try await uploadService().uploadAttachment(
                    data: image.data, fileExtension: image.fileExtension)
                insertionModel?.completeAttachmentUpload(id: flowID, remote: remote)
                let cancelled = Task.isCancelled
                if cancelled || flowID != attachmentFlowID {
                    await resolveInterruptedUpload(remote, identity: identity, flowID: flowID)
                    return
                }
                guard identity == controller.targetIdentity, controller.state == .connected else {
                    await resolveInterruptedUpload(remote, identity: identity, flowID: flowID)
                    return
                }
                attachmentState = .uploaded(remote, identity, nil)
#if DEBUG
                if insertionModel?.fixtureBeginInsert == true {
                    insertUploadedAttachment()
                } else if insertionModel?.fixtureBeginCancel == true {
                    cancelAttachment()
                }
#endif
            } catch is CancellationError {
                insertionModel?.failAttachmentUpload(
                    id: flowID, cleanup: nil,
                    message: "The upload was canceled before a remote file existed.")
                if flowID == attachmentFlowID { clearAttachmentFlow() }
            } catch let error as RemoteAttachmentError {
                if case .cleanupRequired(let cleanup, _) = error {
                    insertionModel?.failAttachmentUpload(
                        id: flowID, cleanup: cleanup,
                        message: error.localizedDescription)
                    if flowID == attachmentFlowID {
                        let disposal = CompanionAttachmentDisposal(
                            resource: .incomplete(cleanup), targetIdentity: identity,
                            dismissAfterSuccess: Task.isCancelled || attachmentState == .cancellingUpload)
                        attachmentState = .discardFailed(disposal, error.localizedDescription)
                    }
                } else {
                    insertionModel?.failAttachmentUpload(
                        id: flowID, cleanup: nil, message: error.localizedDescription)
                    if flowID == attachmentFlowID {
                        if Task.isCancelled || attachmentState == .cancellingUpload {
                            clearAttachmentFlow()
                        } else {
                            attachmentState = .failed(error.localizedDescription)
                        }
                    }
                }
            } catch {
                insertionModel?.failAttachmentUpload(
                    id: flowID, cleanup: nil, message: error.localizedDescription)
                if flowID == attachmentFlowID {
                    if Task.isCancelled || attachmentState == .cancellingUpload {
                        clearAttachmentFlow()
                    } else {
                        attachmentState = .failed(error.localizedDescription)
                    }
                }
            }
        }
    }

    private func startFixtureAttachmentIfNeeded() {
#if DEBUG
        guard controller.state == .connected else { return }
        if insertionModel?.fixtureBeginUpload == true,
           case .ready = attachmentState,
           let prepared = preparedImage {
            insertionModel?.fixtureBeginUpload = false
            upload(prepared)
        }
        if let text = insertionModel?.fixtureDraftText {
            insertionModel?.fixtureDraftText = nil
            draftText = text
            insertDraft()
        }
        if let command = insertionModel?.fixtureEditorCommand {
            insertionModel?.fixtureEditorCommand = nil
            applyEditorCommand(command)
        }
#endif
    }

    private func uploadService() -> CompanionAttachmentUploading {
        if let insertionModel { return insertionModel.uploadPerformer() }
        if let transport { return CompanionTransportUpload(transport: transport) }
        return CompanionUnavailableUpload()
    }

    private func insertUploadedAttachment() {
        guard case .uploaded(let remote, let identity, _) = attachmentState else { return }
        guard let flowID = attachmentFlowID else { return }
        attachmentState = .inserting(remote, identity)
        attachmentTask = Task {
            defer { if flowID == attachmentFlowID { attachmentTask = nil } }
            if let insertionModel {
                _ = await insertionModel.submitUploadedPath(
                    remote, controller: controller, owner: capturedOwner,
                    target: target, title: title, id: flowID)
                clearAttachmentFlow()
                return
            }
            do {
                let written = try await controller.insertAttachment(
                    path: remote.path, identity: identity)
                guard flowID == attachmentFlowID else { return }
                if written {
                    clearAttachmentFlow()
                } else {
                    attachmentState = .uploaded(
                        remote, identity,
                        "The terminal target changed before the path was written. Discard this upload, then reopen Attach on the current connection.")
                }
            } catch let error as OfficialTerminalInputError {
                guard flowID == attachmentFlowID else { return }
                attachmentState = .uploaded(
                    remote, identity,
                    "The path was not accepted (\(error.localizedDescription)). Discard this upload, then retry on the current connection.")
            } catch {
                guard flowID == attachmentFlowID else { return }
                attachmentState = .unknownOutcome(remote, identity)
                attachmentError = "The path write outcome is unknown (\(error.localizedDescription)). The private file was not deleted."
            }
        }
    }

    private func preserveOwnedUploadAcrossLifecycle() {
        if case .uploading = attachmentState,
           let flowID = attachmentFlowID,
           insertionModel?.receipt(id: flowID) != nil {
            return
        }
        cancelAttachment()
    }

    private func cancelAttachment() {
        if attachmentState.discardsOnCancel {
            switch attachmentState {
            case .uploaded(let remote, let identity, _):
                beginDiscard(CompanionAttachmentDisposal(
                    resource: .completed(remote), targetIdentity: identity,
                    dismissAfterSuccess: true))
            case .discardFailed(let disposal, _):
                beginDiscard(CompanionAttachmentDisposal(
                    resource: disposal.resource, targetIdentity: disposal.targetIdentity,
                    dismissAfterSuccess: true))
            default:
                break
            }
            return
        }
        switch attachmentState {
        case .ready, .failed, .unknownOutcome:
            clearAttachmentFlow()
        case .uploading:
            attachmentState = .cancellingUpload
            attachmentTask?.cancel()
        default:
            break
        }
    }

    private func performDiscardRecovery(_ action: CompanionAttachmentRecoveryAction) {
        attachmentState.recoveryEffect(for: action)?.perform(
            retryDiscard: { beginDiscard($0) },
            closeWithoutDeletion: {
                if let flowID = attachmentFlowID {
                    insertionModel?.forgetReceiptIfPresent(id: flowID)
                }
                clearAttachmentFlow()
            })
    }

    private func beginDiscard(_ disposal: CompanionAttachmentDisposal) {
        guard let flowID = attachmentFlowID else { return }
        attachmentState = .discarding(disposal)
        attachmentTask = Task {
            defer { if flowID == attachmentFlowID { attachmentTask = nil } }
            let message = await discardThroughModel(flowID: flowID, disposal: disposal)
            if flowID != attachmentFlowID { return }
            if message == nil {
                if disposal.dismissAfterSuccess { clearAttachmentFlow() }
                else { attachmentState = .ready }
            } else {
                attachmentState = .discardFailed(disposal, message ?? "Cleanup failed.")
            }
        }
    }

    private func resolveInterruptedUpload(
        _ remote: RemoteAttachment, identity: UUID, flowID: UUID
    ) async {
        let disposal = CompanionAttachmentDisposal(
            resource: .completed(remote), targetIdentity: identity,
            dismissAfterSuccess: true)
        let message = await discardThroughModel(flowID: flowID, disposal: disposal)
        if flowID != attachmentFlowID { return }
        if message == nil {
            clearAttachmentFlow()
        } else {
            attachmentState = .discardFailed(disposal, message ?? "Cleanup failed.")
        }
    }

    private func discardThroughModel(
        flowID: UUID, disposal: CompanionAttachmentDisposal
    ) async -> String? {
        if let insertionModel {
            switch disposal.resource {
            case .completed(let remote):
                insertionModel.completeAttachmentUpload(id: flowID, remote: remote)
            case .incomplete(let cleanup):
                insertionModel.failAttachmentUpload(
                    id: flowID, cleanup: cleanup,
                    message: "A private upload did not finish cleanup. Reconnect to this Mac to retry Discard.")
            }
            return await insertionModel.discardAttachment(id: flowID)
        }
        do {
            guard let transport else {
                return "Cleanup needs a live connection to this Mac."
            }
            switch disposal.resource {
            case .completed(let remote):
                try await transport.removeUninsertedAttachment(remote)
            case .incomplete(let cleanup):
                try await transport.retryAttachmentCleanup(cleanup)
            }
            return nil
        } catch {
            return "The private upload is still on this Mac because cleanup failed (\(error.localizedDescription)). Reconnect to this host and retry Discard."
        }
    }

    private var draftBinding: Binding<String> {
        Binding(
            get: { draftText },
            set: { newValue in
                if newValue != draftText,
                   submittedDraftID != nil
                    || insertionModel?.receipt(id: draftFlowID) != nil
                    || insertionModel?.wasForgotten(draftFlowID) == true {
                    submittedDraftID = nil
                    draftFlowID = UUID()
                }
                draftText = newValue
            })
    }

    private func beginNewDraftIfCurrentFlowIsOwned() {
        if submittedDraftID != nil || insertionModel?.wasForgotten(draftFlowID) == true
            || insertionModel?.receipt(id: draftFlowID) != nil {
            submittedDraftID = nil
            draftFlowID = UUID()
            draftText = ""
        }
    }

    private func applyEditorCommand(_ command: CompanionDraftEditorCommand) {
        switch command {
        case .setText(let text):
            showDraft = true
            draftBinding.wrappedValue = text
        case .insert:
            showDraft = true
            insertDraft()
        case .cancel:
            showDraft = false
            draftError = nil
        }
    }

    private func insertDraft() {
        if insertionModel?.wasForgotten(draftFlowID) == true
            || (insertionModel?.receipt(id: draftFlowID) != nil
                && insertionModel?.receipt(id: draftFlowID)?.phase != .submitting) {
            draftFlowID = UUID()
            submittedDraftID = nil
        }
        let retained = draftText
        let flowID = draftFlowID
        draftBusy = true
        draftError = nil
        Task {
            defer { draftBusy = false }
            if let insertionModel {
                let finish = await insertionModel.submitDraft(
                    retained, controller: controller, owner: capturedOwner,
                    target: target, title: title, id: flowID)
                submittedDraftID = finish.operationID
                switch finish {
                case .written:
                    draftText = ""
                    showDraft = false
                    submittedDraftID = nil
                    draftFlowID = UUID()
                case .confirmedNotWritten, .acknowledgementUnknown, .awaiting:
                    draftText = retained
                    draftError = insertionModel.receipt(id: finish.operationID)?.recoveryMessage
                }
                return
            }
            let identity = controller.targetIdentity
            do {
                switch try await controller.insertDraftText(retained, identity: identity) {
                case .written:
                    draftText = ""
                    showDraft = false
                case .unavailable:
                    draftText = retained
                    draftError = "The terminal target is unavailable. The draft was kept and not written."
                case .rejected(let reason):
                    draftText = retained
                    draftError = reason
                }
            } catch {
                draftText = retained
                draftError = "The draft was not acknowledged (\(error.localizedDescription)). It was kept and not cleared."
            }
        }
    }

    private func handOffInsertionOnTeardown() {
        let owner = capturedOwner
        if let flowID = attachmentFlowID {
            insertionModel?.markAttachmentForRecovery(id: flowID)
            switch attachmentState {
            case .cancellingUpload:
                attachmentTask?.cancel()
            default:
                break
            }
        } else if let preserved = attachmentState.preservedOnTeardown {
            switch preserved.payload {
            case .uploaded(let remote) where preserved.unknown:
                insertionModel?.preserveUnknownUpload(
                    remote, owner: owner, target: target, title: title)
            case .uploaded(let remote):
                insertionModel?.preserveUninsertedUpload(
                    remote, owner: owner, target: target, title: title)
            case .incompleteCleanup(let cleanup):
                insertionModel?.preserveIncompleteCleanup(
                    cleanup, owner: owner, target: target, title: title)
            case .draft, .pending:
                break
            }
        }
        if let submitted = submittedDraftID {
            if insertionModel?.wasForgotten(submitted) == true {
                return
            }
            return
        }
        if !draftBusy, !draftText.isEmpty {
            insertionModel?.preserveUnsentDraft(
                draftText, owner: owner, target: target, title: title, id: draftFlowID)
        }
    }

    private func clearAttachmentFlow() {
        attachmentTask = nil
        attachmentState = .ready
        attachmentFlowID = nil
        attachmentTargetIdentity = nil
        photoPickerFlowID = nil
        filePickerFlowID = nil
        preparedImage = nil
    }
}


#if DEBUG
private struct CompanionDraftEditorCommandSeam: View {
    @ObservedObject var model: CompanionConnectionModel
    let apply: (CompanionDraftEditorCommand) -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear { consume() }
            .onChange(of: model.fixtureEditorCommand) { _, _ in consume() }
            .onChange(of: model.insertionEpoch) { _, _ in consume() }
    }

    private func consume() {
        guard let command = model.fixtureEditorCommand else { return }
        apply(command)
        Task { @MainActor in
            if model.fixtureEditorCommand == command {
                model.fixtureEditorCommand = nil
            }
        }
    }
}
#endif

struct CompanionDraftEditor: View {
    @Binding var text: String
    let busy: Bool
    let error: String?
    var location: CompanionTerminalLocation? = nil
    let onInsert: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                if let location {
                    CompanionDestinationContext(
                        location: location,
                        prefix: "Writes into this terminal")
                }
                Text("Writes into this terminal's draft. Does not press Return.")
                    .font(Typography.app(13))
                    .foregroundStyle(Palette.textDim)
                TextEditor(text: $text)
                    .font(Typography.machine(15))
                    .padding(8)
                    .frame(minHeight: 180)
                    .scrollContentBackground(.hidden)
                    .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .disabled(busy)
                    .accessibilityIdentifier("companion-draft-editor")
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(Typography.app(13))
                        .foregroundStyle(Palette.died)
                }
                CompanionPrimaryButton(
                    title: busy ? "Writing…" : "Insert into draft",
                    enabled: !busy && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    action: onInsert)
                Spacer()
            }
            .padding(18)
            .companionScreen()
            .navigationTitle("Draft")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel).disabled(busy)
                }
            }
        }
    }
}

struct CompanionKeysPanel: View {
    enum Section: String, CaseIterable { case navigation = "Navigation", function = "F1–F12", control = "Ctrl" }
    @ObservedObject var controller: CompanionTerminalController
    @Environment(\.dismiss) private var dismiss
    @State private var section: Section = .navigation

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Terminal keys").font(Typography.app(18, .semibold)); Spacer()
                Button("Done") { dismiss() }.font(Typography.app(15, .semibold))
            }
            HStack(spacing: 8) {
                panelButton("Copy", systemImage: "doc.on.doc") { controller.copySelection() }
                panelButton("Paste", systemImage: "doc.on.clipboard") { controller.pasteClipboardText() }
                panelButton("Select all", systemImage: "selection.pin.in.out") { controller.selectAll() }
            }
            Picker("Key group", selection: $section) {
                ForEach(Section.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            Group {
                switch section { case .navigation: navigation; case .function: functions; case .control: controls }
            }
            Spacer(minLength: 0)
        }
        .padding(16).background(Palette.ground.ignoresSafeArea()).foregroundStyle(Palette.text)
    }

    private var navigation: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(spacing: 5) {
                key("↑", .up)
                HStack(spacing: 5) { key("←", .left); key("↓", .down); key("→", .right) }
                Text("Directional pad").font(Typography.machine(9)).foregroundStyle(Palette.textFaint)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 2), spacing: 5) {
                key("home", .home); key("end", .end); key("pg up", .pageUp); key("pg down", .pageDown)
                key("delete", .deleteForward); key("⇧ tab", .backTab)
            }
        }
    }

    private var functions: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 4), spacing: 7) {
            ForEach(1...12, id: \.self) { number in key("F\(number)", .function(number)) }
        }
    }

    private var controls: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 4), spacing: 7) {
            ForEach(["c", "d", "z", "l", "a", "e", "k", "u"], id: \.self) { letter in
                Button { controller.sendKey(.text(letter), modifiers: .control) } label: {
                    Text("^\(letter.uppercased())").font(Typography.machine(13, .semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).accessibilityLabel("Control \(letter.uppercased())")
            }
        }
    }

    private func key(_ label: String, _ key: TerminalKeyPress) -> some View {
        Button { controller.sendKey(key) } label: {
            Text(label).font(Typography.machine(12, .semibold))
                .frame(minWidth: 48, maxWidth: .infinity, minHeight: 44)
                .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).accessibilityLabel(label)
    }

    private func panelButton(_ label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: systemImage).font(Typography.app(13, .semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
    }
}

struct CompanionAttachmentPreview: View {
    let prepared: PreparedCompanionImage
    let state: CompanionAttachmentState
    var location: CompanionTerminalLocation? = nil
    let upload: () -> Void
    let insert: () -> Void
    let retryDiscard: () -> Void
    let leavePrivateFile: () -> Void
    let cancel: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                if let location {
                    CompanionDestinationContext(
                        location: location,
                        prefix: "Attaches to this terminal")
                }
                Image(uiImage: prepared.image).resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 360)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("Selected image preview")
                Text("\(prepared.fileExtension.uppercased()) · \(prepared.sizeLabel)")
                    .font(Typography.machine(11)).foregroundStyle(Palette.textDim)
                switch state {
                case .ready: Button("Upload to this Mac", action: upload).primaryAttachmentButton()
                    .accessibilityIdentifier("companion-attachment-upload")
                case .uploading:
                    HStack(spacing: 10) { ProgressView(); Text("Uploading securely…") }
                        .font(Typography.app(15, .semibold)).frame(minHeight: 48)
                case .cancellingUpload:
                    HStack(spacing: 10) { ProgressView(); Text("Canceling upload and checking cleanup…") }
                        .font(Typography.app(15, .semibold)).frame(minHeight: 48)
                        .accessibilityIdentifier("companion-attachment-cancelling")
                case .uploaded(let remote, _, let message):
                    Text(remote.path).font(Typography.machine(10)).foregroundStyle(Palette.textDim)
                        .lineLimit(2).textSelection(.enabled)
                    if let message {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(Typography.app(13)).foregroundStyle(Palette.died)
                    }
                    Button("Insert Attachment", action: insert).primaryAttachmentButton()
                    .accessibilityIdentifier("companion-attachment-insert")
                    Text("Inserts the image path into the current draft. It will not press Return.")
                        .font(Typography.app(12)).foregroundStyle(Palette.textFaint).multilineTextAlignment(.center)
                case .inserting:
                    HStack(spacing: 10) { ProgressView(); Text("Writing the path to this terminal…") }
                        .font(Typography.app(15, .semibold)).frame(minHeight: 48)
                case .discarding:
                    HStack(spacing: 10) { ProgressView(); Text("Discarding the private upload…") }
                        .font(Typography.app(15, .semibold)).frame(minHeight: 48)
                case .discardFailed(_, let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(Typography.app(13)).foregroundStyle(Palette.died)
                    Button("Retry Discard", action: retryDiscard).primaryAttachmentButton()
                    Text("Cleanup can only finish while this Mac is reachable. Retry after reconnecting, or deliberately leave the private upload behind and close this preview.")
                        .font(Typography.app(12)).foregroundStyle(Palette.textFaint).multilineTextAlignment(.center)
                    Button("Leave Private File on Mac and Close", role: .destructive,
                           action: leavePrivateFile)
                        .font(Typography.app(14, .semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                    Text("This makes no further deletion attempt. The private file and directory may remain on this Mac, and cleanup cannot be retried from this preview after it closes.")
                        .font(Typography.app(12)).foregroundStyle(Palette.textFaint)
                        .multilineTextAlignment(.center)
                case .unknownOutcome(let remote, _):
                    Text(remote.path).font(Typography.machine(10)).foregroundStyle(Palette.textDim)
                        .lineLimit(2).textSelection(.enabled)
                    Label("The write outcome is unknown. The private file was not deleted.", systemImage: "exclamationmark.triangle.fill")
                        .font(Typography.app(13)).foregroundStyle(Palette.waiting)
                        .fixedSize(horizontal: false, vertical: true)
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(Typography.app(13)).foregroundStyle(Palette.died)
                    Button("Try Upload Again", action: upload).primaryAttachmentButton()
                }
                Spacer()
            }
            .padding(18).background(Palette.ground.ignoresSafeArea()).foregroundStyle(Palette.text)
            .navigationTitle("Image attachment").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel)
                        .accessibilityIdentifier("companion-attachment-cancel")
                        .disabled({
                            switch state {
                            case .inserting, .cancellingUpload, .discarding, .discardFailed: return true
                            default: return false
                            }
                        }())
                }
            }
        }
    }
}

private struct CompanionDockIntrinsicWidthKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private extension View {
    func primaryAttachmentButton() -> some View {
        font(Typography.app(16, .semibold)).foregroundStyle(Palette.accentOn)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(Palette.accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct CompanionTerminalRepresentable: UIViewRepresentable {
    let opener: CompanionTerminalOpener
    let target: OfficialTerminalAttachmentTarget
    @ObservedObject var controller: CompanionTerminalController

    func makeCoordinator() -> Coordinator {
        Coordinator(opener: opener, target: target, identity: controller.targetIdentity, controller: controller)
    }

    func makeUIView(context: Context) -> CompanionInteractiveTerminalView {
        let font = UIFont(name: "IBMPlexMono", size: 12.5) ?? UIFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        let view = CompanionInteractiveTerminalView(frame: .zero, font: font)
        view.nativeBackgroundColor = UIColor(rgba: 0x211E1A)
        view.nativeForegroundColor = UIColor(rgba: 0xE9DDCA)
        view.changeScrollback(5_000)
        view.terminalDelegate = context.coordinator
        view.allowMouseReporting = false
        view.pageKeysScrollLocally = false
        view.inputAccessoryView = nil
        view.isUserInteractionEnabled = false
        view.contentInsetAdjustmentBehavior = .never
        view.responderChanged = { [weak controller] visible in controller?.responderChanged(visible) }
        context.coordinator.attach(view)
        controller.adopt(view: view, identity: context.coordinator.identity)
        return view
    }

    func updateUIView(_ uiView: CompanionInteractiveTerminalView, context: Context) {}
    static func dismantleUIView(_ uiView: CompanionInteractiveTerminalView, coordinator: Coordinator) { coordinator.stop() }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency TerminalViewDelegate, UIGestureRecognizerDelegate {
        private let opener: CompanionTerminalOpener
        private let target: OfficialTerminalAttachmentTarget
        let identity: UUID
        private weak var controller: CompanionTerminalController?
        private weak var view: CompanionInteractiveTerminalView?
        private var session: (any CompanionTerminalSessionHandle)?
        private var outputTask: Task<Void, Never>?
        private var stopped = false
        private var latestDimensions = (cols: 80, rows: 24, pixelWidth: 0, pixelHeight: 0)
        private var scrollGesture: UIPanGestureRecognizer?
        private var lastTranslationY: CGFloat = 0
        private var scrollQuantizer = CompanionScrollQuantizer()
        private var momentumLink: CADisplayLink?
        private var momentumVelocity: CGFloat = 0
        private var momentumEvents = 0
        private var modifierObservers: [NSObjectProtocol] = []

        init(opener: @escaping CompanionTerminalOpener, target: OfficialTerminalAttachmentTarget, identity: UUID,
             controller: CompanionTerminalController) {
            self.opener = opener; self.target = target; self.identity = identity; self.controller = controller
        }

        func attach(_ view: CompanionInteractiveTerminalView) {
            self.view = view
            installScrollGesture(on: view)
            installModifierObservers(for: view)
            let grid = view.getTerminal()
            latestDimensions = (grid.cols, grid.rows, Int(view.bounds.width * view.contentScaleFactor),
                                Int(view.bounds.height * view.contentScaleFactor))
            outputTask = Task { [weak self] in
                guard let self else { return }
                let initial = latestDimensions
                let opened = await opener(
                    target, initial.cols, initial.rows, initial.pixelWidth, initial.pixelHeight)
                let terminal: any CompanionTerminalSessionHandle
                switch opened {
                case .success(let session):
                    terminal = session
                case .failure(let error):
                    if !Task.isCancelled, !stopped {
                        controller?.ended(.failed(error.localizedDescription), identity: identity)
                    }
                    return
                }
                guard !Task.isCancelled, !stopped else { await terminal.close(); return }
                guard controller?.adopt(terminal, identity: identity) == true else { await terminal.close(); return }
                session = terminal
                let current = latestDimensions
                await terminal.resize(cols: current.cols, rows: current.rows,
                                      pixelWidth: current.pixelWidth, pixelHeight: current.pixelHeight)
                await terminal.start()
                do {
                    for try await data in terminal.output {
                        if Task.isCancelled { break }
                        view.feed(byteArray: [UInt8](data)[...])
                        if await terminal.readyForInput, controller?.state == .connecting {
                            view.isUserInteractionEnabled = true
                            controller?.receivedOutput(identity: identity)
                            if controller?.suppressAutoKeyboard != true {
                                _ = view.becomeFirstResponder()
                            }
                        }
                    }
                    if !Task.isCancelled, !stopped {
                        stopMomentum(); view.isUserInteractionEnabled = false
                        controller?.ended(.disconnected, identity: identity)
                    }
                } catch {
                    if !Task.isCancelled, !stopped {
                        stopMomentum(); view.isUserInteractionEnabled = false
                        controller?.ended(.failed(error.localizedDescription), identity: identity)
                    }
                }
            }
        }

        func stop() {
            guard !stopped else { return }
            stopped = true; stopMomentum()
            if let scrollGesture { view?.removeGestureRecognizer(scrollGesture) }
            scrollGesture = nil
            for observer in modifierObservers { NotificationCenter.default.removeObserver(observer) }
            modifierObservers.removeAll()
            outputTask?.cancel(); outputTask = nil
            let held = session; session = nil
            Task { await held?.close() }
        }

        func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) {
            latestDimensions = (cols, rows, pixelWidth, pixelHeight)
            if let session {
                Task { await session.resize(cols: cols, rows: rows, pixelWidth: pixelWidth, pixelHeight: pixelHeight) }
            }
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) { session?.send(Data(data)) }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            resize(cols: newCols, rows: newRows,
                   pixelWidth: Int(source.bounds.width * source.contentScaleFactor),
                   pixelHeight: Int(source.bounds.height * source.contentScaleFactor))
        }
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

        private func installScrollGesture(on view: CompanionInteractiveTerminalView) {
            let gesture = UIPanGestureRecognizer(target: self, action: #selector(handleRemoteScroll(_:)))
            gesture.maximumNumberOfTouches = 1; gesture.cancelsTouchesInView = false; gesture.delegate = self
            view.addGestureRecognizer(gesture)
            // SwiftTerm is a UIScrollView. Let this vertical recognizer win so a
            // finger drag cannot move local contentOffset while also scrolling
            // the official remote attach. Horizontal/selection gestures still
            // proceed when the remote recognizer declines to begin.
            view.panGestureRecognizer.require(toFail: gesture)
            scrollGesture = gesture
        }

        private func installModifierObservers(for view: CompanionInteractiveTerminalView) {
            for name in [Notification.Name.terminalViewControlModifierReset,
                         Notification.Name.terminalViewMetaModifierReset] {
                modifierObservers.append(NotificationCenter.default.addObserver(
                    forName: name, object: view, queue: .main) { [weak self] _ in
                        Task { @MainActor in self?.controller?.modifierWasConsumed() }
                    })
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer, let view,
                  !view.selectionActive, controller?.state == .connected else { return false }
            let velocity = pan.velocity(in: view)
            return abs(velocity.y) > abs(velocity.x) * 1.15
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let view else { return false }
            if gestureRecognizer === view.panGestureRecognizer
                || otherGestureRecognizer === view.panGestureRecognizer { return false }
            return true
        }

        @objc private func handleRemoteScroll(_ gesture: UIPanGestureRecognizer) {
            guard let view, !view.selectionActive else { stopMomentum(); return }
            switch gesture.state {
            case .began:
                stopMomentum(); scrollQuantizer.reset(); lastTranslationY = gesture.translation(in: view).y
            case .changed:
                let translation = gesture.translation(in: view).y
                sendScrollEvents(scrollQuantizer.consume(deltaY: translation - lastTranslationY), gesture: gesture)
                lastTranslationY = translation
            case .ended: startMomentum(velocity: gesture.velocity(in: view).y)
            case .cancelled, .failed: stopMomentum()
            default: break
            }
        }

        private func sendScrollEvents(_ directions: [CompanionRemoteScrollDirection], gesture: UIGestureRecognizer?) {
            guard !stopped, controller?.state == .connected, let session, let view else { return }
            let terminal = view.getTerminal()
            let point = gesture?.location(in: view) ?? CGPoint(x: view.bounds.midX, y: view.bounds.midY)
            let cell = CompanionRemoteScrollEncoder.cell(
                at: point, viewportOrigin: view.bounds.origin, cellSize: view.cellSize,
                columns: terminal.cols, rows: terminal.rows)
            for direction in directions {
                session.send(Data(CompanionRemoteScrollEncoder.sgrWheel(
                    direction, column: cell.column, row: cell.row)))
            }
        }

        private func startMomentum(velocity: CGFloat) {
            let clamped = min(1_800, max(-1_800, velocity))
            guard abs(clamped) >= 420 else { return }
            momentumVelocity = clamped; momentumEvents = 0
            let link = CADisplayLink(target: self, selector: #selector(stepMomentum(_:)))
            link.add(to: .main, forMode: .common); momentumLink = link
        }

        @objc private func stepMomentum(_ link: CADisplayLink) {
            guard let view, !view.selectionActive, controller?.state == .connected else { stopMomentum(); return }
            let elapsed = max(1.0 / 120.0, min(1.0 / 30.0, link.targetTimestamp - link.timestamp))
            let events = scrollQuantizer.consume(deltaY: momentumVelocity * elapsed)
            momentumEvents += events.count; sendScrollEvents(events, gesture: nil)
            momentumVelocity *= pow(0.90, elapsed * 60)
            if abs(momentumVelocity) < 110 || momentumEvents >= 12 { stopMomentum() }
        }

        private func stopMomentum() {
            momentumLink?.invalidate(); momentumLink = nil; momentumVelocity = 0
            momentumEvents = 0; scrollQuantizer.reset()
        }
    }
}
