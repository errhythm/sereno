// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Sereno",
    platforms: [.macOS("26.0")],
    dependencies: [
        // First external dependency this project has taken on. Replaces the hardcoded
        // Carbon RegisterEventHotKey in App.swift's GlobalHotkey with a user-editable
        // global shortcut; pinned to an exact tag, not a range, per project convention
        // for anything that ships in the built app.
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", exact: "3.0.1")
    ],
    targets: [
        .executableTarget(
            name: "Sereno",
            dependencies: ["KeyboardShortcuts"],
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
