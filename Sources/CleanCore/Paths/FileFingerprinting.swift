import Darwin
import Foundation

public protocol FileFingerprinting: Sendable {
    func fingerprint(at url: URL) throws -> FileFingerprint
}

public enum FileFingerprintError: Error, Equatable {
    case unreadable(errno: Int32)
}

public struct SystemFileFingerprinter: FileFingerprinting, Sendable {
    public init() {}

    public func fingerprint(at url: URL) throws -> FileFingerprint {
        var value = stat()
        guard lstat(url.path, &value) == 0 else {
            throw FileFingerprintError.unreadable(errno: errno)
        }

        let modified = Date(
            timeIntervalSince1970: TimeInterval(value.st_mtimespec.tv_sec)
                + TimeInterval(value.st_mtimespec.tv_nsec) / 1_000_000_000
        )

        return FileFingerprint(
            deviceID: UInt64(value.st_dev),
            fileID: UInt64(value.st_ino),
            ownerID: value.st_uid,
            sizeBytes: UInt64(max(0, value.st_size)),
            modifiedAt: modified
        )
    }
}
