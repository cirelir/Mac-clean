# Mac Clean Foundation MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a runnable native macOS menu-bar MVP that safely scans application caches, classifies candidates, supports Finder source tracing, cleans only validated green candidates, records local audit history, and evaluates weekly catch-up scans while running.

**Architecture:** A Swift Package separates a platform-neutral `CleanCore` library from a `MacCleanUI` SwiftUI library and a thin `MacCleanApp` executable. Scanners only discover evidence, `RiskClassifier` decides policy, `CleanupPlanner` creates immutable plans, and `CleanupExecutor` is the only component allowed to change files. Platform services are injected behind protocols so path safety, scanning, Finder reveal, persistence, scheduling, and notifications can be tested independently.

**Tech Stack:** Swift 6.3, macOS 14+, Swift Package Manager, SwiftUI, AppKit, Observation, SwiftData, UserNotifications, Swift Testing

## Global Constraints

- Support macOS 14 and later.
- Produce no network traffic and include no third-party runtime dependencies.
- Never inspect or delete user documents, downloads, photos, music, or project workspaces.
- Never infer unused dependencies from last-access time.
- Never automatically clean caches belonging to a running application.
- Normalize paths, resolve symbolic links, enforce component-level allowed-root containment, and revalidate file identity immediately before cleanup.
- Scanners return evidence only; they never delete files.
- The UI never deletes files directly; all mutations pass through `CleanupPlanner` and `CleanupExecutor`.
- Every candidate exposes its source path, scanner, rule, owner, risk reason, and Finder reveal state.
- Green candidates may be automatically cleaned; yellow candidates require confirmation; red candidates are report-only.
- All UI must support light and dark appearances, VoiceOver, keyboard navigation, and at least 4.5:1 text contrast.
- Use test-first development for every behavior and security fix.

## Phase Boundary

This plan produces the first independently runnable product slice: application inventory, application-cache scanning, safe cleanup, Finder reveal, audit history, weekly scheduling, and the confirmed A-style menu UI.

The approved specification has two additional independently reviewable slices:

- Package-manager and developer-tool scanners for Homebrew, npm, pip, Cargo, Xcode DerivedData, and unavailable simulators.
- Privileged XPC Helper, Full Disk Access onboarding, login-item registration for true background launch, Xcode application project, hardened runtime, universal archive, Developer ID signing, notarization, stapling, and `.dmg` distribution.

Those slices receive their own implementation plans after this MVP passes its acceptance checks.

## File Structure

```text
Package.swift                                  Swift package manifest and target boundaries
Sources/CleanCore/Models/CleanupCandidate.swift Candidate, evidence, risk, action, fingerprint models
Sources/CleanCore/Models/ApplicationInventory.swift Installed and running application model
Sources/CleanCore/Paths/SafePathValidator.swift Canonicalization and allowed-root enforcement
Sources/CleanCore/Paths/FileFingerprinting.swift Stable precondition fingerprint capture
Sources/CleanCore/Risk/RiskClassifier.swift      Evidence-to-risk policy
Sources/CleanCore/Scanning/Scanner.swift         Scanner protocol and scan context
Sources/CleanCore/Scanning/ApplicationInventoryProvider.swift System application inventory
Sources/CleanCore/Scanning/DirectorySizer.swift  Cancellation-aware directory sizing
Sources/CleanCore/Scanning/ApplicationCacheScanner.swift Application cache discovery
Sources/CleanCore/Scanning/ScanCoordinator.swift Scanner orchestration and partial failures
Sources/CleanCore/Cleanup/CleanupPlanner.swift    Immutable cleanup plan creation
Sources/CleanCore/Cleanup/CleanupExecutor.swift   Revalidated cache-content deletion
Sources/CleanCore/Audit/AuditRecord.swift         Value-type audit contract
Sources/MacCleanUI/App/AppModel.swift             Main-actor UI state and commands
Sources/MacCleanUI/App/LiveDependencies.swift     Production dependency composition
Sources/MacCleanUI/Finder/FinderRevealer.swift    NSWorkspace Finder integration
Sources/MacCleanUI/Persistence/SwiftDataAuditStore.swift Local audit persistence
Sources/MacCleanUI/Scheduling/WeeklyScanScheduler.swift Weekly due-date policy
Sources/MacCleanUI/Scheduling/NotificationService.swift User notification adapter
Sources/MacCleanUI/Views/MenuBarRootView.swift    Confirmed compact menu popover
Sources/MacCleanUI/Views/DetailView.swift         Grouped candidate list and actions
Sources/MacCleanUI/Views/CandidateRow.swift       Evidence, risk, and Finder row UI
Sources/MacCleanApp/MacCleanApp.swift             SwiftUI scenes and application entry point
Tests/CleanCoreTests/...                          Core behavior and filesystem integration tests
Tests/CleanCoreTests/Support/CoreTestFixtures.swift Reusable core value fixtures
Tests/MacCleanUITests/...                         UI service and view-model tests
Tests/MacCleanUITests/Support/UITestFixtures.swift Reusable UI fakes and value fixtures
```

---

### Task 1: Swift Package Boundaries and Candidate Contract

**Files:**
- Create: `Package.swift`
- Create: `Sources/CleanCore/Models/CleanupCandidate.swift`
- Create: `Sources/CleanCore/Models/ApplicationInventory.swift`
- Create: `Sources/MacCleanUI/Placeholder.swift`
- Create: `Sources/MacCleanApp/MacCleanApp.swift`
- Test: `Tests/CleanCoreTests/CleanupCandidateTests.swift`
- Test: `Tests/MacCleanUITests/PlaceholderTests.swift`

**Interfaces:**
- Produces: `CleanupCandidate`, `CandidateEvidence`, `CandidateCategory`, `RiskLevel`, `CleanupAction`, `FileFingerprint`, `InstalledApplication`, and `ApplicationInventory`.
- Produces package modules `CleanCore`, `MacCleanUI`, and executable `MacCleanApp` for every later task.

- [ ] **Step 1: Create the package manifest and failing domain test**

```swift
// Package.swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MacClean",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CleanCore", targets: ["CleanCore"]),
        .library(name: "MacCleanUI", targets: ["MacCleanUI"]),
        .executable(name: "MacCleanApp", targets: ["MacCleanApp"])
    ],
    targets: [
        .target(name: "CleanCore"),
        .target(name: "MacCleanUI", dependencies: ["CleanCore"]),
        .executableTarget(name: "MacCleanApp", dependencies: ["MacCleanUI", "CleanCore"]),
        .testTarget(name: "CleanCoreTests", dependencies: ["CleanCore"]),
        .testTarget(name: "MacCleanUITests", dependencies: ["MacCleanUI", "CleanCore"])
    ],
    swiftLanguageModes: [.v6]
)
```

```swift
// Tests/CleanCoreTests/CleanupCandidateTests.swift
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
```

- [ ] **Step 2: Run the test and verify the missing model failure**

