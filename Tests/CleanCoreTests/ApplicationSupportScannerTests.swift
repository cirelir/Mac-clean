import Foundation
import Testing
@testable import CleanCore

@Test func listsUnownedDirectoriesAndSkipsOwnedApplicationData() async throws {
    let fixture = try SupportFixture(
        entries: ["Google": 2_048, "TRAE SOLO CN": 512, "Editor": 1_024]
    )

    let discoveries = try await fixture.scanner().scan(
        context: CoreTestFixtures.context(installed: ["Editor"])
    )

    #expect(discoveries.count == 2)
    #expect(discoveries.allSatisfy { $0.kind == .orphanResidual(confidence: .inferred) })
    #expect(discoveries.allSatisfy { $0.evidence.ruleID == "unowned-application-support-data" })
    #expect(Set(discoveries.map(\.displayName)) == Set(["Google", "TRAE SOLO CN"]))
}

@Test func matchesOwnersByBundleIDAndDisplayNameCaseInsensitively() async throws {
    let fixture = try SupportFixture(entries: ["google": 128, "com.example.Editor": 256, "Leftover": 64])

    let discoveries = try await fixture.scanner().scan(
        context: CoreTestFixtures.context(installed: ["Google", "com.example.Editor"])
    )

    #expect(discoveries.map(\.displayName) == ["Leftover"])
}

@Test func fuzzyMatchesDirectoryNameVariantsToInstalledApps() async throws {
    let fixture = try SupportFixture(
        entries: ["kimi-desktop": 128, "Google": 256, "Genuine Residual": 64]
    )

    let discoveries = try await fixture.scanner().scan(
        context: CoreTestFixtures.context(installed: ["Kimi"])
    )

    // "kimi-desktop" normalized matches installed "Kimi"; "Google" does not
    // match "Kimi"; only the true residual remains (sorted alphabetically).
    #expect(discoveries.map(\.displayName) == ["Genuine Residual", "Google"])
    #expect(discoveries.allSatisfy { $0.kind == .orphanResidual(confidence: .inferred) })
}

@Test func skipsSystemContainersSystemServicesAndRegularFiles() async throws {
    let fixture = try SupportFixture(entries: [
        "Google": 128,
        "com.apple.container": 64,
        "Knowledge": 512,
        "ControlCenter": 256,
        "MacClean": 96
    ])
    try Data(repeating: 0x43, count: 32).write(to: fixture.root.appending(path: "loose.plist"))

    let discoveries = try await fixture.scanner().scan(
        context: CoreTestFixtures.context()
    )

    // System containers, system service data, the app's own data, and regular
    // files are all excluded; only the genuine residual remains.
    #expect(discoveries.map(\.displayName) == ["Google"])
}

@Test func supportScannerSkipsUnenumerableChildAndStillCompletes() async throws {
    let fixture = try SupportFixture(entries: ["Google": 128, "blocked": 64])
    let blocked = fixture.root.appending(path: "blocked")
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: blocked.path)
    defer {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: blocked.path
        )
    }

    let discoveries = try await fixture.scanner().scan(
        context: CoreTestFixtures.context()
    )

    #expect(discoveries.map(\.displayName) == ["Google"])
}

@Test func missingSupportRootScansAsEmptyInsteadOfFailing() async throws {
    let missingRoot = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
    let validator = SafePathValidator(allowedRoots: [missingRoot], forbiddenExactPaths: [])
    let scanner = ApplicationSupportScanner(
        supportRoot: missingRoot,
        validator: validator,
        fingerprinter: SystemFileFingerprinter()
    )

    let discoveries = try await scanner.scan(context: CoreTestFixtures.context())

    #expect(discoveries.isEmpty)
}

private final class SupportFixture {
    let root: URL
    let validator: SafePathValidator

    init(entries: [String: Int]) throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (name, count) in entries {
            let directory = root.appending(path: name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(repeating: 0x41, count: count).write(to: directory.appending(path: "data.bin"))
        }
        validator = SafePathValidator(allowedRoots: [root], forbiddenExactPaths: [])
    }

    func scanner() -> ApplicationSupportScanner {
        ApplicationSupportScanner(
            supportRoot: root,
            validator: validator,
            fingerprinter: SystemFileFingerprinter()
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}
