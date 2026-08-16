import Foundation

/// What a planned uninstall item represents inside an application's data.
public enum UninstallItemRole: String, Codable, CaseIterable, Sendable {
    case appBundle
    case applicationSupport
    case caches
    case logs
    case preferences
    case httpStorages
    case webKit
    case savedState
    case containers
    case groupContainers
    case applicationScripts
    case launchAgents
    /// Developer tool data, e.g. ~/Library/Developer/Xcode for Xcode.
    case developerData
}

/// A single object planned for removal during an application uninstall: the
/// application bundle itself or one of its data directories/files. Planning
/// records the object's fingerprint so the executor can re-verify identity
/// before moving it to the trash.
public struct UninstallItem: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let role: UninstallItemRole
    public let url: URL
    public let displayName: String
    public let sizeBytes: UInt64
    public let fingerprint: FileFingerprint

    public init(
        id: UUID,
        role: UninstallItemRole,
        url: URL,
        displayName: String,
        sizeBytes: UInt64,
        fingerprint: FileFingerprint
    ) {
        self.id = id
        self.role = role
        self.url = url
        self.displayName = displayName
        self.sizeBytes = sizeBytes
        self.fingerprint = fingerprint
    }
}

/// The immutable plan for uninstalling one application: the app bundle plus
/// every matched data directory/file the user confirmed.
public struct AppUninstallPlan: Hashable, Sendable {
    public let id: UUID
    public let application: InstalledApplication
    public let items: [UninstallItem]

    public init(
        id: UUID = UUID(),
        application: InstalledApplication,
        items: [UninstallItem]
    ) {
        self.id = id
        self.application = application
        self.items = items
    }

    public var estimatedBytes: UInt64 {
        items.reduce(UInt64(0)) { total, item in
            let (sum, overflow) = total.addingReportingOverflow(item.sizeBytes)
            return overflow ? UInt64.max : sum
        }
    }
}

public enum UninstallGateError: Error, Equatable, CustomStringConvertible {
    /// The application is running; it must be quit before it can be uninstalled.
    case applicationIsRunning
    /// The application is a macOS system application and cannot be uninstalled.
    case systemApplication
    /// The application bundle no longer exists at its inventory location.
    case applicationBundleMissing

    public var description: String {
        switch self {
        case .applicationIsRunning:
            return "应用正在运行，请先退出后再卸载"
        case .systemApplication:
            return "这是 macOS 系统应用，无法卸载"
        case .applicationBundleMissing:
            return "应用本体已不存在"
        }
    }
}

public struct UninstallItemResult: Hashable, Sendable {
    public let itemID: UUID
    public let status: CleanupItemStatus

    public init(itemID: UUID, status: CleanupItemStatus) {
        self.itemID = itemID
        self.status = status
    }
}

public struct UninstallResult: Hashable, Sendable {
    public let planID: UUID
    public let items: [UninstallItemResult]

    public init(planID: UUID, items: [UninstallItemResult]) {
        self.planID = planID
        self.items = items
    }
}

public protocol AppUninstalling: Sendable {
    /// Builds the uninstall plan for an installed application: the app bundle
    /// plus every data directory/file that matches the application's bundle ID
    /// or display name under the user Library data roots. Throws
    /// UninstallGateError when the application is a system application or no
    /// longer exists. Running applications are still planned — the caller
    /// decides whether to quit them before execute.
    func plan(for application: InstalledApplication) async throws -> AppUninstallPlan
    /// Moves every planned item into the trash. Throws
    /// UninstallGateError.applicationIsRunning when the application is still
    /// running (the caller should quit it first via ApplicationQuitting).
    func execute(_ plan: AppUninstallPlan) async throws -> UninstallResult
}

