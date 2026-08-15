import Foundation

enum ApplicationCacheScannerError: Error, Equatable {
    case identityChanged(URL)
}

public struct ApplicationCacheScanner: Scanner, Sendable {
    public let id: String
    public let cacheRoot: URL
    public let validator: SafePathValidator
    public let fingerprinter: any FileFingerprinting
    public let directorySizer: any DirectorySizing

    public init(
        id: String = "application-cache",
        cacheRoot: URL,
        validator: SafePathValidator,
        fingerprinter: any FileFingerprinting,
        directorySizer: any DirectorySizing = DirectorySizer()
    ) {
        self.id = id
        self.cacheRoot = cacheRoot
        self.validator = validator
        self.fingerprinter = fingerprinter
        self.directorySizer = directorySizer
    }

    public func scan(context: ScanContext) async throws -> [DiscoveredItem] {
        let pinnedCacheRoot = try validator.pinnedAllowedRoot(for: cacheRoot)
        let children = try FileManager.default.contentsOfDirectory(
            at: pinnedCacheRoot,
            includingPropertiesForKeys: nil
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        let matcher = ApplicationNameMatcher(
            installedApplications: context.inventory.installedApplications
        )

        var discoveries: [DiscoveredItem] = []
        discoveries.reserveCapacity(children.count)

        for child in children {
            try Task.checkCancellation()
            do {
                discoveries.append(
                    try await discovery(
                        for: child,
                        matcher: matcher
                    )
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch ApplicationCacheScannerError.identityChanged(let url) {
                // A cache object that changed while it was being sized must
                // fail the scan closed: its data can no longer be trusted.
                throw ApplicationCacheScannerError.identityChanged(url)
            } catch {
                // A single cache directory that cannot be validated, sized, or
                // fingerprinted must not abort the whole scan. macOS protects
                // some caches (e.g. CloudKit) from user-process enumeration;
                // others may vanish mid-scan. Skip the child and keep going.
                continue
            }
        }

        return discoveries
    }

    private func discovery(
        for child: URL,
        matcher: ApplicationNameMatcher
    ) async throws -> DiscoveredItem {
        let validatedPath = try validator.validate(child)
        let fingerprint = try fingerprinter.fingerprint(at: validatedPath.canonicalURL)
        let size = try await directorySizer.size(of: validatedPath.canonicalURL)
        let values = try validatedPath.canonicalURL.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        let isCanonicalChild = child.standardizedFileURL.path
            == validatedPath.canonicalURL.path
        let isCacheDirectory = isCanonicalChild
            && values.isDirectory == true
            && values.isSymbolicLink != true
        let application = isCacheDirectory
            ? matcher.match(directoryName: child.lastPathComponent)
            : nil
        let candidateEvidence = evidence(for: application)
        let finalFingerprint = try fingerprinter.fingerprint(
            at: validatedPath.canonicalURL
        )
        guard finalFingerprint == fingerprint else {
            throw ApplicationCacheScannerError.identityChanged(
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
            evidence: candidateEvidence,
            kind: discoveryKind(application: application, isCacheDirectory: isCacheDirectory)
        )
    }

    private func discoveryKind(
        application: InstalledApplication?,
        isCacheDirectory: Bool
    ) -> DiscoveryKind {
        if application != nil {
            return .regenerableApplicationCache
        }
        // An unknown cache directory has no installed owner, so it is an
        // inferred residual that the user can confirm and remove.
        if isCacheDirectory {
            return .orphanResidual(confidence: .inferred)
        }
        return .unknown
    }

    private func evidence(for application: InstalledApplication?) -> CandidateEvidence {
        if let application {
            return CandidateEvidence(
                scannerID: id,
                ruleID: "installed-bundle-id-cache-directory",
                ownerName: application.name,
                ownerBundleID: application.bundleID,
                explanation: "The cache directory name exactly matches an installed application's bundle ID"
            )
        }

        return CandidateEvidence(
            scannerID: id,
            ruleID: "unknown-cache-directory",
            ownerName: nil,
            ownerBundleID: nil,
            explanation: "已核对系统安装的应用，未找到匹配的 Bundle ID 或应用名，推断应用已卸载；缓存残留可安全清除"
        )
    }
}
