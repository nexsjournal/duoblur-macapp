// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DuoBlur",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DuoBlur", targets: ["DuoBlurApp"]),
        .library(name: "DuoBlurCore", targets: ["DuoBlurCore"]),
        .library(name: "DuoBlurMotion", targets: ["DuoBlurMotion"]),
        .library(name: "DuoBlurRender", targets: ["DuoBlurRender"]),
    ],
    targets: [
        // 纯逻辑，零依赖。无 UI、无硬件、无权限 —— 因此可以 100% 单测。
        .target(name: "DuoBlurCore"),

        // 头部追踪。依赖 CoreMotion，但通过 MotionSource 协议把硬件隔离在边界之外。
        .target(name: "DuoBlurMotion", dependencies: ["DuoBlurCore"]),

        // 捕获与 Metal 渲染。做成库（而不是 App 的一部分）是为了能离屏跑黄金图像测试。
        // Shaders/ 由 Makefile 用 xcrun metal 离线编译成 metallib（SwiftPM 没有内建
        // metal 编译支持），所以这里排除掉，不让 SwiftPM 抱怨未处理的文件。
        .target(name: "DuoBlurRender", dependencies: ["DuoBlurCore"], exclude: ["Shaders"]),

        .executableTarget(
            name: "DuoBlurApp",
            dependencies: ["DuoBlurCore", "DuoBlurMotion", "DuoBlurRender"]
        ),

        .testTarget(name: "DuoBlurCoreTests", dependencies: ["DuoBlurCore"]),
        .testTarget(name: "DuoBlurMotionTests", dependencies: ["DuoBlurMotion", "DuoBlurCore"]),
    ],
    // 严格并发：这个项目横跨传感器回调线程 / 渲染线程 / 主线程，数据竞争检查是刚需。
    swiftLanguageModes: [.v6]
)
