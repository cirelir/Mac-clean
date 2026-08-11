import Foundation
import Testing
@testable import CleanCore

@Test func rejectsAllowedRootItself() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let validator = SafePathValidator(allowedRoots: [root], forbiddenExactPaths: [])

    #expect(throws: PathValidationError.targetIsAllowedRoot) {
        try validator.validate(root)
    }
}

@Test func rejectsSymlinkThatEscapesAllowedRoot() throws {
    let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let root = base.appending(path: "allowed")
    let outside = base.appending(path: "outside")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    let link = root.appending(path: "escape")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    let validator = SafePathValidator(allowedRoots: [root], forbiddenExactPaths: [])

    #expect(throws: PathValidationError.outsideAllowedRoots) {
        try validator.validate(link)
    }
}

@Test func rejectsAnyAllowedRootWhenRootsAreNested() throws {
    let parentRoot = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let nestedRoot = parentRoot.appending(path: "nested")
    try FileManager.default.createDirectory(at: nestedRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: parentRoot) }

    let validator = SafePathValidator(
        allowedRoots: [parentRoot, nestedRoot],
        forbiddenExactPaths: []
    )

    #expect(throws: PathValidationError.targetIsAllowedRoot) {
        try validator.validate(nestedRoot)
    }
}

@Test func rejectsSiblingWhoseNameSharesAllowedRootPrefix() throws {
    let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let root = base.appending(path: "allowed")
    let sibling = base.appending(path: "allowed-escape")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    let validator = SafePathValidator(allowedRoots: [root], forbiddenExactPaths: [])

    #expect(throws: PathValidationError.outsideAllowedRoots) {
        try validator.validate(sibling)
    }
}

@Test func rejectsForbiddenPathContainingDotDot() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let intermediate = root.appending(path: "intermediate")
    let target = root.appending(path: "forbidden")
    try FileManager.default.createDirectory(at: intermediate, withIntermediateDirectories: true)
    try Data().write(to: target)
    defer { try? FileManager.default.removeItem(at: root) }

    let noncanonicalForbidden = URL(
        fileURLWithPath: intermediate.path + "/../forbidden"
    )
    let validator = SafePathValidator(
        allowedRoots: [root],
        forbiddenExactPaths: [noncanonicalForbidden]
    )

    #expect(throws: PathValidationError.forbiddenTarget) {
        try validator.validate(target)
    }
}

@Test func rejectsForbiddenPathThroughSymlinkAlias() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let actualDirectory = root.appending(path: "actual")
    let alias = root.appending(path: "alias")
    let target = actualDirectory.appending(path: "forbidden")
    try FileManager.default.createDirectory(at: actualDirectory, withIntermediateDirectories: true)
    try Data().write(to: target)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actualDirectory)
    defer { try? FileManager.default.removeItem(at: root) }

    let validator = SafePathValidator(
        allowedRoots: [root],
        forbiddenExactPaths: [alias.appending(path: "forbidden")]
    )

    #expect(throws: PathValidationError.forbiddenTarget) {
        try validator.validate(target)
    }
}

@Test func rejectsMissingTarget() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let missing = root.appending(path: "missing")
    let validator = SafePathValidator(allowedRoots: [root], forbiddenExactPaths: [])

    #expect(throws: PathValidationError.missingTarget) {
        try validator.validate(missing)
    }
}

@Test func returnsCanonicalPathAndContainingRootForAllowedTarget() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let directory = root.appending(path: "directory")
    let target = directory.appending(path: "candidate")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data().write(to: target)
    defer { try? FileManager.default.removeItem(at: root) }

    let noncanonicalTarget = URL(
        fileURLWithPath: directory.path + "/../directory/candidate"
    )
    let validator = SafePathValidator(allowedRoots: [root], forbiddenExactPaths: [])

    let validated = try validator.validate(noncanonicalTarget)

    #expect(validated.originalURL == noncanonicalTarget)
    #expect(validated.canonicalURL == target.standardizedFileURL.resolvingSymlinksInPath())
    #expect(validated.allowedRoot == root.standardizedFileURL.resolvingSymlinksInPath())
}