Run: `swift test --filter candidateRetainsSourceEvidenceAndFinderURL`

Expected: compilation fails because `CleanupCandidate` and its related types do not exist.

- [ ] **Step 3: Implement the exact value contracts**

```swift
// Sources/CleanCore/Models/CleanupCandidate.swift
import Foundation

public enum CandidateCategory: String, Codable, CaseIterable, Sendable {
    case applicationCache, applicationLog, orphanResidual, packageManager, developerTool, reportOnly
}

public enum RiskLevel: String, Codable, CaseIterable, Sendable {
    case green, yellow, red
}

public enum CleanupAction: String, Codable, Sendable {
    case deleteContentsPreservingRoot, moveToTrash, packageManagerCommand, reportOnly
}

public struct FileFingerprint: Hashable, Codable, Sendable {
    public let deviceID: UInt64
    public let fileID: UInt64
    public let ownerID: UInt32
    public let sizeBytes: UInt64
    public let modifiedAt: Date

    public init(deviceID: UInt64, fileID: UInt64, ownerID: UInt32, sizeBytes: UInt64, modifiedAt: Date) {
        self.deviceID = deviceID
        self.fileID = fileID
        self.ownerID = ownerID
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
    }
}

public struct CandidateEvidence: Hashable, Codable, Sendable {
    public let scannerID: String
    public let ruleID: String
    public let ownerName: String?
    public let ownerBundleID: String?
    public let explanation: String
    public let commandPreview: String?

    public init(scannerID: String, ruleID: String, ownerName: String?, ownerBundleID: String?, explanation: String, commandPreview: String? = nil) {
        self.scannerID = scannerID
        self.ruleID = ruleID
        self.ownerName = ownerName
        self.ownerBundleID = ownerBundleID
        self.explanation = explanation
        self.commandPreview = commandPreview
    }
}

public struct CleanupCandidate: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let displayName: String
    public let category: CandidateCategory
    public let sourceURL: URL
    public let canonicalURL: URL
    public let sizeBytes: UInt64
    public let modifiedAt: Date
    public let fingerprint: FileFingerprint
    public let evidence: CandidateEvidence
    public let risk: RiskLevel
    public let riskReason: String
    public let proposedAction: CleanupAction
}
```

Add explicit public initializers containing every stored property to `CleanupCandidate`, `CandidateEvidence`, `FileFingerprint`, `InstalledApplication`, and `ApplicationInventory`; cross-target UI and test code must not rely on internal memberwise initializers. `ApplicationInventory.swift` defines `InstalledApplication(name:bundleID:url:)` and `ApplicationInventory(installedApplications:runningBundleIDs:)`, both `Hashable`, `Codable`, and `Sendable`. Add a minimal `MacCleanUI.placeholderName == "Mac Clean"` assertion so both library targets compile. The executable initially renders `MenuBarExtra("Mac Clean", systemImage: "externaldrive") { Text("Mac Clean") }`.

- [ ] **Step 4: Run the complete package test suite**

Run: `swift test`

Expected: all domain and placeholder tests pass with zero warnings.

- [ ] **Step 5: Commit the package foundation**

```bash
git add Package.swift Sources Tests
git commit -m "feat: establish Mac Clean package architecture"
```

---

### Task 2: Canonical Path Validation and File Identity

**Files:**
- Create: `Sources/CleanCore/Paths/SafePathValidator.swift`
- Create: `Sources/CleanCore/Paths/FileFingerprinting.swift`
- Test: `Tests/CleanCoreTests/SafePathValidatorTests.swift`
- Test: `Tests/CleanCoreTests/FileFingerprintingTests.swift`

**Interfaces:**
- Consumes: `FileFingerprint` from Task 1.
- Produces: `ValidatedPath`, `PathValidationError`, `SafePathValidator.validate(_:)`, and `FileFingerprinting.fingerprint(at:)`.

- [ ] **Step 1: Write failing traversal and root-rejection tests**

```swift
import Foundation
import Testing
@testable import CleanCore

@Test func rejectsAllowedRootItself() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let validator = SafePathValidator(allowedRoots: [root], forbiddenExactPaths: [])
    #expect(throws: PathValidationError.targetIsAllowedRoot) { try validator.validate(root) }
}

@Test func rejectsSymlinkThatEscapesAllowedRoot() throws {
    let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let root = base.appending(path: "allowed")
    let outside = base.appending(path: "outside")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let link = root.appending(path: "escape")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    let validator = SafePathValidator(allowedRoots: [root], forbiddenExactPaths: [])
    #expect(throws: PathValidationError.outsideAllowedRoots) { try validator.validate(link) }
}
```

- [ ] **Step 2: Verify the security tests fail before implementation**

Run: `swift test --filter SafePathValidatorTests`

Expected: compilation fails because `SafePathValidator` is undefined.

- [ ] **Step 3: Implement component-level containment and `lstat` fingerprints**

```swift
public struct ValidatedPath: Hashable, Sendable {
    public let originalURL: URL
    public let canonicalURL: URL
    public let allowedRoot: URL
}

public enum PathValidationError: Error, Equatable {
    case missingTarget
    case outsideAllowedRoots
    case targetIsAllowedRoot
    case forbiddenTarget
}

public struct SafePathValidator: Sendable {
    public let allowedRoots: [URL]
    public let forbiddenExactPaths: Set<URL>

    public func validate(_ url: URL) throws -> ValidatedPath {
        guard FileManager.default.fileExists(atPath: url.path) else { throw PathValidationError.missingTarget }
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        let roots = allowedRoots.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        guard let root = roots.first(where: { canonical.pathComponents.starts(with: $0.pathComponents) }) else {
            throw PathValidationError.outsideAllowedRoots
        }
        guard canonical != root else { throw PathValidationError.targetIsAllowedRoot }
        guard !forbiddenExactPaths.contains(canonical) else { throw PathValidationError.forbiddenTarget }
        return ValidatedPath(originalURL: url, canonicalURL: canonical, allowedRoot: root)
    }
}
```

`SystemFileFingerprinter` calls Darwin `lstat`, converts `st_dev`, `st_ino`, `st_uid`, `st_size`, and nanosecond modification time into `FileFingerprint`, and throws `FileFingerprintError.unreadable(errno:)` on failure. The test creates a temporary file, fingerprints it, replaces it, and asserts the file ID or modification tuple changes.

```swift
public protocol FileFingerprinting: Sendable {
    func fingerprint(at url: URL) throws -> FileFingerprint
}

public enum FileFingerprintError: Error, Equatable { case unreadable(errno: Int32) }

public struct SystemFileFingerprinter: FileFingerprinting, Sendable {
    public init() {}
    public func fingerprint(at url: URL) throws -> FileFingerprint {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw FileFingerprintError.unreadable(errno: errno) }
        let modified = Date(timeIntervalSince1970: TimeInterval(value.st_mtimespec.tv_sec) + TimeInterval(value.st_mtimespec.tv_nsec) / 1_000_000_000)
        return FileFingerprint(
            deviceID: UInt64(value.st_dev),
            fileID: UInt64(value.st_ino),
            ownerID: value.st_uid,
            sizeBytes: UInt64(max(0, value.st_size)),
            modifiedAt: modified
        )
    }
}
```

