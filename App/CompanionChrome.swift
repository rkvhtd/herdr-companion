import SwiftUI
import UIKit
import HerdrKit

struct CompanionMark: View {
    var size: CGFloat = 36

    var body: some View {
        Image("AppLogo")
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct CompanionStatusBadge: View {
    let group: AgentGroup
    var compact: Bool = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 5) {
            if group == .working {
                TurningRing(color: group.color, diameter: compact ? 8 : 10, lineWidth: 1.4)
            } else if group == .unrecognised {
                Image(systemName: "questionmark.circle.fill")
                    .font(Typography.app(compact ? 11 : 12, .semibold))
                    .foregroundStyle(group.color)
            } else if group == .needsYou {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(Typography.app(compact ? 11 : 12, .semibold))
                    .foregroundStyle(group.color)
            } else {
                Circle().fill(group.color).frame(width: compact ? 6 : 7, height: compact ? 6 : 7)
            }
            Text(group.sectionTitle)
                .font(Typography.app(compact ? 12 : 13, .semibold))
                .foregroundStyle(group.color)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(group.spokenLabel)
    }
}

struct CompanionLocationBar: View {
    let mac: String
    let session: String
    var workspace: String? = nil
    var terminal: String? = nil
    var compact: Bool = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if compact {
                Text(compactLine)
                    .font(Typography.app(12))
                    .foregroundStyle(Palette.textDim)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(mac)
                        .font(Typography.app(14, .semibold))
                        .foregroundStyle(Palette.text)
                        .lineLimit(1)
                    Text(parts.joined(separator: " · "))
                        .font(Typography.app(12))
                        .foregroundStyle(Palette.textDim)
                        .lineLimit(2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(([mac] + parts).joined(separator: ", "))
    }

    private var compactLine: String {
        ([mac] + abbreviatedParts).joined(separator: " · ")
    }

    private var abbreviatedParts: [String] {
        [session, workspace, terminal].compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
    }

    private var parts: [String] {
        [session, workspace, terminal].compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
    }
}

enum CompanionDeskPlace: String, CaseIterable, Identifiable, Equatable {
    case desk
    case workspaces

    var id: String { rawValue }

    var title: String {
        switch self {
        case .desk: return "Desk"
        case .workspaces: return "Workspaces"
        }
    }
}

struct CompanionConnectionHeader: View {
    let mac: String
    let session: String
    var status: String
    var isLive: Bool = true
    var switchAction: (() -> Void)? = nil
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let switchControl = Group {
            if let switchAction {
                Button("Switch Mac", action: switchAction)
                    .font(Typography.app(13, .semibold))
                    .foregroundStyle(Palette.accent)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("companion-switch-mac")
                    .accessibilityLabel("Switch Mac")
                    .accessibilityHint("Returns to saved Macs")
            }
        }
        let identity = VStack(alignment: .leading, spacing: 2) {
            Text(mac)
                .font(Typography.app(16, .semibold))
                .foregroundStyle(Palette.text)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle()
                    .fill(isLive ? Palette.done : Palette.waiting)
                    .frame(width: 6, height: 6)
                Text("\(session) · \(status)")
                    .font(Typography.app(12))
                    .foregroundStyle(Palette.textDim)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    identity
                    switchControl
                }
            } else {
                HStack(alignment: .center, spacing: 10) {
                    identity
                    Spacer(minLength: 8)
                    switchControl
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

struct CompanionDeskSwitcher: View {
    let selected: CompanionDeskPlace
    let action: (CompanionDeskPlace) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(CompanionDeskPlace.allCases) { place in
                Button {
                    action(place)
                } label: {
                    Text(place.title)
                        .font(Typography.app(15, selected == place ? .semibold : .regular))
                        .foregroundStyle(selected == place ? Palette.text : Palette.textDim)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(selected == place ? Palette.accent : Palette.hairline)
                                .frame(height: selected == place ? 2 : 0.5)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected == place ? .isSelected : [])
                .accessibilityIdentifier("destination-\(place.rawValue)")
            }
        }
        .accessibilityIdentifier("desk-destinations")
    }
}

struct CompanionCountMark: View {
    let value: Int
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 1) {
            Text("\(value)")
                .font(Typography.app(14, .semibold))
                .foregroundStyle(color)
                .monospacedDigit()
            Text(label)
                .font(Typography.app(10))
                .foregroundStyle(Palette.textFaint)
                .lineLimit(1)
        }
        .frame(minWidth: 28)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(value) \(label)")
    }
}

