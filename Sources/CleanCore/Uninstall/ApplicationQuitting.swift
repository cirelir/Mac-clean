import Foundation

/// Quits a running application before its uninstall. The UI layer provides
/// the real implementation (NSWorkspace); the protocol lives in CleanCore so
/// the uninstall flow and its tests stay AppKit-independent.
public protocol ApplicationQuitting: Sendable {
    /// Gracefully asks the application to quit and waits (bounded) for it to
    /// exit. Returns true once the application is no longer running; returns
    /// false when the application could not be quit (or was never running is
    /// treated as success — there is nothing to quit).
    func quit(_ application: InstalledApplication) async -> Bool
}
