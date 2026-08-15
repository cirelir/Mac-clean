import SwiftUI

/// Injected from the status item controller so the menu bar panel can open the
/// details window even though it is hosted in an NSPopover (outside the SwiftUI
/// scene hierarchy, where `openWindow` is unavailable).
private struct OpenDetailsWindowKey: EnvironmentKey {
    static let defaultValue: @MainActor () -> Void = {}
}

extension EnvironmentValues {
    public var openDetailsWindow: @MainActor () -> Void {
        get { self[OpenDetailsWindowKey.self] }
        set { self[OpenDetailsWindowKey.self] = newValue }
    }
}
