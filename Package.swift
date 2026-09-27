// swift-tools-version: 5.9
import PackageDescription

// Host-executable tests for the queue, SQLite and native clear-media export.
// Application integration is compiled separately by the CocoaPods fixture.
let package = Package(
    name: "StreamDownloaderCoreVerification",
    platforms: [.macOS(.v12), .iOS(.v15)],
    products: [],
    targets: [
        .target(name: "StreamDownloaderCore", path: "ios", exclude: ["Bridge", "Player", "DRM/FairPlaySession.swift", "DRM/FairPlayLicenseBroker.swift", "Media/FileDownloadEngine.swift", "Media/HLSDownloadEngine.swift", "Media/HLSDownloadPlan.swift", "Media/NativeMediaCatalog.swift", "Media/NativeMediaEngine.swift"], sources: ["Core", "Storage", "DRM/FairPlayVault.swift", "Media/MP4Exporter.swift"], linkerSettings: [.linkedLibrary("sqlite3"), .linkedFramework("Security")]),
        .testTarget(name: "StreamDownloaderCoreTests", dependencies: ["StreamDownloaderCore"], path: "tests/swift"),
    ],
    swiftLanguageVersions: [.v5]
)
