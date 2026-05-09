// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "meetingrec",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "meetingrec",
            path: "Sources/meetingrec",
            exclude: ["Info.plist"],
            linkerSettings: [
                // Embed Info.plist so NSMicrophoneUsageDescription is surfaced to TCC
                // when the binary requests microphone access.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/meetingrec/Info.plist"
                ])
            ]
        )
    ]
)
