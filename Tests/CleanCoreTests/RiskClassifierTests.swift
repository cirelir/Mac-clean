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

@Test func rotatableLogYoungerThanSevenDaysIsRedAndReportOnly() throws {
    let item = CoreTestFixtures.discovery(kind: .rotatableLog(olderThanDays: 6))
    let context = CoreTestFixtures.context(installed: ["com.example.Editor"])

    let candidate = try RiskClassifier().classify(item, context: context)

    #expect(candidate.risk == .red)
    #expect(candidate.proposedAction == .reportOnly)
}

@Test func rotatableLogAtSevenDaysIsGreen() throws {
    let item = CoreTestFixtures.discovery(kind: .rotatableLog(olderThanDays: 7))
    let context = CoreTestFixtures.context(installed: ["com.example.Editor"])

    let candidate = try RiskClassifier().classify(item, context: context)

    #expect(candidate.risk == .green)
    #expect(candidate.proposedAction == .deleteContentsPreservingRoot)
}

@Test func rotatableLogWithUninstalledOwnerIsRedAndReportOnly() throws {
    let item = CoreTestFixtures.discovery(kind: .rotatableLog(olderThanDays: 7))

    let candidate = try RiskClassifier().classify(item, context: CoreTestFixtures.context())

    #expect(candidate.risk == .red)
    #expect(candidate.proposedAction == .reportOnly)
}

@Test func rotatableLogWithoutOwnerIsRedAndReportOnly() throws {
    let item = CoreTestFixtures.discovery(kind: .rotatableLog(olderThanDays: 7), ownerBundleID: nil)

    let candidate = try RiskClassifier().classify(item, context: CoreTestFixtures.context())

    #expect(candidate.risk == .red)
    #expect(candidate.proposedAction == .reportOnly)
}

@Test func rotatableLogWithRunningOwnerIsRedAndReportOnly() throws {
    let item = CoreTestFixtures.discovery(kind: .rotatableLog(olderThanDays: 7))
    let context = CoreTestFixtures.context(
        installed: ["com.example.Editor"],
        running: ["com.example.Editor"]
    )

    let candidate = try RiskClassifier().classify(item, context: context)

    #expect(candidate.risk == .red)
    #expect(candidate.proposedAction == .reportOnly)
}

@Test func runningOwnerDowngradesAuthoritativeOrphanResidual() throws {
    let item = CoreTestFixtures.discovery(kind: .orphanResidual(confidence: .authoritative))
    let context = CoreTestFixtures.context(running: ["com.example.Editor"])

    let candidate = try RiskClassifier().classify(item, context: context)

    #expect(candidate.risk == .red)
    #expect(candidate.proposedAction == .reportOnly)
}

@Test func missingOwnerDowngradesAuthoritativeOrphanResidual() throws {
    let item = CoreTestFixtures.discovery(
        kind: .orphanResidual(confidence: .authoritative),
        ownerBundleID: nil
    )

    let candidate = try RiskClassifier().classify(item, context: CoreTestFixtures.context())

    #expect(candidate.risk == .red)
    #expect(candidate.proposedAction == .reportOnly)
}

@Test func runningOwnerDowngradesAuthoritativeUnusedDependency() throws {
    let item = CoreTestFixtures.discovery(kind: .authoritativeUnusedDependency)
    let context = CoreTestFixtures.context(running: ["com.example.Editor"])

    let candidate = try RiskClassifier().classify(item, context: context)

    #expect(candidate.risk == .red)
    #expect(candidate.proposedAction == .reportOnly)
}

@Test func missingOwnerDowngradesAuthoritativeUnusedDependency() throws {
    let item = CoreTestFixtures.discovery(kind: .authoritativeUnusedDependency, ownerBundleID: nil)

    let candidate = try RiskClassifier().classify(item, context: CoreTestFixtures.context())

    #expect(candidate.risk == .red)
    #expect(candidate.proposedAction == .reportOnly)
}

@Test func candidatePreservesSourceCanonicalURLAndFingerprint() throws {
    let sourceURL = URL(fileURLWithPath: "/tmp/mac-clean-tests/original/Editor cache")
    let canonicalURL = URL(fileURLWithPath: "/tmp/mac-clean-tests/canonical/Editor cache")
    let fingerprint = FileFingerprint(
        deviceID: 42,
        fileID: 99,
        ownerID: 777,
        sizeBytes: 4_096,
        modifiedAt: Date(timeIntervalSince1970: 1_700_000_123)
    )
    let evidence = CandidateEvidence(
        scannerID: "propagation-fixture",
        ruleID: "distinct-source-and-canonical-urls",
        ownerName: "Editor",
        ownerBundleID: "com.example.Editor",
        explanation: "Propagation fixture"
    )
    let item = DiscoveredItem(
        displayName: "Editor cache",
        sourceURL: sourceURL,
        validatedPath: .init(
            originalURL: sourceURL,
            canonicalURL: canonicalURL,
            allowedRoot: canonicalURL.deletingLastPathComponent()
        ),
        sizeBytes: 4_096,
        modifiedAt: CoreTestFixtures.date,
        fingerprint: fingerprint,
        evidence: evidence,
        kind: .regenerableApplicationCache
    )
    let context = CoreTestFixtures.context(installed: ["com.example.Editor"])

    let candidate = try RiskClassifier().classify(item, context: context)

    #expect(candidate.evidence == item.evidence)
    #expect(candidate.sourceURL == sourceURL)
    #expect(candidate.canonicalURL == item.validatedPath.canonicalURL)
    #expect(candidate.fingerprint == fingerprint)
}
