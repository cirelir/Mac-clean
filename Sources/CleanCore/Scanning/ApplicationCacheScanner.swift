import Foundation

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
        let children = try FileManager.default.contentsOfDirectory(
            at: cacheRoot,
            includingPropertiesForKeys: nil
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        let applicationsByBundleID = Dictionary(
            context.inventory.installedApplications.map { ($0.bundleID, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var discoveries: [DiscoveredItem] = []
        discoveries.reserveCapacity(children.count)

        for child in children {
            try Task.checkCancellation()
            let validatedPath = try validator.validate(child)
            let fingerprint = try fingerprinter.fingerprint(at: validatedPath.canonicalURL)
            let size = try await directorySizer.size(of: validatedPath.canonicalURL)
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let isCacheDirectory = values.isDirectory == true && values.isSymbolicLink != true
            let application = isCacheDirectory
                ? applicationsByBundleID[child.lastPathComponent]
                : nil

            discoveries.append(
                DiscoveredItem(
                    displayName: child.lastPathComponent,
                    sourceURL: child,
                    validatedPath: validatedPath,
                    sizeBytes: size,
                    modifiedAt: fingerprint.modifiedAt,
                    fingerprint: fingerprint,
                    evidence: evidence(for: application),
                    kind: application == nil ? .unknown : .regenerableApplicationCache
                )
            )
        }

        return discoveries
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
            explanation: "No installed application has a bundle ID that exactly matches this cache directory"
        )
    }
}
