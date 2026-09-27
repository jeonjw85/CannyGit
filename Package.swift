// swift-tools-version: 6.0
import PackageDescription

// Also permits compilation and integration tests while full Xcode is unavailable.
// Both build paths use the same application sources and SwiftTerm release.
let package = Package(
    name: "CannyGit",
    defaultLocalization: "ko",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "CannyGit", targets: ["CannyGit"])],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.19.0")
    ],
    targets: [
        .target(
            name: "CannyPTY",
            path: "CannyGit/Services/Execution/PTYBridge",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "CannyGit",
            dependencies: ["CannyPTY", "SwiftTerm"],
            path: "CannyGit",
            exclude: ["Services/Execution/PTYBridge", "CannyGit-Bridging-Header.h"],
            resources: [.copy("Resources")]
        ),
        .testTarget(
            name: "CannyGitTests",
            dependencies: ["CannyGit"],
            path: "CannyGitTests",
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
