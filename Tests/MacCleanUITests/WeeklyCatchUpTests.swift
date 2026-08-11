import CleanCore
import Foundation
import Testing
@testable import MacCleanUI

enum CleanupInvocation: CaseIterable, Sendable {
    case manual, catchUp
}

@Test @MainActor func launchPerformsOneCatchUpScanWhenLastScanIsOverdue() async {
    let now = Date(timeIntervalSince1970: 1_700_700_000)
    let coordinator = RecordingScanCoordinator()
    let model = AppModel(
        dependencies: .fixture(
            lastScan: Date(timeIntervalSince1970: 1_700_000_000),
            now: { now },
            coordinator: coordinator
        )
    )

    await model.performCatchUpScanIfDue()
    await model.performCatchUpScanIfDue()

    #expect(coordinator.scanCount == 1)
}

@Test @MainActor func catchUpCleansOnlyGreenCandidatesAndSendsAggregateSummary() async {
    let now = Date(timeIntervalSince1970: 1_700_700_000)
    let firstGreen = UITestFixtures.candidate(risk: .green, sizeBytes: 1_000)
    let secondGreen = UITestFixtures.candidate(risk: .green, sizeBytes: 2_000)
    let yellow = UITestFixtures.candidate(risk: .yellow, sizeBytes: 4_000)
    let red = UITestFixtures.candidate(risk: .red, sizeBytes: 8_000)
    let coordinator = RecordingScanCoordinator(
        reports: [
            ScanReport(
                candidates: [firstGreen, yellow, secondGreen, red],
                failures: []
            ),
            UITestFixtures.scanReport(candidateCount: 0, failureCount: 0)
        ]
    )
    let executor = StubCleanupExecutor(
        resultItems: [
            CleanupItemResult(
                candidateID: firstGreen.id,
                status: .success(estimatedDeletedBytes: 900)
            ),
            CleanupItemResult(
                candidateID: secondGreen.id,
                status: .skipped(.fingerprintChanged)
            )
        ]
    )
    let notifications = RecordingNotificationService()
    let model = AppModel(
        dependencies: .fixture(
            lastScan: Date(timeIntervalSince1970: 1_700_000_000),
            now: { now },
            coordinator: coordinator,
            cleanupExecutor: executor,
            notifications: notifications
        )
    )

    let summary = await model.performCatchUpScanIfDue()

    let plans = await executor.plans
    let delivered = await notifications.summaries
    #expect(plans.count == 1)
    #expect(Set(plans[0].items.map(\.candidateID)) == Set([firstGreen.id, secondGreen.id]))
    #expect(summary == CatchUpCleanupSummary(
        estimatedDeletedBytes: 900,
        pendingReviewCount: 1
    ))
    #expect(delivered == [
        RecordingNotificationService.Summary(
            estimatedDeletedBytes: 900,
            pendingReviewCount: 1
        )
    ])
}

