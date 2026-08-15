import AppKit
import CleanCore
import Foundation
import SwiftUI

public struct CandidatePresentation {
    private let candidate: CleanupCandidate
    private let fileManager: FileManager

    public let path: String
    public let riskLabel: String
    public let riskReason: String
    public let finderActionTitle: String
    public let formattedSize: String

    public var finderRevealState: FinderRevealState {
        FinderRevealState(url: candidate.canonicalURL, fileManager: fileManager)
    }

    public var isFinderActionEnabled: Bool {
        finderActionSnapshot.isEnabled
    }

    public var finderAccessibilityHint: String {
        finderActionSnapshot.accessibilityHint
    }

    var finderActionSnapshot: FinderActionSnapshot {
        FinderActionSnapshot(revealState: finderRevealState)
    }

    public init(candidate: CleanupCandidate, fileManager: FileManager = .default) {
        self.candidate = candidate
        self.fileManager = fileManager
        path = candidate.canonicalURL.path
        riskLabel = switch candidate.risk {
        case .green: "安全缓存"
        case .yellow: "需要确认"
        case .red: "仅报告"
        }
        riskReason = candidate.riskReason
        finderActionTitle = "在 Finder 中显示"
        formattedSize = ByteCountFormatter.string(
            fromByteCount: Int64(clamping: candidate.sizeBytes),
            countStyle: .file
        )
    }
}

struct FinderActionSnapshot: Equatable {
    let revealState: FinderRevealState

    var isEnabled: Bool {
        if case .available = revealState {
            return true
        }
        return false
    }

    var accessibilityHint: String {
        switch revealState {
        case .available:
            "在 Finder 中选中此项目。"
        case .unavailable(.missing):
            "路径不存在或已被清理，无法在 Finder 中显示。"
        case .unavailable(.inaccessible):
            "没有访问此路径的权限，无法在 Finder 中显示。"
        }
    }
}

struct FinderAvailabilityRefreshState {
    private(set) var snapshot: FinderActionSnapshot?

    init() {
        snapshot = nil
    }

    init(candidate: CleanupCandidate, fileManager: FileManager = .default) {
        snapshot = CandidatePresentation(
            candidate: candidate,
            fileManager: fileManager
        ).finderActionSnapshot
    }

    var isEnabled: Bool {
        snapshot?.isEnabled ?? false
    }

    var accessibilityHint: String {
        snapshot?.accessibilityHint ?? "展开详情后检查 Finder 位置是否可用。"
    }

    mutating func refresh(
        candidate: CleanupCandidate,
        fileManager: FileManager = .default
    ) {
        snapshot = CandidatePresentation(
            candidate: candidate,
            fileManager: fileManager
        ).finderActionSnapshot
    }
}

@MainActor
final class ApplicationIconCache {
    static let shared = ApplicationIconCache()

    private enum Entry {
        case icon(NSImage)
        case missing
    }

    private var entries: [String: Entry] = [:]

    func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }

        if let entry = entries[bundleID] {
            switch entry {
            case .icon(let image): return image
            case .missing: return nil
            }
        }

        guard let applicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleID
        ) else {
            entries[bundleID] = .missing
            return nil
        }

        let image = NSWorkspace.shared.icon(forFile: applicationURL.path)
        entries[bundleID] = .icon(image)
        return image
    }
}

@MainActor
public struct CandidateRow: View {
    private let candidate: CleanupCandidate
    private let presentation: CandidatePresentation
    private let applicationIcon: NSImage?
    private let onReveal: () -> Void
    @Binding private var selection: Set<UUID>
    @Environment(\.scenePhase) private var scenePhase
    @State private var isExpanded = false
    @State private var finderAvailability: FinderAvailabilityRefreshState

    public init(
        candidate: CleanupCandidate,
        applicationIcon: NSImage? = nil,
        selection: Binding<Set<UUID>>,
        onReveal: @escaping () -> Void
    ) {
        self.candidate = candidate
        self.presentation = CandidatePresentation(candidate: candidate)
        self.applicationIcon = applicationIcon
        self.onReveal = onReveal
        _selection = selection
        _finderAvailability = State(
            initialValue: FinderAvailabilityRefreshState()
        )
    }

