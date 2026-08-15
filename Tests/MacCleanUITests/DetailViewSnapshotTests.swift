import AppKit
import CleanCore
import Foundation
import SwiftUI
import Testing
@testable import MacCleanUI

@Test @MainActor func detailViewRendersThePrimaryResultsState() async throws {
    let candidates = [
        visualCandidate(
            id: "10000000-0000-0000-0000-000000000001",
            name: "Xcode DerivedData",
            category: .developerTool,
            risk: .green,
            sizeBytes: 5_600_000_000,
            ownerName: "Xcode",
            ownerBundleID: "com.apple.dt.Xcode",
            explanation: "Xcode 构建派生数据，可安全重建",
            path: "/Users/example/Library/Developer/Xcode/DerivedData"
        ),
        visualCandidate(
            id: "10000000-0000-0000-0000-000000000002",
            name: "Chrome 缓存",
            category: .applicationCache,
            risk: .green,
            sizeBytes: 1_900_000_000,
            ownerName: "Google Chrome",
            ownerBundleID: "com.google.Chrome",
            explanation: "浏览器缓存和临时文件",
            path: "/Users/example/Library/Caches/Google/Chrome"
        ),
        visualCandidate(
            id: "10000000-0000-0000-0000-000000000003",
            name: "Homebrew 下载缓存",
            category: .packageManager,
            risk: .green,
            sizeBytes: 900_000_000,
            ownerName: "Homebrew",
            ownerBundleID: nil,
            explanation: "已下载的软件包缓存",
            path: "/Users/example/Library/Caches/Homebrew"
        ),
        visualCandidate(
            id: "10000000-0000-0000-0000-000000000004",
            name: "已卸载应用残留",
            category: .orphanResidual,
            risk: .yellow,
            sizeBytes: 2_700_000_000,
            ownerName: "Example Editor",
            ownerBundleID: "com.example.Editor",
            explanation: "应用已卸载，其支持文件仍保留在本机",
            path: "/Users/example/Library/Application Support/Example Editor"
        ),
        visualCandidate(
            id: "10000000-0000-0000-0000-000000000005",
            name: "旧版 Xcode 模拟器",
            category: .developerTool,
            risk: .yellow,
            sizeBytes: 1_400_000_000,
            ownerName: "Xcode",
            ownerBundleID: "com.apple.dt.Xcode",
            explanation: "已不再使用的模拟器运行时",
            path: "/Users/example/Library/Developer/CoreSimulator/Profiles/Runtimes"
        ),
        visualCandidate(
            id: "10000000-0000-0000-0000-000000000006",
            name: "受保护的设备备份",
            category: .reportOnly,
            risk: .red,
            sizeBytes: 300_000_000,
            ownerName: "macOS",
            ownerBundleID: nil,
            explanation: "系统仍在引用，仅供参考",
            path: "/Users/example/Library/Application Support/MobileSync/Backup"
        )
    ]
    let model = AppModel(
        dependencies: .fixture(report: ScanReport(candidates: candidates, failures: []))
    )
    await model.scan()

    let hostingView = NSHostingView(
        rootView: DetailView(model: model)
            .environment(AppearanceStore(preference: .light))
            .frame(width: 1_440, height: 1_024)
            .environment(\.colorScheme, .light)
            .environment(\.controlActiveState, .key)
    )
    hostingView.frame = NSRect(x: 0, y: 0, width: 1_440, height: 1_024)
    let window = NSWindow(
        contentRect: hostingView.frame,
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.contentView = hostingView
    window.makeKeyAndOrderFront(nil)
    if ProcessInfo.processInfo.environment["MACCLEAN_SNAPSHOT_PATH"] != nil {
        NSApp.activate(ignoringOtherApps: true)
    }
    hostingView.layoutSubtreeIfNeeded()
    await Task.yield()
    hostingView.layoutSubtreeIfNeeded()

    let bitmap = try #require(
        hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
    )
    hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
    #expect(bitmap.pixelsWide == 1_440)
    #expect(bitmap.pixelsHigh == 1_024)

    if let outputPath = ProcessInfo.processInfo.environment["MACCLEAN_SNAPSHOT_PATH"] {
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
    }

    window.close()
}