@Test @MainActor func catchUpReportsPartialDeletionWithoutCallingItComplete() async {
    let now = Date(timeIntervalSince1970: 1_700_700_000)
    let green = UITestFixtures.candidate(risk: .green, sizeBytes: 1_000)
    let coordinator = RecordingScanCoordinator(
        reports: [
            ScanReport(candidates: [green], failures: []),
            UITestFixtures.scanReport(candidateCount: 0, failureCount: 0)
        ]
    )
    let executor = StubCleanupExecutor(
        resultItems: [
            CleanupItemResult(
                candidateID: green.id,
                status: .partial(
                    estimatedDeletedBytes: 250,
                    message: "one entry remained"
                )
            )
        ]
    )
    let audit = InMemoryAuditStore(
        lastScan: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let notifications = RecordingNotificationService()
    let model = AppModel(
        dependencies: .fixture(
            now: { now },
            coordinator: coordinator,
            cleanupExecutor: executor,
            audit: audit,
            notifications: notifications
        )
    )

    let summary = await model.performCatchUpScanIfDue()

    #expect(summary?.estimatedDeletedBytes == 250)
    #expect(audit.appendedRecords.count == 1)
    #expect(audit.appendedRecords[0].outcome == .failed)
    #expect(audit.appendedRecords[0].sizeBytes == 250)
    #expect(audit.appendedRecords[0].message?.contains("Partial cleanup") == true)
}

@Test @MainActor func emptyCatchUpPersistsTimestampWithoutExecutingCleanup() async {
    let now = Date(timeIntervalSince1970: 1_700_700_000)
    let oldScan = Date(timeIntervalSince1970: 1_700_000_000)
    let audit = InMemoryAuditStore(lastScan: oldScan)
    let executor = StubCleanupExecutor()
    let notifications = RecordingNotificationService()
    let model = AppModel(
        dependencies: .fixture(
            now: { now },
            cleanupExecutor: executor,
            audit: audit,
            notifications: notifications
        )
    )

    let summary = await model.performCatchUpScanIfDue()

    let plans = await executor.plans
    let delivered = await notifications.summaries
    #expect(summary == CatchUpCleanupSummary(
        estimatedDeletedBytes: 0,
        pendingReviewCount: 0
    ))
    #expect(audit.scanDates == [oldScan, now])
    #expect(plans.isEmpty)
    #expect(delivered == [
        RecordingNotificationService.Summary(
            estimatedDeletedBytes: 0,
            pendingReviewCount: 0
        )
    ])
}

@Test @MainActor func failedCatchUpScanDoesNotCleanOrSendSuccessSummary() async {
    let now = Date(timeIntervalSince1970: 1_700_700_000)
    let oldScan = Date(timeIntervalSince1970: 1_700_000_000)
    let coordinator = RecordingScanCoordinator()
    let executor = StubCleanupExecutor()
    let audit = InMemoryAuditStore(lastScan: oldScan)
    let notifications = RecordingNotificationService()
    let model = AppModel(
        dependencies: .fixture(
            now: { now },
            inventory: StubInventoryProvider(error: .inventoryUnavailable),
            coordinator: coordinator,
            cleanupExecutor: executor,
            audit: audit,
            notifications: notifications
        )
    )

    let summary = await model.performCatchUpScanIfDue()

    let plans = await executor.plans
    let delivered = await notifications.summaries
    #expect(summary == nil)
    #expect(coordinator.scanCount == 0)
    #expect(audit.scanDates == [oldScan])
    #expect(plans.isEmpty)
    #expect(delivered.isEmpty)
    #expect(model.state.errorMessage?.contains("inventoryUnavailable") == true)
}

@Test @MainActor func catchUpScannerFailureDoesNotSuppressSameTimeRetry() async {
    let now = Date(timeIntervalSince1970: 1_700_700_000)
    let oldScan = Date(timeIntervalSince1970: 1_700_000_000)
    let failure = ScannerFailure(
        scannerID: "application-cache",
        message: "cache root unreadable"
    )
    let failedReport = ScanReport(candidates: [], failures: [failure])
    let coordinator = RecordingScanCoordinator(reports: [failedReport, failedReport])
    let executor = StubCleanupExecutor()
    let audit = InMemoryAuditStore(lastScan: oldScan)
    let notifications = RecordingNotificationService()
    let model = AppModel(
        dependencies: .fixture(
            now: { now },
            coordinator: coordinator,
            cleanupExecutor: executor,
            audit: audit,
            notifications: notifications
        )
    )

    let firstSummary = await model.performCatchUpScanIfDue()
    let secondSummary = await model.performCatchUpScanIfDue()

    let plans = await executor.plans
    let delivered = await notifications.summaries
    #expect(firstSummary == nil)
    #expect(secondSummary == nil)
    #expect(coordinator.scanCount == 2)
    #expect(audit.scanDates == [oldScan])
    #expect(plans.isEmpty)
    #expect(delivered.isEmpty)
    #expect(model.state.failures == [failure])
    #expect(model.state.phase == .results)
}

