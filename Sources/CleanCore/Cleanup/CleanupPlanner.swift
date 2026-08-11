import Foundation

public struct CleanupPlanItem: Hashable, Sendable {
    public let candidateID: UUID
    public let canonicalURL: URL
    public let expectedFingerprint: FileFingerprint
    public let action: CleanupAction

    public init(
        candidateID: UUID,
        canonicalURL: URL,
        expectedFingerprint: FileFingerprint,
        action: CleanupAction
    ) {
        self.candidateID = candidateID
        self.canonicalURL = canonicalURL
        self.expectedFingerprint = expectedFingerprint
        self.action = action
    }
}

public struct CleanupPlan: Hashable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let items: [CleanupPlanItem]

    public init(id: UUID, createdAt: Date, items: [CleanupPlanItem]) {
        self.id = id
        self.createdAt = createdAt
        self.items = items
    }
}

public struct CleanupPlanner: Sendable {
    public init() {}

    public func plan(
        candidates: [CleanupCandidate],
        confirmedIDs: Set<UUID>,
        now: Date = .now
    ) -> CleanupPlan {
        let items = candidates
            .filter {
                $0.risk == .green
                    || ($0.risk == .yellow && confirmedIDs.contains($0.id))
            }
            .filter { $0.risk != .red && $0.proposedAction != .reportOnly }
            .map {
                CleanupPlanItem(
                    candidateID: $0.id,
                    canonicalURL: $0.canonicalURL,
                    expectedFingerprint: $0.fingerprint,
                    action: $0.proposedAction
                )
            }

        return CleanupPlan(id: UUID(), createdAt: now, items: items)
    }
}
