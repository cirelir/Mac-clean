import AppKit
import CleanCore
import Foundation
import SwiftUI

/// App-uninstall workspace: a searchable list of installed applications on
/// the left, and the uninstall plan (app bundle + matched data items) of the
/// selected application on the right. Every item is a checkbox; confirmed
/// items are moved to the trash (recoverable), never permanently deleted.
@MainActor
struct UninstallView: View {
    @Bindable private var model: AppModel
    @State private var searchText = ""
    @State private var selectedBundleID: String?
    @State private var selectedItemIDs: Set<UUID> = []
    @State private var showConfirmation = false

    init(model: AppModel) {
        self.model = model
    }

    var body: some View {
        HStack(spacing: 0) {
            applicationList
                .frame(width: 300)

            Divider()

            planDetail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await model.loadUninstallableApplications()
        }
        // A newly built plan defaults to every item selected; the user can
        // uncheck anything they want to keep, or use the select-all toggle.
        .onChange(of: model.state.uninstallPlan?.id) { _, _ in
            guard let plan = model.state.uninstallPlan else { return }
            selectedItemIDs = Set(plan.items.map(\.id))
        }
    }

    // MARK: - Application list

    private var applicationList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                TextField("搜索应用", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除搜索")
                }

                Button {
                    Task { await model.loadUninstallableApplications() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(model.state.uninstallPhase == .uninstalling)
                .help("刷新应用列表")
                .accessibilityLabel("刷新应用列表")
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            if filteredApplications.isEmpty {
                ContentUnavailableView {
                    Label(searchText.isEmpty ? "没有可卸载的应用" : "没有匹配的应用", systemImage: "app.dashed")
                } description: {
                    Text("系统应用不会出现在这里。")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedBundleID) {
                    ForEach(filteredApplications) { row in
                        applicationRow(row)
                            .tag(row.application.bundleID)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onChange(of: selectedBundleID) { _, newValue in
            guard let newValue else { return }
            guard let application = model.state.uninstallableApplications.first(
                where: { $0.bundleID == newValue }
            ) else { return }
            selectedItemIDs = []
            Task { await model.buildUninstallPlan(for: application) }
        }
    }

    private func applicationRow(_ row: UninstallableAppRow) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: icon(for: row.application))
                .resizable()
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(row.application.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(row.application.bundleID)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if model.isRunning(row.application) {
                Label("运行中", systemImage: "play.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.application.name)
    }

    // MARK: - Plan detail

    @ViewBuilder
    private var planDetail: some View {
        switch model.state.uninstallPhase {
        case .idle, .loadingApps:
            loadingPlaceholder
        case .buildingPlan:
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.regular)
                Text("正在分析应用数据…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .uninstalling:
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.regular)
                Text("正在移入废纸篓…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            if let plan = model.state.uninstallPlan {
                planContent(plan)
            } else if !model.state.uninstallOutcomes.isEmpty {
                outcomesContent
            } else if let errorMessage = model.state.uninstallErrorMessage {
                errorContent(errorMessage)
            } else {
                idlePlaceholder
            }
        }
    }

    private func planContent(_ plan: AppUninstallPlan) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: icon(for: plan.application))
                    .resizable()
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(plan.application.name)
                            .font(.title3.bold())
                        if model.isRunning(plan.application) {
                            Label("运行中", systemImage: "play.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    Text(plan.application.bundleID)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(formattedBytes(selectedBytes(in: plan)))
                        .font(.system(size: 22, weight: .bold))
                        .monospacedDigit()
                    Text("选中 \(selectedItemIDs.count) 项 / 共 \(plan.items.count) 项")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let errorMessage = model.state.uninstallErrorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("卸载出错：" + errorMessage)
            }

            HStack(spacing: 12) {
                Text("将移入废纸篓，可随时恢复。取消勾选可保留对应数据。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Toggle("全选", isOn: allSelectedBinding)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .accessibilityHint("勾选或取消勾选列表中的全部项目")
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(plan.items) { item in
                        itemRow(item)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                        Divider()
                            .padding(.leading, 50)
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            }

            HStack(spacing: 12) {
                Label("卸载后应用本体与所选数据一并移入废纸篓", systemImage: "trash")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button(role: .destructive) {
                    showConfirmation = true
                } label: {
                    Label(uninstallButtonTitle, systemImage: "trash")
                        .font(.body.weight(.medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.red)
                .disabled(selectedItemIDs.isEmpty || model.state.uninstallPhase == .uninstalling)
                .accessibilityHint("将选中项目移入废纸篓，应用本体不再保留")
                .confirmationDialog(
                    "确认卸载 \(plan.application.name)？",
                    isPresented: $showConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("移入废纸篓", role: .destructive) {
                        let ids = selectedItemIDs
                        selectedItemIDs = []
                        selectedBundleID = nil
                        Task { await model.uninstall(itemIDs: ids) }
                    }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text(confirmationMessage(for: plan))
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func itemRow(_ item: UninstallItem) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: binding(for: item))
                .toggleStyle(.checkbox)
                .labelsHidden()

            Image(systemName: symbol(for: item.role))
                .foregroundStyle(roleColor(item.role))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayName)
                    .font(.system(size: 13))
                Text(roleTitle(item.role) + " · " + item.url.path)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            Text(formattedBytes(item.sizeBytes))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.displayName + "，" + roleTitle(item.role))
    }

    private var outcomesContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("卸载完成", systemImage: "checkmark.circle.fill")
                .font(.title3.bold())
                .foregroundStyle(.green)
            Text("选中的项目已移入废纸篓，可从废纸篓恢复。")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(model.state.uninstallOutcomes.enumerated()), id: \.offset) { _, outcome in
                    Text(outcome)
                        .font(.caption)
                        .textSelection(.enabled)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func errorContent(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("无法卸载", systemImage: "exclamationmark.triangle.fill")
                .font(.title3.bold())
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var idlePlaceholder: some View {
        ContentUnavailableView {
            Label("选择要卸载的应用", systemImage: "app.badge")
        } description: {
            Text("左侧选择应用后，这里会列出应用本体与其数据目录。")
        }
    }

    private var loadingPlaceholder: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.regular)
            Text("正在加载应用…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    /// True when every item of the current plan is selected. Toggling it on
    /// selects all items; toggling it off deselects all items.
    private var allSelectedBinding: Binding<Bool> {
        Binding(
            get: {
                guard let plan = model.state.uninstallPlan, !plan.items.isEmpty else {
                    return false
                }
                return selectedItemIDs.count == plan.items.count
            },
            set: { isSelected in
                guard let plan = model.state.uninstallPlan else { return }
                selectedItemIDs = isSelected
                    ? Set(plan.items.map(\.id))
                    : []
            }
        )
    }

    private func binding(for item: UninstallItem) -> Binding<Bool> {
        Binding(
            get: { selectedItemIDs.contains(item.id) },
            set: { isSelected in
                if isSelected {
                    selectedItemIDs.insert(item.id)
                } else {
                    selectedItemIDs.remove(item.id)
                }
            }
        )
    }

    private var uninstallButtonTitle: String {
        guard let application = model.state.selectedUninstallApplication,
              model.isRunning(application) else {
            return "移入废纸篓并卸载"
        }
        return "退出并卸载"
    }

    private func confirmationMessage(for plan: AppUninstallPlan) -> String {
        let selection = "将把选中的 " + String(selectedItemIDs.count)
            + " 项（约 " + formattedBytes(selectedBytes(in: plan)) + "）移入废纸篓。"
        guard model.isRunning(plan.application) else {
            return selection
        }
        return plan.application.name + " 正在运行，将先退出应用。" + selection
    }

    private func selectedBytes(in plan: AppUninstallPlan) -> UInt64 {
        plan.items.filter { selectedItemIDs.contains($0.id) }
            .reduce(UInt64(0)) { total, item in
                let (sum, overflow) = total.addingReportingOverflow(item.sizeBytes)
                return overflow ? UInt64.max : sum
            }
    }

    private var filteredApplications: [UninstallableAppRow] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let applications = model.state.uninstallableApplications
        let filtered = query.isEmpty
            ? applications
            : applications.filter {
                $0.name.localizedStandardContains(query)
                    || $0.bundleID.localizedStandardContains(query)
            }
        return filtered.map(UninstallableAppRow.init)
    }

    private func icon(for application: InstalledApplication) -> NSImage {
        NSWorkspace.shared.icon(forFile: application.url.path)
    }

    private func formattedBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(
            fromByteCount: Int64(clamping: bytes),
            countStyle: .file
        )
    }

    private func roleTitle(_ role: UninstallItemRole) -> String {
        switch role {
        case .appBundle: "应用本体"
        case .applicationSupport: "应用支持数据"
        case .caches: "缓存"
        case .logs: "日志"
        case .preferences: "偏好设置"
        case .httpStorages: "HTTP 存储"
        case .webKit: "WebKit 数据"
        case .savedState: "保存的应用状态"
        case .containers: "沙盒容器"
        case .groupContainers: "共享组容器"
        case .applicationScripts: "应用脚本"
        case .launchAgents: "登录启动项"
        case .developerData: "开发者数据"
        }
    }

    private func symbol(for role: UninstallItemRole) -> String {
        switch role {
        case .appBundle: "app.badge"
        case .applicationSupport: "folder"
        case .caches: "externaldrive"
        case .logs: "doc.text"
        case .preferences: "gearshape"
        case .httpStorages: "globe"
        case .webKit: "safari"
        case .savedState: "archivebox"
        case .containers: "shippingbox"
        case .groupContainers: "shippingbox.fill"
        case .applicationScripts: "applescript"
        case .launchAgents: "power"
        case .developerData: "hammer"
        }
    }

    private func roleColor(_ role: UninstallItemRole) -> Color {
        switch role {
        case .appBundle: .red
        case .applicationSupport, .containers, .groupContainers: .blue
        case .caches, .httpStorages, .webKit, .savedState: .teal
        case .logs, .preferences, .applicationScripts, .launchAgents: .orange
        case .developerData: .purple
        }
    }
}

private struct UninstallableAppRow: Identifiable {
    let application: InstalledApplication

    var id: String { application.bundleID }
}
