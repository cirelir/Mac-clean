import Foundation

public protocol ApplicationInventoryProviding: Sendable {
    func inventory() async throws -> ApplicationInventory
}

public struct SystemApplicationInventoryProvider: ApplicationInventoryProviding {
    public let applicationRoots: [URL]
    public let runningBundleIDs: @Sendable () -> Set<String>

    public init(
        applicationRoots: [URL],
        runningBundleIDs: @escaping @Sendable () -> Set<String>
    ) {
        self.applicationRoots = applicationRoots
        self.runningBundleIDs = runningBundleIDs
    }

    public func inventory() async throws -> ApplicationInventory {
        var applicationsByBundleID: [String: InstalledApplication] = [:]

        for root in applicationRoots {
            let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            while let url = enumerator.nextObject() as? URL {
                guard url.pathExtension.lowercased() == "app" else {
                    continue
                }

                enumerator.skipDescendants()

                guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else {
                    continue
                }

                let application = InstalledApplication(
                    name: bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                        ?? url.deletingPathExtension().lastPathComponent,
                    bundleID: bundleID,
                    url: url
                )
                applicationsByBundleID[bundleID] = preferred(application, over: applicationsByBundleID[bundleID])
            }
        }

        return ApplicationInventory(
            installedApplications: applicationsByBundleID.values.sorted { $0.bundleID < $1.bundleID },
            runningBundleIDs: runningBundleIDs()
        )
    }

    private func preferred(
        _ candidate: InstalledApplication,
        over existing: InstalledApplication?
    ) -> InstalledApplication {
        guard let existing else {
            return candidate
        }

        let candidateKey = (candidate.url.lastPathComponent, candidate.url.path)
        let existingKey = (existing.url.lastPathComponent, existing.url.path)
        return candidateKey < existingKey ? candidate : existing
    }
}
