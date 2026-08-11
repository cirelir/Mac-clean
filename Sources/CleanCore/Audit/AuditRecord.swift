import Foundation

public enum AuditOutcome: String, Codable, Hashable, Sendable {
    case cleaned, skipped, failed
}

public struct AuditRecord: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let scanID: UUID
    public let candidateID: UUID
    public let sourcePath: String
    public let canonicalPath: String
    public let scannerID: String
    public let risk: RiskLevel
    public let action: CleanupAction
    public let sizeBytes: UInt64
    public let timestamp: Date
    public let outcome: AuditOutcome
    public let message: String?

    public init(
        id: UUID,
        scanID: UUID,
        candidateID: UUID,
        sourcePath: String,
        canonicalPath: String,
        scannerID: String,
        risk: RiskLevel,
        action: CleanupAction,
        sizeBytes: UInt64,
        timestamp: Date,
        outcome: AuditOutcome,
        message: String?
    ) {
        self.id = id
        self.scanID = scanID
        self.candidateID = candidateID
        self.sourcePath = sourcePath
        self.canonicalPath = canonicalPath
        self.scannerID = scannerID
        self.risk = risk
        self.action = action
        self.sizeBytes = sizeBytes
        self.timestamp = timestamp
        self.outcome = outcome
        self.message = message
    }
}
