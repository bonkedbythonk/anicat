// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AnicatApple",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
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
        )
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
        .target(
            name: "Cmpv",
            path: "Sources/Cmpv",
            publicHeadersPath: "include",
            linkerSettings: [
                .unsafeFlags(["-L/opt/homebrew/opt/mpv/lib", "-lmpv"])
            ]
        ),
        .target(
            name: "AnicatUI",
            dependencies: ["AnicatCoreKit", "Cmpv"],
            path: "Sources/AnicatUI",
            resources: [
                .copy("Resources/Shaders"),
                .process("Resources/Images"),
                .copy("Resources/Fonts")
            ]
        ),
        .executableTarget(
            name: "Anicat",
            dependencies: ["AnicatUI", "AnicatCoreKit", "Cmpv"],
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
