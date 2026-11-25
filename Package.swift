// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "apple-voicememos-mcp",
    platforms: [.macOS(.v26)],
    targets: [
        // All logic lives here so the tests can import it. The executable target below
        // is only a launcher: an executable target cannot be imported by a test target.
        .target(name: "VoiceMemosMCPCore"),
        .executableTarget(
            name: "apple-voicememos-mcp",
            dependencies: ["VoiceMemosMCPCore"],
            // TCC identifies this binary by its own embedded Info.plist. Claude Desktop
            // spawns MCP servers through Contents/Helpers/disclaimer, which calls
            // responsibility_spawnattrs_setdisclaim, so the process is its own TCC
            // subject and cannot borrow the host app's usage descriptions. Without the
            // embedded plist macOS denies speech recognition without ever prompting.
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/Info.plist",
                ])
            ]
        ),
        .testTarget(name: "VoiceMemosMCPCoreTests", dependencies: ["VoiceMemosMCPCore"]),
    ]
)
