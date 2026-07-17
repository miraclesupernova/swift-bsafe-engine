// swift-tools-version:6.0
// SPDX-License-Identifier: LGPL-3.0-only
// SPDX-FileCopyrightText: 2024-2026 Nicholas Amorim <nicholas@santos.ee>

import PackageDescription

let package = Package(
    name: "BSafeEngine",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .macCatalyst(.v17),
        .tvOS(.v17),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "BSafeEngine", targets: ["BSafeEngine"]),
    ],
    targets: [
        .target(
            name: "BSafeEngine",
            path: "Sources/BSafeEngine",
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .testTarget(
            name: "BSafeEngineTests",
            dependencies: ["BSafeEngine"],
            path: "Tests/BSafeEngineTests",
            resources: [
                .copy("ReferenceWavs"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
