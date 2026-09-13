// swift-tools-version: 5.7
// 注:MacZip 的构建与测试走 Scripts/build.sh / Scripts/test.sh (raw swiftc),
// 本 manifest 供 IDE 索引与未来 Xcode 环境使用;无 Xcode 的 CLT 14.x 上
// SwiftPM manifest 编译存在已知损坏,以此脚本化方案规避。
import PackageDescription

let package = Package(
    name: "MacZip",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "MacZipCore",
            targets: ["MacZipCore"]
        )
    ],
    targets: [
        .target(
            name: "MacZipCore",
            path: "Sources/MacZipCore",
            linkerSettings: [
                .linkedLibrary("z")
            ]
        )
    ]
)
