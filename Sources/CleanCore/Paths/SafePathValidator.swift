import Foundation

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

    public init(allowedRoots: [URL], forbiddenExactPaths: Set<URL>) {
        self.allowedRoots = allowedRoots
        self.forbiddenExactPaths = forbiddenExactPaths
    }

    public func validate(_ url: URL) throws -> ValidatedPath {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PathValidationError.missingTarget
        }

        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        let roots = allowedRoots.map { $0.standardizedFileURL.resolvingSymlinksInPath() }

        guard let root = roots.first(where: {
            canonical.pathComponents.starts(with: $0.pathComponents)
        }) else {
            throw PathValidationError.outsideAllowedRoots
        }
        guard !roots.contains(canonical) else {
            throw PathValidationError.targetIsAllowedRoot
        }
        guard !forbiddenExactPaths.contains(canonical) else {
            throw PathValidationError.forbiddenTarget
        }

        return ValidatedPath(originalURL: url, canonicalURL: canonical, allowedRoot: root)
    }
}
