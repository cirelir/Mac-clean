import Foundation
import UserNotifications

public protocol NotificationSending: Sendable {
    func requestAuthorizationIfNeeded() async -> Bool
    func sendCleanupSummary(estimatedDeletedBytes: UInt64, pendingReviewCount: Int) async
}

public actor UserNotificationService: NotificationSending {
    private let client: any NotificationCenterClient
    private var hasRequestedAuthorization = false

    public init() {
        client = SystemNotificationCenterClient()
    }

    init(client: any NotificationCenterClient) {
        self.client = client
    }

    public func requestAuthorizationIfNeeded() async -> Bool {
        switch await client.authorizationState() {
        case .authorized:
            return true
        case .denied:
            return false
        case .notDetermined:
            guard !hasRequestedAuthorization else { return false }
            hasRequestedAuthorization = true
            return (try? await client.requestAuthorization()) ?? false
        }
    }

    public func sendCleanupSummary(
        estimatedDeletedBytes: UInt64,
        pendingReviewCount: Int
    ) async {
        guard await requestAuthorizationIfNeeded() else { return }

        let notification = CleanupSummaryNotification(
            title: "Mac Clean Weekly Summary",
            body: "Estimated cleaned data: \(estimatedDeletedBytes) bytes. "
                + "Pending review: \(pendingReviewCount)."
        )
        try? await client.deliver(notification)
    }
}

enum NotificationAuthorizationState: Sendable {
    case notDetermined, denied, authorized
}

struct CleanupSummaryNotification: Equatable, Sendable {
    let title: String
    let body: String
}

protocol NotificationCenterClient: Sendable {
    func authorizationState() async -> NotificationAuthorizationState
    func requestAuthorization() async throws -> Bool
    func deliver(_ notification: CleanupSummaryNotification) async throws
}

private struct SystemNotificationCenterClient: NotificationCenterClient, @unchecked Sendable {
    private let center = UNUserNotificationCenter.current()

    func authorizationState() async -> NotificationAuthorizationState {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .authorized, .provisional, .ephemeral:
            return .authorized
        @unknown default:
            return .denied
        }
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert])
    }

    func deliver(_ notification: CleanupSummaryNotification) async throws {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        try await center.add(request)
    }
}
