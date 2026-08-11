import CleanCore
import Foundation
import Observation

public struct AppDependencies {
    public let inventory: any ApplicationInventoryProviding
    public let coordinator: any ScanCoordinating
    public let planner: CleanupPlanner
    public let cleanupExecutor: any CleanupExecuting
    public let audit: any AuditStoring
    public let finder: any FinderRevealing
    public let notifications: any NotificationSending
    public let now: @Sendable () -> Date

    public init(
        inventory: any ApplicationInventoryProviding,
        coordinator: any ScanCoordinating,
        planner: CleanupPlanner,
        cleanupExecutor: any CleanupExecuting,
        audit: any AuditStoring,
        finder: any FinderRevealing,
        notifications: any NotificationSending,
        now: @escaping @Sendable () -> Date
    ) {
        self.inventory = inventory
        self.coordinator = coordinator
        self.planner = planner
        self.cleanupExecutor = cleanupExecutor
        self.audit = audit
        self.finder = finder
        self.notifications = notifications
        self.now = now
    }
}

@MainActor
@Observable
public final class AppModel {
    public enum Phase: Equatable {
        case idle, scanning, results, cleaning
    }

    public struct State {
        public var phase: Phase = .idle
        public var candidates: [CleanupCandidate] = []
        public var failures: [ScannerFailure] = []
        public var lastScan: Date?
        public var errorMessage: String?

        public init() {}
    }

    public private(set) var state = State()

    @ObservationIgnored
    private let dependencies: AppDependencies

    @ObservationIgnored
    private var currentScanID: UUID?

    public init(dependencies: AppDependencies) {
        self.dependencies = dependencies
    }

    public var estimatedReclaimableBytes: UInt64 {
        state.candidates
            .lazy
            .filter { $0.risk == .green }
            .reduce(0) { total, candidate in
                let (sum, overflow) = total.addingReportingOverflow(candidate.sizeBytes)
                return overflow ? UInt64.max : sum
            }
    }

    public var reclaimableBytes: UInt64 {
        estimatedReclaimableBytes
    }

    public var greenSummary: String {
        "\(state.candidates.count { $0.risk == .green }) 项"
    }

    public var yellowSummary: String {
        "\(state.candidates.count { $0.risk == .yellow }) 项"
    }

    public func scan() async {
        state.phase = .scanning
        state.errorMessage = nil

        do {
            let inventory = try await dependencies.inventory.inventory()
            let report = await dependencies.coordinator.scan(
                context: ScanContext(inventory: inventory, now: dependencies.now())
            )
            state.candidates = report.candidates
            state.failures = report.failures

            let completedAt = dependencies.now()
            state.lastScan = completedAt
            currentScanID = UUID()
            try dependencies.audit.recordScan(at: completedAt)
            state.phase = .results
        } catch {
            state.errorMessage = String(describing: error)
            state.phase = .idle
        }
    }

    public func cleanGreenCandidates() async {
        let candidates = state.candidates
        let scanID = currentScanID
        state.phase = .cleaning
        state.errorMessage = nil

        let plan = dependencies.planner.plan(
            candidates: candidates,
            confirmedIDs: [],
            now: dependencies.now()
        )
        let result = await dependencies.cleanupExecutor.execute(plan)
        let completedAt = dependencies.now()
        let candidatesByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        var auditErrors: [String] = []

        for item in result.items {
            guard let candidate = candidatesByID[item.candidateID] else {
                auditErrors.append("Cleanup result references an unknown candidate")
                continue
            }

            do {
                try dependencies.audit.append(
                    auditRecord(
                        for: candidate,
                        result: item,
                        scanID: scanID ?? plan.id,
                        timestamp: completedAt
                    )
                )
            } catch {
                auditErrors.append(String(describing: error))
            }
        }

        await scan()
        if !auditErrors.isEmpty {
            state.errorMessage = auditErrors.joined(separator: "\n")
        }
    }

    public func reveal(_ candidate: CleanupCandidate) {
        guard case .available(let url) = FinderRevealState(url: candidate.canonicalURL) else {
            return
        }
        dependencies.finder.reveal([url])
    }

    private func auditRecord(
        for candidate: CleanupCandidate,
        result: CleanupItemResult,
        scanID: UUID,
        timestamp: Date
    ) -> AuditRecord {
        let details = auditDetails(for: result.status)
        return AuditRecord(
            id: UUID(),
            scanID: scanID,
            candidateID: candidate.id,
            sourcePath: candidate.sourceURL.path,
            canonicalPath: candidate.canonicalURL.path,
            scannerID: candidate.evidence.scannerID,
            risk: candidate.risk,
            action: candidate.proposedAction,
            sizeBytes: details.estimatedDeletedBytes,
            timestamp: timestamp,
            outcome: details.outcome,
            message: details.message
        )
    }

    private func auditDetails(
        for status: CleanupItemStatus
    ) -> (estimatedDeletedBytes: UInt64, outcome: AuditOutcome, message: String?) {
        switch status {
        case .success(let estimatedDeletedBytes):
            return (estimatedDeletedBytes, .cleaned, nil)
        case .partial(let estimatedDeletedBytes, let message):
            return (estimatedDeletedBytes, .failed, "Partial cleanup: \(message)")
        case .skipped(let reason):
            return (0, .skipped, "Skipped: \(reason.rawValue)")
        case .failed(let message):
            return (0, .failed, message)
        }
    }
}
