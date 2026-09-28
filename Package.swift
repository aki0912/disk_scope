// swift-tools-version: 5.9
import PackageDescription
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let package = Package(
    name: "DiskScope",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "DiskScope", targets: ["DiskScope"])],
    targets: [
        .systemLibrary(name: "CScanner"),
        .target(name: "DiskScopeCore"),
        .executableTarget(
            name: "DiskScope",
            dependencies: ["DiskScopeCore", "CScanner"],
            linkerSettings: [.unsafeFlags(["-L", root + "/rust/target/release", "-ldiskscope_scanner"])]
        ),
        .testTarget(name: "DiskScopeCoreTests", dependencies: ["DiskScopeCore"])
    ]
)
