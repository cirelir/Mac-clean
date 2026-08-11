import CleanCore
import Foundation
import SwiftData

@MainActor
public protocol AuditStoring: AnyObject {
    func append(_ record: AuditRecord) throws
    func recordScan(at date: Date) throws
    func records() throws -> [AuditRecord]
    func latestScanDate() throws -> Date?
    func clear() throws
}

@MainActor
public final class SwiftDataAuditStore: AuditStoring {
    private let context: ModelContext

    public init() throws {
        let container = try Self.makeContainer(isStoredInMemoryOnly: false)
        context = ModelContext(container)
    }

    private init(container: ModelContainer) {
        context = ModelContext(container)
    }

    public static func inMemory() throws -> SwiftDataAuditStore {
        try SwiftDataAuditStore(container: makeContainer(isStoredInMemoryOnly: true))
    }

    public func append(_ record: AuditRecord) throws {
        context.insert(AuditEntry(record: record))
        try context.save()
    }

    public func recordScan(at date: Date) throws {
        context.insert(ScanEntry(timestamp: date))
        try context.save()
    }

    public func records() throws -> [AuditRecord] {
        try context.fetch(FetchDescriptor<AuditEntry>())
            .map { try $0.record() }
            .sorted {
                if $0.timestamp != $1.timestamp {
                    return $0.timestamp > $1.timestamp
                }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    public func latestScanDate() throws -> Date? {
        try context.fetch(FetchDescriptor<ScanEntry>())
            .lazy
            .map(\.timestamp)
            .max()
    }

    public func clear() throws {
        for entry in try context.fetch(FetchDescriptor<AuditEntry>()) {
            context.delete(entry)
        }
        for entry in try context.fetch(FetchDescriptor<ScanEntry>()) {
            context.delete(entry)
        }
        try context.save()
    }

    private static func makeContainer(isStoredInMemoryOnly: Bool) throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: isStoredInMemoryOnly)
        return try ModelContainer(
            for: AuditEntry.self,
            ScanEntry.self,
            configurations: configuration
        )
    }
}

private enum AuditStoreError: Error {
    case corruptRecord
}

@Model
private final class AuditEntry {
    var id: UUID
    var scanID: UUID
    var candidateID: UUID
    var sourcePath: String
    var canonicalPath: String
    var scannerID: String
    var risk: String
    var action: String
    var sizeBytes: UInt64
    var timestamp: Date
    var outcome: String
    var message: String?

    init(record: AuditRecord) {
        id = record.id
        scanID = record.scanID
        candidateID = record.candidateID
        sourcePath = record.sourcePath
        canonicalPath = record.canonicalPath
        scannerID = record.scannerID
        risk = record.risk.rawValue
        action = record.action.rawValue
        sizeBytes = record.sizeBytes
        timestamp = record.timestamp
        outcome = record.outcome.rawValue
        message = record.message
    }

    func record() throws -> AuditRecord {
        guard
            let risk = RiskLevel(rawValue: risk),
            let action = CleanupAction(rawValue: action),
            let outcome = AuditOutcome(rawValue: outcome)
        else {
            throw AuditStoreError.corruptRecord
        }

        return AuditRecord(
            id: id,
            scanID: scanID,
            candidateID: candidateID,
            sourcePath: sourcePath,
            canonicalPath: canonicalPath,
            scannerID: scannerID,
            risk: risk,
            action: action,
            sizeBytes: sizeBytes,
            timestamp: timestamp,
            outcome: outcome,
            message: message
        )
    }
}

@Model
private final class ScanEntry {
    var timestamp: Date

    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