/// Plans and executes application uninstalls.
///
/// Planning is intentionally conservative: only direct children of each data
/// root are inspected. Exact matches (name or bundle ID, case/punctuation
/// normalized) always win; for Application Support / Caches / Logs, a
/// one-directional containment match additionally accepts directories that are
/// a core word of the display name (e.g. "Google" for Google Chrome, "Code"
/// for Visual Studio Code) or that embed the full normalized bundle ID (e.g.
/// "com.google.Chrome.ShipIt"). Reverse containment is never used, so a short
/// app name like "Pro" cannot pull in an unrelated "Profiles" directory. Every
/// matched item is a checkbox the user confirms before anything is moved.
///
/// Execution reuses the existing CleanupExecutor move-to-trash path: every
/// item is re-validated against a dedicated SafePathValidator, its identity
/// is re-checked via descriptor + fingerprint, and it lands in the user's
/// trash (recoverable), never a permanent delete.
public actor SystemAppUninstaller: AppUninstalling {
    private let libraryRoot: URL
    private let inventory: any ApplicationInventoryProviding
    private let executor: any CleanupExecuting
    private let fingerprinter: any FileFingerprinting
    private let directorySizer: any DirectorySizing
    private let now: @Sendable () -> Date

    public init(
        libraryRoot: URL,
        inventory: any ApplicationInventoryProviding,
        executor: any CleanupExecuting,
        fingerprinter: any FileFingerprinting = SystemFileFingerprinter(),
        directorySizer: any DirectorySizing = DirectorySizer(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.libraryRoot = libraryRoot
        self.inventory = inventory
        self.executor = executor
        self.fingerprinter = fingerprinter
        self.directorySizer = directorySizer
        self.now = now
    }

    public func plan(for application: InstalledApplication) async throws -> AppUninstallPlan {
        try Self.gate(application)

        var plannedItems: [UninstallItem] = []
        if let bundleItem = try await bundleItem(for: application) {
            plannedItems.append(bundleItem)
        }
        if plannedItems.isEmpty {
            throw UninstallGateError.applicationBundleMissing
        }

        for root in Self.dataRoots {
            try Task.checkCancellation()
            plannedItems += try await dataItems(in: root, application: application)
        }

        return AppUninstallPlan(application: application, items: plannedItems)
    }

    public func execute(_ plan: AppUninstallPlan) async throws -> UninstallResult {
        let latestInventory = try await inventory.inventory()
        if latestInventory.runningBundleIDs.contains(plan.application.bundleID) {
            throw UninstallGateError.applicationIsRunning
        }

        let cleanupPlan = CleanupPlan(
            id: UUID(),
            createdAt: now(),
            items: plan.items.map {
                CleanupPlanItem(
                    candidateID: $0.id,
                    canonicalURL: $0.url,
                    expectedFingerprint: $0.fingerprint,
                    action: .moveToTrash,
                    estimatedBytes: $0.sizeBytes
                )
            }
        )
        let result = await executor.execute(cleanupPlan)
        return UninstallResult(
            planID: plan.id,
            items: result.items.map {
                UninstallItemResult(itemID: $0.candidateID, status: $0.status)
            }
        )
    }

    /// Only bundles under /System are SIP-protected system applications and
    /// never uninstalled. Apple's user-installable apps that ship in
    /// /Applications — Xcode (com.apple.dt.Xcode), Final Cut, Pages, ... — are
    /// listable and uninstallable; the few SIP-protected stragglers still in
    /// /Applications fail gracefully at move time. Running applications are
    /// planned like any other; the UI quits them (ApplicationQuitting) and
    /// execute() re-checks that the process is gone before moving anything.
    private static func gate(_ application: InstalledApplication) throws {
        if application.url.path.hasPrefix("/System/") {
            throw UninstallGateError.systemApplication
        }
    }

    private func bundleItem(
        for application: InstalledApplication
    ) async throws -> UninstallItem? {
        let url = application.url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        // A bundle that cannot be fingerprinted (vanished, unreadable) is
        // skipped rather than aborting the whole plan.
        return (try? await uninstallItem(at: url, role: .appBundle)) ?? nil
    }

    private func dataItems(
        in root: DataRoot,
        application: InstalledApplication
    ) async throws -> [UninstallItem] {
        let rootURL = libraryRoot.appending(
            path: root.directoryName,
            directoryHint: .isDirectory
        )
        guard FileManager.default.fileExists(atPath: rootURL.path) else {
            return []
        }

        let children = try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }

        var items: [UninstallItem] = []
        for child in children {
            try Task.checkCancellation()
            guard root.matches(child.lastPathComponent, application: application) else {
                continue
            }
            let values = try? child.resourceValues(
                forKeys: [.isSymbolicLinkKey, .isAliasFileKey]
            )
            guard values?.isSymbolicLink != true, values?.isAliasFile != true else {
                // Symlinks/aliases are never moved: their target may live
                // outside the validated roots.
                continue
            }
            // A single child that cannot be fingerprinted or sized (vanished,
            // unreadable, huge) must not abort the whole plan; it is skipped.
            if let item = (try? await uninstallItem(at: child, role: root.role)) ?? nil {
                items.append(item)
            }
        }
        return items
    }

    private func uninstallItem(
        at url: URL,
        role: UninstallItemRole
    ) async throws -> UninstallItem? {
        let fingerprint = try fingerprinter.fingerprint(at: url)
        let size = (await sizeWithTimeout(of: url)) ?? 0
        let finalFingerprint = try fingerprinter.fingerprint(at: url)
        guard Self.sameObject(fingerprint, finalFingerprint) else {
            // The object was replaced while it was being sized; do not plan it.
            return nil
        }
        return UninstallItem(
            id: UUID(),
            role: role,
            url: url.standardizedFileURL,
            displayName: url.lastPathComponent,
            sizeBytes: size,
            fingerprint: fingerprint
        )
    }

    /// Object identity (device + inode) is what matters for a later trash move.
    /// A directory whose contents are actively being written (a running app's
    /// database, cache, ...) changes its own mtime/size constantly, so a full
    /// fingerprint equality check would silently drop real data directories.
    private static func sameObject(
        _ first: FileFingerprint,
        _ second: FileFingerprint
    ) -> Bool {
        first.deviceID == second.deviceID && first.fileID == second.fileID
    }

    /// Sizes a directory with a bounded timeout. Huge data directories (chat
    /// histories, developer device support, ...) can take a long time to walk;
    /// a failure or timeout keeps the item in the plan with a size of zero
    /// instead of aborting the whole uninstall plan. The trash move itself
    /// does not need the size.
    private func sizeWithTimeout(of url: URL) async -> UInt64? {
        let sizer = directorySizer
        return await withTaskGroup(of: UInt64?.self) { group in
            group.addTask {
                try? await sizer.size(of: url)
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(30))
                return nil
            }
            defer { group.cancelAll() }
            return await group.next() ?? nil
        }
    }
}

