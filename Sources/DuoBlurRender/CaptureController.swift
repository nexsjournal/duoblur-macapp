import Foundation
import Metal
import CoreVideo
@preconcurrency import ScreenCaptureKit
import os
import DuoBlurCore

/// 一帧捕获结果。
///
/// **`CVMetalTexture` 必须与 `MTLTexture` 同生命周期持有**：`CVMetalTextureGetTexture`
/// 返回的 `MTLTexture` 不持有底层 IOSurface，`CVMetalTexture` 一释放纹理就可能失效。
/// 这是这类代码最常见的崩溃原因，所以这里把两者绑在同一个对象里，外部拿不到裸纹理。
public final class CapturedFrame: @unchecked Sendable {
    public let texture: MTLTexture
    public let geometry: DisplayGeometry
    /// 捕获帧的显示时刻（来自 SCK 附件）
    public let displayTime: CFTimeInterval
    /// 宿主时钟下收到的时刻
    public let receivedAt: CFTimeInterval
    /// SCK 报告内容未变化
    public let isIdle: Bool

    private let retained: CVMetalTexture?

    init(
        texture: MTLTexture,
        retained: CVMetalTexture?,
        geometry: DisplayGeometry,
        displayTime: CFTimeInterval,
        receivedAt: CFTimeInterval,
        isIdle: Bool
    ) {
        self.texture = texture
        self.retained = retained
        self.geometry = geometry
        self.displayTime = displayTime
        self.receivedAt = receivedAt
        self.isIdle = isIdle
    }
}

/// 建流流程的超时错误。
enum CaptureSetupError: Error, CustomStringConvertible {
    case timeout(step: String, seconds: Double)

    var description: String {
        switch self {
        case .timeout(let step, let seconds):
            return "建流在「\(step)」这一步超过 \(Int(seconds)) 秒未完成（静默挂起）"
        }
    }
}

/// 一路 `SCStream`。
///
/// 关键处理（都是实际上机踩过的坑）：
/// - **排除自身进程**，否则覆盖窗会被自己捕获 → 无限镜像反馈
/// - **几何从附件读**，不假设 1:1（`contentRect` / `contentScale`）
/// - `.idle` 帧**复用上一帧纹理**，不重新上传
/// - 首帧 `startCapture` 要 200–500ms，所以在应用启动时就建立，不等用户转头
public final class CaptureController: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {

    public let displayID: CGDirectDisplayID
    private let display: DisplayInfo

    private struct State {
        var latest: CapturedFrame?
        // SCK 回调被调用的次数（无论帧是否被采用）。
        // 与 frameCount 一起看就能区分两种完全不同的失效：
        // "回调从未触发"（SCK 没推帧）vs "回调触发了但帧被丢弃"（格式/几何问题）。
        var callbackCount: UInt64 = 0
        var frameCount: UInt64 = 0
        var isRunning = false
        var lastError: String?
        /// 从 startCapture 到首帧的耗时，用于诊断
        var firstFrameLatency: TimeInterval?
        var startedAt: CFTimeInterval = 0
        var droppedFrames: UInt64 = 0
        var firstDropReason: String?
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let sampleQueue = DispatchQueue(
        label: "com.duoblur.app.capture.samples",
        qos: .userInteractive
    )
    private var stream: SCStream?
    private var textureCache: CVMetalTextureCache?
    private let textureUsage: [String: Any]

    public init(display: DisplayInfo, device: MTLDevice) {
        self.displayID = display.id
        self.display = display
        self.textureUsage = [kCVMetalTextureUsage as String: MTLTextureUsage.shaderRead.rawValue]
        super.init()
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        self.textureCache = cache
    }

    public var latestFrame: CapturedFrame? { lock.withLock { $0.latest } }
    public var frameCount: UInt64 { lock.withLock { $0.frameCount } }
    public var callbackCount: UInt64 { lock.withLock { $0.callbackCount } }
    public var droppedFrames: UInt64 { lock.withLock { $0.droppedFrames } }
    public var lastError: String? { lock.withLock { $0.lastError } }
    public var firstFrameLatency: TimeInterval? { lock.withLock { $0.firstFrameLatency } }

    // MARK: 启停

    public func start() async {
        let alreadyRunning = lock.withLock { state -> Bool in
            if state.isRunning { return true }
            state.isRunning = true
            state.startedAt = CFAbsoluteTimeGetCurrent()
            return false
        }
        guard !alreadyRunning else { return }

        do {
            // 每一步都包超时：捕获链路上有若干个 await，其中任一个挂住都会表现成
            // "无错误、无帧、无解释"，最难查。宁可 8 秒后报"哪一步超时"。
            let content = try await withSetupTimeout(8, step: "获取可共享内容") {
                try await SCShareableContent.current
            }
            guard let scDisplay = content.displays.first(where: { $0.displayID == displayID }) else {
                fail("系统未提供该显示器的捕获对象（显示器可能已断开）")
                return
            }

            let filter = makeFilter(content: content, display: scDisplay)

            let configuration = SCStreamConfiguration()
            configuration.width = Int(display.pixelSize.width)
            configuration.height = Int(display.pixelSize.height)
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.colorSpaceName = CGColorSpace.sRGB
            // queueDepth 3 是延迟与抗抖动的平衡点；太大反而增加呈现延迟
            configuration.queueDepth = 3
            // 跟随显示器刷新率的常见上限；配合按需降帧
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            // 光标由系统绘制在覆盖窗之上，天然保持清晰，所以不捕获
            configuration.showsCursor = false
            configuration.capturesAudio = false
            configuration.scalesToFit = false
            if #available(macOS 14.0, *) {
                configuration.captureResolution = .best
            }
            if #available(macOS 14.2, *) {
                configuration.includeChildWindows = true
            }

            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)

