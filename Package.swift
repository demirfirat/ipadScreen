// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ipadscreen",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ipadscreen",
            path: "Sources/ipadscreen",
            // `web/` is deliberately not a SwiftPM resource: when it is,
            // the generated accessor embeds the absolute build path
            // (including the user name) in the binary. package.sh copies it
            // into the .app; during development it's read from the source
            // tree.
            exclude: ["web"]
        )
    ]
)
