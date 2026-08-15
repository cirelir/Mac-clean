import Foundation
import Testing
@testable import CleanCore

@Test func coordinatorReturnsSuccessfulScannerResultsAlongsideFailure() async {
    let coordinator = ScanCoordinator(
        scanners: [FixtureScanner.success(id: "good"), FixtureScanner.failure(id: "bad")],
        classifier: RiskClassifier()
    )

    let report = await coordinator.scan(
        context: CoreTestFixtures.context(installed: ["com.example.Editor"])
    )

    #expect(report.candidates.count == 1)
    #expect(report.candidates[0].risk == .green)
    #expect(report.failures.map(\.scannerID) == ["bad"])
    #expect(report.totalBytes == 1_024)
}

@Test func coordinatorClassifiesUnknownDiscoveriesAsRedInsteadOfDroppingThem() async {
    let coordinator = ScanCoordinator(
        scanners: [FixtureScanner.unknown(id: "unknown")],
        classifier: RiskClassifier()
    )

    let report = await coordinator.scan(context: CoreTestFixtures.context())

    #expect(report.candidates.count == 1)
    #expect(report.candidates[0].risk == .red)
    #expect(report.candidates[0].proposedAction == .reportOnly)
    #expect(report.failures.isEmpty)
}

@Test func coordinatorDoesNotYieldGreenCandidateWhenCacheTraversalFails() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let cache = root.appending(path: "com.example.Editor")
    let blocked = cache.appending(path: "blocked")
    try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
    try Data(repeating: 0x41, count: 64).write(to: cache.appending(path: "payload.bin"))
    try Data(repeating: 0x42, count: 4_096).write(to: blocked.appending(path: "hidden.bin"))
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: blocked.path)
    defer {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: blocked.path
        )
        try? FileManager.default.removeItem(at: root)
    }
    let scanner = ApplicationCacheScanner(
        cacheRoot: root,
        validator: SafePathValidator(allowedRoots: [root], forbiddenExactPaths: []),
        fingerprinter: SystemFileFingerprinter()
    )
    let coordinator = ScanCoordinator(scanners: [scanner], classifier: RiskClassifier())

    let report = await coordinator.scan(
        context: CoreTestFixtures.context(installed: ["com.example.Editor"])
    )

    // A cache whose contents cannot be fully enumerated is skipped entirely:
    // it never becomes a candidate (so nothing can be deleted), and the
    // remaining scan still completes without a scanner failure.
    #expect(report.candidates.isEmpty)
    #expect(report.failures.isEmpty)
}

private struct FixtureScanner: CleanCore.Scanner {
    enum FixtureError: Error { case expectedFailure }

    let id: String
    let result: Result<[DiscoveredItem], FixtureError>

    func scan(context: ScanContext) async throws -> [DiscoveredItem] {
        try result.get()
    }

    static func success(id: String) -> Self {
        .init(
            id: id,
            result: .success([
                CoreTestFixtures.cacheDiscovery(ownerBundleID: "com.example.Editor")
            ])
        )
    }

    static func failure(id: String) -> Self {
        .init(id: id, result: .failure(.expectedFailure))
    }

    static func unknown(id: String) -> Self {
        .init(
            id: id,
            result: .success([
                CoreTestFixtures.discovery(kind: .unknown, ownerBundleID: nil)
            ])
        )
    }
}
