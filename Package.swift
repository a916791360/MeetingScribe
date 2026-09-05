// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "MeetingScribe",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "MeetingScribe", targets: ["MeetingScribe"])
    ],
    targets: [
        .executableTarget(
            name: "MeetingScribe",
            path: ".",
            exclude: [
                "README.md",
                ".gitignore"
            ],
            sources: [
                "MeetingScribeApp.swift",
                "ContentView.swift",
                "MeetingModels.swift",
                "MeetingStore.swift",
                "WhisperPipeline.swift"
            ]
        )
    ]
)
