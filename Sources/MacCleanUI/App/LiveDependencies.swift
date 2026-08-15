import AppKit
import CleanCore
import Foundation

public enum LiveDependencies {
    @MainActor
    public static func makeAppModel() throws -> AppModel {
        let fileManager = FileManager.default
        let homeDirectory = fileManager.homeDirectoryForCurrentUser.standardizedFileURL
        // macOS can transiently refuse the very first access to ~/.Trash in a
        // session; warm it up at launch so cleanup never hits that.
        _ = try? fileManager.contentsOfDirectory(
            atPath: homeDirectory.appending(path: ".Trash").path
        )
        let cacheRoot = homeDirectory
            .appending(path: "Library/Caches", directoryHint: .isDirectory)
            .standardizedFileURL
        let logsRoot = homeDirectory
            .appending(path: "Library/Logs", directoryHint: .isDirectory)
            .standardizedFileURL
        let derivedDataRoot = homeDirectory
            .appending(
                path: "Library/Developer/Xcode/DerivedData",
                directoryHint: .isDirectory
            )
            .standardizedFileURL
        let developerRoot = derivedDataRoot
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let applicationSupportRoot = homeDirectory
            .appending(
                path: "Library/Application Support",
                directoryHint: .isDirectory
            )
            .standardizedFileURL
        let validator = SafePathValidator(
            allowedRoots: [
                cacheRoot,
                logsRoot,
                derivedDataRoot,
                developerRoot,
                applicationSupportRoot
            ],
            forbiddenExactPaths: [
                URL(fileURLWithPath: "/", isDirectory: true),
                homeDirectory,
                cacheRoot,
                logsRoot,
                derivedDataRoot,
                developerRoot,
                applicationSupportRoot
            ]
        )
        let fingerprinter = SystemFileFingerprinter()
        let cacheScanner = ApplicationCacheScanner(
            cacheRoot: cacheRoot,
            validator: validator,
            fingerprinter: fingerprinter
        )
        let systemDataScanner = SystemDataScanner(
            logRoot: logsRoot,
            validator: validator,
            fingerprinter: fingerprinter
        )
        let developerDataScanner = DeveloperDataScanner(
            derivedDataRoot: derivedDataRoot,
            developerRoot: developerRoot,
            validator: validator,
            fingerprinter: fingerprinter
        )
        let applicationSupportScanner = ApplicationSupportScanner(
            supportRoot: applicationSupportRoot,
            validator: validator,
            fingerprinter: fingerprinter
        )
        let inventory = SystemApplicationInventoryProvider(
            applicationRoots: [
                URL(fileURLWithPath: "/Applications", isDirectory: true),
                URL(fileURLWithPath: "/System/Applications", isDirectory: true),
                URL(fileURLWithPath: "/Library/Input Methods", isDirectory: true),
                homeDirectory.appending(path: "Applications", directoryHint: .isDirectory)
            ],
            runningBundleIDs: {
                Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
            }
        )
        let dependencies = AppDependencies(
            inventory: inventory,
            coordinator: ScanCoordinator(
                scanners: [
                    cacheScanner,
                    systemDataScanner,
                    developerDataScanner,
                    applicationSupportScanner
                ],
                classifier: RiskClassifier()
            ),
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
