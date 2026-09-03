// swift-tools-version: 5.9
import PackageDescription

// AnicatCoreKit is the generated UniFFI binding plus the prebuilt Rust engine.
// The .a inside the xcframework is produced by scripts/build-xcframework.sh —
// it is a build artifact, not source, and is regenerated rather than edited.
let package = Package(
    name: "AnicatApple",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "AnicatCoreKit", targets: ["AnicatCoreKit"])
    ],
    targets: [
        .binaryTarget(name: "AnicatCore", path: "AnicatCore.xcframework"),
        .target(
            name: "AnicatCoreKit",
            dependencies: ["AnicatCore"],
            linkerSettings: [
                // rusqlite's bundled SQLite and librqbit's memmap2 both reach
                // into libSystem; aws-lc-rs (rustls' backend) pulls in libc++.
                .linkedLibrary("c++"),
                // Reachability and the system trust store, reached through
                // rustls-platform-verifier's dependencies.
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("Security")
            ]
        ),
        .testTarget(name: "AnicatCoreKitTests", dependencies: ["AnicatCoreKit"])
    ]
)
