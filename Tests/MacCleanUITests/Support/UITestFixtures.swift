import CleanCore
import Foundation
@testable import MacCleanUI

enum UITestFixtures {
    static let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
    static let scanID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    static let candidateID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    static let auditID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!

    static func auditRecord(sourcePath: String) -> AuditRecord {
        AuditRecord(
            id: auditID,
            scanID: scanID,
            candidateID: candidateID,
            sourcePath: sourcePath,
            canonicalPath: "/canonical\(sourcePath)",
            scannerID: "fixture-scanner",
            risk: .green,
            action: .deleteContentsPreservingRoot,
            sizeBytes: 1_024,
            timestamp: timestamp,
            outcome: .cleaned,
            message: nil
        )
    }

    static func candidate(sourceURL: URL, canonicalURL: URL) -> CleanupCandidate {
        candidate(
            risk: .green,
            path: canonicalURL.path,
            id: candidateID,
            sourceURL: sourceURL
        )
    }

    static func candidate(
        risk: RiskLevel,
        path: String = "/tmp/mac-clean-tests/com.example.Editor",
        id: UUID = UUID(),
        sizeBytes: UInt64 = 1_024,
        sourceURL: URL? = nil
    ) -> CleanupCandidate {
        let canonicalURL = URL(fileURLWithPath: path).standardizedFileURL
        let sourceURL = sourceURL ?? canonicalURL
        let action: CleanupAction
        switch risk {
        case .green:
            action = .deleteContentsPreservingRoot
        case .yellow:
            action = .moveToTrash
        case .red:
            action = .reportOnly
        }

        return CleanupCandidate(
            id: id,
            displayName: sourceURL.lastPathComponent,
            category: risk == .red ? .reportOnly : .applicationCache,
            sourceURL: sourceURL,
            canonicalURL: canonicalURL,
            sizeBytes: sizeBytes,
            modifiedAt: timestamp,
            fingerprint: FileFingerprint(
                deviceID: 1,
                fileID: 2,
                ownerID: 501,
                sizeBytes: sizeBytes,
                modifiedAt: timestamp
            ),
            evidence: CandidateEvidence(
                scannerID: "fixture-scanner",
                ruleID: "fixture-rule",
                ownerName: "Editor",
                ownerBundleID: "com.example.Editor",
                explanation: "Fixture evidence"
            ),
            risk: risk,
            riskReason: "Fixture risk",
            proposedAction: action
        )
    }

    static func scanReport(candidateCount: Int, failureCount: Int) -> ScanReport {
        ScanReport(
            candidates: (0..<candidateCount).map { index in
                candidate(
                    risk: .green,
                    path: "/tmp/mac-clean-tests/candidate-\(index)",
                    id: UUID()
                )
            },
            failures: (0..<failureCount).map { index in
                ScannerFailure(scannerID: "fixture-scanner-\(index)", message: "Fixture failure")
            }
        )
    }
}

enum UITestFixtureError: Error, Sendable {
    case inventoryUnavailable, auditUnavailable
}

struct StubInventoryProvider: ApplicationInventoryProviding {
    let result: Result<ApplicationInventory, UITestFixtureError>

    init(
        inventory: ApplicationInventory = ApplicationInventory(
            installedApplications: [],
            runningBundleIDs: []
        )
    ) {
        result = .success(inventory)
    }

    init(error: UITestFixtureError) {
        result = .failure(error)
    }

    func inventory() async throws -> ApplicationInventory {
        try result.get()
    }
}

struct StubScanCoordinator: ScanCoordinating {
    let report: ScanReport

    init(report: ScanReport = UITestFixtures.scanReport(candidateCount: 0, failureCount: 0)) {
        self.report = report
    }

    func scan(context: ScanContext) async -> ScanReport {
        report
    }
}

@MainActor
final class RecordingScanCoordinator: ScanCoordinating {
    private let reports: [ScanReport]
    private(set) var contexts: [ScanContext] = []

    init(reports: [ScanReport] = [UITestFixtures.scanReport(candidateCount: 0, failureCount: 0)]) {
        self.reports = reports
    }

    var scanCount: Int { contexts.count }

    func scan(context: ScanContext) async -> ScanReport {
        contexts.append(context)
        let index = min(contexts.count - 1, reports.count - 1)
        return reports[index]
    }
}

actor StubCleanupExecutor: CleanupExecuting {
    private let result: @Sendable (CleanupPlan) -> CleanupResult
    private(set) var plans: [CleanupPlan] = []

    init(resultItems: [CleanupItemResult] = []) {
        result = { plan in
            CleanupResult(planID: plan.id, items: resultItems)
        }
    }

    init(result: @escaping @Sendable (CleanupPlan) -> CleanupResult) {
        self.result = result
    }

    func execute(_ plan: CleanupPlan) async -> CleanupResult {
        plans.append(plan)
        return result(plan)
    }
}

actor SequencedInventoryProvider: ApplicationInventoryProviding {
    private let results: [Result<ApplicationInventory, UITestFixtureError>]
    private var nextIndex = 0

    init(results: [Result<ApplicationInventory, UITestFixtureError>]) {
        precondition(!results.isEmpty)
        self.results = results
    }

    func inventory() async throws -> ApplicationInventory {
        let index = min(nextIndex, results.count - 1)
        nextIndex += 1
        return try results[index].get()
    }
}

