import CleanCore
import Foundation
import Observation

public struct CatchUpCleanupSummary: Equatable, Sendable {
    public let estimatedDeletedBytes: UInt64
    public let pendingReviewCount: Int

    public init(estimatedDeletedBytes: UInt64, pendingReviewCount: Int) {
        self.estimatedDeletedBytes = estimatedDeletedBytes
        self.pendingReviewCount = pendingReviewCount
    }
}

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
    private enum ScanMode {
        case manual, weeklyCatchUp
    }

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

    @ObservationIgnored
    private var scanGeneration: UInt64 = 0

    @ObservationIgnored
    private var catchUpInProgress = false

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
        guard !catchUpInProgress else { return }
        _ = await performScan(mode: .manual)
    }

    private func performScan(mode: ScanMode) async -> Bool {
        guard state.phase != .cleaning else { return false }

        scanGeneration &+= 1
        let generation = scanGeneration
        state.phase = .scanning
        state.candidates = []
        state.failures = []
        state.errorMessage = nil
        currentScanID = nil

        do {
            let inventory = try await dependencies.inventory.inventory()
            guard generation == scanGeneration else { return false }
            let report = await dependencies.coordinator.scan(
                context: ScanContext(inventory: inventory, now: dependencies.now())
            )
            guard generation == scanGeneration else { return false }

            state.candidates = report.candidates
            state.failures = report.failures
            if mode == .weeklyCatchUp, !report.failures.isEmpty {
                currentScanID = nil
                state.phase = .results
                return false
            }

            let completedAt = dependencies.now()
            try dependencies.audit.recordScan(at: completedAt)
            state.lastScan = completedAt
            currentScanID = UUID()
            state.phase = .results
            return true
        } catch {
            guard generation == scanGeneration else { return false }
            state.candidates = []
            state.failures = []
            currentScanID = nil
            state.errorMessage = String(describing: error)
            state.phase = .idle
            return false
        }
    }

    @discardableResult
    public func performCatchUpScanIfDue() async -> CatchUpCleanupSummary? {
        guard
            !catchUpInProgress,
            state.phase != .scanning,
            state.phase != .cleaning
        else { return nil }

        let lastScan: Date?
        do {
            lastScan = try dependencies.audit.latestScanDate()
        } catch {
            state.errorMessage = String(describing: error)
            return nil
        }

        guard WeeklyScanScheduler.isDue(lastScan: lastScan, now: dependencies.now()) else {
            return nil
        }

        catchUpInProgress = true
        defer { catchUpInProgress = false }
        guard await performScan(mode: .weeklyCatchUp) else { return nil }

        let pendingReviewCount = state.candidates.count { $0.risk == .yellow }
        let summary: CatchUpCleanupSummary
        if state.candidates.contains(where: { $0.risk == .green }) {
            guard let cleanupSummary = await performGreenCleanup(
                pendingReviewCount: pendingReviewCount
            ) else {
                return nil
            }
            summary = cleanupSummary
        } else {
            summary = CatchUpCleanupSummary(
                estimatedDeletedBytes: 0,
                pendingReviewCount: pendingReviewCount
            )
        }

        await dependencies.notifications.sendCleanupSummary(
            estimatedDeletedBytes: summary.estimatedDeletedBytes,
            pendingReviewCount: summary.pendingReviewCount
        )
        return summary
    }

    public func cleanGreenCandidates() async {
        guard !catchUpInProgress else { return }
        _ = await performGreenCleanup(
            pendingReviewCount: state.candidates.count { $0.risk == .yellow }
        )
    }

    private func performGreenCleanup(
        pendingReviewCount: Int
    ) async -> CatchUpCleanupSummary? {
        guard state.phase == .results, let currentScanID else { return nil }

        let candidates = state.candidates
        let scanID = currentScanID
        guard candidates.contains(where: { $0.risk == .green }) else {
            return CatchUpCleanupSummary(
                estimatedDeletedBytes: 0,
                pendingReviewCount: pendingReviewCount
            )
        }

        state.phase = .cleaning
        state.errorMessage = nil
        let latestInventory: ApplicationInventory
        do {
            latestInventory = try await dependencies.inventory.inventory()
        } catch {
            state.phase = .results
            state.errorMessage = String(describing: error)
            return nil
        }

        let revalidatedCandidates = candidates.filter { candidate in
            guard candidate.risk == .green else { return true }
            guard let ownerBundleID = candidate.evidence.ownerBundleID else {
                return false
            }
            return !latestInventory.runningBundleIDs.contains(ownerBundleID)
        }
        let plan = dependencies.planner.plan(
            candidates: revalidatedCandidates,
            confirmedIDs: [],
            now: dependencies.now()
        )
        guard !plan.items.isEmpty else {
            state.phase = .results
            _ = await performScan(mode: .manual)
            return nil
        }

        let result = await dependencies.cleanupExecutor.execute(plan)
        let completedAt = dependencies.now()
        let candidatesByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        var auditErrors: [String] = []

        let protocolMismatch = cleanupProtocolMismatch(plan: plan, result: result)
        if let mismatch = protocolMismatch {
            auditErrors.append(mismatch)
            for plannedItem in plan.items {
                guard let candidate = candidatesByID[plannedItem.candidateID] else { continue }
                do {
                    try dependencies.audit.append(
                        auditRecord(
                            for: candidate,
                            result: CleanupItemResult(
                                candidateID: plannedItem.candidateID,
                                status: .failed(message: mismatch)
                            ),
                            scanID: scanID,
                            timestamp: completedAt
                        )
                    )
                } catch {
                    auditErrors.append(String(describing: error))
                }
            }
        } else {
            for item in result.items {
                guard let candidate = candidatesByID[item.candidateID] else { continue }
                do {
                    try dependencies.audit.append(
                        auditRecord(
                            for: candidate,
                            result: item,
                            scanID: scanID,
                            timestamp: completedAt
                        )
                    )
                } catch {
                    auditErrors.append(String(describing: error))
                }
            }
        }

        let summary = protocolMismatch == nil
            ? cleanupSummary(for: result, pendingReviewCount: pendingReviewCount)
            : nil
        state.phase = .results
        _ = await performScan(mode: .manual)
        let combinedErrors = auditErrors + [state.errorMessage].compactMap { $0 }
        if !combinedErrors.isEmpty {
            state.errorMessage = combinedErrors.joined(separator: "\n")
        }
        return summary
    }

    public func reveal(_ candidate: CleanupCandidate) {
        guard case .available(let url) = FinderRevealState(url: candidate.canonicalURL) else {
            return
        }
        dependencies.finder.reveal([url])
    }

    private func cleanupProtocolMismatch(
        plan: CleanupPlan,
        result: CleanupResult
    ) -> String? {
        guard result.planID == plan.id else {
            return "Cleanup executor protocol mismatch: result plan ID does not match the requested plan"
        }

        let plannedIDs = plan.items.map(\.candidateID)
        let resultIDs = result.items.map(\.candidateID)
        let uniquePlannedIDs = Set(plannedIDs)
        let uniqueResultIDs = Set(resultIDs)
        guard
            uniquePlannedIDs.count == plannedIDs.count,
            uniqueResultIDs.count == resultIDs.count,
            resultIDs.count == plannedIDs.count,
            uniqueResultIDs == uniquePlannedIDs
        else {
            return "Cleanup executor protocol mismatch: result candidates are not a one-to-one match for the requested plan"
        }

        return nil
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

    private func cleanupSummary(
        for result: CleanupResult,
        pendingReviewCount: Int
    ) -> CatchUpCleanupSummary {
        let estimatedDeletedBytes = result.items.reduce(UInt64(0)) { total, item in
            let itemBytes: UInt64
            switch item.status {
            case .success(let estimatedDeletedBytes),
                 .partial(let estimatedDeletedBytes, _):
                itemBytes = estimatedDeletedBytes
            case .skipped, .failed:
                itemBytes = 0
            }

            let (sum, overflow) = total.addingReportingOverflow(itemBytes)
            return overflow ? UInt64.max : sum
        }
        return CatchUpCleanupSummary(
            estimatedDeletedBytes: estimatedDeletedBytes,
            pendingReviewCount: pendingReviewCount
        )
    }
}
