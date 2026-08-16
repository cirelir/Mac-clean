import Foundation
import Testing
@testable import CleanCore

@Test func uninstallerPlansBundleAndCoreDataItems() async throws {
    let fixture = try UninstallFixture()
    defer { fixture.cleanup() }

    let appURL = fixture.makeAppBundle()
    fixture.makeDirectoryData(at: "Application Support/com.example.Foo", payload: [0x01, 0x02])
    fixture.makeDirectoryData(at: "Caches/Foo", payload: [0x03])
    fixture.makeFileData(at: "Preferences/com.example.Foo.plist", payload: [0x04, 0x05, 0x06])
    // Unrelated data that must never be planned.
    fixture.makeDirectoryData(at: "Application Support/com.apple.other", payload: [0x07])
    fixture.makeDirectoryData(at: "Application Support/Other App", payload: [0x08])
    fixture.makeFileData(at: "Preferences/com.example.Other.plist", payload: [0x09])

    let app = fixture.application(url: appURL)
    let plan = try await fixture.uninstaller.plan(for: app)

    #expect(plan.items.count == 4)
    #expect(Set(plan.items.map(\.role)) == [.appBundle, .applicationSupport, .caches, .preferences])
    #expect(plan.items.first { $0.role == .appBundle }?.url.path == appURL.path)
    #expect(plan.items.first { $0.role == .caches }?.displayName == "Foo")
    #expect(plan.items.first { $0.role == .preferences }?.displayName == "com.example.Foo.plist")
    #expect(plan.items.allSatisfy { $0.sizeBytes > 0 })
    #expect(plan.estimatedBytes > 0)
}

@Test func uninstallerPlansExtendedRolesAndNormalizedNameVariants() async throws {
    let fixture = try UninstallFixture()
    defer { fixture.cleanup() }

    let appURL = fixture.makeAppBundle()
    // HTTPStorages: bundle-ID directory plus its binarycookies file.
    fixture.makeDirectoryData(at: "HTTPStorages/com.example.Foo", payload: [0x0A])
    fixture.makeFileData(at: "HTTPStorages/com.example.Foo.binarycookies", payload: [0x0B])
    fixture.makeDirectoryData(at: "WebKit/com.example.Foo", payload: [0x0C])
    fixture.makeDirectoryData(at: "Saved Application State/com.example.Foo.savedState", payload: [0x0D])
    fixture.makeDirectoryData(at: "Containers/com.example.Foo", payload: [0x0E])
    fixture.makeDirectoryData(at: "Group Containers/group.com.example.Foo", payload: [0x0F])
    fixture.makeDirectoryData(at: "Application Scripts/com.example.Foo", payload: [0x10])
    fixture.makeFileData(at: "LaunchAgents/com.example.Foo.plist", payload: [0x11])
    // Punctuation-normalized display name: "Kimi Desktop" matches "kimi-desktop".
    fixture.makeDirectoryData(at: "Caches/kimi-desktop", payload: [0x12])
    fixture.makeDirectoryData(at: "Application Support/Kimi Desktop", payload: [0x13])
    // Group containers of other apps and other LaunchAgents are not matched.
    fixture.makeDirectoryData(at: "Group Containers/group.other.app", payload: [0x14])
    fixture.makeFileData(at: "LaunchAgents/com.other.App.plist", payload: [0x15])

    let app = InstalledApplication(
        name: "Kimi Desktop",
        bundleID: "com.example.Foo",
        url: appURL
    )
    let plan = try await fixture.uninstaller.plan(for: app)

    #expect(plan.items.count == 11) // app bundle + 10 data items
    #expect(plan.items.map(\.role).filter { $0 == .httpStorages }.count == 2)
    #expect(plan.items.contains { $0.role == .groupContainers && $0.displayName == "group.com.example.Foo" })
    #expect(plan.items.contains { $0.role == .launchAgents && $0.displayName == "com.example.Foo.plist" })
    #expect(plan.items.contains { $0.role == .caches && $0.displayName == "kimi-desktop" })
    #expect(plan.items.contains { $0.role == .applicationSupport && $0.displayName == "Kimi Desktop" })
    #expect(!plan.items.contains { $0.displayName == "group.other.app" })
    #expect(!plan.items.contains { $0.displayName == "com.other.App.plist" })
}

