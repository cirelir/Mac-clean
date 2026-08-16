import AppKit
import CleanCore

/// Quits a running application through NSWorkspace before uninstalling it.
/// Only a graceful terminate is issued — no force-quit — and the wait for the
/// process to exit is bounded, so user data in unsaved documents is never
/// put at risk by the uninstall flow.
public struct NSWorkspaceApplicationQuitter: ApplicationQuitting {
    public init() {}

    public func quit(_ application: InstalledApplication) async -> Bool {
        guard let runningApplication = NSWorkspace.shared
            .runningApplications
            .first(where: { $0.bundleIdentifier == application.bundleID })
        else {
            // Not running; there is nothing to quit.
            return true
        }

        guard runningApplication.terminate() else {
            return false
        }

        // A graceful quit can take a moment (e.g. a save prompt); poll for
        // up to ~15 seconds before giving up. If the user answers a save
        // dialog, isTerminated flips as soon as the app actually exits.
        for _ in 0..<60 {
            try? await Task.sleep(for: .milliseconds(250))
            if runningApplication.isTerminated {
                return true
            }
        }
        return false
    }
}