@Test @MainActor func manualScanCannotInvalidateAnActiveCatchUpScan() async {
    let now = Date(timeIntervalSince1970: 1_700_700_000)
    let coordinator = SuspendingFirstScanCoordinator(
        firstReport: UITestFixtures.scanReport(candidateCount: 0, failureCount: 0),
        laterReport: UITestFixtures.scanReport(candidateCount: 0, failureCount: 0)
    )
    let notifications = RecordingNotificationService()
    let model = AppModel(
        dependencies: .fixture(
            lastScan: Date(timeIntervalSince1970: 1_700_000_000),
            now: { now },
            coordinator: coordinator,
            notifications: notifications
        )
    )

    let catchUp = Task { await model.performCatchUpScanIfDue() }
    await coordinator.waitUntilFirstScanStarts()
    await model.scan()
    let countWhileCatchUpWasSuspended = await coordinator.recordedScanCount()
    await coordinator.resumeFirstScan()
    let summary = await catchUp.value

    let delivered = await notifications.summaries
    #expect(countWhileCatchUpWasSuspended == 1)
    #expect(summary == CatchUpCleanupSummary(
        estimatedDeletedBytes: 0,
        pendingReviewCount: 0
    ))
    #expect(delivered.count == 1)
}

@Test @MainActor func catchUpDoesNotInvalidateAnActiveManualScan() async {
    let now = Date(timeIntervalSince1970: 1_700_700_000)
    let coordinator = SuspendingFirstScanCoordinator(
        firstReport: UITestFixtures.scanReport(candidateCount: 0, failureCount: 0),
        laterReport: UITestFixtures.scanReport(candidateCount: 0, failureCount: 0)
    )
    let notifications = RecordingNotificationService()
    let model = AppModel(
        dependencies: .fixture(
            lastScan: Date(timeIntervalSince1970: 1_700_000_000),
            now: { now },
            coordinator: coordinator,
            notifications: notifications
        )
    )

    let manualScan = Task { await model.scan() }
    await coordinator.waitUntilFirstScanStarts()
    let summary = await model.performCatchUpScanIfDue()
    let countWhileManualScanWasSuspended = await coordinator.recordedScanCount()
    await coordinator.resumeFirstScan()
    await manualScan.value

    let delivered = await notifications.summaries
    #expect(summary == nil)
    #expect(countWhileManualScanWasSuspended == 1)
    #expect(delivered.isEmpty)
    #expect(model.state.phase == .results)
}