- [ ] **Step 4: Run focused and complete tests**

Run: `swift test --filter SafePathValidatorTests && swift test --filter FileFingerprintingTests && swift test`

Expected: all tests pass; the symlink escape and allowed-root target are rejected.

- [ ] **Step 5: Commit path safety**

```bash
git add Sources/CleanCore/Paths Tests/CleanCoreTests
git commit -m "feat: enforce canonical cleanup paths"
```

---

### Task 3: Central Risk Classification

**Files:**
- Create: `Sources/CleanCore/Scanning/Scanner.swift`
- Create: `Sources/CleanCore/Risk/RiskClassifier.swift`
- Create: `Tests/CleanCoreTests/Support/CoreTestFixtures.swift`
- Test: `Tests/CleanCoreTests/RiskClassifierTests.swift`

**Interfaces:**
- Consumes: Task 1 models and Task 2 `ValidatedPath`.
- Produces: `DiscoveredItem`, `DiscoveryKind`, `ScanContext`, `Scanner`, and `RiskClassifier.classify(_:context:)`.

- [ ] **Step 1: Write failing green, yellow, and red policy tests**

```swift
@Test func installedStoppedApplicationCacheIsGreen() throws {
    let item = CoreTestFixtures.cacheDiscovery(ownerBundleID: "com.example.Editor")
    let context = CoreTestFixtures.context(installed: ["com.example.Editor"], running: [])
    #expect(try RiskClassifier().classify(item, context: context).risk == .green)
}

@Test func runningApplicationCacheIsRed() throws {
    let item = CoreTestFixtures.cacheDiscovery(ownerBundleID: "com.example.Editor")
    let context = CoreTestFixtures.context(installed: ["com.example.Editor"], running: ["com.example.Editor"])
    let candidate = try RiskClassifier().classify(item, context: context)
    #expect(candidate.risk == .red)
    #expect(candidate.proposedAction == .reportOnly)
}

@Test func authoritativeOrphanResidualIsYellow() throws {
    let item = CoreTestFixtures.discovery(kind: .orphanResidual(confidence: .authoritative))
    #expect(try RiskClassifier().classify(item, context: CoreTestFixtures.context()).risk == .yellow)
}
```

- [ ] **Step 2: Verify tests fail because the policy layer is absent**

Run: `swift test --filter RiskClassifierTests`

Expected: compilation fails on missing `DiscoveredItem` and `RiskClassifier`.

- [ ] **Step 3: Implement the scanner contract and exhaustive risk switch**

```swift
public enum DiscoveryConfidence: String, Codable, Sendable { case authoritative, inferred, unknown }
public enum DiscoveryKind: Hashable, Codable, Sendable {
    case regenerableApplicationCache
    case rotatableLog(olderThanDays: Int)
    case orphanResidual(confidence: DiscoveryConfidence)
    case authoritativeUnusedDependency
    case unknown
}

public struct DiscoveredItem: Hashable, Sendable {
    public let displayName: String
    public let sourceURL: URL
    public let validatedPath: ValidatedPath
    public let sizeBytes: UInt64
    public let modifiedAt: Date
    public let fingerprint: FileFingerprint
    public let evidence: CandidateEvidence
    public let kind: DiscoveryKind
}

public struct ScanContext: Sendable {
    public let inventory: ApplicationInventory
    public let now: Date
}

public protocol Scanner: Sendable {
    var id: String { get }
    func scan(context: ScanContext) async throws -> [DiscoveredItem]
}
```

`RiskClassifier` uses one exhaustive switch: regenerable cache is green only when the owner Bundle ID is installed and not running; authoritative orphan and unused dependency are yellow; every inferred, unknown, missing-owner, or running-app item is red. It copies the exact evidence and canonical URL into `CleanupCandidate` and assigns `.reportOnly` to every red result.

Create `CoreTestFixtures` with deterministic values used by later core tests:

```swift
enum CoreTestFixtures {
    static let date = Date(timeIntervalSince1970: 1_700_000_000)
    static let path = URL(fileURLWithPath: "/tmp/mac-clean-tests/com.example.Editor")

    static func fingerprint(size: UInt64 = 1024) -> FileFingerprint {
        .init(deviceID: 1, fileID: 2, ownerID: 501, sizeBytes: size, modifiedAt: date)
    }

    static func discovery(kind: DiscoveryKind, ownerBundleID: String? = "com.example.Editor") -> DiscoveredItem {
        .init(
            displayName: "Editor cache",
            sourceURL: path,
            validatedPath: .init(originalURL: path, canonicalURL: path, allowedRoot: path.deletingLastPathComponent()),
            sizeBytes: 1024,
            modifiedAt: date,
            fingerprint: fingerprint(),
            evidence: .init(scannerID: "fixture", ruleID: "fixture-rule", ownerName: "Editor", ownerBundleID: ownerBundleID, explanation: "Fixture evidence"),
            kind: kind
        )
    }

    static func cacheDiscovery(ownerBundleID: String) -> DiscoveredItem {
        discovery(kind: .regenerableApplicationCache, ownerBundleID: ownerBundleID)
    }

    static func context(installed: [String] = [], running: [String] = []) -> ScanContext {
        let applications = installed.map { InstalledApplication(name: $0, bundleID: $0, url: URL(fileURLWithPath: "/Applications/\($0).app")) }
        return .init(inventory: .init(installedApplications: applications, runningBundleIDs: Set(running)), now: date)
    }
}
```

- [ ] **Step 4: Run policy mutation checks**

Run: `swift test --filter RiskClassifierTests && swift test`

Expected: all tests pass. Temporarily changing the running-app branch to green makes `runningApplicationCacheIsRed` fail; restore the correct branch and rerun to green.

- [ ] **Step 5: Commit centralized policy**

```bash
git add Sources/CleanCore/Scanning Sources/CleanCore/Risk Tests/CleanCoreTests
git commit -m "feat: classify cleanup candidates by evidence"
```

---

### Task 4: Installed and Running Application Inventory

**Files:**
- Create: `Sources/CleanCore/Scanning/ApplicationInventoryProvider.swift`
- Test: `Tests/CleanCoreTests/ApplicationInventoryProviderTests.swift`

**Interfaces:**
- Consumes: `InstalledApplication` and `ApplicationInventory` from Task 1.
- Produces: `ApplicationInventoryProviding.inventory() async throws` and `SystemApplicationInventoryProvider`.

- [ ] **Step 1: Write a failing fixture-based application bundle test**

