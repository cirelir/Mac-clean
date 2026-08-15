import Foundation

enum DeveloperDataScannerError: Error, Equatable {
    case identityChanged(URL)
}

/// Discovers cleanable developer-tool data:
///
/// - Xcode `DerivedData` project directories, owned by Xcode
///   (`com.apple.dt.Xcode`), are green candidates only when Xcode is
///   installed and not running, because build artifacts are regenerable.
/// - Top-level `~/Library/Developer` directories (simulators, test devices,
///   downloads) are listed as inferred residuals for the user to confirm and
///   remove; the Xcode directory itself is excluded because its cleanable
///   content is covered by the DerivedData scan.
///
/// Children that cannot be validated, sized, or fingerprinted are skipped so
/// a single bad entry never aborts the whole scan; root pinning and identity
/// changes stay fatal.
public struct DeveloperDataScanner: Scanner, Sendable {
    public static let xcodeBundleID = "com.apple.dt.Xcode"
    static let xcodeDirectoryName = "Xcode"

    public let id: String
    public let derivedDataRoot: URL
    public let developerRoot: URL
    public let validator: SafePathValidator
    public let fingerprinter: any FileFingerprinting
    public let directorySizer: any DirectorySizing

    public init(
        id: String = "developer-data",
        derivedDataRoot: URL,
        developerRoot: URL? = nil,
        validator: SafePathValidator,
        fingerprinter: any FileFingerprinting,
        directorySizer: any DirectorySizing = DirectorySizer()
    ) {
        self.id = id
        self.derivedDataRoot = derivedDataRoot
        self.developerRoot = developerRoot ?? derivedDataRoot.deletingLastPathComponent()
        self.validator = validator
        self.fingerprinter = fingerprinter
        self.directorySizer = directorySizer
    }

    public func scan(context: ScanContext) async throws -> [DiscoveredItem] {
        var discoveries: [DiscoveredItem] = []
        discoveries.append(contentsOf: try await scanDerivedData())
        discoveries.append(contentsOf: try await scanDeveloperTopLevel())
        return discoveries
    }

    private func scanDerivedData() async throws -> [DiscoveredItem] {
        guard FileManager.default.fileExists(atPath: derivedDataRoot.path) else {
            // No Xcode build data yet is not an error.
            return []
        }

        let pinnedRoot = try validator.pinnedAllowedRoot(for: derivedDataRoot)
        let children = try FileManager.default.contentsOfDirectory(
            at: pinnedRoot,
            includingPropertiesForKeys: nil
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }

        var discoveries: [DiscoveredItem] = []
        discoveries.reserveCapacity(children.count)

        for child in children {
            try Task.checkCancellation()
            do {
                guard let discovery = try await discovery(
                    for: child,
                    kind: .developerData,
                    evidence: CandidateEvidence(
                        scannerID: id,
                        ruleID: "xcode-derived-data",
                        ownerName: "Xcode",
                        ownerBundleID: Self.xcodeBundleID,
                        explanation: "Xcode build artifacts are regenerable on the next build"
                    )
                ) else {
                    continue
                }
                discoveries.append(discovery)
            } catch is CancellationError {
                throw CancellationError()
            } catch DeveloperDataScannerError.identityChanged(let url) {
                throw DeveloperDataScannerError.identityChanged(url)
            } catch {
                continue
            }
        }

        return discoveries
    }

    private func scanDeveloperTopLevel() async throws -> [DiscoveredItem] {
        guard FileManager.default.fileExists(atPath: developerRoot.path) else {
            return []
        }
        // Auxiliary scan: when the developer root is not pinned by the
        // validator (e.g. it did not exist at startup), skip it gracefully.
        guard let pinnedRoot = try? validator.pinnedAllowedRoot(for: developerRoot) else {
            return []
        }
        let children = try FileManager.default.contentsOfDirectory(
            at: pinnedRoot,
            includingPropertiesForKeys: nil
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }

        var discoveries: [DiscoveredItem] = []
        for child in children where child.lastPathComponent != Self.xcodeDirectoryName {
            try Task.checkCancellation()
            do {
                guard let discovery = try await discovery(
                    for: child,
                    kind: .orphanResidual(confidence: .inferred),
                    evidence: CandidateEvidence(
                        scannerID: id,
                        ruleID: "developer-top-level-data",
                        ownerName: nil,
                        ownerBundleID: nil,
                        explanation: "Developer data directory (simulators, caches); confirm before removing"
                    )
                ) else {
                    continue
                }
                discoveries.append(discovery)
            } catch is CancellationError {
                throw CancellationError()
            } catch DeveloperDataScannerError.identityChanged(let url) {
                throw DeveloperDataScannerError.identityChanged(url)
            } catch {
                continue
            }
        }

        return discoveries
    }

    private func discovery(
        for child: URL,
        kind: DiscoveryKind,
        evidence: CandidateEvidence
    ) async throws -> DiscoveredItem? {
        let validatedPath = try validator.validate(child)
        let fingerprint = try fingerprinter.fingerprint(at: validatedPath.canonicalURL)
        let size = try await directorySizer.size(of: validatedPath.canonicalURL)
        let values = try validatedPath.canonicalURL.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        let isCanonicalChild = child.standardizedFileURL.path
            == validatedPath.canonicalURL.path
        let isDirectory = isCanonicalChild
            && values.isDirectory == true
            && values.isSymbolicLink != true
        guard isDirectory, size > 0 else {
            return nil
        }

        let finalFingerprint = try fingerprinter.fingerprint(
            at: validatedPath.canonicalURL
        )
        guard finalFingerprint == fingerprint else {
            throw DeveloperDataScannerError.identityChanged(
                validatedPath.canonicalURL
            )
        }

        return DiscoveredItem(
            displayName: child.lastPathComponent,
            sourceURL: child,
            validatedPath: validatedPath,
            sizeBytes: size,
            modifiedAt: fingerprint.modifiedAt,
            fingerprint: fingerprint,
            evidence: evidence,
            kind: kind
        )
    }
}
