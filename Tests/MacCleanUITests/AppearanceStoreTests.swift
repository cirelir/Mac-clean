import AppKit
import Testing
@testable import MacCleanUI

@Suite(.serialized)
struct AppearanceStoreTests {
    private let defaults = UserDefaults.standard

    @Test @MainActor func preferenceTitlesAreLocalized() {
        #expect(AppearancePreference.system.title == "跟随系统")
        #expect(AppearancePreference.light.title == "浅色")
        #expect(AppearancePreference.dark.title == "深色")
    }

    @Test @MainActor func preferenceDefaultsToSystemWhenNothingStored() {
        defaults.removeObject(forKey: AppearanceStore.defaultsKey)
        defer { defaults.removeObject(forKey: AppearanceStore.defaultsKey) }
        let store = AppearanceStore()
        #expect(store.preference == .system)
    }

    @Test @MainActor func preferencePersistsAndRestoresFromUserDefaults() {
        defaults.removeObject(forKey: AppearanceStore.defaultsKey)
        defer { defaults.removeObject(forKey: AppearanceStore.defaultsKey) }

        let store = AppearanceStore(preference: .dark)
        #expect(defaults.string(forKey: AppearanceStore.defaultsKey) == "dark")

        let restored = AppearanceStore()
        #expect(restored.preference == .dark)
    }

    @Test @MainActor func changingPreferencePersistsAndAppliesToNSApp() {
        defaults.removeObject(forKey: AppearanceStore.defaultsKey)
        defer { defaults.removeObject(forKey: AppearanceStore.defaultsKey) }

        let store = AppearanceStore(preference: .system)
        store.preference = .dark
        #expect(defaults.string(forKey: AppearanceStore.defaultsKey) == "dark")
        #expect(NSApp.appearance?.name == NSAppearance.Name.darkAqua)

        store.preference = .light
        #expect(NSApp.appearance?.name == NSAppearance.Name.aqua)

        store.preference = .system
        #expect(NSApp.appearance == nil)
    }
}
