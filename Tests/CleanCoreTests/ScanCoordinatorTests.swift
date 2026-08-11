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
