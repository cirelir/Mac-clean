import CleanCore
import Foundation
import Testing
@testable import MacCleanUI

@Test @MainActor func scanPublishesCandidatesAndPartialFailures() async {
    let report = UITestFixtures.scanReport(candidateCount: 2, failureCount: 1)
    let audit = InMemoryAuditStore()
    let model = AppModel(dependencies: .fixture(report: report, audit: audit))

    await model.scan()

    #expect(model.state.candidates.count == 2)
    #expect(model.state.failures.count == 1)
    #expect(model.state.phase == .results)
    #expect(model.state.lastScan == UITestFixtures.timestamp)
    #expect(audit.scanDates == [UITestFixtures.timestamp])
}

@Test @MainActor func completedEmptyScanRecordsItsTimestamp() async {
    let audit = InMemoryAuditStore()
    let model = AppModel(dependencies: .fixture(audit: audit))

    await model.scan()

    #expect(model.state.candidates.isEmpty)
    #expect(model.state.phase == .results)
    #expect(audit.scanDates == [UITestFixtures.timestamp])
}

@Test @MainActor func failedInventoryReturnsToIdleWithAnError() async {
    let model = AppModel(
        dependencies: .fixture(
            inventory: StubInventoryProvider(error: .inventoryUnavailable)
        )
    )

    await model.scan()

    #expect(model.state.phase == .idle)
    #expect(model.state.errorMessage?.contains("inventoryUnavailable") == true)
}

@Test @MainActor func failedRescanInvalidatesThePreviousCleanupSnapshot() async {
    let candidate = UITestFixtures.candidate(risk: .green)
    let inventory = SequencedInventoryProvider(
        results: [
            .success(ApplicationInventory(installedApplications: [], runningBundleIDs: [])),
            .failure(.inventoryUnavailable)
        ]
    )
    let executor = StubCleanupExecutor()
    let model = AppModel(
        dependencies: .fixture(
            report: ScanReport(candidates: [candidate], failures: []),
            inventory: inventory,
            cleanupExecutor: executor
        )
    )
    await model.scan()

    await model.scan()
    await model.cleanGreenCandidates()

    let plans = await executor.plans
    #expect(model.state.phase == .idle)
    #expect(model.state.candidates.isEmpty)
    #expect(model.estimatedReclaimableBytes == 0)
    #expect(plans.isEmpty)
}

@Test @MainActor func laterScanWinsWhenAnEarlierScanReturnsLast() async {
    let stale = UITestFixtures.candidate(risk: .green, path: "/tmp/stale")
    let latest = UITestFixtures.candidate(risk: .green, path: "/tmp/latest")
    let coordinator = SuspendingFirstScanCoordinator(
        firstReport: ScanReport(candidates: [stale], failures: []),
        laterReport: ScanReport(candidates: [latest], failures: [])
    )
    let audit = InMemoryAuditStore()
    let model = AppModel(
        dependencies: .fixture(coordinator: coordinator, audit: audit)
    )

    let earlierScan = Task { await model.scan() }
    await coordinator.waitUntilFirstScanStarts()
    await model.scan()
    await coordinator.resumeFirstScan()
    await earlierScan.value

    #expect(model.state.candidates.map(\.id) == [latest.id])
    #expect(model.state.phase == .results)
    #expect(audit.scanDates == [UITestFixtures.timestamp])
}

@Test @MainActor func cleanupIsIgnoredWhileAScanIsInProgress() async {
    let scanned = UITestFixtures.candidate(risk: .green)
    let coordinator = SuspendingFirstScanCoordinator(
        firstReport: ScanReport(candidates: [scanned], failures: []),
        laterReport: UITestFixtures.scanReport(candidateCount: 0, failureCount: 0)
    )
    let executor = StubCleanupExecutor()
    let model = AppModel(
        dependencies: .fixture(coordinator: coordinator, cleanupExecutor: executor)
    )

    let scan = Task { await model.scan() }
    await coordinator.waitUntilFirstScanStarts()
    await model.cleanGreenCandidates()
    let plansBeforeCompletion = await executor.plans
    await coordinator.resumeFirstScan()
    await scan.value

    #expect(plansBeforeCompletion.isEmpty)
    #expect(model.state.candidates.map(\.id) == [scanned.id])
    #expect(model.state.phase == .results)
}

