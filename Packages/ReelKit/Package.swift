// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ReelKit",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MediaCore", targets: ["MediaCore"]),
        .library(name: "Metadata", targets: ["Metadata"]),
        .library(name: "MediaSources", targets: ["MediaSources"]),
        .library(name: "Playback", targets: ["Playback"]),
        .library(name: "Library", targets: ["Library"]),
        .library(name: "Sync", targets: ["Sync"]),
    ],
    dependencies: [
        // LGPL 2.1. Shipped as a dynamic xcframework; see PLAN.md §10.
        .package(url: "https://code.videolan.org/videolan/VLCKit-SPM.git", from: "3.6.0"),
        // MIT. SMB2/3 client used for browsing and scanning.
        .package(url: "https://github.com/amosavian/AMSMB2.git", from: "3.0.0"),
        // MIT. Keychain wrapper for source credentials.
        .package(url: "https://github.com/kishikawakatsumi/KeychainAccess.git", from: "4.2.2"),
    ],
    targets: [
        // Pure Swift: models, filename parser, classifier, item keys. No Apple-only imports.
        .target(name: "MediaCore"),

        // TMDb client, response cache, artwork URL builder. Foundation only.
        .target(name: "Metadata", dependencies: ["MediaCore"]),

        // Source protocols and implementations (Local, SMB, WebDAV) plus discovery and credentials.
        .target(
            name: "MediaSources",
            dependencies: [
                "MediaCore",
                .product(name: "AMSMB2", package: "AMSMB2", condition: .when(platforms: [.iOS])),
                .product(name: "KeychainAccess", package: "KeychainAccess", condition: .when(platforms: [.iOS, .macOS])),
            ]
        ),

        // VLCKit wrapper exposing an async state stream to SwiftUI.
        .target(
            name: "Playback",
            dependencies: [
                "MediaCore",
                .product(name: "VLCKit", package: "VLCKit-SPM", condition: .when(platforms: [.iOS])),
            ]
        ),

        // SwiftData models, scan queue, matcher, image loader.
        .target(name: "Library", dependencies: ["MediaCore", "Metadata", "MediaSources"]),

        // CloudKit sync of watch state, favourites and overrides.
        .target(name: "Sync", dependencies: ["MediaCore", "Library"]),

        .testTarget(name: "MediaCoreTests", dependencies: ["MediaCore"]),
        .testTarget(name: "MetadataTests", dependencies: ["Metadata"]),
    ]
)
