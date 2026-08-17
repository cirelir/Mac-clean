import Foundation

/// Version information for Mac Clean.
/// Update `current` before each release to match the release tag.
public enum AppVersion {
    /// The current semantic version of the app.
    public static let current = "0.2.1"

    /// A user-facing version string, e.g. "v0.2.0".
    public static var displayString: String {
        "v\(current)"
    }

    /// The URL where users can download the latest release.
    /// Points to the GitHub releases page of the Mac-clean repository.
    public static let updateURL = URL(
        string: "https://github.com/cirelir/Mac-clean/releases/latest"
    )!
}
