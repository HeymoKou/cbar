// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "cbar",
    platforms: [.macOS(.v14)],   // @Observable requires macOS 14
    targets: [
        .target(name: "CbarCore"),
        .executableTarget(name: "Cbar", dependencies: ["CbarCore"]),
        .executableTarget(name: "CbarSelfTest", dependencies: ["CbarCore"]),
    ],
    // ponytail: Swift 5 language mode — a tiny menu-bar app doesn't need Swift 6
    // static actor-isolation checks over AppKit. Threading is simple by hand
    // (Process off-main, UI on main). Bump to .v6 + @MainActor if it ever grows.
    swiftLanguageModes: [.v5]
)