@Test @MainActor func deniedNotificationsDoNotBlockOrRepeatCatchUpScanning() async {
    let now = Date(timeIntervalSince1970: 1_700_700_000)
    let coordinator = RecordingScanCoordinator()
    let audit = InMemoryAuditStore(
        lastScan: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let client = CatchUpNotificationClientStub(status: .denied)
    let notifications = UserNotificationService(client: client)
    let model = AppModel(
        dependencies: .fixture(
            now: { now },
            coordinator: coordinator,
            audit: audit,
            notifications: notifications
        )
    )

    await model.performCatchUpScanIfDue()
    await model.performCatchUpScanIfDue()

    let notificationSnapshot = await client.snapshot()
    #expect(coordinator.scanCount == 1)
    #expect(audit.scanDates.last == now)
    #expect(notificationSnapshot.requestCount == 0)
    #expect(notificationSnapshot.deliveryCount == 0)
}

private actor CatchUpNotificationClientStub: NotificationCenterClient {
    private let status: NotificationAuthorizationState
    private var requestCount = 0
    private var deliveryCount = 0

    init(status: NotificationAuthorizationState) {
        self.status = status
    }

    func authorizationState() async -> NotificationAuthorizationState {
        status
    }

    func requestAuthorization() async throws -> Bool {
        requestCount += 1
        return false
    }

    func deliver(_ notification: CleanupSummaryNotification) async throws {
        deliveryCount += 1
    }

    func snapshot() -> (requestCount: Int, deliveryCount: Int) {
        (requestCount, deliveryCount)
    }
}

@Test(arguments: CleanupInvocation.allCases)
@MainActor func cleanupSkipsGreenOwnerThatStartedRunning(
    invocation: CleanupInvocation
) async {
    let now = Date(timeIntervalSince1970: 1_700_700_000)
    let green = UITestFixtures.candidate(risk: .green, sizeBytes: 1_000)
    let initialInventory = cleanupInventory(runningBundleIDs: [])
    let runningInventory = cleanupInventory(
        runningBundleIDs: ["com.example.Editor"]
    )
    let inventory = SequencedInventoryProvider(
        results: [
            .success(initialInventory),
            .success(runningInventory),
            .success(runningInventory)
        ]
    )
    let coordinator = RecordingScanCoordinator(
        reports: [
            ScanReport(candidates: [green], failures: []),
            UITestFixtures.scanReport(candidateCount: 0, failureCount: 0)
        ]
    )
    let executor = StubCleanupExecutor { plan in
        CleanupResult(
            planID: plan.id,
            items: plan.items.map {
                CleanupItemResult(
                    candidateID: $0.candidateID,
                    status: .success(estimatedDeletedBytes: 900)
                )
            }
        )
    }
    let notifications = RecordingNotificationService()
    let model = AppModel(
        dependencies: .fixture(
            lastScan: Date(timeIntervalSince1970: 1_700_000_000),
            now: { now },
            inventory: inventory,
            coordinator: coordinator,
            cleanupExecutor: executor,
            notifications: notifications
        )
    )

    let summary: CatchUpCleanupSummary?
    switch invocation {
    case .manual:
        await model.scan()
        await model.cleanGreenCandidates()
        summary = nil
    case .catchUp:
        summary = await model.performCatchUpScanIfDue()
    }

    let plans = await executor.plans
    let delivered = await notifications.summaries
    #expect(plans.isEmpty)
    #expect(coordinator.scanCount == 2)
    #expect(model.state.candidates.isEmpty)
    #expect(model.state.phase == .results)
    #expect(delivered.isEmpty)
    if invocation == .catchUp {
        #expect(summary == nil)
    }
}

@Test(arguments: CleanupInvocation.allCases)
@MainActor func cleanupFailsClosedWhenFreshInventoryIsUnavailable(
    invocation: CleanupInvocation
) async {
    let now = Date(timeIntervalSince1970: 1_700_700_000)
    let green = UITestFixtures.candidate(risk: .green, sizeBytes: 1_000)
    let inventory = SequencedInventoryProvider(
        results: [
            .success(cleanupInventory(runningBundleIDs: [])),
            .failure(.inventoryUnavailable)
        ]
    )
    let coordinator = RecordingScanCoordinator(
        reports: [ScanReport(candidates: [green], failures: [])]
    )
    let executor = StubCleanupExecutor { plan in
        CleanupResult(
            planID: plan.id,
            items: plan.items.map {
                CleanupItemResult(
                    candidateID: $0.candidateID,
                    status: .success(estimatedDeletedBytes: 900)
                )
            }
        )
    }
    let notifications = RecordingNotificationService()
    let model = AppModel(
        dependencies: .fixture(
            lastScan: Date(timeIntervalSince1970: 1_700_000_000),
            now: { now },
            inventory: inventory,
            coordinator: coordinator,
            cleanupExecutor: executor,
            notifications: notifications
        )
    )

    let summary: CatchUpCleanupSummary?
    switch invocation {
    case .manual:
        await model.scan()
        await model.cleanGreenCandidates()
        summary = nil
    case .catchUp:
        summary = await model.performCatchUpScanIfDue()
    }

    let plans = await executor.plans
    let delivered = await notifications.summaries
    #expect(plans.isEmpty)
    #expect(coordinator.scanCount == 1)
    #expect(model.state.phase == .results)
    #expect(model.state.errorMessage?.contains("inventoryUnavailable") == true)
    #expect(delivered.isEmpty)
    if invocation == .catchUp {
        #expect(summary == nil)
    }
}

private func cleanupInventory(
    runningBundleIDs: Set<String>
) -> ApplicationInventory {
    ApplicationInventory(
        installedApplications: [
            InstalledApplication(
                name: "Editor",
                bundleID: "com.example.Editor",
                url: URL(fileURLWithPath: "/Applications/Editor.app")
            )
        ],
        runningBundleIDs: runningBundleIDs
    )
}
