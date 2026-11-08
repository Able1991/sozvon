// swift-tools-version:6.0
// Sozvon: a menu bar app (Sozvon) plus UI-free logic (SozvonCore).
// Build the .app with ./build.sh; run tests with swift test (or ./test.sh, which also covers the engine).

import PackageDescription

// Complete concurrency checking: everything it reports is fixed, and no new warnings are allowed.
let strict: [SwiftSetting] = [.unsafeFlags(["-strict-concurrency=complete"])]

let package = Package(
    name: "Sozvon",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Sozvon", targets: ["Sozvon"]),
        .library(name: "SozvonCore", targets: ["SozvonCore"]),
    ],
    dependencies: [
        // Updates: downloads, verifies (EdDSA + Developer ID) and installs new versions. Exact pin.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .target(name: "SozvonCore", swiftSettings: strict),
        .executableTarget(
            name: "Sozvon",
            dependencies: ["SozvonCore", .product(name: "Sparkle", package: "Sparkle")],
            // build.sh copies resources into the bundle (Contents/Resources); SwiftPM leaves them alone.
            exclude: ["Resources", "Sozvon.entitlements"],
            swiftSettings: strict,
            // build.sh puts Sparkle.framework into Contents/Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "SozvonCoreTests", dependencies: ["SozvonCore"], swiftSettings: strict),
    ],
    swiftLanguageModes: [.v5]
)