@Test @MainActor func publicScanIsIgnoredWhileCleanupIsInProgress() async {
    let candidate = UITestFixtures.candidate(risk: .green)
    let firstReport = ScanReport(candidates: [candidate], failures: [])
    let emptyReport = UITestFixtures.scanReport(candidateCount: 0, failureCount: 0)
    let coordinator = RecordingScanCoordinator(reports: [firstReport, emptyReport])
    let executor = SuspendingCleanupExecutor()
    let model = AppModel(
        dependencies: .fixture(coordinator: coordinator, cleanupExecutor: executor)
    )
    await model.scan()

    let cleanup = Task { await model.cleanGreenCandidates() }
    await executor.waitUntilExecutionStarts()
    await model.scan()
    let scanCountWhileCleaning = coordinator.scanCount
    await executor.resumeExecution()
    await cleanup.value

    #expect(scanCountWhileCleaning == 1)
    #expect(coordinator.scanCount == 2)
    #expect(model.state.candidates.isEmpty)
    #expect(model.state.phase == .results)
}

@Test @MainActor func revealDelegatesCanonicalCandidateURL() throws {
    let sourceURL = FileManager.default.temporaryDirectory
        .appending(path: "missing-source-\(UUID().uuidString)")
    let canonicalURL = FileManager.default.temporaryDirectory
        .appending(path: "finder-target-\(UUID().uuidString)")
    try Data().write(to: canonicalURL)
    defer { try? FileManager.default.removeItem(at: canonicalURL) }
    let recorder = RecordingFinderRevealer()
    let model = AppModel(dependencies: .fixture(finder: recorder))
    let candidate = UITestFixtures.candidate(
        sourceURL: sourceURL,
        canonicalURL: canonicalURL
    )

    model.reveal(candidate)

    #expect(recorder.urls == [candidate.canonicalURL])
}

@Test @MainActor func revealRecomputesCanonicalAvailabilityForEveryRequest() throws {
    let canonicalURL = FileManager.default.temporaryDirectory
        .appending(path: "dynamic-finder-target-\(UUID().uuidString)")
    let recorder = RecordingFinderRevealer()
    let model = AppModel(dependencies: .fixture(finder: recorder))
    let candidate = UITestFixtures.candidate(
        risk: .green,
        path: canonicalURL.path
    )

    model.reveal(candidate)
    #expect(recorder.urls.isEmpty)

    try Data().write(to: canonicalURL)
    defer { try? FileManager.default.removeItem(at: canonicalURL) }
    model.reveal(candidate)

    #expect(recorder.urls == [candidate.canonicalURL])
}

@Test @MainActor func cleanPlansOnlyGreenCandidatesAndRescans() async {
    let green = UITestFixtures.candidate(risk: .green)
    let yellow = UITestFixtures.candidate(risk: .yellow)
    let red = UITestFixtures.candidate(risk: .red)
    let firstReport = ScanReport(candidates: [green, yellow, red], failures: [])
    let secondReport = UITestFixtures.scanReport(candidateCount: 0, failureCount: 0)
    let coordinator = RecordingScanCoordinator(reports: [firstReport, secondReport])
    let executor = StubCleanupExecutor(
        resultItems: [
            CleanupItemResult(
                candidateID: green.id,
                status: .success(estimatedDeletedBytes: green.sizeBytes)
            )
        ]
    )
    let model = AppModel(
        dependencies: .fixture(coordinator: coordinator, cleanupExecutor: executor)
    )
    await model.scan()

    await model.cleanGreenCandidates()

    let plans = await executor.plans
    #expect(plans.count == 1)
    #expect(plans.first?.items.map(\.candidateID) == [green.id])
    #expect(coordinator.scanCount == 2)
    #expect(model.state.phase == .results)
    #expect(model.state.candidates.isEmpty)
}

