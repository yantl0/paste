// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Paste",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Paste",
            path: "Sources/Paste",
            swiftSettings: [.unsafeFlags(["-Osize"], .when(configuration: .release))],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
