import Foundation

public enum WeeklyScanScheduler {
    public static let interval: TimeInterval = 7 * 24 * 60 * 60

    public static func isDue(lastScan: Date?, now: Date) -> Bool {
        guard let lastScan else { return true }
        return now.timeIntervalSince(lastScan) >= interval
    }
}
