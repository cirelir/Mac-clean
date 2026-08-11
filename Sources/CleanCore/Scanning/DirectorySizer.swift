import Foundation

public protocol DirectorySizing: Sendable {
    func size(of url: URL) async throws -> UInt64
}

public enum DirectorySizingError: Error, Equatable {
    case cannotEnumerate(URL)
    case sizeOverflow
}

public struct DirectorySizer: DirectorySizing, Sendable {
    public init() {}

    public func size(of url: URL) async throws -> UInt64 {
        try Task.checkCancellation()

        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        let rootValues = try url.resourceValues(forKeys: Set(keys))

        if rootValues.isSymbolicLink == true {
            return 0
        }
        if rootValues.isRegularFile == true {
            return try adding(UInt64(max(0, rootValues.fileSize ?? 0)), to: 0)
        }

        var enumerationFailureURL: URL?
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            errorHandler: { failingURL, _ in
                if enumerationFailureURL == nil {
                    enumerationFailureURL = failingURL
                }
                return false
            }
        ) else {
            throw DirectorySizingError.cannotEnumerate(url)
        }

        var total: UInt64 = 0
        var entryCount = 0
        while let entry = enumerator.nextObject() as? URL {
            entryCount += 1
            if entryCount.isMultiple(of: 128) {
                try Task.checkCancellation()
            }

            let values = try entry.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            guard values.isRegularFile == true else {
                continue
            }

            total = try adding(UInt64(max(0, values.fileSize ?? 0)), to: total)
        }

        if let enumerationFailureURL {
            throw DirectorySizingError.cannotEnumerate(enumerationFailureURL)
        }
        try Task.checkCancellation()
        return total
    }

    private func adding(_ size: UInt64, to total: UInt64) throws -> UInt64 {
        let (sum, overflow) = total.addingReportingOverflow(size)
        guard !overflow else {
            throw DirectorySizingError.sizeOverflow
        }
        return sum
    }
}
