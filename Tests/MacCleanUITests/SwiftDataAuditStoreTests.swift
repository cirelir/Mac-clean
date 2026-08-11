import Foundation
import Testing
@testable import MacCleanUI

@Test @MainActor func auditStoreRoundTripsOriginalSourcePath() throws {
    let store = try SwiftDataAuditStore.inMemory()
    let record = UITestFixtures.auditRecord(
        sourcePath: "/Users/example/Library/Caches/com.example.Editor"
    )

    try store.append(record)

    #expect(try store.records().first?.sourcePath == record.sourcePath)
}

@Test @MainActor func auditStoreRoundTripsCompleteRecord() throws {
    let store = try SwiftDataAuditStore.inMemory()
    let record = UITestFixtures.auditRecord(sourcePath: "/source/path")

    try store.append(record)

    #expect(try store.records() == [record])
}

@Test @MainActor func auditStoreRecordsScanTimestampWithoutCandidates() throws {
    let store = try SwiftDataAuditStore.inMemory()

    try store.recordScan(at: UITestFixtures.timestamp)

    #expect(try store.records().isEmpty)
    #expect(try store.latestScanDate() == UITestFixtures.timestamp)
}

@Test @MainActor func auditStoreReturnsMostRecentScanTimestamp() throws {
    let store = try SwiftDataAuditStore.inMemory()
    let latest = UITestFixtures.timestamp.addingTimeInterval(60)

    try store.recordScan(at: latest)
    try store.recordScan(at: UITestFixtures.timestamp)

    #expect(try store.latestScanDate() == latest)
}

@Test @MainActor func auditStoreClearRemovesAuditAndScanMetadata() throws {
    let store = try SwiftDataAuditStore.inMemory()
    try store.append(UITestFixtures.auditRecord(sourcePath: "/source/path"))
    try store.recordScan(at: UITestFixtures.timestamp)

    try store.clear()

    #expect(try store.records().isEmpty)
    #expect(try store.latestScanDate() == nil)
}

@Test @MainActor func failedAuditAppendRollsBackPendingRecord() throws {
    let failures = SaveFailureController()
    let store = try SwiftDataAuditStore.inMemory(beforeSave: { try failures.beforeSave() })
    let record = UITestFixtures.auditRecord(sourcePath: "/must-not-leak")
    failures.failNextSave()

    #expect(throws: InjectedSaveFailure.self) {
        try store.append(record)
    }

    #expect(try store.records().isEmpty)
    try store.recordScan(at: UITestFixtures.timestamp)
    #expect(try store.records().isEmpty)
}

@Test @MainActor func failedScanTimestampRollsBackPendingDate() throws {
    let failures = SaveFailureController()
    let store = try SwiftDataAuditStore.inMemory(beforeSave: { try failures.beforeSave() })
    failures.failNextSave()

    #expect(throws: InjectedSaveFailure.self) {
        try store.recordScan(at: UITestFixtures.timestamp)
    }

    #expect(try store.latestScanDate() == nil)
    try store.append(UITestFixtures.auditRecord(sourcePath: "/successful-record"))
    #expect(try store.latestScanDate() == nil)
}

@Test @MainActor func failedClearRollsBackPendingDeletions() throws {
    let failures = SaveFailureController()
    let store = try SwiftDataAuditStore.inMemory(beforeSave: { try failures.beforeSave() })
    let record = UITestFixtures.auditRecord(sourcePath: "/must-remain")
    try store.append(record)
    try store.recordScan(at: UITestFixtures.timestamp)
    failures.failNextSave()

    #expect(throws: InjectedSaveFailure.self) {
        try store.clear()
    }

    #expect(try store.records() == [record])
    #expect(try store.latestScanDate() == UITestFixtures.timestamp)
}

private struct InjectedSaveFailure: Error {}

@MainActor
private final class SaveFailureController {
    private var shouldFailNextSave = false

    func failNextSave() {
        shouldFailNextSave = true
    }

    func beforeSave() throws {
        guard shouldFailNextSave else { return }
        shouldFailNextSave = false
        throw InjectedSaveFailure()
    }
}
