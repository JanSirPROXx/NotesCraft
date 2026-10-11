// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "NoteCraft", platforms: [.macOS(.v14), .iOS(.v17)],
  products: [
    .library(name: "NoteCraftCore", targets: ["NoteCraftCore"]),
    .executable(name: "NoteCraft", targets: ["NoteCraft"]),
  ],
  targets: [
    .target(name: "NoteCraftCore"),
    .executableTarget(
      name: "NoteCraft", dependencies: ["NoteCraftCore"],
      exclude: ["Assets.xcassets"]),
    .testTarget(name: "NoteCraftCoreTests", dependencies: ["NoteCraftCore"]),
    .testTarget(name: "NoteCraftTests", dependencies: ["NoteCraft", "NoteCraftCore"]),
  ])
