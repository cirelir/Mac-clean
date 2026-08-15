import Foundation

public struct RiskClassifier: Sendable {
    public init() {}

    public func classify(_ item: DiscoveredItem, context: ScanContext) throws -> CleanupCandidate {
        switch item.kind {
        case .systemData:
            // System diagnostics (e.g. crash reports) are regenerable, contain
            // no user data, and have no application owner to protect, so they
            // are safe to clear without owner gating.
            return candidate(
                for: item,
                category: .systemData,
                risk: .green,
                riskReason: "System diagnostics are regenerable and contain no user data",
                proposedAction: .deleteContentsPreservingRoot
            )

        case .regenerableApplicationCache:
            let gate = ownerGate(for: item, context: context)
            guard case .ok(_, let ownerIsInstalled) = gate else {
                return reportOnlyCandidate(for: item, reason: gate.reason)
            }
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
            let gate = ownerGate(for: item, context: context)
            guard case .ok(_, let ownerIsInstalled) = gate else {
                return reportOnlyCandidate(for: item, reason: gate.reason)
            }
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
            // Residuals are by definition owner-less, so the owner gate does
            // not apply; only a running owner (e.g. the app was re-installed)
            // downgrades the item to report-only.
            if let ownerBundleID = item.evidence.ownerBundleID,
               context.inventory.runningBundleIDs.contains(ownerBundleID) {
                return reportOnlyCandidate(
                    for: item,
                    reason: "The owning application is running"
                )
            }
            switch confidence {
            case .authoritative, .inferred:
                return candidate(
                    for: item,
                    category: .orphanResidual,
                    risk: .yellow,
                    riskReason: confidence == .authoritative
                        ? "Residual ownership is authoritative and requires confirmation"
                        : "Residual ownership is inferred; confirm before removing",
                    proposedAction: .moveToTrash
                )
            case .unknown:
                return reportOnlyCandidate(
                    for: item,
                    reason: "Residual ownership is unknown"
                )
            }

        case .authoritativeUnusedDependency:
            let gate = ownerGate(for: item, context: context)
            guard case .ok = gate else {
                return reportOnlyCandidate(for: item, reason: gate.reason)
            }
            return candidate(
                for: item,
                category: .packageManager,
                risk: .yellow,
                riskReason: "An authoritative package manager result requires confirmation",
                proposedAction: .packageManagerCommand
            )

        case .developerData:
            let gate = ownerGate(for: item, context: context)
            guard case .ok(_, let ownerIsInstalled) = gate else {
                return reportOnlyCandidate(for: item, reason: gate.reason)
            }
            guard ownerIsInstalled else {
                return reportOnlyCandidate(
                    for: item,
                    reason: "The developer tool is not installed"
                )
            }
            return candidate(
                for: item,
                category: .developerTool,
                risk: .green,
                riskReason: "Build artifacts are regenerable and the tool is not running",
                proposedAction: .deleteContentsPreservingRoot
            )

        case .unknown:
            return reportOnlyCandidate(for: item, reason: "The discovery kind is unknown")
        }
    }

    private enum OwnerGate {
        case ok(ownerBundleID: String, ownerIsInstalled: Bool)
        case reportOnly(reason: String)

        var reason: String {
            if case .reportOnly(let reason) = self {
                return reason
            }
            return ""
        }
    }

    private func ownerGate(
        for item: DiscoveredItem,
        context: ScanContext
    ) -> OwnerGate {
        guard let ownerBundleID = item.evidence.ownerBundleID else {
            return .reportOnly(reason: "The item's owner is unknown")
        }

        guard !context.inventory.runningBundleIDs.contains(ownerBundleID) else {
            return .reportOnly(reason: "The owning application is running")
        }

        let ownerIsInstalled = context.inventory.installedApplications.contains {
            $0.bundleID == ownerBundleID
        }
        return .ok(ownerBundleID: ownerBundleID, ownerIsInstalled: ownerIsInstalled)
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
