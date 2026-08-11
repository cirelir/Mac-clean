import Foundation
import Testing
@testable import CleanCore

@Test func executorRejectsTargetReplacedAfterScan() async throws {
    let fixture = try CleanupFixture.greenCache()
    let plan = CleanupPlanner().plan(candidates: [fixture.candidate], confirmedIDs: [])

    try fixture.replaceTargetAfterFingerprint()
    let replacementFingerprint = try SystemFileFingerprinter().fingerprint(at: fixture.target)
    let result = await fixture.executor.execute(plan)

    #expect(replacementFingerprint.fileID != fixture.candidate.fingerprint.fileID)
    #expect(result.items.first?.status == .skipped(.fingerprintChanged))
    #expect(FileManager.default.fileExists(atPath: fixture.target.path))
    #expect(FileManager.default.fileExists(atPath: fixture.target.appending(path: "replacement.bin").path))
}

@Test func executorDeletesOnlyContentsAndPreservesValidatedCacheRoot() async throws {
    let fixture = try CleanupFixture.greenCache(payload: Data([0x41, 0x42, 0x43]))
    let nested = fixture.target.appending(path: "nested")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try Data([0x44, 0x45]).write(to: nested.appending(path: "nested.bin"))
    try fixture.refreshCandidateFingerprint()
    let plan = CleanupPlanner().plan(candidates: [fixture.candidate], confirmedIDs: [])

    let result = await fixture.executor.execute(plan)

    #expect(result.items == [
        CleanupItemResult(candidateID: fixture.candidate.id, status: .success(reclaimedBytes: 5))
    ])
    var isDirectory: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: fixture.target.path, isDirectory: &isDirectory))
    #expect(isDirectory.boolValue)
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.target.path).isEmpty)
}

@Test func executorDoesNotFollowChildSymlinksWhileClearingContents() async throws {
    let fixture = try CleanupFixture.greenCache(payload: Data([0x41]))
    let sentinel = fixture.root.appending(path: "sentinel.bin")
    try Data([0x53, 0x41, 0x46, 0x45]).write(to: sentinel)
    try FileManager.default.createSymbolicLink(
        at: fixture.target.appending(path: "sentinel-link"),
        withDestinationURL: sentinel
    )
    try fixture.refreshCandidateFingerprint()
    let plan = CleanupPlanner().plan(candidates: [fixture.candidate], confirmedIDs: [])

    let result = await fixture.executor.execute(plan)

    #expect(result.items.first?.status == .success(reclaimedBytes: 1))
    #expect(FileManager.default.fileExists(atPath: sentinel.path))
    #expect(try Data(contentsOf: sentinel) == Data([0x53, 0x41, 0x46, 0x45]))
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.target.path).isEmpty)
}

@Test func executorRejectsAllowedRootItselfWithoutRemovingItsContents() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let payload = root.appending(path: "must-remain.bin")
    try Data([0x41]).write(to: payload)
    let fingerprinter = SystemFileFingerprinter()
    let candidate = CoreTestFixtures.candidate(
        risk: .green,
        path: root.path,
        fingerprint: try fingerprinter.fingerprint(at: root)
    )
    let executor = CleanupExecutor(
        validator: SafePathValidator(allowedRoots: [root], forbiddenExactPaths: []),
        fingerprinter: fingerprinter,
        fileManager: .default
    )

    let result = await executor.execute(
        CleanupPlanner().plan(candidates: [candidate], confirmedIDs: [])
    )

    #expect(result.items.first?.status == .skipped(.pathRejected))
    #expect(FileManager.default.fileExists(atPath: payload.path))
}

