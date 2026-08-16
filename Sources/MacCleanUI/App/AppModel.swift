import CleanCore
import Foundation
import Observation

public struct CatchUpCleanupSummary: Equatable, Sendable {
    public let estimatedDeletedBytes: UInt64
    public let pendingReviewCount: Int

    public init(estimatedDeletedBytes: UInt64, pendingReviewCount: Int) {
        self.estimatedDeletedBytes = estimatedDeletedBytes
        self.pendingReviewCount = pendingReviewCount
    }
}

public struct AppDependencies {
    public let inventory: any ApplicationInventoryProviding
    public let coordinator: any ScanCoordinating
    public let planner: CleanupPlanner
    public let cleanupExecutor: any CleanupExecuting
    public let uninstaller: any AppUninstalling
    public let quitter: any ApplicationQuitting
    public let audit: any AuditStoring
    public let finder: any FinderRevealing
    public let notifications: any NotificationSending
    public let now: @Sendable () -> Date

    public init(
        inventory: any ApplicationInventoryProviding,
        coordinator: any ScanCoordinating,
        planner: CleanupPlanner,
        cleanupExecutor: any CleanupExecuting,
        uninstaller: any AppUninstalling,
        quitter: any ApplicationQuitting,
        audit: any AuditStoring,
        finder: any FinderRevealing,
        notifications: any NotificationSending,
        now: @escaping @Sendable () -> Date
    ) {
        self.inventory = inventory
        self.coordinator = coordinator
        self.planner = planner
        self.cleanupExecutor = cleanupExecutor
        self.uninstaller = uninstaller
        self.quitter = quitter
        self.audit = audit
        self.finder = finder
        self.notifications = notifications
        self.now = now
    }
}

@MainActor
@Observable
public final class AppModel {
    private enum ScanMode {
        case manual, weeklyCatchUp
    }

    public enum Phase: Equatable {
        case idle, scanning, results, cleaning
    }

    public enum UninstallPhase: Equatable {
        case idle, loadingApps, ready, buildingPlan, uninstalling
    }

    public struct State {
        public var phase: Phase = .idle
        public var candidates: [CleanupCandidate] = []
        public var failures: [ScannerFailure] = []
        public var lastScan: Date?
        public var errorMessage: String?
        public var lastCleanupOutcomes: [String] = []

        public var uninstallPhase: UninstallPhase = .idle
        public var uninstallableApplications: [InstalledApplication] = []
        public var runningBundleIDs: Set<String> = []
        public var selectedUninstallApplication: InstalledApplication?
        public var uninstallPlan: AppUninstallPlan?
        public var uninstallOutcomes: [String] = []
        public var uninstallErrorMessage: String?

        public init() {}
    }

    public private(set) var state = State()

    @ObservationIgnored
    private let dependencies: AppDependencies

    @ObservationIgnored
    private var currentScanID: UUID?

    @ObservationIgnored
    private var scanGeneration: UInt64 = 0

    @ObservationIgnored
    private var catchUpInProgress = false

    public init(dependencies: AppDependencies) {
        self.dependencies = dependencies
    }

    public var estimatedReclaimableBytes: UInt64 {
        state.candidates
            .lazy
            .filter { $0.risk == .green }
            .reduce(0) { total, candidate in
                let (sum, overflow) = total.addingReportingOverflow(candidate.sizeBytes)
                return overflow ? UInt64.max : sum
            }
    }

    public var reclaimableBytes: UInt64 {
        estimatedReclaimableBytes
    }

    public var greenSummary: String {
        "\(state.candidates.count { $0.risk == .green }) 项"
    }

    public var yellowSummary: String {
        "\(state.candidates.count { $0.risk == .yellow }) 项"
    }

    public func scan() async {
        guard !catchUpInProgress else { return }
        _ = await performScan(mode: .manual)
    }

