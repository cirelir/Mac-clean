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
        // The uninstaller deliberately works over a wider set of user Library
        // data roots (preferences, containers, saved state, ...) than the
        // scanning validator. It uses its own validator so the scan-time
        // security boundary is not widened.
        let libraryRoot = homeDirectory
            .appending(path: "Library", directoryHint: .isDirectory)
            .standardizedFileURL
        let preferencesRoot = libraryRoot
            .appending(path: "Preferences", directoryHint: .isDirectory)
            .standardizedFileURL
        let httpStoragesRoot = libraryRoot
            .appending(path: "HTTPStorages", directoryHint: .isDirectory)
            .standardizedFileURL
        let webKitRoot = libraryRoot
            .appending(path: "WebKit", directoryHint: .isDirectory)
            .standardizedFileURL
        let savedStateRoot = libraryRoot
            .appending(path: "Saved Application State", directoryHint: .isDirectory)
            .standardizedFileURL
        let containersRoot = libraryRoot
            .appending(path: "Containers", directoryHint: .isDirectory)
            .standardizedFileURL
        let groupContainersRoot = libraryRoot
            .appending(path: "Group Containers", directoryHint: .isDirectory)
            .standardizedFileURL
        let applicationScriptsRoot = libraryRoot
            .appending(path: "Application Scripts", directoryHint: .isDirectory)
            .standardizedFileURL
        let launchAgentsRoot = libraryRoot
            .appending(path: "LaunchAgents", directoryHint: .isDirectory)
            .standardizedFileURL
        let applicationsRoot = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let userApplicationsRoot = homeDirectory
            .appending(path: "Applications", directoryHint: .isDirectory)
            .standardizedFileURL
        let inputMethodsRoot = URL(
            fileURLWithPath: "/Library/Input Methods",
            isDirectory: true
        )
        let uninstallRoots = [
            applicationSupportRoot,
            cacheRoot,
            logsRoot,
            preferencesRoot,
            httpStoragesRoot,
            webKitRoot,
            savedStateRoot,
            containersRoot,
            groupContainersRoot,
            applicationScriptsRoot,
            launchAgentsRoot,
            developerRoot,
            applicationsRoot,
            userApplicationsRoot,
            inputMethodsRoot
        ]
        let uninstallValidator = SafePathValidator(
            allowedRoots: uninstallRoots,
            forbiddenExactPaths: Set(
                [URL(fileURLWithPath: "/", isDirectory: true), homeDirectory]
                    + uninstallRoots
            )
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
            uninstaller: SystemAppUninstaller(
                libraryRoot: libraryRoot,
                inventory: inventory,
                executor: CleanupExecutor(validator: uninstallValidator)
            ),
            quitter: NSWorkspaceApplicationQuitter(),
            audit: try SwiftDataAuditStore(),
            finder: NSWorkspaceFinderRevealer(),
            notifications: UserNotificationService(),
            now: Date.init
        )
        return AppModel(dependencies: dependencies)
    }
}
