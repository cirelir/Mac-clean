import Foundation
@testable import CleanCore

enum CoreTestFixtures {
    static let date = Date(timeIntervalSince1970: 1_700_000_000)
    static let path = URL(fileURLWithPath: "/tmp/mac-clean-tests/com.example.Editor")

    static func fingerprint(size: UInt64 = 1024) -> FileFingerprint {
        .init(deviceID: 1, fileID: 2, ownerID: 501, sizeBytes: size, modifiedAt: date)
    }

    static func candidate(
        risk: RiskLevel,
        path: String = path.path,
        fingerprint: FileFingerprint = fingerprint(),
        action: CleanupAction? = nil,
        id: UUID = UUID()
    ) -> CleanupCandidate {
        let url = URL(fileURLWithPath: path)
        let defaultAction: CleanupAction
        switch risk {
        case .green:
            defaultAction = .deleteContentsPreservingRoot
        case .yellow:
            defaultAction = .moveToTrash
        case .red:
            defaultAction = .reportOnly
        }
        let proposedAction = action ?? defaultAction

        return CleanupCandidate(
            id: id,
            displayName: url.lastPathComponent,
            category: risk == .red ? .reportOnly : .applicationCache,
            sourceURL: url,
            canonicalURL: url.standardizedFileURL.resolvingSymlinksInPath(),
            sizeBytes: fingerprint.sizeBytes,
            modifiedAt: fingerprint.modifiedAt,
            fingerprint: fingerprint,
            evidence: .init(
                scannerID: "fixture",
                ruleID: "fixture-rule",
                ownerName: "Editor",
                ownerBundleID: "com.example.Editor",
                explanation: "Fixture evidence"
            ),
            risk: risk,
            riskReason: "Fixture risk",
            proposedAction: proposedAction
        )
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