```swift
@Test func discoversBundleIDAndExcludesDuplicateApplicationURLs() async throws {
    let fixture = try ApplicationBundleFixture(name: "Editor", bundleID: "com.example.Editor")
    let provider = SystemApplicationInventoryProvider(
        applicationRoots: [fixture.root, fixture.root],
        runningBundleIDs: { ["com.example.Editor"] }
    )
    let inventory = try await provider.inventory()
    #expect(inventory.installedApplications.map(\.bundleID) == ["com.example.Editor"])
    #expect(inventory.runningBundleIDs == Set(["com.example.Editor"]))
}
```

The same test file defines `ApplicationBundleFixture`. Its initializer creates `<temporary root>/Editor.app/Contents/Info.plist` with literal `CFBundleIdentifier`, `CFBundleName`, and `CFBundlePackageType = APPL` values, and its `deinit` removes only the UUID-named temporary root. This makes the test exercise `Bundle(url:)` against a real bundle layout rather than a mock.

```swift
private final class ApplicationBundleFixture {
    let root: URL

    init(name: String, bundleID: String) throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let contents = root.appending(path: "\(name).app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleName": name,
            "CFBundlePackageType": "APPL"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appending(path: "Info.plist"))
    }

    deinit { try? FileManager.default.removeItem(at: root) }
}
```

- [ ] **Step 2: Run the inventory test and verify the missing provider failure**

Run: `swift test --filter ApplicationInventoryProviderTests`

Expected: compilation fails because `SystemApplicationInventoryProvider` is undefined.

- [ ] **Step 3: Implement bundle enumeration with injected running-state input**

```swift
public protocol ApplicationInventoryProviding: Sendable {
    func inventory() async throws -> ApplicationInventory
}

public struct SystemApplicationInventoryProvider: ApplicationInventoryProviding {
    public let applicationRoots: [URL]
    public let runningBundleIDs: @Sendable () -> Set<String>

    public func inventory() async throws -> ApplicationInventory {
        var byBundleID: [String: InstalledApplication] = [:]
        for root in applicationRoots {
            let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
            let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
            while let url = enumerator?.nextObject() as? URL {
                guard url.pathExtension == "app", let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { continue }
                enumerator?.skipDescendants()
                byBundleID[id] = InstalledApplication(name: bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? url.deletingPathExtension().lastPathComponent, bundleID: id, url: url)
            }
        }
        return ApplicationInventory(installedApplications: byBundleID.values.sorted { $0.bundleID < $1.bundleID }, runningBundleIDs: runningBundleIDs())
    }
}
```

Production composition supplies `/Applications`, `~/Applications`, and Launch Services-visible application URLs, while the AppKit adapter supplies `NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)`.

Give `InstalledApplication` and `ApplicationInventory` public memberwise initializers in `ApplicationInventory.swift`; `MacCleanUI` and fixture targets must construct them without `@testable` access.

- [ ] **Step 4: Run fixture and complete tests**

Run: `swift test --filter ApplicationInventoryProviderTests && swift test`

Expected: the fixture bundle is discovered once and its running Bundle ID is preserved.

- [ ] **Step 5: Commit application inventory**

```bash
git add Sources/CleanCore/Scanning/ApplicationInventoryProvider.swift Tests/CleanCoreTests/ApplicationInventoryProviderTests.swift
git commit -m "feat: inventory installed and running applications"
```

---

### Task 5: Application Cache Scanner and Partial-Failure Coordination

**Files:**
- Create: `Sources/CleanCore/Scanning/DirectorySizer.swift`
- Create: `Sources/CleanCore/Scanning/ApplicationCacheScanner.swift`
- Create: `Sources/CleanCore/Scanning/ScanCoordinator.swift`
- Test: `Tests/CleanCoreTests/ApplicationCacheScannerTests.swift`
- Test: `Tests/CleanCoreTests/ScanCoordinatorTests.swift`

**Interfaces:**
- Consumes: `Scanner`, `ScanContext`, `SafePathValidator`, `SystemFileFingerprinter`, and application inventory.
- Produces: `DirectorySizing.size(of:) async throws`, `ApplicationCacheScanner`, `ScanReport`, `ScannerFailure`, and `ScanCoordinator.scan(context:)`.

- [ ] **Step 1: Write failing cache ownership and partial-failure tests**

```swift
@Test func emitsInstalledBundleCacheAndReportsUnknownDirectoryAsRedEvidence() async throws {
    let fixture = try CacheFixture(entries: ["com.example.Editor": 2048, "mystery-cache": 128])
    let scanner = ApplicationCacheScanner(cacheRoot: fixture.root, validator: fixture.validator, fingerprinter: SystemFileFingerprinter())
    let discoveries = try await scanner.scan(context: fixture.context(installed: ["com.example.Editor"]))
    #expect(discoveries.count == 2)
    #expect(discoveries.first { $0.evidence.ownerBundleID == "com.example.Editor" }?.kind == .regenerableApplicationCache)
    #expect(discoveries.first { $0.sourceURL.lastPathComponent == "mystery-cache" }?.kind == .unknown)
}

@Test func coordinatorReturnsSuccessfulScannerResultsAlongsideFailure() async {
    let coordinator = ScanCoordinator(scanners: [FixtureScanner.success(id: "good"), FixtureScanner.failure(id: "bad")], classifier: RiskClassifier())
    let report = await coordinator.scan(context: CoreTestFixtures.context())
    #expect(report.candidates.count == 1)
    #expect(report.failures.map(\.scannerID) == ["bad"])
}
```

- [ ] **Step 2: Verify scanner and coordinator tests fail**

Run: `swift test --filter ApplicationCacheScannerTests && swift test --filter ScanCoordinatorTests`

Expected: compilation fails on the missing scanner, sizer, and coordinator types.

- [ ] **Step 3: Implement cancellation-aware sizing and discovery**

`DirectorySizer` enumerates regular files with `.fileSizeKey` and `.isSymbolicLinkKey`, skips symbolic-link descendants, checks `Task.checkCancellation()` every 128 entries, and accumulates into `UInt64` using overflow reporting. `ApplicationCacheScanner` enumerates only immediate children of the injected cache root, validates each child, fingerprints it, sizes it, and assigns `.regenerableApplicationCache` only when its directory name exactly matches an installed Bundle ID; all other children become `.unknown`.

