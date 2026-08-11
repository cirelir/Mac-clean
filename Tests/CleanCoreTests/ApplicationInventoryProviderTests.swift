import Foundation
import Testing
import CleanCore

@Test func discoversBundleIDAndExcludesDuplicateApplicationURLs() async throws {
    let fixture = try ApplicationBundleFixture(name: "Editor", bundleID: "com.example.Editor")
    let provider = SystemApplicationInventoryProvider(
        applicationRoots: [fixture.root, fixture.root],
        runningBundleIDs: { ["com.example.Editor"] }
    )

    let inventory = try await provider.inventory()

    #expect(inventory.installedApplications.map(\.bundleID) == ["com.example.Editor"])
    #expect(inventory.runningBundleIDs == Set(["com.example.Editor"]))
}

@Test func choosesTheLexicallyFirstApplicationForDuplicateBundleIdentifiers() async throws {
    let alpha = try ApplicationBundleFixture(name: "Alpha", bundleID: "com.example.Editor")
    let zeta = try ApplicationBundleFixture(name: "Zeta", bundleID: "com.example.Editor")
    let provider = SystemApplicationInventoryProvider(
        applicationRoots: [zeta.root, alpha.root],
        runningBundleIDs: { [] }
    )

    let inventory = try await provider.inventory()

    #expect(inventory.installedApplications.count == 1)
    #expect(inventory.installedApplications[0].name == "Alpha")
    #expect(inventory.installedApplications[0].url.lastPathComponent == "Alpha.app")
}

private final class ApplicationBundleFixture {
    let root: URL

    init(name: String, bundleID: String) throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let contents = root.appending(path: "\(name).app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleName": name,
            "CFBundlePackageType": "APPL"
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: contents.appending(path: "Info.plist"))
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}
