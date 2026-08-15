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
        CleanupItemResult(
            candidateID: fixture.candidate.id,
            status: .success(estimatedDeletedBytes: 5)
        )
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

    #expect(result.items.first?.status == .success(estimatedDeletedBytes: 1))
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

@Test func executorFailsClosedForUnsupportedPackageManagerActions() async throws {
    let fixture = try CleanupFixture.greenCache()
    let packageManager = CoreTestFixtures.candidate(
        risk: .green,
        path: fixture.target.path,
        fingerprint: fixture.candidate.fingerprint,
        action: .packageManagerCommand
    )
    let plan = CleanupPlanner().plan(candidates: [packageManager], confirmedIDs: [])

    let result = await fixture.executor.execute(plan)

    #expect(result.items.map(\.status) == [.skipped(.unsupportedAction)])
    #expect(FileManager.default.fileExists(atPath: fixture.target.appending(path: "cache.bin").path))
}

@Test func executorMovesValidatedDirectoryIntoTrash() async throws {
    let root = try makeTemporaryDirectory()
    let trash = try makeTemporaryDirectory()
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: trash)
    }
    let target = root.appending(path: "Google")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try Data([0x47, 0x4F]).write(to: target.appending(path: "residual.bin"))
    let fingerprinter = SystemFileFingerprinter()
    let candidate = CoreTestFixtures.candidate(
        risk: .yellow,
        path: target.path,
        fingerprint: try fingerprinter.fingerprint(at: target)
    )
    let executor = CleanupExecutor(
        validator: SafePathValidator(allowedRoots: [root], forbiddenExactPaths: []),
        fingerprinter: fingerprinter,
        fileManager: .default,
        hooks: CleanupExecutionHooks(),
        trashDirectory: trash
    )

    let result = await executor.execute(
        CleanupPlanner().plan(candidates: [candidate], confirmedIDs: [candidate.id])
    )

    #expect(result.items.first?.status == .success(estimatedDeletedBytes: candidate.sizeBytes))
    #expect(!FileManager.default.fileExists(atPath: target.path))
    #expect(FileManager.default.fileExists(atPath: trash.appending(path: "Google").path))
    #expect(try Data(contentsOf: trash.appending(path: "Google").appending(path: "residual.bin")) == Data([0x47, 0x4F]))
}

@Test func executorCleansDirectoryWhoseContentsChangedSinceScan() async throws {
    let fixture = try CleanupFixture.greenCache(payload: Data([0x41]))
    // An app writes new files between scan and cleanup: the directory object
    // is unchanged (same device/inode), so cleanup must still proceed.
    try Data([0x42]).write(to: fixture.target.appending(path: "added-later.bin"))
    let plan = CleanupPlanner().plan(candidates: [fixture.candidate], confirmedIDs: [])

    let result = await fixture.executor.execute(plan)

    #expect(result.items.first?.status == .success(estimatedDeletedBytes: 2))
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.target.path).isEmpty)
}

@Test func executorMovesToTrashEvenWhenContentsChangedSinceScan() async throws {
    let root = try makeTemporaryDirectory()
    let trash = try makeTemporaryDirectory()
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: trash)
    }
    let target = root.appending(path: "Residual")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try Data([0x41]).write(to: target.appending(path: "residual.bin"))
    let fingerprinter = SystemFileFingerprinter()
    let candidate = CoreTestFixtures.candidate(
        risk: .yellow,
        path: target.path,
        fingerprint: try fingerprinter.fingerprint(at: target)
    )
    try Data([0x42]).write(to: target.appending(path: "added-later.bin"))
    let executor = CleanupExecutor(
        validator: SafePathValidator(allowedRoots: [root], forbiddenExactPaths: []),
        fingerprinter: fingerprinter,
        fileManager: .default,
        hooks: CleanupExecutionHooks(),
        trashDirectory: trash
    )

    let result = await executor.execute(
        CleanupPlanner().plan(candidates: [candidate], confirmedIDs: [candidate.id])
    )

    #expect(result.items.first?.status == .success(estimatedDeletedBytes: candidate.sizeBytes))
    #expect(!FileManager.default.fileExists(atPath: target.path))
    #expect(FileManager.default.fileExists(atPath: trash.appending(path: "Residual").path))
}