```swift
public struct ScannerFailure: Error, Hashable, Sendable {
    public let scannerID: String
    public let message: String
}

public struct ScanReport: Sendable {
    public let candidates: [CleanupCandidate]
    public let failures: [ScannerFailure]
    public var totalBytes: UInt64 { candidates.reduce(0) { $0 + $1.sizeBytes } }
}

public protocol ScanCoordinating: Sendable {
    func scan(context: ScanContext) async -> ScanReport
}

public struct ScanCoordinator: ScanCoordinating, Sendable {
    public let scanners: [any Scanner]
    public let classifier: RiskClassifier

    public func scan(context: ScanContext) async -> ScanReport {
        await withTaskGroup(of: Result<(String, [DiscoveredItem]), ScannerFailure>.self) { group in
            for scanner in scanners {
                group.addTask {
                    do { return .success((scanner.id, try await scanner.scan(context: context))) }
                    catch { return .failure(ScannerFailure(scannerID: scanner.id, message: String(describing: error))) }
                }
            }
            var candidates: [CleanupCandidate] = []
            var failures: [ScannerFailure] = []
            for await result in group {
                switch result {
                case .success((_, let items)): candidates += items.compactMap { try? classifier.classify($0, context: context) }
                case .failure(let failure): failures.append(failure)
                }
            }
            return ScanReport(candidates: candidates.sorted { $0.sizeBytes > $1.sizeBytes }, failures: failures.sorted { $0.scannerID < $1.scannerID })
        }
    }
}
```

`ApplicationCacheScannerTests.swift` defines `CacheFixture`: it creates a UUID-named temporary cache root, creates one directory and one data file for each `[bundleID: byteCount]` entry, builds a validator whose only allowed root is that cache root, and returns a `ScanContext` through `CoreTestFixtures.context`. `ScanCoordinatorTests.swift` defines this real protocol fake:

```swift
private final class CacheFixture {
    let root: URL
    let validator: SafePathValidator

    init(entries: [String: Int]) throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (name, count) in entries {
            let directory = root.appending(path: name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(repeating: 0x41, count: count).write(to: directory.appending(path: "payload.bin"))
        }
        validator = SafePathValidator(allowedRoots: [root], forbiddenExactPaths: [])
    }

    func context(installed: [String]) -> ScanContext { CoreTestFixtures.context(installed: installed) }
    deinit { try? FileManager.default.removeItem(at: root) }
}
```

```swift
private struct FixtureScanner: Scanner {
    enum FixtureError: Error { case expectedFailure }
    let id: String
    let result: Result<[DiscoveredItem], FixtureError>

    func scan(context: ScanContext) async throws -> [DiscoveredItem] { try result.get() }

    static func success(id: String) -> Self {
        .init(id: id, result: .success([CoreTestFixtures.cacheDiscovery(ownerBundleID: "com.example.Editor")]))
    }

    static func failure(id: String) -> Self {
        .init(id: id, result: .failure(.expectedFailure))
    }
}
```

- [ ] **Step 4: Run scanner integration and complete tests**

Run: `swift test --filter ApplicationCacheScannerTests && swift test --filter ScanCoordinatorTests && swift test`

Expected: known cache is classifiable as green, unknown cache remains red, and one scanner failure does not erase successful candidates.

- [ ] **Step 5: Commit the first real scanner**

```bash
git add Sources/CleanCore/Scanning Tests/CleanCoreTests
git commit -m "feat: scan application caches safely"
```

---

### Task 6: Immutable Cleanup Plans and Revalidated Execution

**Files:**
- Create: `Sources/CleanCore/Cleanup/CleanupPlanner.swift`
- Create: `Sources/CleanCore/Cleanup/CleanupExecutor.swift`
- Test: `Tests/CleanCoreTests/CleanupPlannerTests.swift`
- Test: `Tests/CleanCoreTests/CleanupExecutorTests.swift`

**Interfaces:**
- Consumes: `CleanupCandidate`, `SafePathValidator`, and `FileFingerprinting`.
- Produces: `CleanupPlan`, `CleanupPlanItem`, `CleanupPlanner.plan(candidates:confirmedIDs:)`, `CleanupResult`, and `CleanupExecutor.execute(_:)`.

- [ ] **Step 1: Write failing confirmation and replacement-race tests**

```swift
@Test func plannerIncludesGreenAndConfirmedYellowButNeverRed() {
    let candidates = [CoreTestFixtures.candidate(risk: .green), CoreTestFixtures.candidate(risk: .yellow), CoreTestFixtures.candidate(risk: .red)]
    let plan = CleanupPlanner().plan(candidates: candidates, confirmedIDs: [candidates[1].id])
    #expect(plan.items.map(\.candidateID) == [candidates[0].id, candidates[1].id])
}

@Test func executorRejectsTargetReplacedAfterScan() async throws {
    let fixture = try CleanupFixture.greenCache()
    let plan = CleanupPlanner().plan(candidates: [fixture.candidate], confirmedIDs: [])
    try fixture.replaceTargetAfterFingerprint()
    let result = await fixture.executor.execute(plan)
    #expect(result.items.first?.status == .skipped(.fingerprintChanged))
    #expect(FileManager.default.fileExists(atPath: fixture.target.path))
}
```

- [ ] **Step 2: Verify cleanup tests fail before mutation code exists**

Run: `swift test --filter CleanupPlannerTests && swift test --filter CleanupExecutorTests`

Expected: compilation fails because cleanup plan and executor types are undefined.

- [ ] **Step 3: Implement the plan gate and delete-contents action**

```swift
public struct CleanupPlanItem: Hashable, Sendable {
    public let candidateID: UUID
    public let canonicalURL: URL
    public let expectedFingerprint: FileFingerprint
    public let action: CleanupAction
}

public struct CleanupPlan: Hashable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let items: [CleanupPlanItem]
}

public protocol CleanupExecuting: Sendable {
    func execute(_ plan: CleanupPlan) async -> CleanupResult
}

public enum CleanupSkipReason: String, Hashable, Codable, Sendable {
    case fingerprintChanged, pathRejected, unsupportedAction
}

public enum CleanupItemStatus: Hashable, Sendable {
    case success(reclaimedBytes: UInt64)
    case skipped(CleanupSkipReason)
    case failed(message: String)
}

public struct CleanupItemResult: Hashable, Sendable {
    public let candidateID: UUID
    public let status: CleanupItemStatus
}

public struct CleanupResult: Hashable, Sendable {
    public let planID: UUID
    public let items: [CleanupItemResult]
}

public struct CleanupPlanner: Sendable {
    public func plan(candidates: [CleanupCandidate], confirmedIDs: Set<UUID>, now: Date = .now) -> CleanupPlan {
        let items = candidates.filter { $0.risk == .green || ($0.risk == .yellow && confirmedIDs.contains($0.id)) }
            .filter { $0.risk != .red && $0.proposedAction != .reportOnly }
            .map { CleanupPlanItem(candidateID: $0.id, canonicalURL: $0.canonicalURL, expectedFingerprint: $0.fingerprint, action: $0.proposedAction) }
        return CleanupPlan(id: UUID(), createdAt: now, items: items)
    }
}
```

`CleanupExecutor: CleanupExecuting` re-runs `SafePathValidator`, captures a fresh fingerprint, requires exact equality with `expectedFingerprint`, and supports only `.deleteContentsPreservingRoot` in this phase. It enumerates immediate children and removes each child without deleting the validated cache root. It reports per-item statuses `.success(reclaimedBytes:)`, `.skipped(.fingerprintChanged)`, `.skipped(.pathRejected)`, or `.failed(message:)`. Yellow `.moveToTrash` and package-manager actions return `.skipped(.unsupportedAction)` within this phase, never a fallback deletion.

