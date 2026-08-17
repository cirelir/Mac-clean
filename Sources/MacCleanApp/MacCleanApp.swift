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

        // Unbundled executables start with the `.prohibited` activation
        // policy, which makes the system silently refuse `NSApp.activate`:
        // the panel still works, but the details window can never be
        // brought to the front. Make the app an activatable menu bar
        // utility (no Dock icon) so its windows can come forward.
        // `NSApplication.shared` (not `NSApp`) must be used here: during
        // `App.init()` the global `NSApp` is still nil, and touching it
        // crashes with an implicitly-unwrapped-optional fatal error.
        NSApplication.shared.setActivationPolicy(.accessory)

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
        // StatusItemController. The Settings scene provides the native
        // preferences window (app menu -> Settings..., Cmd+,) with the
        // shared app-wide stores so changes apply everywhere instantly.
        Settings {
            SettingsView()
                .environment(AppearanceStore.shared)
                .environment(AppSettingsStore.shared)
        }
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