private struct DataRoot: Sendable {
    let role: UninstallItemRole
    let directoryName: String
    let rules: [UninstallMatchRule]

    func matches(_ childName: String, application: InstalledApplication) -> Bool {
        rules.contains { $0.matches(childName, application: application) }
    }
}

private enum UninstallMatchRule: Sendable {
    case bundleID
    case displayName
    /// The child is a core word of the display name (e.g. "Google" inside
    /// "Google Chrome", "Code" inside "Visual Studio Code"). One-directional:
    /// only the app name containing the child name is accepted, never the
    /// reverse, so an app named "Pro" can never pull in an unrelated "Profiles".
    case displayNameCore
    /// The child embeds the full normalized bundle ID (e.g.
    /// "com.microsoft.VSCode.ShipIt" embeds "com.microsoft.VSCode"). A length
    /// floor keeps short bundle IDs from matching unrelated children.
    case bundleIDCore
    case bundleIDFile(extension: String)
    case displayNameFile(extension: String)
    case savedState
    case groupContainer

    func matches(_ childName: String, application: InstalledApplication) -> Bool {
        let bundleID = application.bundleID
        let displayName = application.name
        switch self {
        case .bundleID:
            return childName == bundleID
                || Self.normalize(childName) == Self.normalize(bundleID)
        case .displayName:
            return childName == displayName
                || Self.normalize(childName) == Self.normalize(displayName)
        case .displayNameCore:
            let normalizedChild = Self.normalize(childName)
            let normalizedAppName = Self.normalize(displayName)
            return normalizedChild.count >= 3
                && !normalizedChild.isEmpty
                && normalizedAppName.contains(normalizedChild)
        case .bundleIDCore:
            let normalizedChild = Self.normalize(childName)
            let normalizedBundleID = Self.normalize(bundleID)
            return normalizedBundleID.count >= 8
                && !normalizedChild.isEmpty
                && normalizedChild.contains(normalizedBundleID)
        case .bundleIDFile(let fileExtension):
            return Self.normalize(childName)
                == Self.normalize(bundleID + "." + fileExtension)
        case .displayNameFile(let fileExtension):
            return Self.normalize(childName)
                == Self.normalize(displayName + "." + fileExtension)
        case .savedState:
            return childName == bundleID + ".savedState"
                || Self.normalize(childName) == Self.normalize(bundleID + ".savedState")
        case .groupContainer:
            // Group containers are named either "group.<bundleID>" or
            // "<TeamID>.<bundleID>" (e.g. 5A4RE8SF68.com.tencent.xinWeChat);
            // both embed the full bundle ID, so matching on containment alone
            // (with a length floor) covers both naming schemes.
            let normalizedChild = Self.normalize(childName)
            let normalizedBundleID = Self.normalize(bundleID)
            return normalizedBundleID.count >= 8
                && !normalizedChild.isEmpty
                && normalizedChild.contains(normalizedBundleID)
        }
    }

