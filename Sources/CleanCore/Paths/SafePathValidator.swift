import Darwin
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
    private let allowedRootPins: [AllowedRootPin]
    private let pinnedAllowedRoots: [URL]

    public init(allowedRoots: [URL], forbiddenExactPaths: Set<URL>) {
        let pins = allowedRoots.compactMap(Self.pinAllowedRoot)
        self.allowedRoots = allowedRoots
        allowedRootPins = pins
        pinnedAllowedRoots = pins.map(\.canonicalURL)
        self.forbiddenExactPaths = Set(forbiddenExactPaths.map {
            $0.standardizedFileURL.resolvingSymlinksInPath()
        })
    }

    public func validate(_ url: URL) throws -> ValidatedPath {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PathValidationError.missingTarget
        }

        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()

        guard let root = pinnedAllowedRoots.first(where: {
            canonical.pathComponents.starts(with: $0.pathComponents)
        }) else {
            throw PathValidationError.outsideAllowedRoots
        }
        guard !pinnedAllowedRoots.contains(where: { $0.path == canonical.path }) else {
            throw PathValidationError.targetIsAllowedRoot
        }
        guard !forbiddenExactPaths.contains(canonical) else {
            throw PathValidationError.forbiddenTarget
        }

        return ValidatedPath(originalURL: url, canonicalURL: canonical, allowedRoot: root)
    }

    func pinnedAllowedRoot(for configuredRoot: URL) throws -> URL {
        let configured = configuredRoot.standardizedFileURL
        guard
            let pin = allowedRootPins.first(where: {
                $0.configuredURL.path == configured.path
            }),
            Self.isDirectDirectory(configured),
            configured.resolvingSymlinksInPath().path == pin.canonicalURL.path
        else {
            throw PathValidationError.outsideAllowedRoots
        }

        return pin.canonicalURL
    }

    private static func pinAllowedRoot(_ url: URL) -> AllowedRootPin? {
        let configured = url.standardizedFileURL
        guard isDirectDirectory(configured) else {
            return nil
        }

        return AllowedRootPin(
            configuredURL: configured,
            canonicalURL: configured.resolvingSymlinksInPath()
        )
    }

    private static func isDirectDirectory(_ url: URL) -> Bool {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            return false
        }
        guard status.st_mode & S_IFMT == S_IFDIR else {
            return false
        }
        guard let values = try? url.resourceValues(forKeys: [.isAliasFileKey]) else {
            return false
        }
        return values.isAliasFile != true
    }
}

private struct AllowedRootPin: Sendable {
    let configuredURL: URL
    let canonicalURL: URL
}
