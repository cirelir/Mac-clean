import Foundation

public struct ScannerFailure: Error, Hashable, Sendable {
    public let scannerID: String
    public let message: String

    public init(scannerID: String, message: String) {
        self.scannerID = scannerID
        self.message = message
    }
}

public struct ScanReport: Sendable {
    public let candidates: [CleanupCandidate]
    public let failures: [ScannerFailure]

    public init(candidates: [CleanupCandidate], failures: [ScannerFailure]) {
        self.candidates = candidates
        self.failures = failures
    }

    public var totalBytes: UInt64 {
        candidates.reduce(0) { total, candidate in
            let (sum, overflow) = total.addingReportingOverflow(candidate.sizeBytes)
            return overflow ? UInt64.max : sum
        }
    }
}

public protocol ScanCoordinating: Sendable {
    func scan(context: ScanContext) async -> ScanReport
}

public struct ScanCoordinator: ScanCoordinating, Sendable {
    public let scanners: [any Scanner]
    public let classifier: RiskClassifier

    public init(scanners: [any Scanner], classifier: RiskClassifier) {
        self.scanners = scanners
        self.classifier = classifier
    }

    public func scan(context: ScanContext) async -> ScanReport {
        await withTaskGroup(
            of: Result<(String, [DiscoveredItem]), ScannerFailure>.self
        ) { group in
            for scanner in scanners {
                group.addTask {
                    do {
                        return .success((scanner.id, try await scanner.scan(context: context)))
                    } catch {
                        return .failure(
                            ScannerFailure(
                                scannerID: scanner.id,
                                message: String(describing: error)
                            )
                        )
                    }
                }
            }

            var candidates: [CleanupCandidate] = []
            var failures: [ScannerFailure] = []

            for await result in group {
                switch result {
                case .success((let scannerID, let items)):
                    for item in items {
                        do {
                            candidates.append(try classifier.classify(item, context: context))
                        } catch {
                            failures.append(
                                ScannerFailure(
                                    scannerID: scannerID,
                                    message: "Classification failed: \(String(describing: error))"
                                )
                            )
                        }
                    }
                case .failure(let failure):
                    failures.append(failure)
                }
            }

            return ScanReport(
                candidates: candidates.sorted { $0.sizeBytes > $1.sizeBytes },
                failures: failures.sorted { $0.scannerID < $1.scannerID }
            )
        }
    }
}