struct CompanionWrappingHStack: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, maxWidth.isFinite, x + size.width > maxWidth {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            usedWidth = max(usedWidth, min(maxWidth, x - spacing))
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : usedWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

struct CompanionFilterChip: View {
    let title: String
    let selected: Bool
    var count: Int? = nil
    var fillsWidth: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .lineLimit(1)
                if let count {
                    Text("\(count)")
                        .font(Typography.app(12, .semibold))
                        .monospacedDigit()
                }
            }
            .font(Typography.app(13, selected ? .semibold : .regular))
            .foregroundStyle(selected ? Palette.accent : Palette.textDim)
            .padding(.horizontal, 8)
            .frame(minWidth: 44, minHeight: 44, alignment: .center)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(selected ? Palette.accent : Color.clear)
                    .frame(height: 2)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct CompanionDestinationContext: View {
    let location: CompanionTerminalLocation
    var prefix: String = ""
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !prefix.isEmpty {
                Text(prefix)
                    .font(Typography.app(13))
                    .foregroundStyle(Palette.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(line)
                .font(Typography.app(13, .semibold))
                .foregroundStyle(Palette.text)
                .fixedSize(horizontal: false, vertical: true)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(Typography.machine(12))
                    .foregroundStyle(Palette.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("companion-destination-context")
        .accessibilityLabel(([prefix, line] + [detail].compactMap { $0 }).filter { !$0.isEmpty }.joined(separator: ", "))
    }

    private var line: String {
        [location.mac, location.workspace, location.terminal]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct CompanionSplitBrowserControl: View {
    let browsing: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "sidebar.left")
                .font(.body.weight(.semibold))
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(browsing ? "Focus terminal" : "Show browser")
        .accessibilityHint(
            browsing
                ? "Hides the agent and workspace lists and returns to the selected terminal"
                : "Shows the agent and workspace lists without closing the terminal")
        .accessibilityValue(browsing ? "browser" : "terminal")
        .accessibilityIdentifier("companion-split-browser")
    }
}

struct CompanionFilterBar: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let scopes: [CompanionOverviewScope]
    let selected: CompanionOverviewScope
    let count: (CompanionOverviewScope) -> Int?
    let action: (CompanionOverviewScope) -> Void

    var body: some View {
        let chips = ForEach(scopes) { scope in
            CompanionFilterChip(
                title: scope.title,
                selected: selected == scope,
                count: count(scope),
                fillsWidth: dynamicTypeSize.isAccessibilitySize,
                action: { action(scope) })
            .accessibilityIdentifier("filter-\(scope.rawValue)")
        }
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 0) { chips }
        } else {
            CompanionWrappingHStack(spacing: 4) { chips }
        }
    }
}

struct CompanionEmptyState: View {
    let title: String
    let systemImage: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(Typography.app(16, .semibold))
                .foregroundStyle(Palette.text)
                .labelStyle(.titleAndIcon)
            Text(detail)
                .font(Typography.app(13))
                .foregroundStyle(Palette.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
    }
}

struct CompanionBanner: View {
    enum Kind { case warning, error, info }
    let text: String
    var kind: Kind = .warning

    var body: some View {
        Label(text, systemImage: icon)
            .font(Typography.app(13))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                Rectangle().fill(color).frame(width: 2)
            }
    }

    private var icon: String {
        switch kind {
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        case .info: return "wifi.exclamationmark"
        }
    }

    private var color: Color {
        switch kind {
        case .warning: return Palette.waiting
        case .error: return Palette.died
        case .info: return Palette.textDim
        }
    }
}

struct CompanionPrimaryButton: View {
    let title: String
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Typography.app(16, .semibold))
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(enabled ? Palette.accent : Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .foregroundStyle(enabled ? Palette.accentOn : Palette.textFaint)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

struct CompanionScreenBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(Palette.ground.ignoresSafeArea())
            .tint(Palette.accent)
    }
}

extension View {
    func companionScreen() -> some View {
        modifier(CompanionScreenBackground())
    }
}

enum CompanionWorkspaceTitle {
    static func display(_ workspace: WorkspaceInfo) -> String {
        workspace.label.isEmpty ? "Workspace \(workspace.number)" : workspace.label
    }

