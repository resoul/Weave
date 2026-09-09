// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Weave",
    platforms: [
        .macOS(.v14),
        .iOS(.v16),
        .tvOS(.v16),
    ],
    products: [
        .library(name: "Weave", targets: ["Weave"]),
        .library(name: "WeaveUI", targets: ["WeaveUI"]),
        .library(name: "WeaveAdapters", targets: ["WeaveAdapters"]),
        .library(name: "Logging", targets: ["Logging"]),
        .library(name: "UIKitAdapter", targets: ["UIKitAdapter"]),
        .library(name: "AppKitAdapter", targets: ["AppKitAdapter"]),
        .library(name: "Networking", targets: ["Networking"]),
        .library(name: "Storage", targets: ["Storage"]),
        .library(name: "NetworkingLogging", targets: ["NetworkingLogging"]),
        .library(name: "WeaveTesting", targets: ["WeaveTesting"]),
        .library(name: "Analytics", targets: ["Analytics"]),
        .library(name: "Syntax", targets: ["Syntax"]),
    ],
    dependencies: [
        .package(url: "https://github.com/resoul/flux.git", exact: "1.2.0")
    ],
    targets: [
        .target(
            name: "Weave",
            dependencies: [
                .product(name: "Flux", package: "flux"),
                "WeaveUI",
                "WeaveAdapters",
                .target(name: "UIKitAdapter", condition: .when(platforms: [.iOS, .tvOS])),
                .target(name: "AppKitAdapter", condition: .when(platforms: [.macOS])),
            ]
        ),
        .target(
            name: "WeaveUI",
            dependencies: [
                .product(name: "Flux", package: "flux"),
                "Storage",
            ],
            path: "Sources/WeaveUI"
        ),
        .target(name: "WeaveAdapters", dependencies: ["WeaveUI"]),
        .target(
            name: "Logging",
            dependencies: [.product(name: "Flux", package: "flux")]
        ),
        .target(name: "UIKitAdapter", dependencies: ["WeaveUI", "WeaveAdapters"]),
        .target(name: "AppKitAdapter", dependencies: ["WeaveUI", "WeaveAdapters"]),
        .target(
            name: "Networking",
            dependencies: [.product(name: "Flux", package: "flux")]
        ),
        .target(
            name: "Storage",
            dependencies: [.product(name: "Flux", package: "flux")]
        ),
        .target(name: "NetworkingLogging", dependencies: ["Networking", "Logging"]),
        .target(name: "WeaveTesting", dependencies: ["WeaveUI"]),
        .target(name: "Analytics", dependencies: [.product(name: "Flux", package: "flux")]),
        .target(name: "Syntax", dependencies: ["WeaveUI"]),
        .testTarget(
            name: "WeaveBootstrapTests",
            dependencies: ["Weave", "Storage", .product(name: "Flux", package: "flux")]
        ),
        .testTarget(name: "LoggingTests", dependencies: ["Logging"]),
        .testTarget(
            name: "UIKitAdapterTests", dependencies: ["UIKitAdapter", "Weave", "WeaveAdapters"]),
        .testTarget(
            name: "AppKitAdapterTests", dependencies: ["AppKitAdapter", "Weave", "WeaveAdapters"]),
        .testTarget(name: "NetworkingTests", dependencies: ["Networking"]),
        .testTarget(name: "StorageTests", dependencies: ["Storage"]),
        .testTarget(
            name: "NetworkingLoggingTests",
            dependencies: ["NetworkingLogging", "Networking", "Logging"]),
        .testTarget(name: "WeaveTestingTests", dependencies: ["WeaveTesting", "Weave"]),
        .testTarget(name: "AnalyticsTests", dependencies: ["Analytics"]),
        .testTarget(name: "SyntaxTests", dependencies: ["Syntax", "Weave"]),
    ],
    swiftLanguageModes: [.v6]
)