    public var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 14) {
                evidenceDetails

                Divider()

                HStack {
                    Label(actionLabel, systemImage: actionSymbol)
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button {
                        onReveal()
                    } label: {
                        Label(presentation.finderActionTitle, systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!finderAvailability.isEnabled)
                    .accessibilityLabel(presentation.finderActionTitle)
                    .accessibilityHint(finderAvailability.accessibilityHint)
                }
            }
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.top, 10)
        } label: {
            rowLabel
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(candidate.displayName)
            .accessibilityValue(
                "\(presentation.riskLabel)，\(presentation.formattedSize)，\(ownerLabel)"
            )
            .accessibilityHint(isExpanded ? "折叠证据详情" : "展开证据详情")
        }
        .onChange(of: isExpanded) { _, expanded in
            if expanded {
                refreshFinderAvailability()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, isExpanded {
                refreshFinderAvailability()
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var rowLabel: some View {
        HStack(alignment: .center, spacing: 12) {
            Group {
                if candidate.risk == .yellow {
                    Toggle("", isOn: selectionBinding)
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .accessibilityLabel("选择清除 \(candidate.displayName)")
                } else {
                    Image(systemName: leadingStatusSymbol)
                        .font(.system(size: 16, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(riskColor)
                }
            }
            .frame(width: 18)

            candidateIcon

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(candidate.displayName)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)

                    if candidate.category == .orphanResidual {
                        Text("推荐检查")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }

                Text("\(categoryLabel) · \(ownerLabel) · \(candidate.evidence.explanation)")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            Text(presentation.formattedSize)
                .font(.system(size: 14).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 94, alignment: .trailing)

            riskBadge
                .frame(width: 112, alignment: .center)

            Group {
                if candidate.risk == .yellow {
                    Toggle("", isOn: selectionBinding)
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .accessibilityLabel("选择清除 \(candidate.displayName)")
                } else {
                    Text("—")
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 96, alignment: .center)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var candidateIcon: some View {
        if let applicationIcon {
            Image(nsImage: applicationIcon)
                .resizable()
                .scaledToFit()
                .frame(width: 30, height: 30)
        } else {
            Image(systemName: categorySymbol)
                .font(.system(size: 17, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(riskColor)
                .frame(width: 30, height: 30)
                .background(riskColor.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }

    private var riskBadge: some View {
        Label(presentation.riskLabel, systemImage: riskSymbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(riskColor)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(riskColor.opacity(0.1))
            .clipShape(Capsule())
            .overlay {
                Capsule()
                    .stroke(riskColor.opacity(0.28), lineWidth: 1)
            }
    }

    private var selectionBinding: Binding<Bool> {
        Binding(
            get: { selection.contains(candidate.id) },
            set: { isSelected in
                if isSelected {
                    selection.insert(candidate.id)
                } else {
                    selection.remove(candidate.id)
                }
            }
        )
    }

    private func refreshFinderAvailability() {
        finderAvailability.refresh(candidate: candidate)
    }

    private var evidenceDetails: some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 9) {
            detail("原始路径", candidate.sourceURL.path, monospaced: true)
            detail("规范化路径", candidate.canonicalURL.path, monospaced: true)
            detail("所属来源", ownerLabel)

            if let bundleID = candidate.evidence.ownerBundleID {
                detail("Bundle ID", bundleID, monospaced: true)
            }

            detail("扫描器", candidate.evidence.scannerID, monospaced: true)
            detail("发现规则", candidate.evidence.ruleID, monospaced: true)
            detail("证据", candidate.evidence.explanation)
            detail("风险依据", candidate.riskReason)
            detail("计划动作", actionLabel)
            detail(
                "修改时间",
                candidate.modifiedAt.formatted(date: .abbreviated, time: .shortened)
            )
            detail(
                "文件标识",
                "设备 \(candidate.fingerprint.deviceID)，文件 \(candidate.fingerprint.fileID)，所有者 \(candidate.fingerprint.ownerID)",
                monospaced: true
            )

            if let commandPreview = candidate.evidence.commandPreview {
                detail("命令预览", commandPreview, monospaced: true)
            }
        }
    }

    private func detail(_ title: String, _ value: String, monospaced: Bool = false) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .leading)
            Text(value)
                .font(monospaced ? .caption.monospaced() : .callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private var ownerLabel: String {
        if candidate.category == .orphanResidual {
            return "应用已卸载"
        }
        return candidate.evidence.ownerName
            ?? candidate.evidence.ownerBundleID
            ?? "未知来源"
    }

    private var categoryLabel: String {
        switch candidate.category {
        case .applicationCache: "应用缓存"
        case .applicationLog: "应用日志"
        case .orphanResidual: "应用残留"
        case .systemData: "系统数据"
        case .packageManager: "包管理器"
        case .developerTool: "开发环境"
        case .reportOnly: "仅报告"
        }
    }

    private var actionLabel: String {
        switch candidate.proposedAction {
        case .deleteContentsPreservingRoot: "清理内容并保留目录"
        case .moveToTrash: "移动到废纸篓"
        case .packageManagerCommand: "由包管理器执行"
        case .reportOnly: "仅报告，不执行"
        }
    }

    private var riskSymbol: String {
        switch candidate.risk {
        case .green: "checkmark.shield"
        case .yellow: "exclamationmark.triangle"
        case .red: "hand.raised"
        }
    }

    private var leadingStatusSymbol: String {
        switch candidate.risk {
        case .green: "checkmark.shield.fill"
        case .yellow: "square"
        case .red: "info.circle"
        }
    }

    private var riskColor: Color {
        switch candidate.risk {
        case .green: .green
        case .yellow: .orange
        case .red: .secondary
        }
    }

    private var categorySymbol: String {
        switch candidate.category {
        case .applicationCache: "shippingbox.fill"
        case .applicationLog: "doc.text.fill"
        case .orphanResidual: "app.dashed"
        case .systemData: "internaldrive.fill"
        case .packageManager: "shippingbox.and.arrow.backward.fill"
        case .developerTool: "hammer.fill"
        case .reportOnly: "doc.badge.ellipsis"
        }
    }

    private var actionSymbol: String {
        switch candidate.proposedAction {
        case .deleteContentsPreservingRoot: "sparkles"
        case .moveToTrash: "trash"
        case .packageManagerCommand: "terminal"
        case .reportOnly: "eye"
        }
    }
}