    private func performScan(mode: ScanMode) async -> Bool {
        guard state.phase != .cleaning else { return false }

        scanGeneration &+= 1
        let generation = scanGeneration
        state.phase = .scanning
        state.candidates = []
        state.failures = []
        state.errorMessage = nil
        state.lastCleanupOutcomes = []
        currentScanID = nil

        do {
            let inventory = try await dependencies.inventory.inventory()
            guard generation == scanGeneration else { return false }
            let report = await dependencies.coordinator.scan(
                context: ScanContext(inventory: inventory, now: dependencies.now())
            )
            guard generation == scanGeneration else { return false }

            state.candidates = report.candidates
            state.failures = report.failures
            if mode == .weeklyCatchUp, !report.failures.isEmpty {
                currentScanID = nil
                state.phase = .results
                return false
            }

            let completedAt = dependencies.now()
            try dependencies.audit.recordScan(at: completedAt)
            state.lastScan = completedAt
            currentScanID = UUID()
            state.phase = .results
            return true
        } catch {
            guard generation == scanGeneration else { return false }
            state.candidates = []
            state.failures = []
            currentScanID = nil
            state.errorMessage = String(describing: error)
            state.phase = .idle
            return false
        }
    }

    @discardableResult
    public func performCatchUpScanIfDue() async -> CatchUpCleanupSummary? {
        guard
            !catchUpInProgress,
            state.phase != .scanning,
            state.phase != .cleaning
        else { return nil }

        let lastScan: Date?
        do {
            lastScan = try dependencies.audit.latestScanDate()
        } catch {
            state.errorMessage = String(describing: error)
            return nil
        }

        guard WeeklyScanScheduler.isDue(lastScan: lastScan, now: dependencies.now()) else {
            return nil
        }

        catchUpInProgress = true
        defer { catchUpInProgress = false }
        guard await performScan(mode: .weeklyCatchUp) else { return nil }

        let pendingReviewCount = state.candidates.count { $0.risk == .yellow }
        let summary: CatchUpCleanupSummary
        if state.candidates.contains(where: { $0.risk == .green }) {
            guard let cleanupSummary = await performCleanup(
                confirmedIDs: [],
                pendingReviewCount: pendingReviewCount
            ) else {
                return nil
            }
            summary = cleanupSummary
        } else {
            summary = CatchUpCleanupSummary(
                estimatedDeletedBytes: 0,
                pendingReviewCount: pendingReviewCount
            )
        }

        await dependencies.notifications.sendCleanupSummary(
            estimatedDeletedBytes: summary.estimatedDeletedBytes,
            pendingReviewCount: summary.pendingReviewCount
        )
        return summary
    }

    public func cleanGreenCandidates() async {
        guard !catchUpInProgress else { return }
        _ = await performCleanup(
            confirmedIDs: [],
            pendingReviewCount: state.candidates.count { $0.risk == .yellow }
        )
    }

    /// Cleans green candidates plus the yellow candidates the user explicitly
    /// selected for confirmation.
    public func clean(candidateIDs: Set<UUID>) async {
        guard !catchUpInProgress, state.phase == .results else { return }
        _ = await performCleanup(
            confirmedIDs: candidateIDs,
            pendingReviewCount: state.candidates.count { $0.risk == .yellow }
        )
    }

