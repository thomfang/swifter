// swift-tools-version:5.9

import PackageDescription

let package = Package(
  name: "Swifter",

  platforms: [
    .macOS(.v12),
    .iOS(.v15),
    .tvOS(.v15),
    .watchOS(.v8)
  ],

  products: [
    .library(name: "Swifter", targets: ["Swifter"]),
    .executable(name: "SwifterExample", targets: ["SwifterExample"])
  ],

  dependencies: [],

  targets: [
    .target(
      name: "Swifter",
      dependencies: [],
      path: "Xcode/Sources"
      ),

    .executableTarget(
      name: "SwifterExample",
      dependencies: [
        "Swifter"
      ],
      path: "SwifterExample"
    ),

    .testTarget(
      name: "SwifterTests",
      dependencies: [
        "Swifter"
      ],
      path: "Xcode/Tests",
      resources: [
        .copy("Fixtures")
      ]
    )
  ]
)