@Test func uninstallerPlansRunningApplications() async throws {
    let fixture = try UninstallFixture(runningBundleIDs: ["com.example.Foo"])
    defer { fixture.cleanup() }
    let appURL = fixture.makeAppBundle()
    fixture.makeDirectoryData(at: "Caches/Foo", payload: [0x05])
    let app = fixture.application(url: appURL)

    // Planning a running application is allowed; the UI quits it first and
    // execute() re-checks that the process is gone before moving anything.
    let plan = try await fixture.uninstaller.plan(for: app)

    #expect(plan.items.count == 2) // app bundle + cache
    #expect(plan.items.contains { $0.role == .appBundle })
}

@Test func uninstallerRefusesSystemApplicationsUnderSystemPath() async throws {
    let fixture = try UninstallFixture()
    defer { fixture.cleanup() }

    let systemPathApp = InstalledApplication(
        name: "Finder",
        bundleID: "com.apple.finder",
        url: URL(fileURLWithPath: "/System/Applications/Finder.app")
    )
    await #expect(throws: UninstallGateError.systemApplication) {
        try await fixture.uninstaller.plan(for: systemPathApp)
    }
}

@Test func uninstallerListsAppleDeveloperApplicationsLikeXcode() async throws {
    let fixture = try UninstallFixture()
    defer { fixture.cleanup() }
    let appURL = fixture.makeAppBundle()
    // Xcode's bundle ID is com.apple.dt.Xcode, but the bundle sits in
    // /Applications and is user-installable: it must be listable.
    fixture.makeDirectoryData(at: "Developer/Xcode", payload: [0x30])
    fixture.makeFileData(at: "Preferences/com.apple.dt.Xcode.plist", payload: [0x31])
    let app = InstalledApplication(
        name: "Xcode",
        bundleID: "com.apple.dt.Xcode",
        url: appURL
    )

    let plan = try await fixture.uninstaller.plan(for: app)

    #expect(plan.items.contains { $0.role == .appBundle })
    #expect(plan.items.contains { $0.role == .developerData && $0.displayName == "Xcode" })
    #expect(plan.items.contains { $0.role == .preferences && $0.displayName == "com.apple.dt.Xcode.plist" })
}

@Test func uninstallerThrowsWhenBundleAndDataAreMissing() async throws {
    let fixture = try UninstallFixture()
    defer { fixture.cleanup() }
    let missingURL = fixture.appsDir.appending(path: "Gone.app", directoryHint: .isDirectory)
    let app = fixture.application(url: missingURL)

    await #expect(throws: UninstallGateError.applicationBundleMissing) {
        try await fixture.uninstaller.plan(for: app)
    }
}

@Test func uninstallerSkipsSymbolicLinkChildren() async throws {
    let fixture = try UninstallFixture()
    defer { fixture.cleanup() }
    let appURL = fixture.makeAppBundle()
    let realTarget = fixture.home.appending(path: "elsewhere", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: realTarget, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        at: fixture.library.appending(path: "Application Support/com.example.Foo"),
        withDestinationURL: realTarget
    )
    let app = fixture.application(url: appURL)

    let plan = try await fixture.uninstaller.plan(for: app)

    #expect(plan.items.map(\.role) == [.appBundle])
}