    static func display(workspaceID: String, in topology: SessionTopology?) -> String? {
        topology?.workspaces.first { $0.workspaceID == workspaceID }.map(display)
    }

    static func tab(_ tab: TabInfo) -> String {
        tab.label.isEmpty ? "Tab \(tab.number)" : tab.label
    }
}


struct CompanionTerminalLocation: Equatable {
    let mac: String
    let session: String
    var workspace: String? = nil
    var terminal: String? = nil
}


struct CompanionInsertionRecoverySheet: View {
    @ObservedObject var model: CompanionConnectionModel
    @State private var cleanupMessage: String?

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.recoverableReceipts) { receipt in
                    Section {
                        Text(receipt.title)
                            .font(Typography.app(16, .semibold))
                            .foregroundStyle(Palette.text)
                            .listRowBackground(Palette.surface)
                        Text("\(receipt.owner.hostLabel) · \(receipt.owner.host) · \(targetLabel(receipt))")
                            .font(Typography.machine(12))
                            .foregroundStyle(Palette.textDim)
                            .listRowBackground(Palette.surface)
                        if let message = receipt.recoveryMessage {
                            Label(message, systemImage: "exclamationmark.triangle.fill")
                                .font(Typography.app(14))
                                .foregroundStyle(Palette.waiting)
                                .fixedSize(horizontal: false, vertical: true)
                                .listRowBackground(Palette.surface)
                        }
                        payloadView(receipt)
                            .listRowBackground(Palette.surface)
                        if receipt.isCleanupInFlight {
                            Label("Discarding the private upload…", systemImage: "hourglass")
                                .font(Typography.app(14, .semibold))
                                .foregroundStyle(Palette.waiting)
                                .listRowBackground(Palette.surface)
                                .accessibilityIdentifier("companion-recovery-discarding")
                        } else if receipt.allowsCleanup {
                            Button("Retry Discard") {
                                Task {
                                    cleanupMessage = await model.retryDiscard(receipt)
                                }
                            }
                            .font(Typography.app(15, .semibold))
                            .foregroundStyle(Palette.accentOn)
                            .listRowBackground(Palette.accent)
                            .accessibilityIdentifier("companion-recovery-retry")
                            Button("Leave Private File on Mac") {
                                model.forgetReceipt(receipt)
                            }
                            .font(Typography.app(15, .semibold))
                            .foregroundStyle(Palette.died)
                            .listRowBackground(Palette.surface)
                            .accessibilityIdentifier("companion-recovery-leave")
                        } else if case .draft = receipt.payload {
                            Button("Discard Kept Draft") {
                                model.forgetReceipt(receipt)
                            }
                            .font(Typography.app(15, .semibold))
                            .foregroundStyle(Palette.died)
                            .listRowBackground(Palette.surface)
                            .accessibilityIdentifier("companion-recovery-discard-draft")
                        } else if receipt.canForgetWithoutDeletion {
                            Button("Leave Private File and Forget") {
                                model.forgetReceipt(receipt)
                            }
                            .font(Typography.app(15, .semibold))
                            .foregroundStyle(Palette.died)
                            .listRowBackground(Palette.surface)
                            .accessibilityIdentifier("companion-recovery-leave-unknown")
                            Text("Deletion is not attempted. Delivery remains unknown.")
                                .font(Typography.app(12))
                                .foregroundStyle(Palette.textDim)
                                .fixedSize(horizontal: false, vertical: true)
                                .listRowBackground(Palette.surface)
                        }
                    }
                }
                if let cleanupMessage {
                    Section {
                        Label(cleanupMessage, systemImage: "xmark.octagon.fill")
                            .font(Typography.app(13))
                            .foregroundStyle(Palette.died)
                            .fixedSize(horizontal: false, vertical: true)
                            .listRowBackground(Palette.surface)
                            .accessibilityIdentifier("companion-recovery-error")
                    }
                }
                Section {
                    Button("Close") { model.dismissRecoveryPresentation() }
                        .font(Typography.app(15, .semibold))
                        .foregroundStyle(Palette.text)
                        .frame(minHeight: 44)
                        .listRowBackground(Palette.surface)
                        .accessibilityIdentifier("companion-recovery-close")
                }
            }
            .companionScreen()
            .background {
                CompanionRecoverySheetAnchor()
            }
            .navigationTitle("Kept items")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    CompanionAccessibleTextButton(
                        title: "Close",
                        identifier: "companion-recovery-close",
                        textStyle: .body,
                        aligned: .center,
                        action: { model.dismissRecoveryPresentation() })
                    .frame(minWidth: 88, minHeight: 44)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func payloadView(_ receipt: CompanionInsertionReceipt) -> some View {
        switch receipt.payload {
        case .draft(let text):
            ScrollView {
                Text(text)
                    .font(Typography.machine(14))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 80, maxHeight: 240)
            .accessibilityIdentifier("companion-recovery-draft")
        case .uploaded(let remote):
            ScrollView(.horizontal, showsIndicators: true) {
                Text(remote.path)
                    .font(Typography.machine(11))
                    .textSelection(.enabled)
            }
            .accessibilityIdentifier("companion-recovery-path")
        case .incompleteCleanup:
            Text("Incomplete private upload cleanup")
                .font(Typography.app(13))
                .foregroundStyle(Palette.textDim)
        case .pending:
            Text("Upload still in progress")
                .font(Typography.app(13))
                .foregroundStyle(Palette.textDim)
        }
    }

    private func targetLabel(_ receipt: CompanionInsertionReceipt) -> String {
        switch receipt.target {
        case .agent(let paneID): return "agent \(paneID)"
        case .terminal(let terminalID): return "terminal \(terminalID)"
        }
    }
}

