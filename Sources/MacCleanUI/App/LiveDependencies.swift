import AppKit
import CleanCore
import Foundation

public enum LiveDependencies {
    @MainActor
    public static func makeAppModel() throws -> AppModel {
        let fileManager = FileManager.default
        let homeDirectory = fileManager.homeDirectoryForCurrentUser.standardizedFileURL
        let cacheRoot = homeDirectory
            .appending(path: "Library/Caches", directoryHint: .isDirectory)
            .standardizedFileURL
        let validator = SafePathValidator(
            allowedRoots: [cacheRoot],
            forbiddenExactPaths: [
                URL(fileURLWithPath: "/", isDirectory: true),
                homeDirectory,
                cacheRoot
            ]
        )
        let fingerprinter = SystemFileFingerprinter()
        let cacheScanner = ApplicationCacheScanner(
            cacheRoot: cacheRoot,
            validator: validator,
            fingerprinter: fingerprinter
        )
        let inventory = SystemApplicationInventoryProvider(
            applicationRoots: [
                URL(fileURLWithPath: "/Applications", isDirectory: true),
                URL(fileURLWithPath: "/System/Applications", isDirectory: true),
                homeDirectory.appending(path: "Applications", directoryHint: .isDirectory)
            ],
            runningBundleIDs: {
                Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
            }
        )
        let dependencies = AppDependencies(
            inventory: inventory,
            coordinator: ScanCoordinator(scanners: [cacheScanner], classifier: RiskClassifier()),
            planner: CleanupPlanner(),
            cleanupExecutor: CleanupExecutor(validator: validator),
            audit: try SwiftDataAuditStore(),
            finder: NSWorkspaceFinderRevealer(),
            notifications: UserNotificationService(),
            now: Date.init
        )
        return AppModel(dependencies: dependencies)
    }
}
