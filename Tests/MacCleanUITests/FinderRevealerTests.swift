import Foundation
import Testing
@testable import MacCleanUI

@Test func missingFinderTargetIsDisabled() {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)

    #expect(FinderRevealState(url: url, fileManager: .default) == .unavailable(.missing))
}

@Test func readableFinderTargetIsAvailableAtOriginalURL() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try Data().write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(FinderRevealState(url: url, fileManager: .default) == .available(url))
}

@Test func inaccessibleFinderTargetIsDisabled() {
    let url = URL(fileURLWithPath: "/present/but/inaccessible")
    let fileManager = InaccessibleFileManager()

    #expect(FinderRevealState(url: url, fileManager: fileManager) == .unavailable(.inaccessible))
}

@Test func candidateFinderStateUsesOriginalSourceURL() throws {
    let sourceURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let canonicalURL = URL(fileURLWithPath: "/canonical/path/that/does/not/exist")
    try Data().write(to: sourceURL)
    defer { try? FileManager.default.removeItem(at: sourceURL) }
    let candidate = UITestFixtures.candidate(sourceURL: sourceURL, canonicalURL: canonicalURL)

    #expect(FinderRevealState(candidate: candidate, fileManager: .default) == .available(sourceURL))
}

private final class InaccessibleFileManager: FileManager, @unchecked Sendable {
    override func fileExists(atPath path: String) -> Bool {
        true
    }

    override func isReadableFile(atPath path: String) -> Bool {
        false
    }
}