            // 用 completion-handler 形式而不是 `try await stream.startCapture()`：
            // async 桥接版本在部分 macOS 版本上会**静默挂住**（不返回、不报错），
            // 表现就是"什么错都没有但一帧也收不到"。这里手工桥接并加超时。
            try await withSetupTimeout(10, step: "启动捕获流") {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    stream.startCapture { error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                    }
                }
            }
            self.stream = stream

            // 主动抓一帧作为首帧。
            //
            // 为什么必须这么做：SCStream 是**内容变化驱动**的 —— 屏幕上没有变化就不推帧。
            // 实测遇到过：startCapture 成功、无任何错误、但 8 秒内一帧都没有，
            // 因为屏幕上除了我们自己的窗口（已被排除）几乎静止。
            // 没有首帧就无法显示效果（宁可显示真实屏幕也不显示空白），所以这里主动取一帧打底，
            // 之后的变化仍由 SCStream 推送。
            await primeFirstFrame(filter: filter, configuration: configuration)
        } catch {
            fail("建立屏幕捕获失败：\(error.localizedDescription)")
        }
    }

    /// 用 `SCScreenshotManager` 一次性抓帧（macOS 14+）给实时流打底。
    /// 走与实时回调相同的 `ingest` 路径，所以几何处理完全一致。
    private func primeFirstFrame(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration
    ) async {
        do {
            let sampleBuffer = try await SCScreenshotManager.captureSampleBuffer(
                contentFilter: filter,
                configuration: configuration
            )
            ingest(sampleBuffer)
        } catch {
            // 打底失败不影响实时流；只记录，不把整个会话判失败
            lock.withLock { $0.lastError = "首帧抓取失败：" + error.localizedDescription }
        }
    }

    /// 构造内容过滤器。
    ///
    /// 优先按**应用**排除自身（这样连 HUD / 设置窗口也一起排除，语义最干净）；
    /// 若系统没把本进程列进 `applications`，退化到按**窗口 ID** 排除。
    private func makeFilter(content: SCShareableContent, display scDisplay: SCDisplay) -> SCContentFilter {
        let ownPID = getpid()

        let ownApplications = content.applications.filter { $0.processID == ownPID }
        let filter: SCContentFilter
        if !ownApplications.isEmpty {
            filter = SCContentFilter(
                display: scDisplay,
                excludingApplications: ownApplications,
                exceptingWindows: []
            )
        } else {
            let ownWindows = content.windows.filter { $0.owningApplication?.processID == ownPID }
            filter = SCContentFilter(display: scDisplay, excludingWindows: ownWindows)
        }

        // 我们要连菜单栏一起模糊，所以必须包含它。
        // includeMenuBar 是 14.2+；不支持时 contentRect 会带偏移，
        // 由 DisplayGeometry 的仿射映射兜住（画面不会错位，只是顶部区域取自边缘像素）。
        if #available(macOS 14.2, *) {
            filter.includeMenuBar = true
        }
        return filter
    }

    public func stop() async {
        let wasRunning = lock.withLock { state -> Bool in
            if !state.isRunning { return false }
            state.isRunning = false
            state.latest = nil
            return true
        }
        guard wasRunning else { return }
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
    }

    /// 给建流流程的每一步加超时。
    ///
    /// 存在意义：`SCStream` 的建流链路上有多个 await，其中任一步挂住都会表现成
    /// "启动成功、零错误、零帧、零解释" —— 这是最难排查的一类故障。
    /// 加了超时之后，8~10 秒就能明确指出是哪一步卡住了。
    private func withSetupTimeout<T: Sendable>(
        _ seconds: Double,
        step: String,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw CaptureSetupError.timeout(step: step, seconds: seconds)
            }
            guard let result = try await group.next() else {
                throw CaptureSetupError.timeout(step: step, seconds: seconds)
            }
            group.cancelAll()
            return result
        }
    }

    /// 记录一次被丢弃的帧。
    ///
    /// `lastError` **每次都要写**（而不只是第一次）：写一次就锁死的话，
    /// 启动时的一次瞬态丢弃会把后面所有持续失败都变成"错误=无"，
    /// 又回到"无错误、无帧、无解释"的老问题上。`firstDropReason` 只用于日志。
    private func noteIngestFailure(_ reason: String) {
        lock.withLock { state in
            state.droppedFrames &+= 1
            if state.firstDropReason == nil {
                state.firstDropReason = reason
            }
            state.lastError = reason
        }
    }

    private func fail(_ message: String) {
        lock.withLock { state in
            state.lastError = message
            state.isRunning = false
        }
    }

    // MARK: SCStreamOutput

    public func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen else { return }
        lock.withLock { $0.callbackCount &+= 1 }
        ingest(sampleBuffer)
    }

    /// 统一的帧处理路径。`SCStream` 的实时回调与启动时的一次性抓帧都走这里，
    /// 保证两条路的几何/格式处理完全一致（否则会出现"首帧与后续帧对齐不一样"的诡异 bug）。
    func ingest(_ sampleBuffer: CMSampleBuffer) {
        // 这里的每个早退分支都**必须**报告原因。
        // 曾经因为静默 return，出现过"无错误、无帧、无解释"的状态，
        // 只能靠一步步加日志反推 —— 捕获管线里的静默丢弃是最难查的一类 bug。
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            noteIngestFailure("帧没有图像缓冲（CMSampleBufferGetImageBuffer 返回 nil）")
            return
        }
        guard let textureCache else {
            noteIngestFailure("Metal 纹理缓存未初始化（CVMetalTextureCacheCreate 失败）")
            return
        }

        let receivedAt = CFAbsoluteTimeGetCurrent()
        let attachments = Self.frameAttachments(from: sampleBuffer)
        let isIdle = attachments?.status == .idle
        let displayTime = attachments?.displayTime ?? receivedAt

        // .idle 表示内容未变化 —— 复用上一帧纹理，不重新创建
        if isIdle {
            lock.withLock { state in
                state.frameCount &+= 1
            }
            return
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            textureUsage as CFDictionary,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvTexture
        )
        guard status == kCVReturnSuccess,
              let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else {
            noteIngestFailure("无法把像素缓冲包成 Metal 纹理（CVReturn=\(status)，"
                              + "格式=\(width)×\(height) BGRA）")
            return
        }

        // 几何：用 filter 的 contentRect 为基准（比逐帧附件更稳定），
        // 逐帧的 contentScale / contentRect 若存在则优先采用。
        let geometry = DisplayGeometry(
            displayPointSize: display.pointSize,
            contentRect: attachments?.contentRect
                ?? CGRect(origin: .zero, size: display.pointSize),
            contentScale: attachments?.contentScale ?? display.scale,
            capturePixelSize: CGSize(width: width, height: height)
        )

        let frame = CapturedFrame(
            texture: texture,
            retained: cvTexture,
            geometry: geometry,
            displayTime: displayTime,
            receivedAt: receivedAt,
            isIdle: false
        )

        lock.withLock { state in
            state.frameCount &+= 1
            state.latest = frame
            if state.firstFrameLatency == nil, state.startedAt > 0 {
                state.firstFrameLatency = receivedAt - state.startedAt
            }
            state.lastError = nil
        }
    }

    // MARK: SCStreamDelegate

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        // 同时把最后一帧丢掉：留着它的话上层会继续拿这张陈旧画面合成，
        // 表现为"屏幕被冻结在最后一帧"。丢掉之后上层会 fail-open 回真实屏幕。
        lock.withLock { state in
            state.latest = nil
            state.isRunning = false
        }
        fail("捕获意外停止：\(error.localizedDescription)")
    }

    // MARK: 附件解析

    private struct FrameAttachments {
        var status: SCFrameStatus
        var displayTime: CFTimeInterval
        var contentRect: CGRect?
        var contentScale: Double?
    }

    /// SCK 把帧元数据放在 `CMSampleBuffer` 的附件里。
    /// 这里集中解析一次，避免各处散落 `as?` 转换。
    private static func frameAttachments(from sampleBuffer: CMSampleBuffer) -> FrameAttachments? {
        guard let rawArray = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[String: Any]], let raw = rawArray.first else { return nil }

        var result = FrameAttachments(status: .complete, displayTime: 0)

        if let statusRaw = raw[SCStreamFrameInfo.status.rawValue] as? Int,
           let status = SCFrameStatus(rawValue: statusRaw) {
            result.status = status
        }
        if let time = raw[SCStreamFrameInfo.displayTime.rawValue] as? CMTime,
           time.isValid, time.timescale != 0 {
            result.displayTime = CMTimeGetSeconds(time)
        }
        // contentRect 在不同系统版本上可能是 CGRect，也可能是它的字典表示。
        // 两种都试，取不到就退回显示器的全尺寸（DisplayGeometry 会据此判断是否 1:1）。
        let rectValue = raw[SCStreamFrameInfo.contentRect.rawValue]
        if let rect = rectValue as? CGRect {
            result.contentRect = rect
        } else if let dict = rectValue as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: dict as CFDictionary) {
            result.contentRect = rect
        }
        if let scale = raw[SCStreamFrameInfo.contentScale.rawValue] as? Double {
            result.contentScale = scale
        } else if let scale = raw[SCStreamFrameInfo.contentScale.rawValue] as? CGFloat {
            result.contentScale = Double(scale)
        }
        return result
    }
}
