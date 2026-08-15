import Foundation
import Testing
@testable import MacCleanUI

@Test @MainActor func presentationIncludesPathReasonAndLocalizedRiskLabel() {
    let candidate = UITestFixtures.candidate(
        risk: .green,
        path: "/Users/example/Library/Caches/com.example.Editor"
    )

    let value = CandidatePresentation(candidate: candidate, fileManager: .default)

    #expect(value.path == candidate.canonicalURL.path)
    #expect(value.riskLabel == "安全缓存")
    #expect(value.riskReason == candidate.riskReason)
    #expect(value.finderActionTitle == "在 Finder 中显示")
}

@Test @MainActor func presentationLocalizesEveryRiskAsText() {
    let yellow = CandidatePresentation(
        candidate: UITestFixtures.candidate(risk: .yellow),
        fileManager: .default
    )
    let red = CandidatePresentation(
        candidate: UITestFixtures.candidate(risk: .red),
        fileManager: .default
    )

    #expect(yellow.riskLabel == "需要确认")
    #expect(red.riskLabel == "仅报告")
}

@Test @MainActor func presentationRecomputesFinderAvailabilityFromCurrentFileState() throws {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "presentation-finder-\(UUID().uuidString)")
    let candidate = UITestFixtures.candidate(risk: .green, path: url.path)
    let value = CandidatePresentation(candidate: candidate, fileManager: .default)

    #expect(value.finderRevealState == .unavailable(.missing))

    try Data().write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(value.finderRevealState == .available(candidate.canonicalURL))
}

@Test @MainActor func presentationExplainsWhyFinderActionIsDisabled() {
    let missing = CandidatePresentation(
        candidate: UITestFixtures.candidate(
            risk: .green,
            path: "/missing/presentation-target"
        ),
        fileManager: .default
    )
    let inaccessible = CandidatePresentation(
        candidate: UITestFixtures.candidate(
            risk: .green,
            path: "/present/but/inaccessible"
        ),
        fileManager: PresentationInaccessibleFileManager()
    )

    #expect(!missing.isFinderActionEnabled)
    #expect(missing.finderAccessibilityHint == "路径不存在或已被清理，无法在 Finder 中显示。")
    #expect(!inaccessible.isFinderActionEnabled)
    #expect(inaccessible.finderAccessibilityHint == "没有访问此路径的权限，无法在 Finder 中显示。")
}

@Test @MainActor func presentationFormatsCandidateBytesForDisplay() {
    let value = CandidatePresentation(
        candidate: UITestFixtures.candidate(risk: .green, sizeBytes: 1_024),
        fileManager: .default
    )

    #expect(value.formattedSize == "1 KB")
}

@Test @MainActor func finderAvailabilityChangesOnlyWhenRowStateRefreshes() throws {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "finder-refresh-\(UUID().uuidString)")
    let candidate = UITestFixtures.candidate(risk: .green, path: url.path)
    var state = FinderAvailabilityRefreshState(
        candidate: candidate,
        fileManager: .default
    )
    let initialSnapshot = try #require(state.snapshot)

    #expect(initialSnapshot.revealState == .unavailable(.missing))
    #expect(!state.isEnabled)
    #expect(state.accessibilityHint == "路径不存在或已被清理，无法在 Finder 中显示。")

    try Data().write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(!state.isEnabled)
    state.refresh(candidate: candidate, fileManager: .default)
    let refreshedSnapshot = try #require(state.snapshot)

    #expect(refreshedSnapshot.revealState == .available(candidate.canonicalURL))
    #expect(state.isEnabled)
    #expect(state.accessibilityHint == "在 Finder 中选中此项目。")
}

@Test @MainActor func finderAvailabilityCanDeferFileSystemChecksUntilExpansion() {
    let state = FinderAvailabilityRefreshState()

    #expect(state.snapshot == nil)
    #expect(!state.isEnabled)
    #expect(state.accessibilityHint == "展开详情后检查 Finder 位置是否可用。")
}

private final class PresentationInaccessibleFileManager: FileManager, @unchecked Sendable {
    override func fileExists(atPath path: String) -> Bool {
        true
    }

    override func isReadableFile(atPath path: String) -> Bool {
        false
    }
}
