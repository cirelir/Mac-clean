import Foundation
import Testing
@testable import CleanCore

@Test func candidateRetainsSourceEvidenceAndFinderURL() {
    let source = URL(fileURLWithPath: "/Users/example/Library/Caches/com.example.Editor")
    let candidate = CleanupCandidate(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        displayName: "Editor cache",
        category: .applicationCache,
        sourceURL: source,
        canonicalURL: source,
        sizeBytes: 1024,
        modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
        fingerprint: .init(deviceID: 1, fileID: 2, ownerID: 501, sizeBytes: 1024, modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)),
        evidence: .init(scannerID: "application-cache", ruleID: "installed-bundle-cache", ownerName: "Editor", ownerBundleID: "com.example.Editor", explanation: "Installed application cache"),
        risk: .green,
        riskReason: "Cache is regenerable and the owner is not running",
        proposedAction: .deleteContentsPreservingRoot
    )

    #expect(candidate.sourceURL == source)
    #expect(candidate.evidence.ownerBundleID == "com.example.Editor")
    #expect(candidate.proposedAction == .deleteContentsPreservingRoot)
}

@Test func applicationInventoryRetainsInstalledAndRunningApplications() {
    let application = InstalledApplication(
        name: "Editor",
        bundleID: "com.example.Editor",
        url: URL(fileURLWithPath: "/Applications/Editor.app")
    )
    let inventory = ApplicationInventory(
        installedApplications: [application],
        runningBundleIDs: ["com.example.Editor"]
    )

    #expect(inventory.installedApplications == [application])
    #expect(inventory.runningBundleIDs == ["com.example.Editor"])
}
