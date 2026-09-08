// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AnicatApple",
    platforms: [
        .macOS(.v15),
        .iOS(.v18)
    ],
    products: [
        .executable(
            name: "Anicat",
            targets: ["Anicat"]
        ),
        .library(
            name: "AnicatCoreKit",
            targets: ["AnicatCoreKit"]
        ),
        .library(
            name: "AnicatUI",
            targets: ["AnicatUI"]
        ),
        .library(
            name: "AnicatRemoteActivity",
            targets: ["AnicatRemoteActivity"]
        )
    ],
    dependencies: [
        // libmpv, FFmpeg and their dependency closure as prebuilt
        // xcframeworks for macOS, iOS, tvOS and visionOS, built with
        // gpu-next, libplacebo and MoltenVK, plus MPVKit's `moltenvk`
        // context patch: mpv draws into a CAMetalLayer we hand it as `wid`.
        // Replaces the Homebrew libmpv this package linked from
        // /opt/homebrew/opt/mpv/lib, which could never work for iOS and
        // tied the macOS build to whatever `brew upgrade` last installed.
        // GPL variant: Anicat is GPL-3 already; the variant adds only
        // Samba, which we do not use, but it is the honest match.
        .package(url: "https://github.com/mpvkit/MPVKit.git", exact: "1.0.0")
    ],
    targets: [
        .binaryTarget(
            name: "AnicatCore",
            path: "Frameworks/AnicatCore.xcframework"
        ),
        .target(
            name: "AnicatCoreKit",
            dependencies: ["AnicatCore"],
            path: "Sources/AnicatCoreKit",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        // The Live Activity's shared vocabulary and nothing else. Depends
        // on nothing so the widget extension can link it without dragging
        // mpv and FFmpeg into a process that draws a progress bar.
        .target(
            name: "AnicatRemoteActivity",
            path: "Sources/AnicatRemoteActivity"
        ),
        .target(
            name: "AnicatUI",
            dependencies: [
                "AnicatCoreKit",
                "AnicatRemoteActivity",
                .product(name: "MPVKit-GPL", package: "MPVKit")
            ],
            path: "Sources/AnicatUI",
            resources: [
                .copy("Resources/Shaders"),
                .process("Resources/Images"),
                .copy("Resources/Fonts")
            ]
        ),
        .executableTarget(
            name: "Anicat",
            dependencies: ["AnicatUI", "AnicatCoreKit"],
            path: "Sources/AnicatApp"
        ),
        // Covers the FFI boundary itself, independently of any view: the
        // engine constructs, an async Rust future completes on the Swift
        // side, a record round-trips through SQLite, and a Rust Err arrives
        // as a Swift throw.
        .testTarget(
            name: "AnicatCoreKitTests",
            dependencies: ["AnicatCoreKit"],
            path: "Tests/AnicatCoreKitTests"
        ),
        .testTarget(
            name: "AnicatUITests",
            dependencies: ["AnicatUI", "AnicatCoreKit"],
            path: "Tests/AnicatUITests"
        )
    ]
)
