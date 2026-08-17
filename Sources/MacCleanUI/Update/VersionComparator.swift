import Foundation

/// Pure semantic-version comparison for "x.y.z" style version strings
/// (an optional leading "v"/"V" is ignored; missing parts compare as 0,
/// so "0.2" and "0.2.0" are equal). Kept dependency-free so it is
/// trivially unit-testable.
public enum VersionComparator {
    public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = components(of: lhs)
        let right = components(of: rhs)
        let count = max(left.count, right.count)
        for index in 0..<count {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r {
                return l < r ? .orderedAscending : .orderedDescending
            }
        }
        return .orderedSame
    }

    /// Returns the version string with an optional leading "v" stripped,
    /// for display purposes (e.g. "v0.3.0" -> "0.3.0").
    public static func displayVersion(_ version: String) -> String {
        version.hasPrefix("v") || version.hasPrefix("V")
            ? String(version.dropFirst())
            : version
    }

    private static func components(of version: String) -> [Int] {
        let stripped = displayVersion(version)
        return stripped
            .split(separator: ".", omittingEmptySubsequences: false)
            .map { Int($0) ?? 0 }
    }
}
