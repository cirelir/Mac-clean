import Foundation

/// Matches a data/cache/log directory name against actually installed
/// applications, tolerating the naming variants real apps use.
///
/// Comparison is on a normalized key (lowercased, spaces/punctuation removed)
/// so "kimi-desktop" matches "Kimi", "com.microsoft.VSCode.ShipIt" matches
/// "com.microsoft.VSCode", and "Google" matches "Google Chrome". Exact matches
/// win; otherwise a containment match on core words of at least three
/// characters is used, so short names (like "QQ") never fuzzy-match by
/// accident.
struct ApplicationNameMatcher {
    private let applications: [InstalledApplication]
    private let exactByKey: [String: InstalledApplication]

    init(installedApplications: [InstalledApplication]) {
        applications = installedApplications
        var byKey: [String: InstalledApplication] = [:]
        for app in installedApplications {
            byKey[Self.normalize(app.bundleID)] = app
            byKey[Self.normalize(app.name)] = app
        }
        exactByKey = byKey
    }

    /// Returns the installed application this directory name belongs to, if
    /// one can be found; nil means no installed application matches.
    func match(directoryName: String) -> InstalledApplication? {
        let normalizedName = Self.normalize(directoryName)
        guard !normalizedName.isEmpty else { return nil }

        if let exact = exactByKey[normalizedName] {
            return exact
        }

        for app in applications {
            let appName = Self.normalize(app.name)
            let bundleID = Self.normalize(app.bundleID)
            if Self.containsCore(normalizedName, in: appName)
                || Self.containsCore(normalizedName, in: bundleID) {
                return app
            }
        }
        return nil
    }

    static func normalize(_ value: String) -> String {
        value.lowercased().replacingOccurrences(
            // ICU (NSRegularExpression) does not support the \u{hhhh} brace
            // escape; use the standard \uhhhh form for the CJK range.
            of: "[^a-z0-9\\u4e00-\\u9fff]",
            with: "",
            options: .regularExpression
        )
    }

    /// "kimi-desktop" normalized to "kimidesktop" contains core word "kimi"
    /// from the installed app "Kimi"; the reverse containment also applies.
    private static func containsCore(_ name: String, in candidate: String) -> Bool {
        guard !candidate.isEmpty else { return false }
        if name.count >= 3, candidate.contains(name) {
            return true
        }
        if candidate.count >= 3, name.contains(candidate) {
            return true
        }
        return false
    }
}
