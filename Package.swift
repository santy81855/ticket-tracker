// swift-tools-version: 6.1
import PackageDescription

let package = Package(
  name: "TicketTracker",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "TicketTracker", targets: ["TicketTrackerApp"]),
    .executable(name: "ticket-tracker", targets: ["TrackerAgent"]),
  ],
  dependencies: [
    .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
    .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
    .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.99.2"),
  ],
  targets: [
    .target(name: "TrackerCore"),
    .target(
      name: "TrackerStore",
      dependencies: ["TrackerCore", .product(name: "GRDB", package: "GRDB.swift")]
    ),
    .target(
      name: "TrackerMCP",
      dependencies: ["TrackerCore", "TrackerStore", .product(name: "MCP", package: "swift-sdk")]
    ),
    .executableTarget(name: "TrackerAgent", dependencies: ["TrackerMCP", "TrackerStore"]),
    .executableTarget(
      name: "TicketTrackerApp",
      dependencies: ["TrackerCore", "TrackerStore", .product(name: "SwiftTerm", package: "SwiftTerm")],
      path: "App",
      resources: [
        .copy("Resources/Gargantua"), .copy("Resources/Aurora"), .copy("Resources/Skyline"),
        .copy("Resources/Rain"), .copy("Resources/Nebula"), .copy("Resources/Cabin"),
        .copy("Resources/Xmas"), .copy("Resources/Bonsai"), .copy("Resources/Viewer"),
      ]
    ),
    .testTarget(name: "TrackerCoreTests", dependencies: ["TrackerCore"]),
    .testTarget(name: "TrackerStoreTests", dependencies: ["TrackerCore", "TrackerStore"]),
    .testTarget(
      name: "TrackerMCPTests",
      dependencies: [
        "TrackerCore", "TrackerStore", "TrackerMCP", .product(name: "MCP", package: "swift-sdk"),
      ]
    ),
  ]
)