    static func normalize(_ value: String) -> String {
        ApplicationNameMatcher.normalize(value)
    }
}

private extension SystemAppUninstaller {
    /// The user Library data roots inspected for uninstall items, and how each
    /// child is matched against the application.
    static let dataRoots: [DataRoot] = [
        // Application Support / Caches / Logs also accept containment matches:
        // real apps keep their data under vendor folders ("Google" for Google
        // Chrome) or bundle-ID variants ("com.microsoft.VSCode.ShipIt").
        DataRoot(role: .applicationSupport, directoryName: "Application Support", rules: [.bundleID, .displayName, .displayNameCore, .bundleIDCore]),
        DataRoot(role: .caches, directoryName: "Caches", rules: [.bundleID, .displayName, .displayNameCore, .bundleIDCore]),
        DataRoot(role: .logs, directoryName: "Logs", rules: [.bundleID, .displayName, .displayNameCore, .bundleIDCore]),
        DataRoot(role: .preferences, directoryName: "Preferences", rules: [.bundleIDFile(extension: "plist"), .displayNameFile(extension: "plist")]),
        DataRoot(role: .httpStorages, directoryName: "HTTPStorages", rules: [.bundleID, .bundleIDFile(extension: "binarycookies")]),
        DataRoot(role: .webKit, directoryName: "WebKit", rules: [.bundleID]),
        DataRoot(role: .savedState, directoryName: "Saved Application State", rules: [.savedState]),
        // Containers and Application Scripts also match the app's extension
        // containers (FileProvider / Share / NotificationService extensions
        // have their own bundle IDs that embed the host app's bundle ID).
        DataRoot(role: .containers, directoryName: "Containers", rules: [.bundleID, .bundleIDCore]),
        DataRoot(role: .groupContainers, directoryName: "Group Containers", rules: [.groupContainer]),
        DataRoot(role: .applicationScripts, directoryName: "Application Scripts", rules: [.bundleID, .bundleIDCore]),
        DataRoot(role: .launchAgents, directoryName: "LaunchAgents", rules: [.bundleIDFile(extension: "plist"), .displayNameFile(extension: "plist")]),
        // Developer tools keep most of their data under ~/Library/Developer
        // (e.g. Xcode's DerivedData/UserData/DeviceSupport), matched by the
        // exact tool display name.
        DataRoot(role: .developerData, directoryName: "Developer", rules: [.displayName, .displayNameCore])
    ]
}
