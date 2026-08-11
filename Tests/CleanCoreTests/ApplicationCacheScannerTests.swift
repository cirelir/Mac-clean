import Foundation
import Testing
@testable import CleanCore

@Test func emitsInstalledBundleCacheAndReportsUnknownDirectoryAsRedEvidence() async throws {
    let fixture = try CacheFixture(entries: ["com.example.Editor": 2_048, "mystery-cache": 128])
    let scanner = ApplicationCacheScanner(
        cacheRoot: fixture.root,
        validator: fixture.validator,
        fingerprinter: SystemFileFingerprinter()
    )

    let discoveries = try await scanner.scan(
        context: fixture.context(installed: ["com.example.Editor"])
    )

    #expect(discoveries.count == 2)
    #expect(discoveries.first { $0.evidence.ownerBundleID == "com.example.Editor" }?.kind == .regenerableApplicationCache)
    #expect(discoveries.first { $0.sourceURL.lastPathComponent == "mystery-cache" }?.kind == .unknown)
    #expect(discoveries.first { $0.sourceURL.lastPathComponent == "mystery-cache" }?.evidence.ownerBundleID == nil)
}

@Test func cacheScannerUsesExactBundleIDMatchesAndOnlyEmitsImmediateChildren() async throws {
    let fixture = try CacheFixture(entries: ["com.example.Editor": 64])
    let nested = fixture.root
        .appending(path: "com.example.Editor")
        .appending(path: "nested-cache")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let scanner = ApplicationCacheScanner(
        cacheRoot: fixture.root,
        validator: fixture.validator,
        fingerprinter: SystemFileFingerprinter()
    )

    let discoveries = try await scanner.scan(
        context: fixture.context(installed: ["COM.EXAMPLE.EDITOR"])
    )

    #expect(discoveries.count == 1)
    #expect(discoveries[0].sourceURL.lastPathComponent == "com.example.Editor")
    #expect(discoveries[0].kind == .unknown)
    #expect(discoveries[0].evidence.ownerBundleID == nil)
}

@Test func cacheScannerDoesNotClaimBundleOwnershipForARegularFile() async throws {
    let fixture = try CacheFixture(entries: [:])
    let file = fixture.root.appending(path: "com.example.Editor")
    try Data(repeating: 0x41, count: 32).write(to: file)
    let scanner = ApplicationCacheScanner(
        cacheRoot: fixture.root,
        validator: fixture.validator,
        fingerprinter: SystemFileFingerprinter()
    )

    let discoveries = try await scanner.scan(
        context: fixture.context(installed: ["com.example.Editor"])
    )

    #expect(discoveries.count == 1)
    #expect(discoveries[0].kind == .unknown)
    #expect(discoveries[0].evidence.ownerBundleID == nil)
}

@Test func cacheScannerReportsDirectChildAliasAsUnknownEvenWhenItsNameMatchesABundle() async throws {
    let fixture = try CacheFixture(entries: ["victim-cache": 64])
    let alias = fixture.root.appending(path: "com.example.Editor")
    let victim = fixture.root.appending(path: "victim-cache")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: victim)
    let scanner = ApplicationCacheScanner(
        cacheRoot: fixture.root,
        validator: fixture.validator,
        fingerprinter: SystemFileFingerprinter()
    )

    let discoveries = try await scanner.scan(
        context: fixture.context(installed: ["com.example.Editor"])
    )
    let aliasDiscovery = try #require(
        discoveries.first { $0.sourceURL.lastPathComponent == "com.example.Editor" }
    )

    #expect(aliasDiscovery.sourceURL.standardizedFileURL.path != aliasDiscovery.validatedPath.canonicalURL.path)
    #expect(aliasDiscovery.kind == .unknown)
    #expect(aliasDiscovery.evidence.ownerBundleID == nil)
}

@Test func directorySizerCountsRegularFilesWithoutFollowingSymbolicLinks() async throws {
    let fixture = try CacheFixture(entries: ["com.example.Editor": 256])
    let cache = fixture.root.appending(path: "com.example.Editor")
    let external = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: external) }
    try Data(repeating: 0x42, count: 4_096).write(to: external.appending(path: "external.bin"))
    try FileManager.default.createSymbolicLink(
        at: cache.appending(path: "linked-external"),
        withDestinationURL: external
    )

    let size = try await DirectorySizer().size(of: cache)

    #expect(size == 256)
}

