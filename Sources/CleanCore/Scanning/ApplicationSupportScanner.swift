import Foundation

enum ApplicationSupportScannerError: Error, Equatable {
    case identityChanged(URL)
}

/// Discovers residual (unowned) data under `~/Library/Application Support`.
///
/// Directories that match an installed application (by bundle ID or display
/// name, with fuzzy name-variant matching) are live application data and are
/// skipped entirely. Directories that match nothing are inferred residuals —
/// leftovers of uninstalled apps — and are reported for the user to confirm
/// and move to the trash. System containers (`com.apple.*`), known macOS
/// system service directories, and the app's own data directory are never
/// proposed.
///
/// Children that cannot be validated, sized, or fingerprinted are skipped so a
/// single bad entry never aborts the whole scan; root pinning and identity
/// changes stay fatal.
public struct ApplicationSupportScanner: Scanner, Sendable {
    /// macOS system services keep their data in `~/Library/Application Support`
    /// without a `com.apple.*` prefix; their directories are never proposed.
    static let systemServiceDirectories: Set<String> = [
        "animoji",
        "assistants",
        "addressbook",
        "callhistorydb",
        "callhistorytransactions",
        "clouddocs",
        "controlcenter",
        "crashreporter",
        "differentialprivacy",
        "diskimages",
        "fileprovider",
        "icloud",
        "keyboardservices",
        "knowledge",
        "siri",
        "spotlight",
        "suggestions"
    ]

    public let id: String
    public let supportRoot: URL
    public let validator: SafePathValidator
    public let fingerprinter: any FileFingerprinting
    public let directorySizer: any DirectorySizing

    public init(
        id: String = "application-support",
        supportRoot: URL,
        validator: SafePathValidator,
        fingerprinter: any FileFingerprinting,
        directorySizer: any DirectorySizing = DirectorySizer()
    ) {
        self.id = id
        self.supportRoot = supportRoot
        self.validator = validator
        self.fingerprinter = fingerprinter
        self.directorySizer = directorySizer
    }

    public func scan(context: ScanContext) async throws -> [DiscoveredItem] {
        guard FileManager.default.fileExists(atPath: supportRoot.path) else {
            return []
        }

        let pinnedRoot = try validator.pinnedAllowedRoot(for: supportRoot)
        let children = try FileManager.default.contentsOfDirectory(
            at: pinnedRoot,
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
            } catch ApplicationSupportScannerError.identityChanged(let url) {
                throw ApplicationSupportScannerError.identityChanged(url)
            } catch {
                continue
            }
        }

        return discoveries
    }

    private func discovery(
        for child: URL,
        matcher: ApplicationNameMatcher
    ) async throws -> DiscoveredItem? {
        let name = child.lastPathComponent
        let normalizedName = name.lowercased()
        guard !normalizedName.hasPrefix("com.apple.") else {
            // System containers are never proposed for removal.
            return nil
        }
        guard !Self.systemServiceDirectories.contains(normalizedName) else {
            // macOS system service data is never proposed for removal.
            return nil
        }
        guard normalizedName != "macclean" else {
            // The app's own data directory is never proposed for removal.
            return nil
        }
        guard matcher.match(directoryName: name) == nil else {
            // Live application data stays untouched.
            return nil
        }

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
            throw ApplicationSupportScannerError.identityChanged(
                validatedPath.canonicalURL
            )
        }

        return DiscoveredItem(
            displayName: name,
            sourceURL: child,
            validatedPath: validatedPath,
            sizeBytes: size,
            modifiedAt: fingerprint.modifiedAt,
            fingerprint: fingerprint,
            evidence: CandidateEvidence(
                scannerID: id,
                ruleID: "unowned-application-support-data",
                ownerName: nil,
                ownerBundleID: nil,
                explanation: "已核对系统安装的应用（/Applications、/System/Applications、~/Applications），未找到与“\(name)”匹配的应用，推断已卸载；残留数据可安全清除"
            ),
            kind: .orphanResidual(confidence: .inferred)
        )
    }
}