Expose `CleanupExecutor.init(validator:fingerprinter:fileManager:)`, using `SystemFileFingerprinter` and `.default` in production. Extend `CoreTestFixtures` with `candidate(risk:path:fingerprint:)`; it maps green to `.deleteContentsPreservingRoot`, yellow to `.moveToTrash`, and red to `.reportOnly`, unless the test supplies an explicit action.

```swift
private final class CleanupFixture {
    let root: URL
    let target: URL
    let candidate: CleanupCandidate
    let executor: CleanupExecutor

    private init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        target = root.appending(path: "com.example.Editor")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data([0x41]).write(to: target.appending(path: "cache.bin"))
        let fingerprinter = SystemFileFingerprinter()
        let fingerprint = try fingerprinter.fingerprint(at: target)
        candidate = CoreTestFixtures.candidate(risk: .green, path: target.path, fingerprint: fingerprint)
        executor = CleanupExecutor(
            validator: SafePathValidator(allowedRoots: [root], forbiddenExactPaths: []),
            fingerprinter: fingerprinter,
            fileManager: .default
        )
    }

    static func greenCache() throws -> CleanupFixture { try CleanupFixture() }

    func replaceTargetAfterFingerprint() throws {
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data([0x42]).write(to: target.appending(path: "replacement.bin"))
    }

    deinit { try? FileManager.default.removeItem(at: root) }
}
```

- [ ] **Step 4: Run race, root-preservation, and complete tests**

Run: `swift test --filter CleanupExecutorTests && swift test`

Expected: changed targets are untouched, the cache root survives successful cleanup, and red candidates never enter a plan.

- [ ] **Step 5: Commit guarded cleanup execution**

```bash
git add Sources/CleanCore/Cleanup Tests/CleanCoreTests
git commit -m "feat: execute revalidated cache cleanup plans"
```

---

### Task 7: Local Audit History, Finder Reveal, and Weekly Policy

**Files:**
- Create: `Sources/CleanCore/Audit/AuditRecord.swift`
- Create: `Sources/MacCleanUI/Persistence/SwiftDataAuditStore.swift`
- Create: `Sources/MacCleanUI/Finder/FinderRevealer.swift`
- Create: `Sources/MacCleanUI/Scheduling/WeeklyScanScheduler.swift`
- Create: `Sources/MacCleanUI/Scheduling/NotificationService.swift`
- Create: `Tests/MacCleanUITests/Support/UITestFixtures.swift`
- Test: `Tests/MacCleanUITests/SwiftDataAuditStoreTests.swift`
- Test: `Tests/MacCleanUITests/FinderRevealerTests.swift`
- Test: `Tests/MacCleanUITests/WeeklyScanSchedulerTests.swift`

**Interfaces:**
- Consumes: candidates, scan reports, and cleanup results from Tasks 1, 5, and 6.
- Produces: `AuditRecord`, `AuditStoring`, `FinderRevealing`, `FinderRevealState`, `WeeklyScanScheduler.isDue(lastScan:now:)`, and `NotificationSending`.

- [ ] **Step 1: Write failing persistence, reveal-state, and due-date tests**

```swift
@Test @MainActor func auditStoreRoundTripsOriginalSourcePath() throws {
    let store = try SwiftDataAuditStore.inMemory()
    let record = UITestFixtures.auditRecord(sourcePath: "/Users/example/Library/Caches/com.example.Editor")
    try store.append(record)
    #expect(try store.records().first?.sourcePath == record.sourcePath)
}

@Test func missingFinderTargetIsDisabled() {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    #expect(FinderRevealState(url: url, fileManager: .default) == .unavailable(.missing))
}

@Test func weeklyScanIsDueAtSevenDays() {
    let last = Date(timeIntervalSince1970: 1_700_000_000)
    #expect(WeeklyScanScheduler.isDue(lastScan: last, now: last.addingTimeInterval(7 * 24 * 60 * 60)))
    #expect(!WeeklyScanScheduler.isDue(lastScan: last, now: last.addingTimeInterval(6 * 24 * 60 * 60)))
}
```

- [ ] **Step 2: Verify service tests fail on missing adapters**

Run: `swift test --filter MacCleanUITests`

Expected: compilation fails on missing audit, Finder, and scheduler types.

- [ ] **Step 3: Implement local-only adapters**

```swift
public protocol FinderRevealing: Sendable {
    @MainActor func reveal(_ urls: [URL])
}

public struct NSWorkspaceFinderRevealer: FinderRevealing {
    @MainActor public func reveal(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}

public enum FinderRevealState: Equatable, Sendable {
    case available(URL)
    case unavailable(UnavailableReason)
    public enum UnavailableReason: Equatable, Sendable { case missing, inaccessible }
}

public enum WeeklyScanScheduler {
    public static let interval: TimeInterval = 7 * 24 * 60 * 60
    public static func isDue(lastScan: Date?, now: Date) -> Bool {
        guard let lastScan else { return true }
        return now.timeIntervalSince(lastScan) >= interval
    }
}
```

`AuditRecord` is the exact cross-layer value stored by SwiftData:

```swift
public enum AuditOutcome: String, Codable, Sendable { case cleaned, skipped, failed }

public struct AuditRecord: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let scanID: UUID
    public let candidateID: UUID
    public let sourcePath: String
    public let canonicalPath: String
    public let scannerID: String
    public let risk: RiskLevel
    public let action: CleanupAction
    public let sizeBytes: UInt64
    public let timestamp: Date
    public let outcome: AuditOutcome
    public let message: String?
}
```

`SwiftDataAuditStore` maps the value into a private `@Model AuditEntry`, supports an in-memory `ModelContainer` for tests, stores scan timestamps even when a scan has no candidates, and never stores file contents.

```swift
@MainActor public protocol AuditStoring: AnyObject {
    func append(_ record: AuditRecord) throws
    func recordScan(at date: Date) throws
    func records() throws -> [AuditRecord]
    func latestScanDate() throws -> Date?
    func clear() throws
}

public protocol NotificationSending: Sendable {
    func requestAuthorizationIfNeeded() async -> Bool
    func sendCleanupSummary(reclaimedBytes: UInt64, pendingReviewCount: Int) async
}
```

`UserNotificationService` implements `NotificationSending`, checks authorization before the first weekly summary, requests it only when status is `.notDetermined`, and never repeats a denied prompt. It sends reclaimed-space plus pending-review counts without paths. `UITestFixtures.auditRecord(sourcePath:)` constructs a deterministic `AuditRecord` with fixed UUIDs, the supplied source path, green risk, delete-contents action, 1024 bytes, and the fixed timestamp `1_700_000_000`.

- [ ] **Step 4: Run adapter and complete tests**

Run: `swift test --filter MacCleanUITests && swift test`

