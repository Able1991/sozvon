// swift-tools-version:6.0
// Sozvon: приложение в строке меню (Sozvon) и логика без интерфейса (SozvonCore).
// Сборка .app: ./build.sh; тесты: swift test (или ./test.sh вместе с движком).

import PackageDescription

// Полная проверка конкурентности: всё, что она находит, исправлено, новые предупреждения не допускаем.
let strict: [SwiftSetting] = [.unsafeFlags(["-strict-concurrency=complete"])]

let package = Package(
    name: "Sozvon",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Sozvon", targets: ["Sozvon"]),
        .library(name: "SozvonCore", targets: ["SozvonCore"]),
    ],
    targets: [
        .target(name: "SozvonCore", swiftSettings: strict),
        .executableTarget(
            name: "Sozvon",
            dependencies: ["SozvonCore"],
            // Ресурсы кладёт в бандл build.sh (Contents/Resources), SwiftPM их не трогает.
            exclude: ["Resources", "Sozvon.entitlements"],
            swiftSettings: strict
        ),
        .testTarget(name: "SozvonCoreTests", dependencies: ["SozvonCore"], swiftSettings: strict),
    ],
    swiftLanguageModes: [.v5]
)
