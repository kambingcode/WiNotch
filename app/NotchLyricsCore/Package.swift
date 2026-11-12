// swift-tools-version:6.2
import PackageDescription

let swift5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "NotchLyricsCore",
    platforms: [.macOS("14.6")],
    products: [
        .library(name: "LyricsFinder", targets: ["LyricsFinder"]),
        .library(name: "PlaybackCore", targets: ["PlaybackCore"]),
        .library(name: "SyncEngine", targets: ["SyncEngine"]),
        .library(name: "AppState", targets: ["AppState"]),
        .library(name: "NotchUI", targets: ["NotchUI"]),
        .library(name: "FloatingUI", targets: ["FloatingUI"]),
        .executable(name: "NotchLyricsApp", targets: ["NotchLyricsApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/MxIris-LyricsX-Project/LyricsKit", revision: "bb255842eb8fe48880e15c23c0a7704599dd3504"),
    ],
    targets: [
        // Unmodified copy of MxIris-LyricsX-Project/MusicPlayer at ced0ac7, MPL-2.0.
        .target(
            name: "LXMusicPlayer",
            exclude: ["LICENSE"],
            cSettings: [
                .headerSearchPath("Private"),
                .headerSearchPath("private"),
                .headerSearchPath("BridgingHeader"),
            ]
        ),
        .target(
            name: "LyricsFinder",
            dependencies: [.product(name: "LyricsKit", package: "LyricsKit")],
            swiftSettings: swift5
        ),
        .target(name: "PlaybackCore", dependencies: ["LXMusicPlayer"], swiftSettings: swift5),
        .target(
            name: "SyncEngine",
            dependencies: ["PlaybackCore", .product(name: "LyricsKit", package: "LyricsKit")],
            swiftSettings: swift5
        ),
        .target(
            name: "AppState",
            dependencies: ["LyricsFinder", "PlaybackCore", "SyncEngine", .product(name: "LyricsKit", package: "LyricsKit")],
            swiftSettings: swift5
        ),
        .target(name: "NotchUI", dependencies: ["AppState"], swiftSettings: swift5),
        .target(name: "FloatingUI", dependencies: ["AppState"], swiftSettings: swift5),
        .executableTarget(name: "NotchLyricsApp", dependencies: ["AppState", "LyricsFinder", "NotchUI", "FloatingUI"], swiftSettings: swift5),
        .testTarget(name: "LyricsFinderTests", dependencies: ["LyricsFinder"], swiftSettings: swift5),
        .testTarget(name: "PlaybackCoreTests", dependencies: ["PlaybackCore"], swiftSettings: swift5),
        .testTarget(name: "SyncEngineTests", dependencies: ["SyncEngine"], swiftSettings: swift5),
        .testTarget(name: "AppStateTests", dependencies: ["AppState"], swiftSettings: swift5),
        .testTarget(name: "NotchUITests", dependencies: ["NotchUI"], swiftSettings: swift5),
        .testTarget(name: "FloatingUITests", dependencies: ["FloatingUI"], swiftSettings: swift5),
    ]
)