actor SuspendingFirstScanCoordinator: ScanCoordinating {
    private let firstReport: ScanReport
    private let laterReport: ScanReport
    private var callCount = 0
    private var firstContinuation: CheckedContinuation<ScanReport, Never>?
    private var firstStartedWaiters: [CheckedContinuation<Void, Never>] = []

    init(firstReport: ScanReport, laterReport: ScanReport) {
        self.firstReport = firstReport
        self.laterReport = laterReport
    }

    func scan(context: ScanContext) async -> ScanReport {
        callCount += 1
        guard callCount == 1 else {
            return laterReport
        }

        let waiters = firstStartedWaiters
        firstStartedWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return await withCheckedContinuation { continuation in
            firstContinuation = continuation
        }
    }

    func waitUntilFirstScanStarts() async {
        guard callCount == 0 else { return }
        await withCheckedContinuation { continuation in
            firstStartedWaiters.append(continuation)
        }
    }

    func resumeFirstScan() {
        firstContinuation?.resume(returning: firstReport)
        firstContinuation = nil
    }

    func recordedScanCount() -> Int {
        callCount
    }
}

actor SuspendingCleanupExecutor: CleanupExecuting {
    private var continuation: CheckedContinuation<Void, Never>?
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var plans: [CleanupPlan] = []

    func execute(_ plan: CleanupPlan) async -> CleanupResult {
        plans.append(plan)
        let waiters = startedWaiters
        startedWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        return CleanupResult(
            planID: plan.id,
            items: plan.items.map {
                CleanupItemResult(
                    candidateID: $0.candidateID,
                    status: .success(estimatedDeletedBytes: 0)
                )
            }
        )
    }

    func waitUntilExecutionStarts() async {
        guard plans.isEmpty else { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }

    func resumeExecution() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
final class InMemoryAuditStore: AuditStoring {
    private(set) var appendedRecords: [AuditRecord] = []
    private(set) var scanDates: [Date] = []

    init(lastScan: Date? = nil) {
        if let lastScan {
            scanDates = [lastScan]
        }
    }

    func append(_ record: AuditRecord) throws {
        appendedRecords.append(record)
    }

    func recordScan(at date: Date) throws {
        scanDates.append(date)
    }

    func records() throws -> [AuditRecord] {
        appendedRecords
    }

    func latestScanDate() throws -> Date? {
        scanDates.max()
    }

    func clear() throws {
        appendedRecords.removeAll()
        scanDates.removeAll()
    }
}

@MainActor
final class FailingAppendAuditStore: AuditStoring {
    private(set) var scanDates: [Date] = []

    func append(_ record: AuditRecord) throws {
        throw UITestFixtureError.auditUnavailable
    }

    func recordScan(at date: Date) throws {
        scanDates.append(date)
    }

    func records() throws -> [AuditRecord] {
        []
    }

    func latestScanDate() throws -> Date? {
        scanDates.max()
    }

    func clear() throws {
        scanDates.removeAll()
    }
}

@MainActor
final class RecordingFinderRevealer: FinderRevealing {
    private(set) var urls: [URL] = []

    func reveal(_ urls: [URL]) {
        self.urls.append(contentsOf: urls)
    }
}

actor RecordingNotificationService: NotificationSending {
    struct Summary: Equatable, Sendable {
        let estimatedDeletedBytes: UInt64
        let pendingReviewCount: Int
    }

    private(set) var authorizationRequestCount = 0
    private(set) var summaries: [Summary] = []
    var authorizationResult = true

    func requestAuthorizationIfNeeded() async -> Bool {
        authorizationRequestCount += 1
        return authorizationResult
    }

    func sendCleanupSummary(
        estimatedDeletedBytes: UInt64,
        pendingReviewCount: Int
    ) async {
        summaries.append(
            Summary(
                estimatedDeletedBytes: estimatedDeletedBytes,
                pendingReviewCount: pendingReviewCount
            )
        )
    }
}

@MainActor
extension AppDependencies {
    static func fixture(
        report: ScanReport = UITestFixtures.scanReport(candidateCount: 0, failureCount: 0),
        lastScan: Date? = nil,
        now: @escaping @Sendable () -> Date = { UITestFixtures.timestamp },
        inventory: (any ApplicationInventoryProviding)? = nil,
        coordinator: (any ScanCoordinating)? = nil,
        cleanupExecutor: (any CleanupExecuting)? = nil,
        audit: (any AuditStoring)? = nil,
        finder: (any FinderRevealing)? = nil,
        notifications: (any NotificationSending)? = nil
    ) -> AppDependencies {
        AppDependencies(
            inventory: inventory ?? StubInventoryProvider(),
            coordinator: coordinator ?? StubScanCoordinator(report: report),
            planner: CleanupPlanner(),
            cleanupExecutor: cleanupExecutor ?? StubCleanupExecutor(),
            audit: audit ?? InMemoryAuditStore(lastScan: lastScan),
            finder: finder ?? RecordingFinderRevealer(),
            notifications: notifications ?? RecordingNotificationService(),
            now: now
        )
    }
}
