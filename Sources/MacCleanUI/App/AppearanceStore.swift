import AppKit
import Foundation
import Observation
import SwiftUI

/// The three appearance modes offered by the panel: follow the system or pin
/// the app to light/dark regardless of the system setting.
public enum AppearancePreference: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark

    public var id: Self { self }

    public var title: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }

    public var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// Owns the app-wide appearance preference.
///
/// The preference is persisted in `UserDefaults` and applied to `NSApp`, so
/// every surface of this AppKit-hosted app (the panel, the details window,
/// and any future window) follows the chosen mode immediately.
@MainActor
@Observable
public final class AppearanceStore {
    /// Shared app-wide instance; the Settings window and every hosted
    /// view observe the same object so changes propagate immediately.
    @MainActor public static let shared = AppearanceStore()

    public static let defaultsKey = "macclean.appearancePreference"

    public var preference: AppearancePreference {
        didSet {
            guard preference != oldValue else { return }
            UserDefaults.standard.set(preference.rawValue, forKey: Self.defaultsKey)
            apply()
        }
    }

    public init(preference: AppearancePreference? = nil) {
        if let preference {
            self.preference = preference
            // didSet does not run during initialization, so persist an
            // explicit initial preference here explicitly.
            UserDefaults.standard.set(preference.rawValue, forKey: Self.defaultsKey)
        } else {
            let raw = UserDefaults.standard.string(forKey: Self.defaultsKey)
            self.preference = AppearancePreference(rawValue: raw ?? "") ?? .system
        }
        apply()
    }

    public func apply() {
        // `NSApplication.shared` instead of `NSApp`: the store can be
        // created during app startup when the `NSApp` global is still nil.
        NSApplication.shared.appearance = preference.nsAppearance
    }
}

extension AppearancePreference {
    /// Maps the preference onto SwiftUI color scheme so already-rendered
    /// SwiftUI views (the panel and the details window) update immediately
    /// when the mode changes. `NSApp.appearance` alone does not reliably
    /// refresh SwiftUI content.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