@Test @MainActor func cleanupAuditsEveryResultWithoutOverstatingPartialDeletion() async {
    let success = UITestFixtures.candidate(risk: .green, sizeBytes: 1_000)
    let partial = UITestFixtures.candidate(risk: .green, sizeBytes: 2_000)
    let skipped = UITestFixtures.candidate(risk: .green, sizeBytes: 3_000)
    let failed = UITestFixtures.candidate(risk: .green, sizeBytes: 4_000)
    let report = ScanReport(candidates: [success, partial, skipped, failed], failures: [])
    let coordinator = RecordingScanCoordinator(reports: [report, report])
    let executor = StubCleanupExecutor(
        resultItems: [
            CleanupItemResult(
                candidateID: success.id,
                status: .success(estimatedDeletedBytes: 900)
            ),
            CleanupItemResult(
                candidateID: partial.id,
                status: .partial(estimatedDeletedBytes: 700, message: "one entry remained")
            ),
            CleanupItemResult(candidateID: skipped.id, status: .skipped(.fingerprintChanged)),
            CleanupItemResult(candidateID: failed.id, status: .failed(message: "permission denied"))
        ]
    )
    let audit = InMemoryAuditStore()
    let model = AppModel(
        dependencies: .fixture(
            coordinator: coordinator,
            cleanupExecutor: executor,
            audit: audit
        )
    )
    await model.scan()

    await model.cleanGreenCandidates()

    let records = Dictionary(uniqueKeysWithValues: audit.appendedRecords.map { ($0.candidateID, $0) })
    #expect(records.count == 4)
    #expect(records[success.id]?.outcome == .cleaned)
    #expect(records[success.id]?.sizeBytes == 900)
    #expect(records[partial.id]?.outcome == .failed)
    #expect(records[partial.id]?.sizeBytes == 700)
    #expect(records[partial.id]?.message?.localizedCaseInsensitiveContains("partial") == true)
    #expect(records[skipped.id]?.outcome == .skipped)
    #expect(records[skipped.id]?.sizeBytes == 0)
    #expect(records[failed.id]?.outcome == .failed)
    #expect(records[failed.id]?.sizeBytes == 0)
}

@Test @MainActor func cleanupPreservesAuditAndInternalRescanErrors() async {
    let green = UITestFixtures.candidate(risk: .green)
    let inventory = SequencedInventoryProvider(
        results: [
            .success(ApplicationInventory(installedApplications: [], runningBundleIDs: [])),
            .success(ApplicationInventory(installedApplications: [], runningBundleIDs: [])),
            .failure(.inventoryUnavailable)
        ]
    )
    let coordinator = RecordingScanCoordinator(
        reports: [ScanReport(candidates: [green], failures: [])]
    )
    let executor = StubCleanupExecutor(
        resultItems: [
            CleanupItemResult(
                candidateID: green.id,
                status: .success(estimatedDeletedBytes: 900)
            )
        ]
    )
    let audit = FailingAppendAuditStore()
    let model = AppModel(
        dependencies: .fixture(
            inventory: inventory,
            coordinator: coordinator,
            cleanupExecutor: executor,
            audit: audit
        )
    )
    await model.scan()

    await model.cleanGreenCandidates()

    #expect(model.state.errorMessage?.contains("auditUnavailable") == true)
    #expect(model.state.errorMessage?.contains("inventoryUnavailable") == true)
}

enum MalformedCleanupResultKind: CaseIterable, Sendable {
    case mismatchedPlanID
    case missingPlannedResult
    case duplicatePlannedResult
    case extraUnknownResult
    case extraUnplannedYellowResult
}

