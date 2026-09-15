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
                "LICENSE",
                ".gitignore",
                "AppIcon.svg",
                "AppIcon.iconset",
                "Resources",
                "Packaging",
                "Scripts",
                "Tests",
                "docs"
            ],
            sources: [
                "MeetingScribeApp.swift",
                "AppTheme.swift",
                "WorkbenchView.swift",
                "WindowConfiguration.swift",
                "MeetingModels.swift",
                "Diagnostics.swift",
                "MeetingStore.swift",
                "WhisperPipeline.swift",
                "AudioTrackRecorder.swift",
                "TranscriptCleaner.swift",
                "TranscriptMerger.swift",
                "TranscriptMaterial.swift",
                "TranscriptEditor.swift",
                "Glossary.swift",
                "SummaryEngine.swift",
                "SummaryModelDiscovery.swift",
                "KeychainStore.swift",
                "AudioPlayback.swift"
            ]
        ),
        .testTarget(
            name: "MeetingScribeTests",
            dependencies: ["MeetingScribe"],
            path: "Tests/MeetingScribeTests"
        )
    ]
)