@Test func executorMovesToTrashIsSkippedWhenFingerprintChanged() async throws {
    let root = try makeTemporaryDirectory()
    let trash = try makeTemporaryDirectory()
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: trash)
    }
    let target = root.appending(path: "Residual")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try Data([0x41]).write(to: target.appending(path: "residual.bin"))
    let fingerprinter = SystemFileFingerprinter()
    let candidate = CoreTestFixtures.candidate(
        risk: .yellow,
        path: target.path,
        fingerprint: try fingerprinter.fingerprint(at: target)
    )
    try FileManager.default.moveItem(at: target, to: root.appending(path: "moved-original"))
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try Data([0x42]).write(to: target.appending(path: "replacement.bin"))
    let executor = CleanupExecutor(
        validator: SafePathValidator(allowedRoots: [root], forbiddenExactPaths: []),
        fingerprinter: fingerprinter,
        fileManager: .default,
        hooks: CleanupExecutionHooks(),
        trashDirectory: trash
    )

    let result = await executor.execute(
        CleanupPlanner().plan(candidates: [candidate], confirmedIDs: [candidate.id])
    )

    #expect(result.items.first?.status == .skipped(.fingerprintChanged))
    #expect(FileManager.default.fileExists(atPath: target.appending(path: "replacement.bin").path))
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
        status: .success(estimatedDeletedBytes: 2)
    ))
    #expect(FileManager.default.fileExists(atPath: invalidTarget.path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: validTarget.path).isEmpty)
    #expect(FileManager.default.fileExists(atPath: untouchedTarget.appending(path: "sentinel.bin").path))
}

@Test func executorStaysBoundToOpenedRootAfterPostFingerprintPathSwap() async throws {
    let base = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let allowedRoot = base.appending(path: "allowed")
    let target = allowedRoot.appending(path: "com.example.Editor")
    let openedObject = allowedRoot.appending(path: "opened-original")
    let outside = base.appending(path: "outside")
    let outsideSentinel = outside.appending(path: "must-remain.bin")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try Data([0x41, 0x42, 0x43]).write(to: target.appending(path: "cache.bin"))
    try Data([0x53, 0x41, 0x46, 0x45]).write(to: outsideSentinel)
    let fingerprinter = SystemFileFingerprinter()
    let candidate = CoreTestFixtures.candidate(
        risk: .green,
        path: target.path,
        fingerprint: try fingerprinter.fingerprint(at: target)
    )
    let hooks = CleanupExecutionHooks(
        afterRootOpenedAndFingerprinted: { _ in
            try FileManager.default.moveItem(at: target, to: openedObject)
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
        }
    )
    let executor = CleanupExecutor(
        validator: SafePathValidator(allowedRoots: [allowedRoot], forbiddenExactPaths: []),
        fingerprinter: fingerprinter,
        fileManager: .default,
        hooks: hooks
    )

    let result = await executor.execute(
        CleanupPlanner().plan(candidates: [candidate], confirmedIDs: [])
    )

    #expect(result.items.first?.status == .success(estimatedDeletedBytes: 3))
    #expect(try target.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
    #expect(try Data(contentsOf: outsideSentinel) == Data([0x53, 0x41, 0x46, 0x45]))
    #expect(try FileManager.default.contentsOfDirectory(atPath: openedObject.path).isEmpty)
}

@Test func executorRejectsFinalSymlinkAliasPlanBeforeOpeningTarget() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let actual = root.appending(path: "actual-cache")
    let alias = root.appending(path: "cache-alias")
    let payload = actual.appending(path: "must-remain.bin")
    try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
    try Data([0x41]).write(to: payload)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
    let fingerprinter = SystemFileFingerprinter()
    let item = CleanupPlanItem(
        candidateID: UUID(),
        canonicalURL: alias,
        expectedFingerprint: try fingerprinter.fingerprint(at: actual),
        action: .deleteContentsPreservingRoot
    )
    let plan = CleanupPlan(id: UUID(), createdAt: .now, items: [item])
    let executor = CleanupExecutor(
        validator: SafePathValidator(allowedRoots: [root], forbiddenExactPaths: []),
        fingerprinter: fingerprinter,
        fileManager: .default
    )

    let result = await executor.execute(plan)

    #expect(result.items.first?.status == .skipped(.pathRejected))
    #expect(try Data(contentsOf: payload) == Data([0x41]))
    #expect(try alias.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
}

