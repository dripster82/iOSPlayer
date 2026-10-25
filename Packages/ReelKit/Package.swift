// swift-tools-version: 5.9
import PackageDescription
import Foundation

// VideoLAN's official VLCKit 4 binary (LGPL 2.1, prerelease — the first VLCKit with Picture in
// Picture). There is no official SwiftPM package, so the xcframework is vendored by
// `Scripts/fetch-vlckit.sh` (gitignored). When it is absent — Linux CI, or a fresh checkout before
// the fetch — the Playback module still compiles because VLCPlaybackEngine is wrapped in
// `#if canImport(VLCKit)`; only the pure modules are testable then.
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let vlcKitPath = "Vendor/VLCKit.xcframework"
let hasVLCKit = FileManager.default.fileExists(atPath: packageDir.appendingPathComponent(vlcKitPath).path)

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
        // MIT. SMB2/3 client used for browsing and scanning.
        .package(url: "https://github.com/amosavian/AMSMB2.git", from: "4.0.0"),
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
                .product(name: "AMSMB2", package: "AMSMB2"),
                .product(name: "KeychainAccess", package: "KeychainAccess", condition: .when(platforms: [.iOS, .macOS])),
            ]
        ),

        // VLCKit wrapper exposing an async state stream to SwiftUI.
        .target(
            name: "Playback",
            dependencies: ["MediaCore"] + (hasVLCKit ? [.target(name: "VLCKit", condition: .when(platforms: [.iOS]))] : []),
            linkerSettings: hasVLCKit ? [
                // System frameworks and libraries VLCKit depends on (dynamic xcframework, embedded by Xcode).
                .linkedFramework("AVFoundation", .when(platforms: [.iOS])),
                .linkedFramework("AVKit", .when(platforms: [.iOS])),
                .linkedFramework("AudioToolbox", .when(platforms: [.iOS])),
                .linkedFramework("CFNetwork", .when(platforms: [.iOS])),
                .linkedFramework("CoreGraphics", .when(platforms: [.iOS])),
                .linkedFramework("CoreMedia", .when(platforms: [.iOS])),
                .linkedFramework("CoreText", .when(platforms: [.iOS])),
                .linkedFramework("CoreVideo", .when(platforms: [.iOS])),
                .linkedFramework("OpenGLES", .when(platforms: [.iOS])),
                .linkedFramework("QuartzCore", .when(platforms: [.iOS])),
                .linkedFramework("Security", .when(platforms: [.iOS])),
                .linkedFramework("VideoToolbox", .when(platforms: [.iOS])),
                .linkedLibrary("c++", .when(platforms: [.iOS])),
                .linkedLibrary("xml2", .when(platforms: [.iOS])),
                .linkedLibrary("z", .when(platforms: [.iOS])),
                .linkedLibrary("bz2", .when(platforms: [.iOS])),
                .linkedLibrary("iconv", .when(platforms: [.iOS])),
            ] : []
        ),

        // SwiftData models, scan queue, matcher, image loader.
        .target(name: "Library", dependencies: ["MediaCore", "Metadata", "MediaSources"]),

        // CloudKit sync of watch state, favourites and overrides.
        .target(name: "Sync", dependencies: ["MediaCore", "Library"]),

        .testTarget(name: "MediaCoreTests", dependencies: ["MediaCore", "MediaSources", "Playback"]),
        .testTarget(name: "MetadataTests", dependencies: ["Metadata"]),
    ] + (hasVLCKit ? [.binaryTarget(name: "VLCKit", path: vlcKitPath)] : [])
)