@Test @MainActor func riskFilterStaysLeftAlignedWithCandidateList() async throws {
    let model = AppModel(
        dependencies: .fixture(
            report: UITestFixtures.scanReport(candidateCount: 6, failureCount: 0)
        )
    )
    await model.scan()

    let hosting = NSHostingView(
        rootView: DetailView(model: model)
            .environment(AppearanceStore(preference: .light))
            .frame(width: 1_100, height: 937)
    )
    hosting.frame = NSRect(x: 0, y: 0, width: 1_100, height: 937)
    let window = NSWindow(
        contentRect: hosting.frame,
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.contentView = hosting
    hosting.layoutSubtreeIfNeeded()
    await Task.yield()
    hosting.layoutSubtreeIfNeeded()

    var segmentedMinX: CGFloat?
    var listMinX: CGFloat?
    func walk(_ view: NSView) {
        let frameInHosting = hosting.convert(view.bounds, from: view)
        if view is NSSegmentedControl, segmentedMinX == nil {
            segmentedMinX = frameInHosting.minX
        }
        if String(describing: type(of: view)) == "HostingScrollView", listMinX == nil {
            listMinX = frameInHosting.minX
        }
        for sub in view.subviews {
            walk(sub)
        }
    }
    walk(hosting)

    let segmentedLeading = try #require(segmentedMinX)
    let listLeading = try #require(listMinX)

    // The segmented risk filter must stay flush with the candidate list's
    // leading edge (both share the 28pt horizontal padding).
    #expect(segmentedLeading == listLeading)
}

@Test @MainActor func detailViewIdealHeightAdaptsToCandidateCount() async throws {
    let emptyModel = AppModel(
        dependencies: .fixture(
            report: UITestFixtures.scanReport(candidateCount: 0, failureCount: 0)
        )
    )
    await emptyModel.scan()

    let populatedModel = AppModel(
        dependencies: .fixture(
            report: UITestFixtures.scanReport(candidateCount: 12, failureCount: 0)
        )
    )
    await populatedModel.scan()

    let emptyView = NSHostingView(
        rootView: DetailView(model: emptyModel)
            .environment(AppearanceStore(preference: .light))
    )
    emptyView.layoutSubtreeIfNeeded()
    let populatedView = NSHostingView(
        rootView: DetailView(model: populatedModel)
            .environment(AppearanceStore(preference: .light))
    )
    populatedView.layoutSubtreeIfNeeded()

    let emptyFitting = emptyView.fittingSize
    let populatedFitting = populatedView.fittingSize

    // The window auto-size contract: never below the 640 minimum, and taller
    // content (more candidate rows) must grow the ideal height.
    #expect(emptyFitting.height >= 640)
    #expect(populatedFitting.height > emptyFitting.height)
    #expect(populatedFitting.width == emptyFitting.width)
}

private func visualCandidate(
    id: String,
    name: String,
    category: CandidateCategory,
    risk: RiskLevel,
    sizeBytes: UInt64,
    ownerName: String,
    ownerBundleID: String?,
    explanation: String,
    path: String
) -> CleanupCandidate {
    let url = URL(fileURLWithPath: path).standardizedFileURL
    let action: CleanupAction = switch risk {
    case .green: .deleteContentsPreservingRoot
    case .yellow: .moveToTrash
    case .red: .reportOnly
    }
    let timestamp = Date(timeIntervalSince1970: 1_723_708_800)
    return CleanupCandidate(
        id: UUID(uuidString: id)!,
        displayName: name,
        category: category,
        sourceURL: url,
        canonicalURL: url,
        sizeBytes: sizeBytes,
        modifiedAt: timestamp,
        fingerprint: FileFingerprint(
            deviceID: 1,
            fileID: sizeBytes,
            ownerID: 501,
            sizeBytes: sizeBytes,
            modifiedAt: timestamp
        ),
        evidence: CandidateEvidence(
            scannerID: "visual-fixture",
            ruleID: "selected-redesign",
            ownerName: ownerName,
            ownerBundleID: ownerBundleID,
            explanation: explanation
        ),
        risk: risk,
        riskReason: explanation,
        proposedAction: action
    )
}
