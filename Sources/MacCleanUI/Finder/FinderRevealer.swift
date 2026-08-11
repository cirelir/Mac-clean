import AppKit
import CleanCore
import Foundation

public protocol FinderRevealing: Sendable {
    @MainActor func reveal(_ urls: [URL])
}

public struct NSWorkspaceFinderRevealer: FinderRevealing {
    public init() {}

    @MainActor
    public func reveal(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}

public enum FinderRevealState: Equatable, Sendable {
    case available(URL)
    case unavailable(UnavailableReason)

    public enum UnavailableReason: Equatable, Sendable {
        case missing, inaccessible
    }

    public init(url: URL, fileManager: FileManager = .default) {
        guard fileManager.fileExists(atPath: url.path) else {
            self = .unavailable(.missing)
            return
        }
        guard fileManager.isReadableFile(atPath: url.path) else {
            self = .unavailable(.inaccessible)
            return
        }
        self = .available(url)
    }

    public init(candidate: CleanupCandidate, fileManager: FileManager = .default) {
        self.init(url: candidate.sourceURL, fileManager: fileManager)
    }
}
