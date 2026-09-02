// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Sereno",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Sereno",
            path: "Sources/Sereno",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
