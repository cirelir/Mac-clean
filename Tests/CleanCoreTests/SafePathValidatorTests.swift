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
