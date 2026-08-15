import Foundation
import Testing
@testable import CleanCore

@Test func plannerIncludesGreenAndConfirmedYellowButNeverRed() throws {
    let root = try makePlannerTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let candidates = [
        CoreTestFixtures.candidate(risk: .green, path: root.appending(path: "green").path),
        CoreTestFixtures.candidate(risk: .yellow, path: root.appending(path: "yellow").path),
        CoreTestFixtures.candidate(
            risk: .red,
            path: root.appending(path: "red").path,
            action: .deleteContentsPreservingRoot
        )
    ]

    let plan = CleanupPlanner().plan(
        candidates: candidates,
        confirmedIDs: [candidates[1].id]
    )

    #expect(plan.items.map(\.candidateID) == [candidates[0].id, candidates[1].id])
}

@Test func plannerExcludesUnconfirmedYellowAndEveryReportOnlyAction() throws {
    let root = try makePlannerTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let unconfirmedYellow = CoreTestFixtures.candidate(
        risk: .yellow,
        path: root.appending(path: "unconfirmed-yellow").path
    )
    let greenReportOnly = CoreTestFixtures.candidate(
        risk: .green,
        path: root.appending(path: "green-report-only").path,
        action: .reportOnly
    )
    let confirmedYellowReportOnly = CoreTestFixtures.candidate(
        risk: .yellow,
        path: root.appending(path: "yellow-report-only").path,
        action: .reportOnly
    )

    let plan = CleanupPlanner().plan(
        candidates: [unconfirmedYellow, greenReportOnly, confirmedYellowReportOnly],
        confirmedIDs: [confirmedYellowReportOnly.id]
    )

    #expect(plan.items.isEmpty)
}

@Test func plannerSnapshotsCandidateIdentityPathFingerprintActionAndCreationDate() throws {
    let id = UUID()
    let root = try makePlannerTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appending(path: "snapshot").path
    let fingerprint = CoreTestFixtures.fingerprint(size: 4_096)
    let candidate = CoreTestFixtures.candidate(
        risk: .green,
        path: path,
        fingerprint: fingerprint,
        id: id
    )
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    let plan = CleanupPlanner().plan(candidates: [candidate], confirmedIDs: [], now: now)

    #expect(plan.createdAt == now)
    #expect(plan.items == [
        CleanupPlanItem(
            candidateID: id,
            canonicalURL: URL(fileURLWithPath: path),
            expectedFingerprint: fingerprint,
            action: .deleteContentsPreservingRoot,
            estimatedBytes: 4_096
        )
    ])
}

private func makePlannerTemporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
