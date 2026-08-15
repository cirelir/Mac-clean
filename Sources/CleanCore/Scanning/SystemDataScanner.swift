import Foundation

enum SystemDataScannerError: Error, Equatable {
    case identityChanged(URL)
}

/// Discovers cleanable "System Data" (系统数据) inside the user log root:
///
/// - Per-application log directories (matched to an installed application by
///   display name) are reported as rotatable logs.
/// - The crash/diagnostic reports directory (e.g. `DiagnosticReports`) is
///   reported as owner-less system data that is safe to clear.
///
/// Individual children that cannot be validated, sized, or fingerprinted
/// (protected directories, vanished entries) are skipped so a single bad child
/// never aborts the whole scan; root pinning and identity changes stay fatal.
public struct SystemDataScanner: Scanner, Sendable {
    public let id: String
    public let logRoot: URL
    public let crashReportsDirectoryName: String
    public let minimumLogAgeDays: Int
    public let validator: SafePathValidator
    public let fingerprinter: any FileFingerprinting
    public let directorySizer: any DirectorySizing

    public init(
        id: String = "system-data",
        logRoot: URL,
        crashReportsDirectoryName: String = "DiagnosticReports",
        minimumLogAgeDays: Int = 7,
        validator: SafePathValidator,
        fingerprinter: any FileFingerprinting,
        directorySizer: any DirectorySizing = DirectorySizer()
    ) {
        self.id = id
        self.logRoot = logRoot
        self.crashReportsDirectoryName = crashReportsDirectoryName
        self.minimumLogAgeDays = minimumLogAgeDays
        self.validator = validator
        self.fingerprinter = fingerprinter
        self.directorySizer = directorySizer
    }

    public func scan(context: ScanContext) async throws -> [DiscoveredItem] {
        // No logs yet is not an error: there is simply nothing to scan.
        guard FileManager.default.fileExists(atPath: logRoot.path) else {
            return []
        }

        let pinnedLogRoot = try validator.pinnedAllowedRoot(for: logRoot)
        let children = try FileManager.default.contentsOfDirectory(
            at: pinnedLogRoot,
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
                guard let discovery = try await discovery(
                    for: child,
                    matcher: matcher
                ) else {
                    continue
                }
                discoveries.append(discovery)
            } catch is CancellationError {
                throw CancellationError()
            } catch SystemDataScannerError.identityChanged(let url) {
                // A log object that changed while it was being sized must fail
                // the scan closed: its data can no longer be trusted.
                throw SystemDataScannerError.identityChanged(url)
            } catch {
                // A single log that cannot be validated, sized, or fingerprinted
                // must not abort the whole scan; skip it and keep going.
                continue
            }
        }

        return discoveries
    }

    private func discovery(
        for child: URL,
        matcher: ApplicationNameMatcher
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
            // Only canonical directories with actual bytes are candidates.
            return nil
        }

        let finalFingerprint = try fingerprinter.fingerprint(
            at: validatedPath.canonicalURL
        )
        guard finalFingerprint == fingerprint else {
            throw SystemDataScannerError.identityChanged(
                validatedPath.canonicalURL
            )
        }

        if child.lastPathComponent == crashReportsDirectoryName {
            return crashReportDiscovery(
                for: child,
                validatedPath: validatedPath,
                sizeBytes: size,
                fingerprint: fingerprint
            )
        }

        return applicationLogDiscovery(
            for: child,
            validatedPath: validatedPath,
            matcher: matcher,
            sizeBytes: size,
            fingerprint: fingerprint
        )
    }

    private func applicationLogDiscovery(
        for child: URL,
        validatedPath: ValidatedPath,
        matcher: ApplicationNameMatcher,
        sizeBytes: UInt64,
        fingerprint: FileFingerprint
    ) -> DiscoveredItem {
        let application = matcher.match(directoryName: child.lastPathComponent)
        return DiscoveredItem(
            displayName: child.lastPathComponent,
            sourceURL: child,
            validatedPath: validatedPath,
            sizeBytes: sizeBytes,
            modifiedAt: fingerprint.modifiedAt,
            fingerprint: fingerprint,
            evidence: CandidateEvidence(
                scannerID: id,
                ruleID: "installed-app-log-directory",
                ownerName: application?.name,
                ownerBundleID: application?.bundleID,
                explanation: application == nil
                    ? "No installed application name matches this log directory"
                    : "The log directory name matches an installed application"
            ),
            kind: .rotatableLog(olderThanDays: minimumLogAgeDays)
        )
    }

    private func crashReportDiscovery(
        for child: URL,
        validatedPath: ValidatedPath,
        sizeBytes: UInt64,
        fingerprint: FileFingerprint
    ) -> DiscoveredItem {
        DiscoveredItem(
            displayName: "崩溃报告",
            sourceURL: child,
            validatedPath: validatedPath,
            sizeBytes: sizeBytes,
            modifiedAt: fingerprint.modifiedAt,
            fingerprint: fingerprint,
            evidence: CandidateEvidence(
                scannerID: id,
                ruleID: "crash-reports",
                ownerName: nil,
                ownerBundleID: nil,
                explanation: "Crash and diagnostic reports are regenerable system data"
            ),
            kind: .systemData
        )
    }
}
