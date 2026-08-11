import Darwin
import Foundation
import Testing
@testable import CleanCore

@Test func fingerprintChangesWhenFileIsReplaced() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let file = directory.appending(path: "candidate")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    try Data([0x01]).write(to: file)
    let fingerprinter = SystemFileFingerprinter()
    let original = try fingerprinter.fingerprint(at: file)

    try FileManager.default.removeItem(at: file)
    try Data([0x02, 0x03]).write(to: file)
    let replacement = try fingerprinter.fingerprint(at: file)

    #expect(
        original.fileID != replacement.fileID
            || original.modifiedAt != replacement.modifiedAt
            || original.sizeBytes != replacement.sizeBytes
    )
}

@Test func fingerprintsSymbolicLinkWithoutFollowingIt() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let target = directory.appending(path: "target")
    let link = directory.appending(path: "link")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    try Data([0x01]).write(to: target)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

    let fingerprinter = SystemFileFingerprinter()
    let targetFingerprint = try fingerprinter.fingerprint(at: target)
    let linkFingerprint = try fingerprinter.fingerprint(at: link)

    #expect(linkFingerprint.fileID != targetFingerprint.fileID)
}

@Test func reportsErrnoWhenFingerprintTargetIsMissing() {
    let missing = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let fingerprinter = SystemFileFingerprinter()

    #expect(throws: FileFingerprintError.unreadable(errno: ENOENT)) {
        try fingerprinter.fingerprint(at: missing)
    }
}
