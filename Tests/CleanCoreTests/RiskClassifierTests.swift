import Foundation
import Testing
@testable import CleanCore

@Test func installedStoppedApplicationCacheIsGreen() throws {
    let item = CoreTestFixtures.cacheDiscovery(ownerBundleID: "com.example.Editor")
    let context = CoreTestFixtures.context(installed: ["com.example.Editor"], running: [])

    #expect(try RiskClassifier().classify(item, context: context).risk == .green)
}

@Test func runningApplicationCacheIsRed() throws {
    let item = CoreTestFixtures.cacheDiscovery(ownerBundleID: "com.example.Editor")
    let context = CoreTestFixtures.context(
        installed: ["com.example.Editor"],
        running: ["com.example.Editor"]
    )

    let candidate = try RiskClassifier().classify(item, context: context)

    #expect(candidate.risk == .red)
    #expect(candidate.proposedAction == .reportOnly)
}

@Test func authoritativeOrphanResidualIsYellow() throws {
    let item = CoreTestFixtures.discovery(kind: .orphanResidual(confidence: .authoritative))

    #expect(try RiskClassifier().classify(item, context: CoreTestFixtures.context()).risk == .yellow)
}

@Test func authoritativeUnusedDependencyIsYellow() throws {
    let item = CoreTestFixtures.discovery(kind: .authoritativeUnusedDependency)

    #expect(try RiskClassifier().classify(item, context: CoreTestFixtures.context()).risk == .yellow)
}

@Test func inferredOrphanResidualIsRedAndReportOnly() throws {
    let item = CoreTestFixtures.discovery(kind: .orphanResidual(confidence: .inferred))

    let candidate = try RiskClassifier().classify(item, context: CoreTestFixtures.context())

    #expect(candidate.risk == .red)
    #expect(candidate.proposedAction == .reportOnly)
}

@Test func unknownDiscoveryIsRedAndReportOnly() throws {
    let item = CoreTestFixtures.discovery(kind: .unknown)

    let candidate = try RiskClassifier().classify(item, context: CoreTestFixtures.context())

    #expect(candidate.risk == .red)
    #expect(candidate.proposedAction == .reportOnly)
}

@Test func missingOwnerIsRedAndReportOnly() throws {
    let item = CoreTestFixtures.discovery(
        kind: .regenerableApplicationCache,
        ownerBundleID: nil
    )

    let candidate = try RiskClassifier().classify(item, context: CoreTestFixtures.context())

    #expect(candidate.risk == .red)
    #expect(candidate.proposedAction == .reportOnly)
}

@Test func candidatePreservesEvidenceAndCanonicalURL() throws {
    let item = CoreTestFixtures.cacheDiscovery(ownerBundleID: "com.example.Editor")
    let context = CoreTestFixtures.context(installed: ["com.example.Editor"])

    let candidate = try RiskClassifier().classify(item, context: context)

    #expect(candidate.evidence == item.evidence)
    #expect(candidate.canonicalURL == item.validatedPath.canonicalURL)
}
