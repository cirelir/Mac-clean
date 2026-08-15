import Darwin
import Foundation

/// Enforces a single running instance per user.
///
/// A POSIX advisory lock (`flock`) on a per-user lock file is atomic: exactly
/// one process wins it. The kernel releases the lock automatically when the
/// winning process exits or crashes, so a stale lock can never block a later
/// launch. The losing process asks the winner to show its panel via a
/// distributed notification, then exits without creating a second status item.
@MainActor
enum SingleInstance {
    static let activateNotificationName = NSNotification.Name(
        "com.macclean.statusItem.activate"
    )

    private static var lockDescriptor: Int32 = -1

    private static var lockFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(
                path: "Library/Application Support/MacClean",
                directoryHint: .isDirectory
            )
            .appending(path: "singleton.lock")
    }

    /// Returns true when this process is the first (and only) instance.
    @discardableResult
    static func acquire() -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: lockFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            // Without a writable lock directory we cannot guarantee
            // single-instance semantics; let the app run anyway.
            return true
        }

        let fd = open(lockFileURL.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else {
            return true
        }
        // Keep the descriptor alive for the lifetime of the process so the
        // kernel holds the lock until we exit.
        lockDescriptor = fd
        return flock(fd, LOCK_EX | LOCK_NB) == 0
    }

    /// Asks the already-running instance to bring its panel to the front.
    static func activateExistingInstance() {
        DistributedNotificationCenter.default().post(
            name: activateNotificationName,
            object: nil,
            userInfo: nil
        )
    }
}
