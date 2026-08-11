import Foundation
import Testing
@testable import MacCleanUI

@Test func weeklyScanIsDueAtSevenDays() {
    let last = Date(timeIntervalSince1970: 1_700_000_000)

    #expect(WeeklyScanScheduler.isDue(
        lastScan: last,
        now: last.addingTimeInterval(7 * 24 * 60 * 60)
    ))
    #expect(!WeeklyScanScheduler.isDue(
        lastScan: last,
        now: last.addingTimeInterval(6 * 24 * 60 * 60)
    ))
}

@Test func weeklyScanIsDueWhenNoScanWasRecorded() {
    #expect(WeeklyScanScheduler.isDue(lastScan: nil, now: UITestFixtures.timestamp))
}

@Test func deniedNotificationAuthorizationIsNotRequestedAgain() async {
    let client = NotificationClientStub(status: .notDetermined, requestResult: false)
    let service = UserNotificationService(client: client)

    await service.sendCleanupSummary(estimatedDeletedBytes: 1_024, pendingReviewCount: 2)
    await service.sendCleanupSummary(estimatedDeletedBytes: 2_048, pendingReviewCount: 1)

    let snapshot = await client.snapshot()
    #expect(snapshot.requestCount == 1)
    #expect(snapshot.notifications.isEmpty)
}

@Test func deniedNotificationStatusDoesNotPrompt() async {
    let client = NotificationClientStub(status: .denied, requestResult: true)
    let service = UserNotificationService(client: client)

    let authorized = await service.requestAuthorizationIfNeeded()
    #expect(!authorized)

    let snapshot = await client.snapshot()
    #expect(snapshot.requestCount == 0)
}

@Test func authorizedCleanupSummaryContainsOnlyAggregateValues() async {
    let client = NotificationClientStub(status: .authorized, requestResult: true)
    let service = UserNotificationService(client: client)

    await service.sendCleanupSummary(estimatedDeletedBytes: 1_024, pendingReviewCount: 3)

    let snapshot = await client.snapshot()
    #expect(snapshot.requestCount == 0)
    #expect(snapshot.notifications == [
        CleanupSummaryNotification(
            title: "Mac Clean Weekly Summary",
            body: "Estimated cleaned data: 1024 bytes. Pending review: 3."
        )
    ])
}

private actor NotificationClientStub: NotificationCenterClient {
    private var status: NotificationAuthorizationState
    private let requestResult: Bool
    private var requestCount = 0
    private var notifications: [CleanupSummaryNotification] = []

    init(status: NotificationAuthorizationState, requestResult: Bool) {
        self.status = status
        self.requestResult = requestResult
    }

    func authorizationState() async -> NotificationAuthorizationState {
        status
    }

    func requestAuthorization() async throws -> Bool {
        requestCount += 1
        status = requestResult ? .authorized : .denied
        return requestResult
    }

    func deliver(_ notification: CleanupSummaryNotification) async throws {
        notifications.append(notification)
    }

    func snapshot() -> (requestCount: Int, notifications: [CleanupSummaryNotification]) {
        (requestCount, notifications)
    }
}