@Test func directorySizerPropagatesCancellation() async throws {
    let fixture = try CacheFixture(entries: ["com.example.Editor": 1])
    let cache = fixture.root.appending(path: "com.example.Editor")

    do {
        _ = try await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await DirectorySizer().size(of: cache)
        }.value
        Issue.record("Expected directory sizing to throw CancellationError")
    } catch is CancellationError {
        // Expected.
    }
}

@Test func directorySizerThrowsInsteadOfReturningPartialSizeForUnreadableDescendant() async throws {
    let fixture = try CacheFixture(entries: ["com.example.Editor": 64])
    let cache = fixture.root.appending(path: "com.example.Editor")
    let blocked = cache.appending(path: "blocked")
    try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
    try Data(repeating: 0x42, count: 4_096).write(to: blocked.appending(path: "hidden.bin"))
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: blocked.path)
    defer {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: blocked.path
        )
    }

    do {
        let partialSize = try await DirectorySizer().size(of: cache)
        Issue.record("Expected unreadable descendant to throw, got partial size \(partialSize)")
    } catch DirectorySizingError.cannotEnumerate(let failureURL) {
        #expect(
            failureURL.standardizedFileURL.resolvingSymlinksInPath()
                == blocked.standardizedFileURL.resolvingSymlinksInPath()
        )
    } catch {
        Issue.record("Expected cannotEnumerate, got \(error)")
    }
}

@Test func cacheScannerRejectsConfiguredRootReplacedByOutsideSymlinkBeforeDiscovery() async throws {
    let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let configuredRoot = base.appending(path: "allowed")
    let movedRoot = base.appending(path: "allowed-original")
    let outside = base.appending(path: "outside")
    let victim = outside.appending(path: "com.example.Editor")
    let sentinel = victim.appending(path: "must-remain.bin")
    try FileManager.default.createDirectory(at: configuredRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
    try Data([0x53, 0x41, 0x46, 0x45]).write(to: sentinel)
    defer { try? FileManager.default.removeItem(at: base) }
    let validator = SafePathValidator(allowedRoots: [configuredRoot], forbiddenExactPaths: [])
    let scanner = ApplicationCacheScanner(
        cacheRoot: configuredRoot,
        validator: validator,
        fingerprinter: SystemFileFingerprinter()
    )

    try FileManager.default.moveItem(at: configuredRoot, to: movedRoot)
    try FileManager.default.createSymbolicLink(at: configuredRoot, withDestinationURL: outside)

    do {
        let discoveries = try await scanner.scan(
            context: CoreTestFixtures.context(installed: ["com.example.Editor"])
        )
        Issue.record("Expected replaced cache root to fail, discovered \(discoveries.count) items")
    } catch PathValidationError.outsideAllowedRoots {
        // Expected.
    } catch {
        Issue.record("Expected outsideAllowedRoots, got \(error)")
    }
    #expect(try Data(contentsOf: sentinel) == Data([0x53, 0x41, 0x46, 0x45]))
}

@Test func cacheScannerRejectsCanonicalObjectReplacedDuringSizing() async throws {
    let fixture = try CacheFixture(entries: ["com.example.Editor": 64])
    let target = fixture.root.appending(path: "com.example.Editor")
    let movedTarget = fixture.root.appending(path: "original-cache")
    let scanner = ApplicationCacheScanner(
        cacheRoot: fixture.root,
        validator: fixture.validator,
        fingerprinter: SystemFileFingerprinter(),
        directorySizer: CanonicalObjectReplacingSizer(
            target: target,
            movedTarget: movedTarget
        )
    )

    do {
        let discoveries = try await scanner.scan(
            context: fixture.context(installed: ["com.example.Editor"])
        )
        Issue.record("Expected changed canonical object to fail, discovered \(discoveries.count) items")
    } catch ApplicationCacheScannerError.identityChanged(let changedURL) {
        #expect(changedURL == target.standardizedFileURL)
    } catch {
        Issue.record("Expected identityChanged, got \(error)")
    }
}

private struct CanonicalObjectReplacingSizer: DirectorySizing {
    let target: URL
    let movedTarget: URL

    func size(of url: URL) async throws -> UInt64 {
        try FileManager.default.moveItem(at: target, to: movedTarget)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try Data(repeating: 0x56, count: 4_096).write(to: target.appending(path: "victim.bin"))
        return 4_096
    }
}

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

    func context(installed: [String]) -> ScanContext {
        CoreTestFixtures.context(installed: installed)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}
