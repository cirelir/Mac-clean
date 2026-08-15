import MacCleanUI
import SwiftUI

@main
@MainActor
struct MacCleanApp: App {
    @State private var statusItemController: StatusItemController?
    private let initializationFailure: String?

    init() {
        guard SingleInstance.acquire() else {
            // Another instance is already running: activate it and exit
            // without creating a second status item or window.
            SingleInstance.activateExistingInstance()
            exit(0)
        }

        let model: AppModel?
        let failure: String?
        do {
            model = try LiveDependencies.makeAppModel()
            failure = nil
        } catch {
            model = nil
            failure = String(describing: error)
        }
        initializationFailure = failure
        _statusItemController = State(
            initialValue: StatusItemController(
                model: model,
                initializationFailure: failure
            )
        )
    }

    var body: some Scene {
        // The status item, the panel, and the details window are all owned by
        // StatusItemController; this placeholder scene keeps the SwiftUI app
        // running without opening any window at launch.
        Settings { EmptyView() }
    }
}

struct StartupFailureView: View {
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
