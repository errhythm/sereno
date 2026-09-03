// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Sereno",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Sereno",
            path: "Sources/Sereno",
            // .copy, not .process: the directory structure is preserved and the ttf is
            // handed through byte for byte instead of being re-encoded. Reached at
            // runtime through the generated Sereno_Sereno.bundle. OFL.txt rides along
            // with the font because the SIL Open Font License requires the licence and
            // copyright notice to accompany it.
            resources: [.copy("Fonts")],
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
