import Foundation

public struct RiskClassifier: Sendable {
    public init() {}

    public func classify(_ item: DiscoveredItem, context: ScanContext) throws -> CleanupCandidate {
        guard let ownerBundleID = item.evidence.ownerBundleID else {
            return reportOnlyCandidate(for: item, reason: "The item's owner is unknown")
        }

        guard !context.inventory.runningBundleIDs.contains(ownerBundleID) else {
            return reportOnlyCandidate(for: item, reason: "The owning application is running")
        }

        let ownerIsInstalled = context.inventory.installedApplications.contains {
            $0.bundleID == ownerBundleID
        }

        switch item.kind {
        case .regenerableApplicationCache:
            guard ownerIsInstalled else {
                return reportOnlyCandidate(
                    for: item,
                    reason: "The cache owner is not installed"
                )
            }
            return candidate(
                for: item,
                category: .applicationCache,
                risk: .green,
                riskReason: "Cache is regenerable and the owner is not running",
                proposedAction: .deleteContentsPreservingRoot
            )

        case .rotatableLog(let olderThanDays):
            guard ownerIsInstalled, olderThanDays >= 7 else {
                return reportOnlyCandidate(
                    for: item,
                    reason: "The log is not an installed application's rotatable log older than seven days"
                )
            }
            return candidate(
                for: item,
                category: .applicationLog,
                risk: .green,
                riskReason: "Log is rotatable, older than seven days, and the owner is not running",
                proposedAction: .deleteContentsPreservingRoot
            )

        case .orphanResidual(let confidence):
            switch confidence {
            case .authoritative:
                return candidate(
                    for: item,
                    category: .orphanResidual,
                    risk: .yellow,
                    riskReason: "Residual ownership is authoritative and requires confirmation",
                    proposedAction: .moveToTrash
                )
            case .inferred, .unknown:
                return reportOnlyCandidate(
                    for: item,
                    reason: "Residual ownership is inferred or unknown"
                )
            }

        case .authoritativeUnusedDependency:
            return candidate(
                for: item,
                category: .packageManager,
                risk: .yellow,
                riskReason: "An authoritative package manager result requires confirmation",
                proposedAction: .packageManagerCommand
            )

        case .unknown:
            return reportOnlyCandidate(for: item, reason: "The discovery kind is unknown")
        }
    }

    private func reportOnlyCandidate(for item: DiscoveredItem, reason: String) -> CleanupCandidate {
        candidate(
            for: item,
            category: .reportOnly,
            risk: .red,
            riskReason: reason,
            proposedAction: .reportOnly
        )
    }

    private func candidate(
        for item: DiscoveredItem,
        category: CandidateCategory,
        risk: RiskLevel,
        riskReason: String,
        proposedAction: CleanupAction
    ) -> CleanupCandidate {
        .init(
            id: UUID(),
            displayName: item.displayName,
            category: category,
            sourceURL: item.sourceURL,
            canonicalURL: item.validatedPath.canonicalURL,
            sizeBytes: item.sizeBytes,
            modifiedAt: item.modifiedAt,
            fingerprint: item.fingerprint,
            evidence: item.evidence,
            risk: risk,
            riskReason: riskReason,
            proposedAction: proposedAction
        )
    }
}