Expected: audit path round-trip, missing Finder state, and seven-day boundary all pass.

- [ ] **Step 5: Commit local services**

```bash
git add Sources/CleanCore/Audit Sources/MacCleanUI/Persistence Sources/MacCleanUI/Finder Sources/MacCleanUI/Scheduling Tests/MacCleanUITests
git commit -m "feat: add local audit and weekly scan services"
```

---

### Task 8: Testable App Model and Production Composition

**Files:**
- Create: `Sources/MacCleanUI/App/AppModel.swift`
- Create: `Sources/MacCleanUI/App/LiveDependencies.swift`
- Remove: `Sources/MacCleanUI/Placeholder.swift`
- Modify: `Tests/MacCleanUITests/Support/UITestFixtures.swift`
- Test: `Tests/MacCleanUITests/AppModelTests.swift`
- Remove: `Tests/MacCleanUITests/PlaceholderTests.swift`

**Interfaces:**
- Consumes: inventory, coordinator, planner, executor, audit, Finder, scheduler, and notifications.
- Produces: `AppModel.State`, `AppModel.scan()`, `AppModel.cleanGreenCandidates()`, `AppModel.reveal(_:)`, and `LiveDependencies.makeAppModel()`.

- [ ] **Step 1: Write failing scan-state and Finder delegation tests**

```swift
@Test @MainActor func scanPublishesCandidatesAndPartialFailures() async {
    let dependencies = AppDependencies.fixture(report: UITestFixtures.scanReport(candidateCount: 2, failureCount: 1))
    let model = AppModel(dependencies: dependencies)
    await model.scan()
    #expect(model.state.candidates.count == 2)
    #expect(model.state.failures.count == 1)
    #expect(model.state.phase == .results)
}

@Test @MainActor func revealDelegatesCanonicalCandidateURL() {
    let recorder = RecordingFinderRevealer()
    let model = AppModel(dependencies: .fixture(finder: recorder))
    let candidate = UITestFixtures.candidate(risk: .green)
    model.reveal(candidate)
    #expect(recorder.urls == [candidate.canonicalURL])
}
```

- [ ] **Step 2: Verify app-model tests fail**

Run: `swift test --filter AppModelTests`

Expected: compilation fails because `AppModel` and `AppDependencies` are undefined.

- [ ] **Step 3: Implement main-actor state transitions and live wiring**

```swift
public struct AppDependencies {
    public let inventory: any ApplicationInventoryProviding
    public let coordinator: any ScanCoordinating
    public let planner: CleanupPlanner
    public let cleanupExecutor: any CleanupExecuting
    public let audit: any AuditStoring
    public let finder: any FinderRevealing
    public let notifications: any NotificationSending
    public let now: @Sendable () -> Date
}

@MainActor @Observable
public final class AppModel {
    public enum Phase: Equatable { case idle, scanning, results, cleaning }
    public struct State {
        public var phase: Phase = .idle
        public var candidates: [CleanupCandidate] = []
        public var failures: [ScannerFailure] = []
        public var lastScan: Date?
        public var errorMessage: String?
    }

    public private(set) var state = State()
    private let dependencies: AppDependencies

    public init(dependencies: AppDependencies) { self.dependencies = dependencies }

    public var reclaimableBytes: UInt64 {
        state.candidates.filter { $0.risk == .green }.reduce(0) { $0 + $1.sizeBytes }
    }
    public var greenSummary: String { "\(state.candidates.filter { $0.risk == .green }.count) 项" }
    public var yellowSummary: String { "\(state.candidates.filter { $0.risk == .yellow }.count) 项" }

    public func scan() async {
        state.phase = .scanning
        do {
            let inventory = try await dependencies.inventory.inventory()
            let report = await dependencies.coordinator.scan(context: ScanContext(inventory: inventory, now: dependencies.now()))
            state.candidates = report.candidates
            state.failures = report.failures
            let completedAt = dependencies.now()
            state.lastScan = completedAt
            try dependencies.audit.recordScan(at: completedAt)
            state.phase = .results
        } catch {
            state.errorMessage = String(describing: error)
            state.phase = .idle
        }
    }
}
```

Add `cleanGreenCandidates()` to generate a plan with no yellow confirmations, execute it, append one audit record per result, and rescan. Add `reveal(_:)` only when `FinderRevealState` is available. `LiveDependencies` sets the allowed root to `~/Library/Caches`, forbidden exact paths to `/`, the home directory, and the cache root itself; composes `ApplicationCacheScanner`; and never accepts a cleanup path from UI text.

Give `AppDependencies` a public initializer containing all eight dependencies. Because `AppModel` is `@MainActor`, audit and Finder calls remain on the main actor while scanning and cleanup implementations perform filesystem work off the UI actor.

`UITestFixtures.swift` adds `candidate(risk:path:)`, `scanReport(candidateCount:failureCount:)`, `StubInventoryProvider`, `StubScanCoordinator: ScanCoordinating`, `RecordingScanCoordinator: ScanCoordinating`, `StubCleanupExecutor: CleanupExecuting`, `InMemoryAuditStore: AuditStoring`, `RecordingFinderRevealer: FinderRevealing`, and `RecordingNotificationService: NotificationSending`. `AppDependencies.fixture(...)` composes those real protocol fakes and defaults `now` to `Date(timeIntervalSince1970: 1_700_000_000)`. The fakes record inputs and return caller-supplied values; they do not duplicate production classification or planning logic.

- [ ] **Step 4: Run state-machine and complete tests**

Run: `swift test --filter AppModelTests && swift test`

Expected: scanning, partial failure publication, green cleanup, audit recording, and Finder delegation tests pass.

- [ ] **Step 5: Commit application orchestration**

```bash
git add Sources/MacCleanUI/App Sources/MacCleanUI/Placeholder.swift Tests/MacCleanUITests
git commit -m "feat: orchestrate scans and cleanup in app state"
```

---

### Task 9: Confirmed Menu-Bar UI and Candidate Detail Window

**Files:**
- Create: `Sources/MacCleanUI/Views/MenuBarRootView.swift`
- Create: `Sources/MacCleanUI/Views/DetailView.swift`
- Create: `Sources/MacCleanUI/Views/CandidateRow.swift`
- Modify: `Sources/MacCleanApp/MacCleanApp.swift`
- Test: `Tests/MacCleanUITests/CandidatePresentationTests.swift`

**Interfaces:**
- Consumes: `AppModel` and all candidate fields.
- Produces: `CandidatePresentation`, `MenuBarRootView`, `DetailView`, and the runnable `MacCleanApp` scenes.

- [ ] **Step 1: Write failing presentation tests for source tracing and risk copy**

