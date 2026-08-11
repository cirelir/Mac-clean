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
    case success(reclaimedBytes: UInt64)
    case skipped(CleanupSkipReason)
    case failed(message: String)
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
    private let fingerprinter: any FileFingerprinting
    private let fileManager: FileManager

    public init(
        validator: SafePathValidator,
        fingerprinter: any FileFingerprinting = SystemFileFingerprinter(),
        fileManager: FileManager = .default
    ) {
        self.validator = validator
        self.fingerprinter = fingerprinter
        self.fileManager = fileManager
    }

    public func execute(_ plan: CleanupPlan) async -> CleanupResult {
        var results: [CleanupItemResult] = []
        results.reserveCapacity(plan.items.count)

        for item in plan.items {
            results.append(await execute(item))
        }

        return CleanupResult(planID: plan.id, items: results)
    }

    private func execute(_ item: CleanupPlanItem) async -> CleanupItemResult {
        let validatedPath: ValidatedPath
        do {
            validatedPath = try validator.validate(item.canonicalURL)
        } catch {
            return CleanupItemResult(
                candidateID: item.candidateID,
                status: .skipped(.pathRejected)
            )
        }

        let freshFingerprint: FileFingerprint
        do {
            freshFingerprint = try fingerprinter.fingerprint(at: item.canonicalURL)
        } catch {
            return CleanupItemResult(
                candidateID: item.candidateID,
                status: .skipped(.fingerprintChanged)
            )
        }

        guard freshFingerprint == item.expectedFingerprint else {
            return CleanupItemResult(
                candidateID: item.candidateID,
                status: .skipped(.fingerprintChanged)
            )
        }

        guard item.action == .deleteContentsPreservingRoot else {
            return CleanupItemResult(
                candidateID: item.candidateID,
                status: .skipped(.unsupportedAction)
            )
        }

        do {
            let children = try fileManager.contentsOfDirectory(
                at: validatedPath.canonicalURL,
                includingPropertiesForKeys: nil
            )
            var reclaimedBytes: UInt64 = 0

            for child in children {
                let childSize = try await DirectorySizer().size(of: child)
                let (newTotal, overflow) = reclaimedBytes.addingReportingOverflow(childSize)
                guard !overflow else {
                    throw CleanupExecutionError.reclaimedSizeOverflow
                }
                try fileManager.removeItem(at: child)
                reclaimedBytes = newTotal
            }

            return CleanupItemResult(
                candidateID: item.candidateID,
                status: .success(reclaimedBytes: reclaimedBytes)
            )
        } catch {
            return CleanupItemResult(
                candidateID: item.candidateID,
                status: .failed(message: String(describing: error))
            )
        }
    }
}

private enum CleanupExecutionError: Error {
    case reclaimedSizeOverflow
}
