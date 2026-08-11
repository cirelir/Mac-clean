import Foundation

public struct InstalledApplication: Hashable, Codable, Sendable {
    public let name: String
    public let bundleID: String
    public let url: URL

    public init(name: String, bundleID: String, url: URL) {
        self.name = name
        self.bundleID = bundleID
        self.url = url
    }
}

public struct ApplicationInventory: Hashable, Codable, Sendable {
    public let installedApplications: [InstalledApplication]
    public let runningBundleIDs: Set<String>

    public init(installedApplications: [InstalledApplication], runningBundleIDs: Set<String>) {
        self.installedApplications = installedApplications
        self.runningBundleIDs = runningBundleIDs
    }
}