```swift
@Test func presentationIncludesPathReasonAndLocalizedRiskLabel() {
    let candidate = UITestFixtures.candidate(risk: .green, path: "/Users/example/Library/Caches/com.example.Editor")
    let value = CandidatePresentation(candidate: candidate, fileManager: .default)
    #expect(value.path == candidate.canonicalURL.path)
    #expect(value.riskLabel == "安全缓存")
    #expect(value.riskReason == candidate.riskReason)
    #expect(value.finderActionTitle == "在 Finder 中显示")
}
```

- [ ] **Step 2: Verify presentation test fails**

Run: `swift test --filter CandidatePresentationTests`

Expected: compilation fails because `CandidatePresentation` is undefined.

- [ ] **Step 3: Implement presentation values and SwiftUI views**

`CandidatePresentation` converts bytes with `ByteCountFormatter`, maps green/yellow/red to “安全缓存/需要确认/仅报告”, preserves the canonical path and evidence explanation verbatim, and computes Finder availability.

```swift
public struct MenuBarRootView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mac Clean").font(.headline)
            Text(ByteCountFormatter.string(fromByteCount: Int64(model.reclaimableBytes), countStyle: .file))
                .font(.system(size: 28, weight: .bold, design: .rounded))
            Text("预计可释放空间").foregroundStyle(.secondary)
            Button(model.state.phase == .scanning ? "正在扫描…" : "立即扫描") { Task { await model.scan() } }
                .buttonStyle(.borderedProminent).disabled(model.state.phase == .scanning)
            Divider()
            LabeledContent("安全缓存", value: model.greenSummary)
            LabeledContent("待确认项目", value: model.yellowSummary)
            Button("查看详情") { openWindow(id: "details") }
        }
        .padding(16).frame(width: 300)
    }
}
```

`DetailView` groups by risk, lists `CandidateRow`, exposes search, and places “清理安全缓存” away from Finder/navigation controls. `CandidateRow` shows name, formatted size, risk badge, owner, collapsed path, expandable scanner/rule/reason details, and a Finder button with an accessibility hint explaining disabled states. The app entry point owns one `@State AppModel`, renders `MenuBarExtra`, and declares `Window("Mac Clean 详情", id: "details")`.

Declare public initializers for `MenuBarRootView(model:)`, `DetailView(model:)`, and `CandidateRow(candidate:model:)`; the executable target imports these views from the separate `MacCleanUI` module. Use semantic `Label`, `LabeledContent`, and native button styles so light/dark colors come from the system rather than fixed RGB values.

- [ ] **Step 4: Run tests, compile the app, and launch the menu extra**

Run: `swift test && swift build --product MacCleanApp`

Expected: tests pass and the executable builds without warnings.

Run: `swift run MacCleanApp`

Expected manual check: a 300-point compact menu opens; scanning shows candidates; “查看详情” opens the grouped window; every existing candidate can be selected in Finder; dark-mode text remains readable; VoiceOver announces buttons, risk, size, and disabled Finder reasons. Stop the process with Control-C after inspection.

- [ ] **Step 5: Commit the runnable UI slice**

```bash
git add Sources/MacCleanUI/Views Sources/MacCleanApp Tests/MacCleanUITests
git commit -m "feat: add Mac Clean menu and detail interface"
```

---

### Task 10: Weekly Catch-Up Scan, Documentation, and MVP Acceptance

**Files:**
- Modify: `Sources/MacCleanUI/App/AppModel.swift`
- Modify: `Sources/MacCleanUI/App/LiveDependencies.swift`
- Modify: `Sources/MacCleanApp/MacCleanApp.swift`
- Create: `README.md`
- Create: `docs/security-model.md`
- Test: `Tests/MacCleanUITests/WeeklyCatchUpTests.swift`

**Interfaces:**
- Consumes: weekly policy and notification services from Task 7.
- Produces: `AppModel.performCatchUpScanIfDue()` and documented MVP safety boundaries.

- [ ] **Step 1: Write the failing catch-up behavior test**

```swift
@Test @MainActor func launchPerformsOneCatchUpScanWhenLastScanIsOverdue() async {
    let now = Date(timeIntervalSince1970: 1_700_700_000)
    let coordinator = RecordingScanCoordinator()
    let model = AppModel(dependencies: .fixture(lastScan: Date(timeIntervalSince1970: 1_700_000_000), now: { now }, coordinator: coordinator))
    await model.performCatchUpScanIfDue()
    await model.performCatchUpScanIfDue()
    #expect(coordinator.scanCount == 1)
}
```

- [ ] **Step 2: Verify the catch-up test fails**

Run: `swift test --filter WeeklyCatchUpTests`

Expected: compilation fails because `performCatchUpScanIfDue()` is undefined.

- [ ] **Step 3: Implement one-shot launch catch-up and user-controlled notifications**

`performCatchUpScanIfDue()` reads the latest persisted scan timestamp, calls `WeeklyScanScheduler.isDue`, runs `scan()` when due, records the completed scan timestamp even when it finds no candidates, automatically executes only green candidates, and sends a notification containing reclaimed bytes plus yellow count. A second call at the same injected time observes the new timestamp and does nothing. The app invokes it from `.task` when the menu scene starts and whenever the menu root is recreated. If notification permission is denied, scanning still succeeds and no repeated permission prompt occurs.

Document these exact safety facts in `docs/security-model.md`: allowed cache root, canonical component containment, forbidden root targets, symlink rejection, file fingerprint revalidation, running-app exclusion, no project scanning, no package-manager dependency inference, no privileged helper in the MVP, and no network traffic. `README.md` includes macOS 14+, Xcode 26.4/Swift 6.3 development commands, `swift test`, `swift run MacCleanApp`, and the three-phase roadmap.

- [ ] **Step 4: Run the complete acceptance suite**

Run: `swift test`

Expected: every core and UI test passes with zero failures.

Run: `swift build --product MacCleanApp`

Expected: build exits 0 without warnings.

Run: `git diff --check`

Expected: no whitespace errors.

Run the temporary-directory security fixtures once with `swift test --filter 'SafePathValidatorTests|CleanupExecutorTests'`; expected result is zero failures and no file outside the fixture cache root changes.

- [ ] **Step 5: Review MVP requirements against the approved spec**

Confirm the running slice provides: manual scan, weekly catch-up, green-only automatic cleanup, partial scanner failures, candidate source/rule/reason, Finder reveal, missing-path state, local audit history, compact A-style menu, detail window, dark mode, accessibility labels, and zero network dependencies. Confirm Homebrew/npm/pip/Cargo/Xcode specialized scanners, yellow residual deletion, privileged Helper, signing, notarization, and `.dmg` packaging remain outside this phase boundary.

- [ ] **Step 6: Commit acceptance documentation**

```bash
git add Sources README.md docs/security-model.md Tests
git commit -m "docs: define Mac Clean MVP operation and safety"
```

## Execution Completion Criteria

This plan is complete only when all Task 10 acceptance commands have fresh passing output, the menu-bar application has been manually inspected in light and dark appearances, Finder reveal selects a real test candidate, cleanup security tests prove no path escape, and the working tree contains no unrelated changes.