@Test func uninstallerMovesBundlesDirectoriesAndFilesIntoTrash() async throws {
    let fixture = try UninstallFixture()
    defer { fixture.cleanup() }
    let appURL = fixture.makeAppBundle()
    let supportURL = fixture.makeDirectoryData(at: "Application Support/com.example.Foo", payload: [0x01, 0x02])
    let plistURL = fixture.makeFileData(at: "Preferences/com.example.Foo.plist", payload: [0x03])
    let unrelatedURL = fixture.makeDirectoryData(at: "Application Support/Other App", payload: [0x04])
    let app = fixture.application(url: appURL)
    let plan = try await fixture.uninstaller.plan(for: app)

    let result = try await fixture.uninstaller.execute(plan)

    #expect(result.planID == plan.id)
    #expect(result.items.count == plan.items.count)
    #expect(result.items.allSatisfy {
        if case .success = $0.status { return true }
        return false
    })
    #expect(!FileManager.default.fileExists(atPath: appURL.path))
    #expect(!FileManager.default.fileExists(atPath: supportURL.path))
    #expect(!FileManager.default.fileExists(atPath: plistURL.path))
    #expect(FileManager.default.fileExists(atPath: fixture.trash.appending(path: "Foo.app").path))
    #expect(FileManager.default.fileExists(atPath: fixture.trash.appending(path: "com.example.Foo").path))
    #expect(FileManager.default.fileExists(atPath: fixture.trash.appending(path: "com.example.Foo.plist").path))
    // Unrelated data is untouched.
    #expect(FileManager.default.fileExists(atPath: unrelatedURL.path))
}

@Test func uninstallerRefusesExecutionWhenApplicationStartedRunning() async throws {
    let fixture = try UninstallFixture()
    defer { fixture.cleanup() }
    let appURL = fixture.makeAppBundle()
    fixture.makeDirectoryData(at: "Caches/Foo", payload: [0x05])
    let app = fixture.application(url: appURL)
    let plan = try await fixture.uninstaller.plan(for: app)

    await fixture.setRunning(["com.example.Foo"])
    await #expect(throws: UninstallGateError.applicationIsRunning) {
        try await fixture.uninstaller.execute(plan)
    }
    #expect(FileManager.default.fileExists(atPath: appURL.path))
}

private final class UninstallFixture {
    let home: URL
    let library: URL
    let appsDir: URL
    let trash: URL
    let inventoryProvider: MutableUninstallInventoryProvider
    let uninstaller: SystemAppUninstaller

    init(
        runningBundleIDs: Set<String> = [],
        directorySizer: any DirectorySizing = DirectorySizer(),
        fingerprinter: any FileFingerprinting = SystemFileFingerprinter()
    ) throws {
        home = try makeTemporaryDirectory()
        library = home.appending(path: "Library", directoryHint: .isDirectory)
        appsDir = try makeTemporaryDirectory()
        trash = try makeTemporaryDirectory()
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        for directory in [
            "Application Support", "Caches", "Logs", "Preferences",
            "HTTPStorages", "WebKit", "Saved Application State",
            "Containers", "Group Containers", "Application Scripts", "LaunchAgents"
        ] {
            try FileManager.default.createDirectory(
                at: library.appending(path: directory, directoryHint: .isDirectory),
                withIntermediateDirectories: true
            )
        }

        let roots = [
            library.appending(path: "Application Support", directoryHint: .isDirectory),
            library.appending(path: "Caches", directoryHint: .isDirectory),
            library.appending(path: "Logs", directoryHint: .isDirectory),
            library.appending(path: "Preferences", directoryHint: .isDirectory),
            library.appending(path: "HTTPStorages", directoryHint: .isDirectory),
            library.appending(path: "WebKit", directoryHint: .isDirectory),
            library.appending(path: "Saved Application State", directoryHint: .isDirectory),
            library.appending(path: "Containers", directoryHint: .isDirectory),
            library.appending(path: "Group Containers", directoryHint: .isDirectory),
            library.appending(path: "Application Scripts", directoryHint: .isDirectory),
            library.appending(path: "LaunchAgents", directoryHint: .isDirectory),
            appsDir
        ]
        let forbidden = [URL(fileURLWithPath: "/", isDirectory: true), home] + roots
        let validator = SafePathValidator(allowedRoots: roots, forbiddenExactPaths: Set(forbidden))
        let executor = CleanupExecutor(
            validator: validator,
            fingerprinter: fingerprinter,
            fileManager: .default,
            hooks: CleanupExecutionHooks(),
            trashDirectory: trash
        )
        inventoryProvider = MutableUninstallInventoryProvider(runningBundleIDs: runningBundleIDs)
        uninstaller = SystemAppUninstaller(
            libraryRoot: library,
            inventory: inventoryProvider,
            executor: executor,
            fingerprinter: fingerprinter,
            directorySizer: directorySizer
        )
    }

