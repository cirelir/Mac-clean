import Testing
@testable import MacCleanUI

@Test func compareEqualVersions() {
    #expect(VersionComparator.compare("0.2.0", "0.2.0") == .orderedSame)
    #expect(VersionComparator.compare("0.2", "0.2.0") == .orderedSame)
    #expect(VersionComparator.compare("v0.2.0", "0.2.0") == .orderedSame)
    #expect(VersionComparator.compare("V0.2.0", "0.2.0") == .orderedSame)
}

@Test func compareAscending() {
    #expect(VersionComparator.compare("0.2.0", "0.3.0") == .orderedAscending)
    #expect(VersionComparator.compare("0.1.9", "0.2.0") == .orderedAscending)
    #expect(VersionComparator.compare("0.2", "0.2.1") == .orderedAscending)
    #expect(VersionComparator.compare("0.2.0", "0.2.10") == .orderedAscending)
    #expect(VersionComparator.compare("1.0.0", "2.0.0") == .orderedAscending)
}

@Test func compareDescending() {
    #expect(VersionComparator.compare("0.3.0", "0.2.0") == .orderedDescending)
    #expect(VersionComparator.compare("0.2.1", "0.2.0") == .orderedDescending)
    #expect(VersionComparator.compare("1.0.0", "0.9.9") == .orderedDescending)
}

@Test func displayVersionStripsVPrefix() {
    #expect(VersionComparator.displayVersion("v0.3.0") == "0.3.0")
    #expect(VersionComparator.displayVersion("V0.2.0") == "0.2.0")
    #expect(VersionComparator.displayVersion("0.2.0") == "0.2.0")
}
