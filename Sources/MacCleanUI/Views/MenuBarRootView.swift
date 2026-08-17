import AppKit
import Foundation
import SwiftUI

struct EstimatedSpaceValueText: View {
    let value: String
    @ScaledMetric(relativeTo: .largeTitle) private var pointSize = 28.0

    var body: some View {
        EstimatedSpaceScaledText(value: value, pointSize: pointSize)
    }
}

struct EstimatedSpaceScaledText: View {
    let value: String
    let pointSize: CGFloat

    var body: some View {
        Text(value)
            .font(.system(size: pointSize, weight: .bold, design: .rounded))
            .monospacedDigit()
    }
}

@MainActor
public struct MenuBarRootView: View {
    @Bindable private var model: AppModel
    @Environment(\.openDetailsWindow) private var openDetailsWindow
    @Environment(AppearanceStore.self) private var appearanceStore

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.green)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Mac Clean")
                        .font(.headline)
                    Text("安全、透明地释放空间")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
                statusLabel
            }

            VStack(alignment: .leading, spacing: 4) {
                EstimatedSpaceValueText(value: formattedEstimatedBytes)
                Text("安全缓存可直接清理")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("预计可释放空间")
            .accessibilityValue(formattedEstimatedBytes)

            HStack(spacing: 0) {
                compactMetric(
                    title: "安全缓存",
                    value: model.greenSummary,
                    symbol: "checkmark.shield.fill",
                    color: .green
                )

                Divider()
                    .padding(.vertical, 6)

                compactMetric(
                    title: "待确认",
                    value: model.yellowSummary,
                    symbol: "exclamationmark.triangle.fill",
                    color: .orange
                )
            }
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.1), lineWidth: 1)
            }

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
            .controlSize(.large)
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

            Button {
                openDetailsWindow()
            } label: {
                Label("查看全部候选项", systemImage: "list.bullet.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityHint("打开候选项详情窗口")

            Divider()

            HStack(spacing: 6) {
                Text("Mac Clean")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)

                Text(AppVersion.displayString)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)

                Spacer()

                SettingsLink {
                    Label("设置", systemImage: "gearshape")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help("打开设置")
            }
            .padding(.top, 6)
        }
        .padding(18)
        .frame(width: 330)
        .tint(.blue)
        .preferredColorScheme(appearanceStore.preference.colorScheme)
    }

    private func compactMetric(
        title: String,
        value: String,
        symbol: String,
        color: Color
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.callout.weight(.semibold))
            }
            Spacer(minLength: 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .accessibilityElement(children: .combine)
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