@Test func executorRejectsOutsideTargetAfterPinnedAllowedRootIsReplacedBySymlink() async throws {
    let base = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let outside = base.appending(path: "outside")
    let configuredRoot = base.appending(path: "allowed")
    let movedRoot = base.appending(path: "allowed-original")
    let victim = outside.appending(path: "com.example.Editor")
    let sentinel = victim.appending(path: "must-remain.bin")
    try FileManager.default.createDirectory(at: configuredRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
    try Data([0x53, 0x41, 0x46, 0x45]).write(to: sentinel)
    let fingerprinter = SystemFileFingerprinter()
    let validator = SafePathValidator(allowedRoots: [configuredRoot], forbiddenExactPaths: [])
    try FileManager.default.moveItem(at: configuredRoot, to: movedRoot)
    try FileManager.default.createSymbolicLink(at: configuredRoot, withDestinationURL: outside)
    let candidate = CoreTestFixtures.candidate(
        risk: .green,
        path: victim.path,
        fingerprint: try fingerprinter.fingerprint(at: victim)
    )
    let executor = CleanupExecutor(
        validator: validator,
        fingerprinter: fingerprinter,
        fileManager: .default
    )

    let result = await executor.execute(
        CleanupPlanner().plan(candidates: [candidate], confirmedIDs: [])
    )

    #expect(result.items.first?.status == .skipped(.pathRejected))
    #expect(try Data(contentsOf: sentinel) == Data([0x53, 0x41, 0x46, 0x45]))
}

@Test func executorReportsPartialProgressWhenLaterChildDeletionFails() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appending(path: "com.example.Editor")
    let first = target.appending(path: "a-first.bin")
    let failing = target.appending(path: "b-fail.bin")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try Data([0x41]).write(to: first)
    try Data([0x42, 0x43]).write(to: failing)
    let fingerprinter = SystemFileFingerprinter()
    let candidate = CoreTestFixtures.candidate(
        risk: .green,
        path: target.path,
        fingerprint: try fingerprinter.fingerprint(at: target)
    )
    let hooks = CleanupExecutionHooks(
        beforeRemovingEntry: { relativePath in
            if relativePath == "b-fail.bin" {
                throw InjectedCleanupFailure()
            }
        }
    )
    let executor = CleanupExecutor(
        validator: SafePathValidator(allowedRoots: [root], forbiddenExactPaths: []),
        fingerprinter: fingerprinter,
        fileManager: .default,
        hooks: hooks
    )

    let result = await executor.execute(
        CleanupPlanner().plan(candidates: [candidate], confirmedIDs: [])
    )

    if case .partial(let estimatedDeletedBytes, _) = result.items.first?.status {
        #expect(estimatedDeletedBytes == 1)
    } else {
        Issue.record("Expected partial status after one successful child deletion")
    }
    #expect(!FileManager.default.fileExists(atPath: first.path))
    #expect(FileManager.default.fileExists(atPath: failing.path))
    #expect(FileManager.default.fileExists(atPath: target.path))
}

@Test func concurrentExecuteCallsNeverOverlapTheSamePlan() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appending(path: "com.example.Editor")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try Data([0x41]).write(to: target.appending(path: "cache.bin"))
    let fingerprinter = SystemFileFingerprinter()
    let candidate = CoreTestFixtures.candidate(
        risk: .green,
        path: target.path,
        fingerprint: try fingerprinter.fingerprint(at: target)
    )
    let plan = CleanupPlanner().plan(candidates: [candidate], confirmedIDs: [])
    let overlapProbe = PlanExecutionOverlapProbe()
    let hooks = CleanupExecutionHooks(
        beforePlanExecution: { await overlapProbe.enter() },
        executionDidQueue: { await overlapProbe.releaseBlockedExecution() }
    )
    let executor = CleanupExecutor(
        validator: SafePathValidator(allowedRoots: [root], forbiddenExactPaths: []),
        fingerprinter: fingerprinter,
        fileManager: .default,
        hooks: hooks
    )

    async let firstResult = executor.execute(plan)
    async let secondResult = executor.execute(plan)
    let results = await [firstResult, secondResult]

    #expect(await overlapProbe.maximumActiveExecutions() == 1)
    #expect(results.allSatisfy { $0.planID == plan.id && $0.items.count == 1 })
    #expect(FileManager.default.fileExists(atPath: target.path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
}

private struct InjectedCleanupFailure: Error {}

private actor PlanExecutionOverlapProbe {
    private var activeExecutions = 0
    private var maximumExecutions = 0
    private var shouldBlockFirstExecution = true
    private var blockedContinuation: CheckedContinuation<Void, Never>?

    func enter() async {
        activeExecutions += 1
        maximumExecutions = max(maximumExecutions, activeExecutions)

        if shouldBlockFirstExecution && activeExecutions == 1 {
            await withCheckedContinuation { continuation in
                blockedContinuation = continuation
            }
        } else if shouldBlockFirstExecution && activeExecutions == 2 {
            shouldBlockFirstExecution = false
            blockedContinuation?.resume()
            blockedContinuation = nil
        }

        activeExecutions -= 1
    }

    func releaseBlockedExecution() {
        shouldBlockFirstExecution = false
        blockedContinuation?.resume()
        blockedContinuation = nil
    }

    func maximumActiveExecutions() -> Int {
        maximumExecutions
    }
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