struct CompanionAccessibleTextButton: UIViewRepresentable {
    var title: String
    var identifier: String
    var hint: String? = nil
    var systemImage: String? = nil
    var textStyle: UIFont.TextStyle = .body
    var aligned: UIControl.ContentHorizontalAlignment = .left
    var action: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    final class HitView: UIButton {
        var action: () -> Void = {}
        override init(frame: CGRect) {
            super.init(frame: frame)
            isAccessibilityElement = true
            accessibilityTraits = .button
            titleLabel?.numberOfLines = 0
            titleLabel?.adjustsFontForContentSizeCategory = true
            titleLabel?.adjustsFontSizeToFitWidth = false
            titleLabel?.lineBreakMode = .byWordWrapping
            addTarget(self, action: #selector(tap), for: .touchUpInside)
        }
        var textStyle: UIFont.TextStyle = .body
        required init?(coder: NSCoder) { nil }
        @objc private func tap() { action() }
        override func accessibilityActivate() -> Bool {
            action()
            return true
        }
        override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
            super.traitCollectionDidChange(previousTraitCollection)
            guard traitCollection.preferredContentSizeCategory
                    != previousTraitCollection?.preferredContentSizeCategory else { return }
            titleLabel?.font = UIFont.preferredFont(forTextStyle: textStyle)
            invalidateIntrinsicContentSize()
        }
        override var intrinsicContentSize: CGSize {
            let width = bounds.width > 0 ? bounds.width : 280
            return Self.fittedSize(for: self, width: width)
        }
        static func fittedSize(for view: UIButton, width: CGFloat) -> CGSize {
            let insets = view.contentEdgeInsets
            let hasImage = view.image(for: .normal) != nil
            let imageWidth = (view.image(for: .normal)?.size.width ?? 0) + (hasImage ? 8 : 0)
            let innerWidth = max(44, width - insets.left - insets.right - imageWidth)
            view.titleLabel?.preferredMaxLayoutWidth = innerWidth
            let titleSize = view.titleLabel?.sizeThatFits(
                CGSize(width: innerWidth, height: CGFloat.greatestFiniteMagnitude)) ?? .zero
            let imageHeight = view.image(for: .normal)?.size.height ?? 0
            return CGSize(
                width: width,
                height: max(44, ceil(max(titleSize.height, imageHeight) + insets.top + insets.bottom)))
        }
    }

    func makeUIView(context: Context) -> HitView {
        let view = HitView()
        apply(view)
        return view
    }

    func updateUIView(_ uiView: HitView, context: Context) {
        apply(uiView)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: HitView, context: Context) -> CGSize {
        apply(uiView)
        let width = proposal.width ?? 0
        let targetWidth = width > 0 ? width : 280
        return HitView.fittedSize(for: uiView, width: targetWidth)
    }