    private func performCleanup(
        confirmedIDs: Set<UUID>,
        pendingReviewCount: Int
    ) async -> CatchUpCleanupSummary? {
        guard state.phase == .results, let currentScanID else { return nil }

        let candidates = state.candidates
        let scanID = currentScanID
        let hasWork = confirmedIDs.isEmpty
            ? candidates.contains { $0.risk == .green }
            : candidates.contains { confirmedIDs.contains($0.id) && $0.risk != .red }
        guard hasWork else {
            return CatchUpCleanupSummary(
                estimatedDeletedBytes: 0,
                pendingReviewCount: pendingReviewCount
            )
        }

        state.phase = .cleaning
        state.errorMessage = nil
        let latestInventory: ApplicationInventory
        do {
            latestInventory = try await dependencies.inventory.inventory()
        } catch {
            state.phase = .results
            state.errorMessage = String(describing: error)
            return nil
        }

        let revalidatedCandidates = candidates.filter { candidate in
            switch candidate.risk {
            case .green:
                guard let ownerBundleID = candidate.evidence.ownerBundleID else {
                    // Owner-less system data (e.g. crash reports) has no
                    // application that could have started running to protect.
                    return true
                }
                return !latestInventory.runningBundleIDs.contains(ownerBundleID)
            case .yellow:
                guard confirmedIDs.contains(candidate.id) else {
                    return false
                }
                guard let ownerBundleID = candidate.evidence.ownerBundleID else {
                    return true
                }
                return !latestInventory.runningBundleIDs.contains(ownerBundleID)
            case .red:
                return false
            }
        }
        let plan = dependencies.planner.plan(
            candidates: revalidatedCandidates,
            confirmedIDs: confirmedIDs,
            now: dependencies.now()
        )
        guard !plan.items.isEmpty else {
            state.phase = .results
            _ = await performScan(mode: .manual)
            return nil
        }

        let result = await dependencies.cleanupExecutor.execute(plan)
        let completedAt = dependencies.now()
        let candidatesByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        var auditErrors: [String] = []

        state.lastCleanupOutcomes = result.items.compactMap { item in
            guard let candidate = candidatesByID[item.candidateID] else { return nil }
            switch item.status {
            case .success:
                return "\(candidate.displayName)：已清理"
            case .partial(_, let message):
                return "\(candidate.displayName)：部分完成（\(message)）"
            case .skipped(let reason):
                return "\(candidate.displayName)：跳过（\(skipReasonText(reason))）"
            case .failed(let message):
                return "\(candidate.displayName)：失败（\(message)）"
            }
        }
        appendCleanupLog(plan: plan, result: result, candidatesByID: candidatesByID)

        let protocolMismatch = cleanupProtocolMismatch(plan: plan, result: result)
        if let mismatch = protocolMismatch {
            auditErrors.append(mismatch)
            for plannedItem in plan.items {
                guard let candidate = candidatesByID[plannedItem.candidateID] else { continue }
                do {
                    try dependencies.audit.append(
                        auditRecord(
                            for: candidate,
                            result: CleanupItemResult(
                                candidateID: plannedItem.candidateID,
                                status: .failed(message: mismatch)
                            ),
                            scanID: scanID,
                            timestamp: completedAt
                        )
                    )
                } catch {
                    auditErrors.append(String(describing: error))
                }
            }
        } else {
            for item in result.items {
                guard let candidate = candidatesByID[item.candidateID] else { continue }
                do {
                    try dependencies.audit.append(
                        auditRecord(
                            for: candidate,
                            result: item,
                            scanID: scanID,
                            timestamp: completedAt
                        )
                    )
                } catch {
                    auditErrors.append(String(describing: error))
                }
            }
        }

        let summary = protocolMismatch == nil
            ? cleanupSummary(for: result, pendingReviewCount: pendingReviewCount)
            : nil
        state.phase = .results
        _ = await performScan(mode: .manual)
        let combinedErrors = auditErrors + [state.errorMessage].compactMap { $0 }
        if !combinedErrors.isEmpty {
            state.errorMessage = combinedErrors.joined(separator: "\n")
        }
        return summary
    }

    public func reveal(_ candidate: CleanupCandidate) {
        guard case .available(let url) = FinderRevealState(url: candidate.canonicalURL) else {
            return
        }
        dependencies.finder.reveal([url])
    }

    // MARK: - Application uninstall

    /// Only /System bundles (SIP-protected) can never be uninstalled. Apple's
    /// user-installable apps in /Applications — Xcode, Final Cut, Pages, ... —
    /// are listable, as are third-party input methods under /Library/Input
    /// Methods.
    public func isUninstallable(_ application: InstalledApplication) -> Bool {
        !application.url.path.hasPrefix("/System/")
    }

    public func isRunning(_ application: InstalledApplication) -> Bool {
        state.runningBundleIDs.contains(application.bundleID)
    }

