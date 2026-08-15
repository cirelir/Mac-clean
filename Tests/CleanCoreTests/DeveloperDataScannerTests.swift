import Foundation
import Testing
@testable import CleanCore

@Test func emitsXcodeDerivedDataEntriesWithXcodeOwnership() async throws {
    let fixture = try DerivedDataFixture(entries: ["MyApp-abc123": 2_048, "OtherApp-def456": 512])

    let discoveries = try await fixture.scanner().scan(
        context: CoreTestFixtures.context()
    )

    #expect(discoveries.count == 2)
    for discovery in discoveries {
        #expect(discovery.kind == .developerData)
        #expect(discovery.evidence.ownerBundleID == DeveloperDataScanner.xcodeBundleID)
        #expect(discovery.evidence.ruleID == "xcode-derived-data")
    }
    #expect(
        Set(discoveries.map(\.displayName))
            == Set(["MyApp-abc123", "OtherApp-def456"])
    )
}

@Test func developerScannerSkipsRegularFileAndSymbolicLinkChildren() async throws {
    let fixture = try DerivedDataFixture(entries: ["MyApp-abc123": 2_048, "victim": 256])
    try Data(repeating: 0x43, count: 64).write(to: fixture.root.appending(path: "loose.bin"))
    try FileManager.default.createSymbolicLink(
        at: fixture.root.appending(path: "linked-build"),
        withDestinationURL: fixture.root.appending(path: "MyApp-abc123")
    )

    let discoveries = try await fixture.scanner().scan(
        context: CoreTestFixtures.context()
    )

    #expect(discoveries.allSatisfy { $0.sourceURL.lastPathComponent != "loose.bin" })
    #expect(discoveries.allSatisfy { $0.sourceURL.lastPathComponent != "linked-build" })
    #expect(discoveries.contains { $0.displayName == "MyApp-abc123" })
}

@Test func developerScannerSkipsUnenumerableChildAndStillCompletes() async throws {
    let fixture = try DerivedDataFixture(entries: ["MyApp-abc123": 2_048, "blocked": 128])
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

    #expect(discoveries.count == 1)
    #expect(discoveries.first?.displayName == "MyApp-abc123")
}

@Test func listsTopLevelDeveloperDirectoriesExceptXcodeAsInferredResiduals() async throws {
    let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    for name in ["CoreSimulator", "XCTestDevices", "Xcode"] {
        let directory = base.appending(path: name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 256).write(to: directory.appending(path: "data.bin"))
    }
    let validator = SafePathValidator(allowedRoots: [base], forbiddenExactPaths: [])
    let scanner = DeveloperDataScanner(
        derivedDataRoot: base.appending(path: "Xcode/DerivedData"),
        developerRoot: base,
        validator: validator,
        fingerprinter: SystemFileFingerprinter()
    )

    let discoveries = try await scanner.scan(context: CoreTestFixtures.context())

    #expect(Set(discoveries.map(\.displayName)) == Set(["CoreSimulator", "XCTestDevices"]))
    #expect(discoveries.allSatisfy { $0.kind == .orphanResidual(confidence: .inferred) })
    #expect(discoveries.allSatisfy { $0.evidence.ruleID == "developer-top-level-data" })
}

@Test func missingDerivedDataRootScansAsEmptyInsteadOfFailing() async throws {
    let missingRoot = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
    let validator = SafePathValidator(allowedRoots: [missingRoot], forbiddenExactPaths: [])
    let scanner = DeveloperDataScanner(
        derivedDataRoot: missingRoot,
        validator: validator,
        fingerprinter: SystemFileFingerprinter()
    )

    let discoveries = try await scanner.scan(context: CoreTestFixtures.context())

    #expect(discoveries.isEmpty)
}

private final class DerivedDataFixture {
    let root: URL
    let validator: SafePathValidator

    init(entries: [String: Int]) throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (name, count) in entries {
            let directory = root.appending(path: name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(repeating: 0x41, count: count).write(to: directory.appending(path: "build.bin"))
        }
        validator = SafePathValidator(allowedRoots: [root], forbiddenExactPaths: [])
    }

    func scanner() -> DeveloperDataScanner {
        DeveloperDataScanner(
            derivedDataRoot: root,
            validator: validator,
            fingerprinter: SystemFileFingerprinter()
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}
