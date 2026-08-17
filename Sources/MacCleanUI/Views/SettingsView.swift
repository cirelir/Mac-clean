import AppKit
import Foundation
import SwiftUI

/// Mac Clean preferences window (the system `Settings` scene).
///
/// SwiftUI automatically renders a `TabView` inside the Settings scene with
/// the native macOS toolbar-style tabs (icon + label), so this is the
/// standard preferences layout: a fixed-size window that is closable via
/// the window buttons, Cmd+W / Cmd+,, and the app menu.
@MainActor
public struct SettingsView: View {
    public init() {}

    @Environment(AppearanceStore.self) private var appearanceStore
    @Environment(AppSettingsStore.self) private var settingsStore
    @State private var isCheckingForUpdates = false
    @State private var updateAlert: UpdateAlertItem?

    public var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("通用", systemImage: "gearshape")
                }

            aboutTab
                .tabItem {
                    Label("关于", systemImage: "info.circle")
                }
        }
        .frame(width: 520, height: 380)
        .alert(item: $updateAlert) { item in
            Alert(
                title: Text(item.title),
                message: Text(item.message),
                primaryButton: .default(Text(item.primaryTitle), action: item.primaryAction),
                secondaryButton: .cancel(Text(item.dismissTitle))
            )
        }
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            LabeledContent {
                Picker("", selection: Bindable(appearanceStore).preference) {
                    ForEach(AppearancePreference.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .fixedSize()
            } label: {
                Label("外观模式", systemImage: "circle.lefthalf.filled")
            }

            LabeledContent {
                Toggle("", isOn: Bindable(settingsStore).showRedItems)
                    .labelsHidden()
            } label: {
                Label("显示仅报告项目", systemImage: "eye.slash")
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }

    // MARK: - About

    private var aboutTab: some View {
        VStack(spacing: 20) {
            Image(systemName: "externaldrive.badge.checkmark")
                .font(.system(size: 48))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.green)

            VStack(spacing: 4) {
                Text("Mac Clean")
                    .font(.title2.bold())
                Text("安全、透明地释放空间")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 4) {
                Text("版本")
                    .foregroundStyle(.secondary)
                Text(AppVersion.displayString)
                    .fontWeight(.semibold)
            }
            .font(.callout)

            if isCheckingForUpdates {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button {
                    Task { await checkForUpdates() }
                } label: {
                    Label("检查更新", systemImage: "arrow.up.arrow.down.circle")
                }
                .buttonStyle(.bordered)
                .help("检查 GitHub Releases 是否有新版本")
            }

            Spacer()

            Text("无网络依赖 · 所有扫描数据仅保存在本机")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Update check

    private func checkForUpdates() async {
        isCheckingForUpdates = true
        defer { isCheckingForUpdates = false }
        let result = await UpdateChecker().checkLatestVersion()
        switch result {
        case .upToDate:
            updateAlert = UpdateAlertItem(
                title: "已是最新版本",
                message: "当前版本 v\(AppVersion.current) 已是最新。"
            )
        case .updateAvailable(let version, let releaseURL):
            let target = releaseURL
            updateAlert = UpdateAlertItem(
                title: "发现新版本 \(version)",
                message: "当前版本 v\(AppVersion.current)，是否前往 GitHub Releases 下载 v\(version)？",
                primaryTitle: "前往下载",
                primaryAction: { NSWorkspace.shared.open(target) }
            )
        case .failed:
            updateAlert = UpdateAlertItem(
                title: "检查更新失败",
                message: "无法连接更新服务，请稍后重试，或访问 GitHub Releases 页面。",
                primaryTitle: "打开发布页面",
                primaryAction: { NSWorkspace.shared.open(AppVersion.updateURL) }
            )
        }
    }
}

/// Backing model for the update-check result alert.
struct UpdateAlertItem: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let primaryTitle: String
    let dismissTitle: String
    var primaryAction: () -> Void

    init(
        title: String,
        message: String,
        primaryTitle: String = "好",
        dismissTitle: String = "取消",
        primaryAction: @escaping () -> Void = {}
    ) {
        self.title = title
        self.message = message
        self.primaryTitle = primaryTitle
        self.dismissTitle = dismissTitle
        self.primaryAction = primaryAction
    }
}
