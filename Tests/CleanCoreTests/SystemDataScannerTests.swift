import Foundation
import Testing
@testable import CleanCore

@Test func emitsAppLogsAndCrashReports() async throws {
    let fixture = try SystemDataFixture(
        logs: ["Editor": 2_048, "Mystery Logs": 512],
        crashReportFiles: ["Editor-2026-01-01.ips": 128]
    )

    let discoveries = try await fixture.scanner().scan(
        context: CoreTestFixtures.context(installed: ["Editor"], running: [])
    )

    let appLog = try #require(
        discoveries.first { $0.displayName == "Editor" }
    )
    #expect(appLog.kind == .rotatableLog(olderThanDays: 7))
    #expect(appLog.evidence.ownerBundleID == "Editor")
    #expect(appLog.evidence.ruleID == "installed-app-log-directory")
    #expect(appLog.sizeBytes == 2_048)

    let unknownLog = try #require(
        discoveries.first { $0.displayName == "Mystery Logs" }
    )
    #expect(unknownLog.evidence.ownerBundleID == nil)

    let crash = try #require(
        discoveries.first { $0.displayName == "崩溃报告" }
    )
    #expect(crash.kind == .systemData)
    #expect(crash.evidence.ownerBundleID == nil)
    #expect(crash.evidence.ruleID == "crash-reports")
    #expect(crash.sizeBytes == 128)
}

@Test func matchesApplicationNamesCaseInsensitively() async throws {
    let fixture = try SystemDataFixture(logs: ["editor": 2_048])

    let discoveries = try await fixture.scanner().scan(
        context: CoreTestFixtures.context(installed: ["Editor"])
    )

    let appLog = try #require(discoveries.first)
    #expect(appLog.evidence.ownerBundleID == "Editor")
}

@Test func skipsRegularFileAndSymbolicLinkChildren() async throws {
    let fixture = try SystemDataFixture(logs: ["Editor": 2_048, "victim": 256])
    try Data(repeating: 0x43, count: 64).write(to: fixture.root.appending(path: "loose.log"))
    try FileManager.default.createSymbolicLink(
        at: fixture.root.appending(path: "linked-logs"),
        withDestinationURL: fixture.root.appending(path: "Editor")
    )

    let discoveries = try await fixture.scanner().scan(
        context: CoreTestFixtures.context()
    )

    #expect(discoveries.allSatisfy { $0.sourceURL.lastPathComponent != "loose.log" })
    #expect(discoveries.allSatisfy { $0.sourceURL.lastPathComponent != "linked-logs" })
    #expect(discoveries.contains { $0.displayName == "Editor" })
}

@Test func skipsUnenumerableChildAndStillCompletes() async throws {
    let fixture = try SystemDataFixture(logs: ["Editor": 2_048, "blocked": 128])
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
    #expect(discoveries.first?.displayName == "Editor")
}

@Test func missingLogRootScansAsEmptyInsteadOfFailing() async throws {
    let missingRoot = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
    let validator = SafePathValidator(allowedRoots: [missingRoot], forbiddenExactPaths: [])
    let scanner = SystemDataScanner(
        logRoot: missingRoot,
        validator: validator,
        fingerprinter: SystemFileFingerprinter()
    )

    let discoveries = try await scanner.scan(context: CoreTestFixtures.context())

    #expect(discoveries.isEmpty)
}

private final class SystemDataFixture {
    let root: URL
    let validator: SafePathValidator

    init(logs: [String: Int], crashReportFiles: [String: Int] = [:]) throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (name, count) in logs {
            let directory = root.appending(path: name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(repeating: 0x41, count: count).write(to: directory.appending(path: "log.bin"))
        }
        if !crashReportFiles.isEmpty {
            let directory = root.appending(path: "DiagnosticReports")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (name, count) in crashReportFiles {
                try Data(repeating: 0x42, count: count).write(to: directory.appending(path: name))
            }
        }
        validator = SafePathValidator(allowedRoots: [root], forbiddenExactPaths: [])
    }

    func scanner() -> SystemDataScanner {
        SystemDataScanner(
            logRoot: root,
            validator: validator,
            fingerprinter: SystemFileFingerprinter()
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}
