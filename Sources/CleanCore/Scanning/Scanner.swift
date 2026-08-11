import Foundation

public enum DiscoveryConfidence: String, Codable, Sendable {
    case authoritative
    case inferred
    case unknown
}

public enum DiscoveryKind: Hashable, Codable, Sendable {
    case regenerableApplicationCache
    case rotatableLog(olderThanDays: Int)
    case orphanResidual(confidence: DiscoveryConfidence)
    case authoritativeUnusedDependency
    case unknown
}

public struct DiscoveredItem: Hashable, Sendable {
    public let displayName: String
    public let sourceURL: URL
    public let validatedPath: ValidatedPath
    public let sizeBytes: UInt64
    public let modifiedAt: Date
    public let fingerprint: FileFingerprint
    public let evidence: CandidateEvidence
    public let kind: DiscoveryKind

    public init(
        displayName: String,
        sourceURL: URL,
        validatedPath: ValidatedPath,
        sizeBytes: UInt64,
        modifiedAt: Date,
        fingerprint: FileFingerprint,
        evidence: CandidateEvidence,
        kind: DiscoveryKind
    ) {
        self.displayName = displayName
        self.sourceURL = sourceURL
        self.validatedPath = validatedPath
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
        self.fingerprint = fingerprint
        self.evidence = evidence
        self.kind = kind
    }
}

public struct ScanContext: Sendable {
    public let inventory: ApplicationInventory
    public let now: Date

    public init(inventory: ApplicationInventory, now: Date) {
        self.inventory = inventory
        self.now = now
    }
}

public protocol Scanner: Sendable {
    var id: String { get }
    func scan(context: ScanContext) async throws -> [DiscoveredItem]
}