@Test func executorFailsClosedForUnsupportedActions() async throws {
    let fixture = try CleanupFixture.greenCache()
    let secondTarget = fixture.root.appending(path: "package-cache")
    try FileManager.default.createDirectory(at: secondTarget, withIntermediateDirectories: true)
    try Data([0x50]).write(to: secondTarget.appending(path: "package.bin"))
    let fingerprinter = SystemFileFingerprinter()
    let moveToTrash = CoreTestFixtures.candidate(
        risk: .yellow,
        path: fixture.target.path,
        fingerprint: try fingerprinter.fingerprint(at: fixture.target)
    )
    let packageManager = CoreTestFixtures.candidate(
        risk: .green,
        path: secondTarget.path,
        fingerprint: try fingerprinter.fingerprint(at: secondTarget),
        action: .packageManagerCommand
    )
    let plan = CleanupPlanner().plan(
        candidates: [moveToTrash, packageManager],
        confirmedIDs: [moveToTrash.id]
    )

    let result = await fixture.executor.execute(plan)

    #expect(result.items.map(\.status) == [
        .skipped(.unsupportedAction),
        .skipped(.unsupportedAction)
    ])
    #expect(FileManager.default.fileExists(atPath: fixture.target.appending(path: "cache.bin").path))
    #expect(FileManager.default.fileExists(atPath: secondTarget.appending(path: "package.bin").path))
}

@Test func executorIsolatesItemFailureAndContinuesWithTheNextPlanItem() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let invalidTarget = root.appending(path: "regular-file")
    let validTarget = root.appending(path: "valid-cache")
    let untouchedTarget = root.appending(path: "not-in-plan")
    try Data([0x46]).write(to: invalidTarget)
    try FileManager.default.createDirectory(at: validTarget, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: untouchedTarget, withIntermediateDirectories: true)
    try Data([0x47, 0x48]).write(to: validTarget.appending(path: "cache.bin"))
    try Data([0x49]).write(to: untouchedTarget.appending(path: "sentinel.bin"))
    let fingerprinter = SystemFileFingerprinter()
    let failedCandidate = CoreTestFixtures.candidate(
        risk: .green,
        path: invalidTarget.path,
        fingerprint: try fingerprinter.fingerprint(at: invalidTarget)
    )
    let successfulCandidate = CoreTestFixtures.candidate(
        risk: .green,
        path: validTarget.path,
        fingerprint: try fingerprinter.fingerprint(at: validTarget)
    )
    let executor = CleanupExecutor(
        validator: SafePathValidator(allowedRoots: [root], forbiddenExactPaths: []),
        fingerprinter: fingerprinter,
        fileManager: .default
    )
    let plan = CleanupPlanner().plan(
        candidates: [failedCandidate, successfulCandidate],
        confirmedIDs: []
    )

    let result = await executor.execute(plan)

    #expect(result.items.count == 2)
    if case .failed = result.items[0].status {
        // Expected: a regular file cannot be enumerated as a cache root.
    } else {
        Issue.record("Expected the first item to fail without stopping execution")
    }
    #expect(result.items[1] == CleanupItemResult(
        candidateID: successfulCandidate.id,
        status: .success(reclaimedBytes: 2)
    ))
    #expect(FileManager.default.fileExists(atPath: invalidTarget.path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: validTarget.path).isEmpty)
    #expect(FileManager.default.fileExists(atPath: untouchedTarget.appending(path: "sentinel.bin").path))
}

private final class CleanupFixture {
    let root: URL
    let target: URL
    private(set) var candidate: CleanupCandidate
    let executor: CleanupExecutor

    private init(payload: Data) throws {
        root = try makeTemporaryDirectory()
        target = root.appending(path: "com.example.Editor")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try payload.write(to: target.appending(path: "cache.bin"))
        let fingerprinter = SystemFileFingerprinter()
        let fingerprint = try fingerprinter.fingerprint(at: target)
        candidate = CoreTestFixtures.candidate(
            risk: .green,
            path: target.path,
            fingerprint: fingerprint
        )
        executor = CleanupExecutor(
            validator: SafePathValidator(allowedRoots: [root], forbiddenExactPaths: []),
            fingerprinter: fingerprinter,
            fileManager: .default
        )
    }

    static func greenCache(payload: Data = Data([0x41])) throws -> CleanupFixture {
        try CleanupFixture(payload: payload)
    }

    func replaceTargetAfterFingerprint() throws {
        try FileManager.default.moveItem(
            at: target,
            to: root.appending(path: "original-target")
        )
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data([0x42]).write(to: target.appending(path: "replacement.bin"))
    }

    func refreshCandidateFingerprint() throws {
        let fingerprinter = SystemFileFingerprinter()
        let fingerprint = try fingerprinter.fingerprint(at: target)
        candidate = CoreTestFixtures.candidate(
            risk: .green,
            path: target.path,
            fingerprint: fingerprint,
            id: candidate.id
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}

private func makeTemporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
