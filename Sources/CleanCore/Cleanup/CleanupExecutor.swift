import Foundation

public protocol CleanupExecuting: Sendable {
    func execute(_ plan: CleanupPlan) async -> CleanupResult
}

public enum CleanupSkipReason: String, Hashable, Codable, Sendable {
    case fingerprintChanged
    case pathRejected
    case unsupportedAction
}

public enum CleanupItemStatus: Hashable, Sendable {
    case success(estimatedDeletedBytes: UInt64)
    case partial(estimatedDeletedBytes: UInt64, message: String)
    case skipped(CleanupSkipReason)
    case failed(message: String)
}

struct CleanupExecutionHooks: Sendable {
    let beforePlanExecution: (@Sendable () async -> Void)?
    let executionDidQueue: (@Sendable () async -> Void)?
    let afterRootOpenedAndFingerprinted: (@Sendable (CleanupPlanItem) throws -> Void)?
    let beforeRemovingEntry: (@Sendable (String) throws -> Void)?

    init(
        beforePlanExecution: (@Sendable () async -> Void)? = nil,
        executionDidQueue: (@Sendable () async -> Void)? = nil,
        afterRootOpenedAndFingerprinted: (@Sendable (CleanupPlanItem) throws -> Void)? = nil,
        beforeRemovingEntry: (@Sendable (String) throws -> Void)? = nil
    ) {
        self.beforePlanExecution = beforePlanExecution
        self.executionDidQueue = executionDidQueue
        self.afterRootOpenedAndFingerprinted = afterRootOpenedAndFingerprinted
        self.beforeRemovingEntry = beforeRemovingEntry
    }
}

public struct CleanupItemResult: Hashable, Sendable {
    public let candidateID: UUID
    public let status: CleanupItemStatus

    public init(candidateID: UUID, status: CleanupItemStatus) {
        self.candidateID = candidateID
        self.status = status
    }
}

public struct CleanupResult: Hashable, Sendable {
    public let planID: UUID
    public let items: [CleanupItemResult]

    public init(planID: UUID, items: [CleanupItemResult]) {
        self.planID = planID
        self.items = items
    }
}

public actor CleanupExecutor: CleanupExecuting {
    private let validator: SafePathValidator
    private let hooks: CleanupExecutionHooks
    private var executionInProgress = false
    private var executionWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        validator: SafePathValidator,
        fingerprinter: any FileFingerprinting = SystemFileFingerprinter(),
        fileManager: FileManager = .default
    ) {
        self.validator = validator
        hooks = CleanupExecutionHooks()
        _ = fingerprinter
        _ = fileManager
    }

    init(
        validator: SafePathValidator,
        fingerprinter: any FileFingerprinting,
        fileManager: FileManager,
        hooks: CleanupExecutionHooks
    ) {
        self.validator = validator
        self.hooks = hooks
        _ = fingerprinter
        _ = fileManager
    }

    public func execute(_ plan: CleanupPlan) async -> CleanupResult {
        await acquireExecutionSlot()
        defer { releaseExecutionSlot() }

        if let beforePlanExecution = hooks.beforePlanExecution {
            await beforePlanExecution()
        }

        var results: [CleanupItemResult] = []
        results.reserveCapacity(plan.items.count)

        for item in plan.items {
            results.append(execute(item))
        }

        return CleanupResult(planID: plan.id, items: results)
    }

    private func execute(_ item: CleanupPlanItem) -> CleanupItemResult {
        let validatedPath: ValidatedPath
        do {
            validatedPath = try validator.validate(item.canonicalURL)
        } catch {
            return CleanupItemResult(
                candidateID: item.candidateID,
                status: .skipped(.pathRejected)
            )
        }

        let plannedURL = item.canonicalURL.standardizedFileURL
        guard plannedURL.path == validatedPath.canonicalURL.path else {
            return CleanupItemResult(
                candidateID: item.candidateID,
                status: .skipped(.pathRejected)
            )
        }

        let outcome = DescriptorTreeCleaner(hooks: hooks).deleteContents(
            at: validatedPath.canonicalURL,
            expectedFingerprint: item.expectedFingerprint,
            action: item.action,
            item: item
        )

        let status: CleanupItemStatus
        switch outcome {
        case .success(let estimatedDeletedBytes):
            status = .success(estimatedDeletedBytes: estimatedDeletedBytes)
        case .partial(let estimatedDeletedBytes, let message):
            status = .partial(
                estimatedDeletedBytes: estimatedDeletedBytes,
                message: message
            )
        case .failed(let message):
            status = .failed(message: message)
        case .skipped(let reason):
            status = .skipped(reason)
        }

        return CleanupItemResult(candidateID: item.candidateID, status: status)
    }

    private func acquireExecutionSlot() async {
        guard executionInProgress else {
            executionInProgress = true
            return
        }

        await withCheckedContinuation { continuation in
            executionWaiters.append(continuation)
            if let executionDidQueue = hooks.executionDidQueue {
                Task {
                    await executionDidQueue()
                }
            }
        }
    }

    private func releaseExecutionSlot() {
        guard !executionWaiters.isEmpty else {
            executionInProgress = false
            return
        }

        executionWaiters.removeFirst().resume()
    }
}
