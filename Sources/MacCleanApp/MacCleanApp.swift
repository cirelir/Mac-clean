import MacCleanUI
import SwiftUI

@MainActor
struct MacCleanApp: App {
    @State private var model: AppModel?
    private let initializationFailure: String?

    init() {
        do {
            _model = State(initialValue: try LiveDependencies.makeAppModel())
            initializationFailure = nil
        } catch {
            _model = State(initialValue: nil)
            initializationFailure = String(describing: error)
        }
    }

    var body: some Scene {
        MenuBarExtra("Mac Clean", systemImage: "externaldrive.badge.checkmark") {
            if let model {
                MenuBarRootView(model: model)
                    .task {
                        await model.performCatchUpScanIfDue()
                    }
            } else {
                StartupFailureView(message: initializationFailure)
                    .padding(16)
                    .frame(width: 300)
            }
        }
        .menuBarExtraStyle(.window)

        Window("Mac Clean 详情", id: "details") {
            if let model {
                DetailView(model: model)
            } else {
                StartupFailureView(message: initializationFailure)
                    .padding(24)
                    .frame(minWidth: 480, minHeight: 260)
            }
        }
        .defaultSize(width: 760, height: 560)
    }
}

private struct StartupFailureView: View {
    let message: String?

    var body: some View {
        ContentUnavailableView {
            Label("Mac Clean 无法启动", systemImage: "exclamationmark.triangle")
        } description: {
            Text("初始化本地数据存储失败。请重新打开应用；若问题持续，请检查磁盘空间和文件权限。")
        } actions: {
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityLabel("初始化错误：\(message)")
            }
        }
    }
}

MacCleanApp.main()
