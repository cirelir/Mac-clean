import Foundation

public enum CandidateCategory: String, Codable, CaseIterable, Sendable {
    case applicationCache, applicationLog, orphanResidual, packageManager, developerTool, reportOnly
}

public enum RiskLevel: String, Codable, CaseIterable, Sendable {
    case green, yellow, red
}

public enum CleanupAction: String, Codable, Sendable {
    case deleteContentsPreservingRoot, moveToTrash, packageManagerCommand, reportOnly
}

public struct FileFingerprint: Hashable, Codable, Sendable {
    public let deviceID: UInt64
    public let fileID: UInt64
    public let ownerID: UInt32
    public let sizeBytes: UInt64
    public let modifiedAt: Date

    public init(deviceID: UInt64, fileID: UInt64, ownerID: UInt32, sizeBytes: UInt64, modifiedAt: Date) {
        self.deviceID = deviceID
        self.fileID = fileID
        self.ownerID = ownerID
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
    }
}

public struct CandidateEvidence: Hashable, Codable, Sendable {
    public let scannerID: String
    public let ruleID: String
    public let ownerName: String?
    public let ownerBundleID: String?
    public let explanation: String
    public let commandPreview: String?

    public init(scannerID: String, ruleID: String, ownerName: String?, ownerBundleID: String?, explanation: String, commandPreview: String? = nil) {
        self.scannerID = scannerID
        self.ruleID = ruleID
        self.ownerName = ownerName
        self.ownerBundleID = ownerBundleID
        self.explanation = explanation
        self.commandPreview = commandPreview
    }
}

public struct CleanupCandidate: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let displayName: String
    public let category: CandidateCategory
    public let sourceURL: URL
    public let canonicalURL: URL
    public let sizeBytes: UInt64
    public let modifiedAt: Date
    public let fingerprint: FileFingerprint
    public let evidence: CandidateEvidence
    public let risk: RiskLevel
    public let riskReason: String
    public let proposedAction: CleanupAction

    public init(id: UUID, displayName: String, category: CandidateCategory, sourceURL: URL, canonicalURL: URL, sizeBytes: UInt64, modifiedAt: Date, fingerprint: FileFingerprint, evidence: CandidateEvidence, risk: RiskLevel, riskReason: String, proposedAction: CleanupAction) {
        self.id = id
        self.displayName = displayName
        self.category = category
        self.sourceURL = sourceURL
        self.canonicalURL = canonicalURL
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
        self.fingerprint = fingerprint
        self.evidence = evidence
        self.risk = risk
        self.riskReason = riskReason
        self.proposedAction = proposedAction
    }
}
