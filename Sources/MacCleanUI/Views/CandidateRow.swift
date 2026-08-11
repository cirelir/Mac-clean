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
        if case .available = finderRevealState {
            return true
        }
        return false
    }

    public var finderAccessibilityHint: String {
        switch finderRevealState {
        case .available:
            "在 Finder 中选中此项目。"
        case .unavailable(.missing):
            "路径不存在或已被清理，无法在 Finder 中显示。"
        case .unavailable(.inaccessible):
            "没有访问此路径的权限，无法在 Finder 中显示。"
        }
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

@MainActor
public struct CandidateRow: View {
    private let candidate: CleanupCandidate
    @Bindable private var model: AppModel
    @State private var isExpanded = false

    public init(candidate: CleanupCandidate, model: AppModel) {
        self.candidate = candidate
        self.model = model
    }

    public var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                evidenceDetails

                Divider()

                Button {
                    model.reveal(candidate)
                } label: {
                    Label(presentation.finderActionTitle, systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .disabled(!presentation.isFinderActionEnabled)
                .accessibilityLabel(presentation.finderActionTitle)
                .accessibilityHint(presentation.finderAccessibilityHint)
            }
            .padding(.top, 8)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(candidate.displayName)
                        .font(.headline)

                    Text("\(categoryLabel) · \(ownerLabel)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text(presentation.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(presentation.path)
                }

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 6) {
                    Label(presentation.riskLabel, systemImage: riskSymbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(presentation.formattedSize)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(candidate.displayName)
            .accessibilityValue(
                "\(presentation.riskLabel)，\(presentation.formattedSize)，\(ownerLabel)"
            )
            .accessibilityHint(isExpanded ? "折叠证据详情" : "展开证据详情")
        }
    }

    private var presentation: CandidatePresentation {
        CandidatePresentation(candidate: candidate)
    }

    private var evidenceDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
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
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(monospaced ? .caption.monospaced() : .callout)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }

    private var ownerLabel: String {
        candidate.evidence.ownerName
            ?? candidate.evidence.ownerBundleID
            ?? "未知来源"
    }

    private var categoryLabel: String {
        switch candidate.category {
        case .applicationCache: "应用缓存"
        case .applicationLog: "应用日志"
        case .orphanResidual: "应用残留"
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
}
