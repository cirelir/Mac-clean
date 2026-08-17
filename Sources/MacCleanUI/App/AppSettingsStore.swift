import Foundation
import Observation

/// User-facing settings for Mac Clean, persisted in `UserDefaults`.
///
/// - `showRedItems`: whether to display red-risk ("仅报告") candidates in
///   the cleanup list (default: `true`).
@MainActor
@Observable
public final class AppSettingsStore {
    /// Shared app-wide instance; the Settings window and every hosted
    /// view observe the same object so changes propagate immediately.
    @MainActor public static let shared = AppSettingsStore()

    public var showRedItems: Bool {
        didSet {
            guard showRedItems != oldValue else { return }
            UserDefaults.standard.set(showRedItems, forKey: Self.showRedItemsKey)
        }
    }

    private static let showRedItemsKey = "MacClean.showRedItems"

    public init() {
        showRedItems = UserDefaults.standard.object(forKey: Self.showRedItemsKey) as? Bool ?? true
    }
}
