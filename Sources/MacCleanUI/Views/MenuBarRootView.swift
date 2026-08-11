import Foundation
import SwiftUI

@MainActor
public struct MenuBarRootView: View {
    @Bindable private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Label("Mac Clean", systemImage: "externaldrive.badge.checkmark")
                    .font(.headline)
                Spacer()
                statusLabel
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(formattedEstimatedBytes)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("预计可释放空间")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("预计可释放空间")
            .accessibilityValue(formattedEstimatedBytes)

            Button {
                Task { await model.scan() }
            } label: {
                HStack {
                    if model.state.phase == .scanning {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Label(scanButtonTitle, systemImage: scanButtonSymbol)
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isScanDisabled)
            .accessibilityHint(scanAccessibilityHint)

            if let errorMessage = model.state.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("操作失败：\(errorMessage)")
            }

            if !model.state.failures.isEmpty {
                Label(
                    "\(model.state.failures.count) 个扫描器未完成",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Divider()

            LabeledContent("安全缓存", value: model.greenSummary)
            LabeledContent("待确认项目", value: model.yellowSummary)

            Divider()

            Button {
                openWindow(id: "details")
            } label: {
                Label("查看详情", systemImage: "list.bullet.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityHint("打开候选项详情窗口")
        }
        .padding(16)
        .frame(width: 300)
    }

    private var formattedEstimatedBytes: String {
        ByteCountFormatter.string(
            fromByteCount: Int64(clamping: model.estimatedReclaimableBytes),
            countStyle: .file
        )
    }

    private var isScanDisabled: Bool {
        model.state.phase == .scanning || model.state.phase == .cleaning
    }

    private var scanButtonTitle: String {
        switch model.state.phase {
        case .scanning: "正在扫描…"
        case .cleaning: "正在清理…"
        case .idle, .results: "立即扫描"
        }
    }

    private var scanButtonSymbol: String {
        switch model.state.phase {
        case .scanning: "magnifyingglass"
        case .cleaning: "trash"
        case .idle, .results: "arrow.clockwise"
        }
    }

    private var scanAccessibilityHint: String {
        switch model.state.phase {
        case .scanning: "扫描正在进行，完成后可再次扫描。"
        case .cleaning: "清理正在进行，完成后可再次扫描。"
        case .idle, .results: "扫描受支持位置并生成候选项，不会立即删除文件。"
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        let status = statusPresentation
        Label(status.title, systemImage: status.symbol)
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityLabel("状态：\(status.title)")
    }

    private var statusPresentation: (title: String, symbol: String) {
        switch model.state.phase {
        case .scanning:
            return ("正在扫描", "magnifyingglass")
        case .cleaning:
            return ("正在清理", "trash")
        case .idle where model.state.errorMessage != nil:
            return ("需要处理", "exclamationmark.circle")
        case .results where !model.state.failures.isEmpty:
            return ("部分扫描失败", "exclamationmark.triangle")
        case .results where model.state.candidates.contains(where: { $0.risk == .yellow }):
            return ("存在待确认项", "exclamationmark.triangle")
        case .idle, .results:
            return ("受保护", "checkmark.shield")
        }
    }
}
