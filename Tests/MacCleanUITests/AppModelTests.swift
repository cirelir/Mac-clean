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