    func application(url: URL) -> InstalledApplication {
        InstalledApplication(name: "Foo", bundleID: "com.example.Foo", url: url)
    }

    @discardableResult
    func makeAppBundle() -> URL {
        let url = appsDir.appending(path: "Foo.app", directoryHint: .isDirectory)
        try! FileManager.default.createDirectory(
            at: url.appending(path: "Contents", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try! Data([0x41]).write(to: url.appending(path: "Contents/Info.plist"))
        return url
    }

    @discardableResult
    func makeDirectoryData(at relativePath: String, payload: [UInt8]) -> URL {
        let url = library.appending(path: relativePath, directoryHint: .isDirectory)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try! Data(payload).write(to: url.appending(path: "data.bin"))
        return url
    }

    @discardableResult
    func makeFileData(at relativePath: String, payload: [UInt8]) -> URL {
        let url = library.appending(path: relativePath)
        try! Data(payload).write(to: url)
        return url
    }

    func setRunning(_ bundleIDs: Set<String>) async {
        await inventoryProvider.setRunning(bundleIDs)
    }

    func cleanup() {
        for url in [home, appsDir, trash] {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

actor MutableUninstallInventoryProvider: ApplicationInventoryProviding {
    private var inventory: ApplicationInventory

    init(runningBundleIDs: Set<String>) {
        inventory = ApplicationInventory(
            installedApplications: [
                InstalledApplication(
                    name: "Foo",
                    bundleID: "com.example.Foo",
                    url: URL(fileURLWithPath: "/tmp/Foo.app")
                )
            ],
            runningBundleIDs: runningBundleIDs
        )
    }

    func setRunning(_ bundleIDs: Set<String>) {
        inventory = ApplicationInventory(
            installedApplications: inventory.installedApplications,
            runningBundleIDs: bundleIDs
        )
    }

    func inventory() async throws -> ApplicationInventory {
        inventory
    }
}

private func makeTemporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
@Test func uninstallerMatchesVendorAndBundleIDVariantDataDirectories() async throws {
    let fixture = try UninstallFixture()
    defer { fixture.cleanup() }
    let appURL = fixture.makeAppBundle()
    // Vendor folder: "Google" is the core word of "Google Chrome".
    fixture.makeDirectoryData(at: "Application Support/Google", payload: [0x21])
    fixture.makeDirectoryData(at: "Caches/Google", payload: [0x22])
    // Bundle-ID variant: the ShipIt updater embeds the full bundle ID.
    fixture.makeDirectoryData(at: "Caches/com.google.Chrome.ShipIt", payload: [0x23])
    // Unrelated data must not be pulled in by containment.
    fixture.makeDirectoryData(at: "Application Support/Profiles", payload: [0x24])
    let app = InstalledApplication(
        name: "Google Chrome",
        bundleID: "com.google.Chrome",
        url: appURL
    )

    let plan = try await fixture.uninstaller.plan(for: app)

    #expect(plan.items.contains { $0.role == .applicationSupport && $0.displayName == "Google" })
    #expect(plan.items.contains { $0.role == .caches && $0.displayName == "Google" })
    #expect(plan.items.contains { $0.role == .caches && $0.displayName == "com.google.Chrome.ShipIt" })
    #expect(!plan.items.contains { $0.displayName == "Profiles" })
}

@Test func uninstallerMatchesShortCoreWordDataDirectories() async throws {
    let fixture = try UninstallFixture()
    defer { fixture.cleanup() }
    let appURL = fixture.makeAppBundle()
    // "Code" is a 4-character core word of "Visual Studio Code".
    fixture.makeDirectoryData(at: "Application Support/Code", payload: [0x25])
    fixture.makeDirectoryData(at: "Logs/Code", payload: [0x26])
    let app = InstalledApplication(
        name: "Visual Studio Code",
        bundleID: "com.microsoft.VSCode",
        url: appURL
    )

    let plan = try await fixture.uninstaller.plan(for: app)

    #expect(plan.items.contains { $0.role == .applicationSupport && $0.displayName == "Code" })
    #expect(plan.items.contains { $0.role == .logs && $0.displayName == "Code" })
}

@Test func uninstallerNeverMatchesByReverseContainment() async throws {
    let fixture = try UninstallFixture()
    defer { fixture.cleanup() }
    let appURL = fixture.makeAppBundle()
    // App "Pro" must never pull in an unrelated "Profiles" directory:
    // containment is one-directional (child is a core word of the app name).
    fixture.makeDirectoryData(at: "Application Support/Profiles", payload: [0x27])
    let app = InstalledApplication(
        name: "Pro",
        bundleID: "com.example.Pro",
        url: appURL
    )

    let plan = try await fixture.uninstaller.plan(for: app)

    #expect(plan.items.map(\.role) == [.appBundle])
}

@Test func uninstallerAllowsLibraryInputMethodsBundles() async throws {
    let fixture = try UninstallFixture()
    defer { fixture.cleanup() }
    // A deliberately non-existent bundle under /Library/Input Methods: the
    // gate must not reject a /Library path before the missing-bundle check.
    let missingURL = URL(
        fileURLWithPath: "/Library/Input Methods/__mac-clean-tests-"
            + UUID().uuidString + ".app"
    )
    let app = InstalledApplication(
        name: "Sogou Input",
        bundleID: "com.sogou.inputmethod.sogou",
        url: missingURL
    )

    // The gate must not reject a /Library bundle: the failure must be the
    // missing bundle, not UninstallGateError.systemApplication.
    await #expect(throws: UninstallGateError.applicationBundleMissing) {
        try await fixture.uninstaller.plan(for: app)
    }
}
// MARK: - WeChat-style data (team-ID group containers, extension containers,
// actively-written directories, huge/unreadable directories)

@Test func uninstallerMatchesTeamIDGroupContainers() async throws {
    let fixture = try UninstallFixture()
    defer { fixture.cleanup() }
    let appURL = fixture.makeAppBundle()
    // WeChat's group container uses the Team ID prefix, not "group.".
    fixture.makeDirectoryData(at: "Group Containers/5A4RE8SF68.com.tencent.xinWeChat", payload: [0x40])
    fixture.makeDirectoryData(at: "Group Containers/group.com.tencent.xinWeChat", payload: [0x41])
    fixture.makeDirectoryData(at: "Group Containers/5A4RE8SF68.com.other.app", payload: [0x42])
    let app = InstalledApplication(
        name: "WeChat",
        bundleID: "com.tencent.xinWeChat",
        url: appURL
    )

    let plan = try await fixture.uninstaller.plan(for: app)

    #expect(plan.items.contains { $0.role == .groupContainers && $0.displayName == "5A4RE8SF68.com.tencent.xinWeChat" })
    #expect(plan.items.contains { $0.role == .groupContainers && $0.displayName == "group.com.tencent.xinWeChat" })
    #expect(!plan.items.contains { $0.displayName == "5A4RE8SF68.com.other.app" })
}

@Test func uninstallerMatchesExtensionContainers() async throws {
    let fixture = try UninstallFixture()
    defer { fixture.cleanup() }
    let appURL = fixture.makeAppBundle()
    // FileProvider / Share extensions have their own bundle IDs that embed
    // the host app's bundle ID; their containers and scripts are uninstalled
    // together with the host.
    fixture.makeDirectoryData(at: "Containers/com.tencent.xinWeChat", payload: [0x43])
    fixture.makeDirectoryData(at: "Containers/com.tencent.xinWeChat.WeChatFileProviderExtension", payload: [0x44])
    fixture.makeDirectoryData(at: "Containers/com.tencent.xinWeChat.WeChatMacShare", payload: [0x45])
    fixture.makeDirectoryData(at: "Application Scripts/com.tencent.xinWeChat.WeChatMacShare", payload: [0x46])
    fixture.makeDirectoryData(at: "Containers/com.other.app", payload: [0x47])
    let app = InstalledApplication(
        name: "WeChat",
        bundleID: "com.tencent.xinWeChat",
        url: appURL
    )

    let plan = try await fixture.uninstaller.plan(for: app)

    #expect(plan.items.contains { $0.role == .containers && $0.displayName == "com.tencent.xinWeChat" })
    #expect(plan.items.contains { $0.role == .containers && $0.displayName == "com.tencent.xinWeChat.WeChatFileProviderExtension" })
    #expect(plan.items.contains { $0.role == .containers && $0.displayName == "com.tencent.xinWeChat.WeChatMacShare" })
    #expect(plan.items.contains { $0.role == .applicationScripts && $0.displayName == "com.tencent.xinWeChat.WeChatMacShare" })
    #expect(!plan.items.contains { $0.displayName == "com.other.app" })
}

@Test func uninstallerKeepsItemWhenSizingFails() async throws {
    let fixture = try UninstallFixture(
        directorySizer: FailingDirectorySizer(failingName: "com.tencent.xinWeChat")
    )
    defer { fixture.cleanup() }
    let appURL = fixture.makeAppBundle()
    // Every directory whose last path component matches the failing name
    // throws while being sized.
    fixture.makeDirectoryData(at: "Containers/com.tencent.xinWeChat", payload: [0x48])
    fixture.makeDirectoryData(at: "Caches/com.tencent.xinWeChat", payload: [0x49])
    let app = InstalledApplication(
        name: "WeChat",
        bundleID: "com.tencent.xinWeChat",
        url: appURL
    )

    // The huge/unreadable directories must not abort the plan: they stay
    // listed with a size of zero and the rest of the plan still completes.
    let plan = try await fixture.uninstaller.plan(for: app)

    let wechatContainer = plan.items.first { $0.role == .containers }
    #expect(wechatContainer != nil)
    #expect(wechatContainer?.sizeBytes == 0)
    let wechatCache = plan.items.first { $0.role == .caches }
    #expect(wechatCache != nil)
    #expect(wechatCache?.sizeBytes == 0)
    #expect(plan.items.contains { $0.role == .appBundle })
}

@Test func uninstallerKeepsItemWhenDirectoryChangesDuringSizing() async throws {
    let fixture = try UninstallFixture(
        fingerprinter: MutatingFingerprinter()
    )
    defer { fixture.cleanup() }
    let appURL = fixture.makeAppBundle()
    fixture.makeDirectoryData(at: "Containers/com.tencent.xinWeChat", payload: [0x4A])
    let app = InstalledApplication(
        name: "WeChat",
        bundleID: "com.tencent.xinWeChat",
        url: appURL
    )

    // A running app keeps writing its data directory; only the directory
    // identity (device + inode) is required, not a full fingerprint match.
    let plan = try await fixture.uninstaller.plan(for: app)

    #expect(plan.items.contains { $0.role == .containers && $0.displayName == "com.tencent.xinWeChat" })
}

private struct FailingDirectorySizer: DirectorySizing {
    let failingName: String

    func size(of url: URL) async throws -> UInt64 {
        if url.lastPathComponent == failingName {
            throw DirectorySizingError.cannotEnumerate(url)
        }
        return 512
    }
}

/// Returns a different modifiedAt on every call (same device/inode), like a
/// directory that is actively written while being sized.
private final class MutatingFingerprinter: FileFingerprinting, @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0

    func fingerprint(at url: URL) throws -> FileFingerprint {
        lock.lock()
        defer { lock.unlock() }
        callCount += 1
        return FileFingerprint(
            deviceID: 42,
            fileID: 7,
            ownerID: 501,
            sizeBytes: 1024,
            modifiedAt: Date(
                timeIntervalSince1970: 1_700_000_000 + Double(callCount)
            )
        )
    }
}