    /// Loads the list of uninstallable installed applications together with
    /// the currently running bundle IDs, so the UI can disable running apps.
    public func loadUninstallableApplications() async {
        guard
            state.uninstallPhase != .uninstalling,
            state.uninstallPhase != .buildingPlan
        else { return }

        state.uninstallPhase = .loadingApps
        state.uninstallErrorMessage = nil
        do {
            let inventory = try await dependencies.inventory.inventory()
            let applications = inventory.installedApplications
                .filter { isUninstallable($0) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            state.uninstallableApplications = applications
            state.runningBundleIDs = inventory.runningBundleIDs
            state.uninstallPhase = .ready
        } catch {
            state.uninstallErrorMessage = String(describing: error)
            state.uninstallPhase = .ready
        }
    }

    /// Builds the uninstall plan (app bundle + matched data items) for the
    /// selected application. Failures — e.g. the app is running — surface in
    /// the uninstallErrorMessage state.
    public func buildUninstallPlan(for application: InstalledApplication) async {
        guard state.uninstallPhase != .uninstalling else { return }
        state.selectedUninstallApplication = application
        state.uninstallPlan = nil
        state.uninstallOutcomes = []
        state.uninstallErrorMessage = nil
        state.uninstallPhase = .buildingPlan
        do {
            let plan = try await dependencies.uninstaller.plan(for: application)
            state.uninstallPlan = plan
            state.uninstallPhase = .ready
        } catch {
            state.uninstallErrorMessage = String(describing: error)
            state.uninstallPhase = .ready
        }
    }

    /// Moves the confirmed plan items into the trash, then refreshes the
    /// application list (the uninstalled app disappears from the inventory).
    public func uninstall(itemIDs: Set<UUID>) async {
        guard
            state.uninstallPhase == .ready,
            let plan = state.uninstallPlan,
            !itemIDs.isEmpty
        else { return }

        let items = plan.items.filter { itemIDs.contains($0.id) }
        guard !items.isEmpty else { return }
        let filteredPlan = AppUninstallPlan(
            id: plan.id,
            application: plan.application,
            items: items
        )

        state.uninstallPhase = .uninstalling
        state.uninstallOutcomes = []
        state.uninstallErrorMessage = nil

        // A running application is quit (gracefully) before anything moves;
        // the plan is kept so the user can retry after quitting manually.
        if state.runningBundleIDs.contains(plan.application.bundleID) {
            let quitSucceeded = await dependencies.quitter.quit(plan.application)
            guard quitSucceeded else {
                state.uninstallErrorMessage = plan.application.name
                    + " 正在运行且未能自动退出，请手动退出后重试。"
                state.uninstallPhase = .ready
                return
            }
        }

        do {
            let result = try await dependencies.uninstaller.execute(filteredPlan)
            let itemByID = Dictionary(
                uniqueKeysWithValues: plan.items.map { ($0.id, $0) }
            )
            state.uninstallOutcomes = result.items.compactMap { item in
                guard let uninstallItem = itemByID[item.itemID] else { return nil }
                switch item.status {
                case .success:
                    return uninstallItem.displayName + "：已移入废纸篓"
                case .partial(_, let message):
                    return uninstallItem.displayName + "：部分完成（" + message + "）"
                case .skipped(let reason):
                    return uninstallItem.displayName + "：跳过（" + skipReasonText(reason) + "）"
                case .failed(let message):
                    return uninstallItem.displayName + "：失败（" + message + "）"
                }
            }
        } catch {
            state.uninstallErrorMessage = String(describing: error)
        }

        state.uninstallPhase = .ready
        state.uninstallPlan = nil
        state.selectedUninstallApplication = nil
        await loadUninstallableApplications()
    }

    private func cleanupProtocolMismatch(
        plan: CleanupPlan,
        result: CleanupResult
    ) -> String? {
        guard result.planID == plan.id else {
            return "Cleanup executor protocol mismatch: result plan ID does not match the requested plan"
        }

        let plannedIDs = plan.items.map(\.candidateID)
        let resultIDs = result.items.map(\.candidateID)
        let uniquePlannedIDs = Set(plannedIDs)
        let uniqueResultIDs = Set(resultIDs)
        guard
            uniquePlannedIDs.count == plannedIDs.count,
            uniqueResultIDs.count == resultIDs.count,
            resultIDs.count == plannedIDs.count,
            uniqueResultIDs == uniquePlannedIDs
        else {
            return "Cleanup executor protocol mismatch: result candidates are not a one-to-one match for the requested plan"
        }

        return nil
    }

    /// Appends a diagnostic line for every cleanup attempt so a failed
    /// move-to-trash can be inspected at ~/Library/Logs/MacCleanCleanup.log.
    private func appendCleanupLog(
        plan: CleanupPlan,
        result: CleanupResult,
        candidatesByID: [UUID: CleanupCandidate]
    ) {
        var lines = [
            "[\(Date().formatted(date: .abbreviated, time: .standard))] plan=\(plan.items.count) result=\(result.items.count)"
        ]
        for item in result.items {
            let name = candidatesByID[item.candidateID]?.displayName
                ?? item.candidateID.uuidString
            let status: String
            switch item.status {
            case .success:
                status = "success"
            case .partial(_, let message):
                status = "partial: \(message)"
            case .skipped(let reason):
                status = "skipped: \(reason.rawValue)"
            case .failed(let message):
                status = "failed: \(message)"
            }
            lines.append("  \(name): \(status)")
        }
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Logs/MacCleanCleanup.log", directoryHint: .isDirectory)
        guard let data = (lines.joined(separator: "\n") + "\n").data(using: .utf8) else {
            return
        }
        if FileManager.default.fileExists(atPath: url.path) {
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    private func skipReasonText(_ reason: CleanupSkipReason) -> String {
        switch reason {
        case .fingerprintChanged: "对象已被替换"
        case .pathRejected: "路径校验未通过"
        case .unsupportedAction: "不支持的操作"
        }
    }

    private func auditRecord(
        for candidate: CleanupCandidate,
        result: CleanupItemResult,
        scanID: UUID,
        timestamp: Date
    ) -> AuditRecord {
        let details = auditDetails(for: result.status)
        return AuditRecord(
            id: UUID(),
            scanID: scanID,
            candidateID: candidate.id,
            sourcePath: candidate.sourceURL.path,
            canonicalPath: candidate.canonicalURL.path,
            scannerID: candidate.evidence.scannerID,
            risk: candidate.risk,
            action: candidate.proposedAction,
            sizeBytes: details.estimatedDeletedBytes,
            timestamp: timestamp,
            outcome: details.outcome,
            message: details.message
        )
    }

    private func auditDetails(
        for status: CleanupItemStatus
    ) -> (estimatedDeletedBytes: UInt64, outcome: AuditOutcome, message: String?) {
        switch status {
        case .success(let estimatedDeletedBytes):
            return (estimatedDeletedBytes, .cleaned, nil)
        case .partial(let estimatedDeletedBytes, let message):
            return (estimatedDeletedBytes, .failed, "Partial cleanup: \(message)")
        case .skipped(let reason):
            return (0, .skipped, "Skipped: \(reason.rawValue)")
        case .failed(let message):
            return (0, .failed, message)
        }
    }

    private func cleanupSummary(
        for result: CleanupResult,
        pendingReviewCount: Int
    ) -> CatchUpCleanupSummary {
        let estimatedDeletedBytes = result.items.reduce(UInt64(0)) { total, item in
            let itemBytes: UInt64
            switch item.status {
            case .success(let estimatedDeletedBytes),
                 .partial(let estimatedDeletedBytes, _):
                itemBytes = estimatedDeletedBytes
            case .skipped, .failed:
                itemBytes = 0
            }

            let (sum, overflow) = total.addingReportingOverflow(itemBytes)
            return overflow ? UInt64.max : sum
        }
        return CatchUpCleanupSummary(
            estimatedDeletedBytes: estimatedDeletedBytes,
            pendingReviewCount: pendingReviewCount
        )
    }
}
