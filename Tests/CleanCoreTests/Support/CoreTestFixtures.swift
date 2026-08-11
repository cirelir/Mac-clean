import Foundation
@testable import CleanCore

enum CoreTestFixtures {
    static let date = Date(timeIntervalSince1970: 1_700_000_000)
    static let path = URL(fileURLWithPath: "/tmp/mac-clean-tests/com.example.Editor")

    static func fingerprint(size: UInt64 = 1024) -> FileFingerprint {
        .init(deviceID: 1, fileID: 2, ownerID: 501, sizeBytes: size, modifiedAt: date)
    }

    static func discovery(
        kind: DiscoveryKind,
        ownerBundleID: String? = "com.example.Editor"
    ) -> DiscoveredItem {
        .init(
            displayName: "Editor cache",
            sourceURL: path,
            validatedPath: .init(
                originalURL: path,
                canonicalURL: path,
                allowedRoot: path.deletingLastPathComponent()
            ),
            sizeBytes: 1024,
            modifiedAt: date,
            fingerprint: fingerprint(),
            evidence: .init(
                scannerID: "fixture",
                ruleID: "fixture-rule",
                ownerName: "Editor",
                ownerBundleID: ownerBundleID,
                explanation: "Fixture evidence"
            ),
            kind: kind
        )
    }

    static func cacheDiscovery(ownerBundleID: String) -> DiscoveredItem {
        discovery(kind: .regenerableApplicationCache, ownerBundleID: ownerBundleID)
    }

    static func context(installed: [String] = [], running: [String] = []) -> ScanContext {
        let applications = installed.map {
            InstalledApplication(
                name: $0,
                bundleID: $0,
                url: URL(fileURLWithPath: "/Applications/\($0).app")
            )
        }
        return .init(
            inventory: .init(
                installedApplications: applications,
                runningBundleIDs: Set(running)
            ),
            now: date
        )
    }
}
