// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Hanmium",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Hanmium",
            path: "Sources/Hanmium",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
            ]
        ),
    ]
)
