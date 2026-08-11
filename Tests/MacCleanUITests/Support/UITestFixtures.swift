import CleanCore
import Foundation

enum UITestFixtures {
    static let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
    static let scanID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    static let candidateID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    static let auditID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!

    static func auditRecord(sourcePath: String) -> AuditRecord {
        AuditRecord(
            id: auditID,
            scanID: scanID,
            candidateID: candidateID,
            sourcePath: sourcePath,
            canonicalPath: "/canonical\(sourcePath)",
            scannerID: "fixture-scanner",
            risk: .green,
            action: .deleteContentsPreservingRoot,
            sizeBytes: 1_024,
            timestamp: timestamp,
            outcome: .cleaned,
            message: nil
        )
    }

    static func candidate(sourceURL: URL, canonicalURL: URL) -> CleanupCandidate {
        CleanupCandidate(
            id: candidateID,
            displayName: sourceURL.lastPathComponent,
            category: .applicationCache,
            sourceURL: sourceURL,
            canonicalURL: canonicalURL,
            sizeBytes: 1_024,
            modifiedAt: timestamp,
            fingerprint: FileFingerprint(
                deviceID: 1,
                fileID: 2,
                ownerID: 501,
                sizeBytes: 1_024,
                modifiedAt: timestamp
            ),
            evidence: CandidateEvidence(
                scannerID: "fixture-scanner",
                ruleID: "fixture-rule",
                ownerName: "Editor",
                ownerBundleID: "com.example.Editor",
                explanation: "Fixture evidence"
            ),
            risk: .green,
            riskReason: "Fixture risk",
            proposedAction: .deleteContentsPreservingRoot
        )
    }
}