    private func apply(_ view: HitView) {
        view.action = action
        view.accessibilityIdentifier = identifier
        view.accessibilityLabel = title
        view.accessibilityHint = hint
        view.contentHorizontalAlignment = aligned
        view.setContentHuggingPriority(.required, for: .vertical)
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        view.setTitle(title, for: .normal)
        view.setTitleColor(.label, for: .normal)
        view.tintColor = .label
        if let systemImage {
            view.setImage(UIImage(systemName: systemImage), for: .normal)
        } else {
            view.setImage(nil, for: .normal)
        }
        view.textStyle = textStyle
        let environmentCategory = Self.contentSize(dynamicTypeSize)
        let liveCategory = view.traitCollection.preferredContentSizeCategory
        let category = Self.rank(liveCategory) > Self.rank(environmentCategory) ? liveCategory : environmentCategory
        let traits = UITraitCollection(preferredContentSizeCategory: category)
        view.titleLabel?.font = UIFont.preferredFont(forTextStyle: textStyle, compatibleWith: traits)
        view.titleLabel?.numberOfLines = 0
        view.titleLabel?.adjustsFontForContentSizeCategory = true
        view.titleLabel?.adjustsFontSizeToFitWidth = false
        view.contentEdgeInsets = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        view.invalidateIntrinsicContentSize()
    }

    private static func rank(_ category: UIContentSizeCategory) -> Int {
        switch category {
        case .extraSmall: return 0
        case .small: return 1
        case .medium: return 2
        case .large: return 3
        case .extraLarge: return 4
        case .extraExtraLarge: return 5
        case .extraExtraExtraLarge: return 6
        case .accessibilityMedium: return 7
        case .accessibilityLarge: return 8
        case .accessibilityExtraLarge: return 9
        case .accessibilityExtraExtraLarge: return 10
        case .accessibilityExtraExtraExtraLarge: return 11
        default: return 3
        }
    }

    private static func contentSize(_ size: DynamicTypeSize) -> UIContentSizeCategory {
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
}

private struct CompanionRecoverySheetAnchor: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.accessibilityIdentifier = "companion-recovery-sheet"
        view.isAccessibilityElement = true
        view.accessibilityLabel = "Kept items"
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        uiView.accessibilityIdentifier = "companion-recovery-sheet"
    }
}

private struct CompanionInsertionRecoveryLayout<Content: View>: View {
    @ObservedObject var model: CompanionConnectionModel
    var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    if !model.awaitingReceipts.isEmpty {
                        CompanionBanner(
                            text: awaitingCopy,
                            kind: .info)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .accessibilityIdentifier("companion-recovery-awaiting")
                    }
                    if !model.recoverableReceipts.isEmpty {
                        CompanionAccessibleTextButton(
                            title: entryCopy,
                            identifier: "companion-recovery-entry",
                            hint: "Opens kept drafts and private uploads. Closing the sheet does not discard them.",
                            systemImage: "tray.full",
                            textStyle: .subheadline,
                            aligned: .left,
                            action: { model.openRecoveryPresentation() })
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                        .background(Palette.surfaceRaised)
                    }
                }
            }
            .sheet(isPresented: Binding(
                get: { model.isPresentingRecovery },
                set: { if !$0 { model.dismissRecoveryPresentation() } }
            )) {
                CompanionInsertionRecoverySheet(model: model)
            }
    }

    private var awaitingCopy: String {
        let first = model.awaitingReceipts.first
        let host = first?.owner.hostLabel ?? "this Mac"
        let title = first?.title ?? "the terminal"
        return "Writing to \(title) on \(host). Closing that terminal does not move the write to another target."
    }

    private var entryCopy: String {
        let count = model.recoverableReceipts.count
        let host = model.recoverableReceipts.first?.owner.hostLabel ?? "a Mac"
        if count == 1 { return "1 item kept from \(host). Review" }
        return "\(count) items kept from \(host). Review"
    }
}

struct CompanionInsertionRecoveryModifier: ViewModifier {
    @ObservedObject var model: CompanionConnectionModel

    func body(content: Content) -> some View {
        CompanionInsertionRecoveryLayout(model: model, content: content)
    }
}

extension View {
    func companionInsertionRecovery(model: CompanionConnectionModel) -> some View {
        modifier(CompanionInsertionRecoveryModifier(model: model))
    }
}