@Test(arguments: MalformedCleanupResultKind.allCases)
@MainActor func malformedCleanupResultFailsEveryPlannedAuditAndRescans(
    kind: MalformedCleanupResultKind
) async {
    let first = UITestFixtures.candidate(risk: .green)
    let second = UITestFixtures.candidate(risk: .green)
    let yellow = UITestFixtures.candidate(risk: .yellow)
    let unknownID = UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!
    let report = ScanReport(candidates: [first, second, yellow], failures: [])
    let emptyReport = UITestFixtures.scanReport(candidateCount: 0, failureCount: 0)
    let coordinator = RecordingScanCoordinator(reports: [report, emptyReport])
    let executor = StubCleanupExecutor { plan in
        malformedCleanupResult(
            kind: kind,
            plan: plan,
            yellowID: yellow.id,
            unknownID: unknownID
        )
    }
    let audit = InMemoryAuditStore()
    let model = AppModel(
        dependencies: .fixture(
            coordinator: coordinator,
            cleanupExecutor: executor,
            audit: audit
        )
    )
    await model.scan()

    await model.cleanGreenCandidates()

    #expect(audit.appendedRecords.count == 2)
    #expect(Set(audit.appendedRecords.map(\.candidateID)) == Set([first.id, second.id]))
    #expect(audit.appendedRecords.allSatisfy { $0.outcome == .failed })
    #expect(audit.appendedRecords.allSatisfy { $0.sizeBytes == 0 })
    #expect(audit.appendedRecords.allSatisfy {
        $0.message?.contains("Cleanup executor protocol mismatch") == true
    })
    #expect(model.state.errorMessage?.contains("Cleanup executor protocol mismatch") == true)
    #expect(coordinator.scanCount == 2)
    #expect(model.state.candidates.isEmpty)
}

private func malformedCleanupResult(
    kind: MalformedCleanupResultKind,
    plan: CleanupPlan,
    yellowID: UUID,
    unknownID: UUID
) -> CleanupResult {
    let planned = plan.items.map {
        CleanupItemResult(
            candidateID: $0.candidateID,
            status: .success(estimatedDeletedBytes: 500)
        )
    }

    switch kind {
    case .mismatchedPlanID:
        let firstWrongID = UITestFixtures.auditID
        let secondWrongID = UITestFixtures.scanID
        return CleanupResult(
            planID: plan.id == firstWrongID ? secondWrongID : firstWrongID,
            items: planned
        )
    case .missingPlannedResult:
        return CleanupResult(planID: plan.id, items: Array(planned.dropLast()))
    case .duplicatePlannedResult:
        return CleanupResult(planID: plan.id, items: [planned[0], planned[0], planned[1]])
    case .extraUnknownResult:
        return CleanupResult(
            planID: plan.id,
            items: planned + [
                CleanupItemResult(
                    candidateID: unknownID,
                    status: .success(estimatedDeletedBytes: 500)
                )
            ]
        )
    case .extraUnplannedYellowResult:
        return CleanupResult(
            planID: plan.id,
            items: planned + [
                CleanupItemResult(
                    candidateID: yellowID,
                    status: .success(estimatedDeletedBytes: 500)
                )
            ]
        )
    }
}

@Test @MainActor func summariesCountRiskLevelsAndEstimateOnlyGreenBytes() async {
    let report = ScanReport(
        candidates: [
            UITestFixtures.candidate(risk: .green, sizeBytes: 300),
            UITestFixtures.candidate(risk: .green, sizeBytes: 200),
            UITestFixtures.candidate(risk: .yellow, sizeBytes: 900)
        ],
        failures: []
    )
    let model = AppModel(dependencies: .fixture(report: report))
    await model.scan()

    #expect(model.estimatedReclaimableBytes == 500)
    #expect(model.reclaimableBytes == 500)
    #expect(model.greenSummary == "2 项")
    #expect(model.yellowSummary == "1 项")
}
