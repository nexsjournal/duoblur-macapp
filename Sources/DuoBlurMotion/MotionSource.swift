import Foundation
import DuoBlurCore

/// 头部运动数据源。
///
/// 四个实现共用这个协议：真实耳机、脚本演示、鼠标拖动、键盘推进。
/// **除真实源外都不需要任何权限** —— 因此调参器、单元测试、CI、以及没有耳机时的开发
/// 全部可以正常工作。这是"可测试性"这一非功能需求的主要落点。
public protocol MotionSource: AnyObject, Sendable {

    /// 采样流。消费慢时只保留最新若干个，不排队——避免延迟堆积。
    var samples: AsyncStream<HeadSample> { get }

    /// 状态流。
    var statuses: AsyncStream<MotionStatus> { get }

    /// 当前状态的同步快照（UI 首次渲染时用，避免等第一个状态事件）。
    var currentStatus: MotionStatus { get }

    /// 最近一次采样，可能为 nil。
    var latestSample: HeadSample? { get }

    /// 实测采样率（Hz）。AirPods 固定约 25Hz，这个读数用于发现异常。
    var measuredHz: Double { get }

    func start()
    func stop()

    /// 把当前头部姿态设为"正视"基线。手动回中与校准都走这个入口。
    func recenter()
}

/// 只保留最新值的盒子。
///
/// 存在的理由：传感器以 25Hz 推送、渲染以 60Hz 拉取，两者天然失配。
/// 用队列会把失配变成延迟累积，所以这里**只保留最新值**。
public final class LatestValueBox<Value: Sendable>: @unchecked Sendable {
    private let lock: NSLock = {
        let l = NSLock()
        l.name = "com.duoblur.app.latest-value-box"
        return l
    }()
    private var value: Value?

    public init(_ initial: Value? = nil) { value = initial }

    public func store(_ newValue: Value?) {
        lock.lock(); defer { lock.unlock() }
        value = newValue
    }

    public func load() -> Value? {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    public func take() -> Value? {
        lock.lock(); defer { lock.unlock() }
        let v = value
        value = nil
        return v
    }
}
