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
