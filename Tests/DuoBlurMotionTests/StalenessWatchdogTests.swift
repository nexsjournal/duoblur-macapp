import XCTest
@testable import DuoBlurMotion
import DuoBlurCore

/// StalenessWatchdog 的行为测试。
///
/// 全部用假时钟瞬间推进，测试里没有一个 `sleep`。
final class StalenessWatchdogTests: XCTestCase {

    /// 0.6s 判定
    func testStaleThreshold() {
        var watchdog = StalenessWatchdog(staleAfter: 0.6)
        watchdog.noteConnect(at: 0)
        watchdog.noteSample(at: 0)

        XCTAssertEqual(watchdog.evaluate(now: 0.59, isConnected: true), .ok, "0.59s 不应判陈旧")

        guard case .stale(let since) = watchdog.evaluate(now: 0.61, isConnected: true) else {
            return XCTFail("0.61s 应判陈旧")
        }
        XCTAssertEqual(since, 0.61, accuracy: 1e-9)
    }

    /// 恢复样本后回到正常，且不重建会话
    func testRecoversWithoutRebuild() {
        var watchdog = StalenessWatchdog(staleAfter: 0.6, rebuildAfter: 2.0)
        watchdog.noteConnect(at: 0)
        watchdog.noteSample(at: 0)

        _ = watchdog.evaluate(now: 0.7, isConnected: true)
        watchdog.noteSample(at: 0.7)
        XCTAssertEqual(watchdog.evaluate(now: 0.8, isConnected: true), .ok)
        XCTAssertEqual(watchdog.attempts, 0, "短暂断流不应触发重建")
    }

    /// 重建次数上限
    func testRebuildAttemptsAreCapped() {
        var watchdog = StalenessWatchdog(staleAfter: 0.6, rebuildAfter: 2.0, maxRebuildAttempts: 3)
        watchdog.noteConnect(at: 0)
        watchdog.noteSample(at: 0)

        var rebuilds = 0
        var verdicts: [StalenessWatchdog.Verdict] = []
        // 每 0.1s 评估一次，持续 30s，期间没有任何样本
        for tick in 1...300 {
            let now = Double(tick) * 0.1
            let verdict = watchdog.evaluate(now: now, isConnected: true)
            verdicts.append(verdict)
            if case .shouldRebuild = verdict { rebuilds += 1 }
            if verdict == .giveUp { break }
        }

        XCTAssertEqual(rebuilds, 3, "重建次数应恰好为 3，实际 \(rebuilds)")
        XCTAssertTrue(verdicts.contains(.giveUp), "用尽重建次数后应进入 giveUp")
    }

    /// 首样本宽限期
    func testFirstSampleGracePeriod() {
        var watchdog = StalenessWatchdog(firstSampleGrace: 20, rebuildAfter: 2.0)
        watchdog.noteConnect(at: 0)

        // 15s：仍在宽限期内，不该判失败
        XCTAssertEqual(watchdog.evaluate(now: 15, isConnected: true), .waitingForFirstSample)

        // 21s：超过宽限期，应请求重建
        guard case .shouldRebuild(let attempt) = watchdog.evaluate(now: 21, isConnected: true) else {
            return XCTFail("21s 无样本应请求重建，实际 \(watchdog.evaluate(now: 21, isConnected: true))")
        }
        XCTAssertEqual(attempt, 1)
    }

    /// 未连接时报告"等待设备"，而不是"陈旧"
    func testDisconnectedReportsWaitingForDevice() {
        var watchdog = StalenessWatchdog()
        watchdog.noteConnect(at: 0)
        watchdog.noteSample(at: 0)
        watchdog.noteDisconnect()
        XCTAssertEqual(watchdog.evaluate(now: 5, isConnected: false), .waitingForDevice)
    }

    /// 重建完成后获得一个完整的宽限期
    func testRebuildGetsFreshGracePeriod() {
        var watchdog = StalenessWatchdog(staleAfter: 0.6, rebuildAfter: 2.0)
        watchdog.noteConnect(at: 0)
        watchdog.noteSample(at: 0)

        _ = watchdog.evaluate(now: 2.1, isConnected: true)      // 触发第一次重建
        watchdog.noteRebuildCompleted(at: 2.1)

        // 刚重建完：应该是等样本，而不是立刻又判陈旧
        let verdict = watchdog.evaluate(now: 2.2, isConnected: true)
        XCTAssertEqual(verdict, .waitingForFirstSample, "重建后应立即进入等待首样本，实际 \(verdict)")
    }

    /// 两次重建之间必须有间隔，不能每个 tick 都请求
    func testRebuildIsNotRequestedEveryTick() {
        var watchdog = StalenessWatchdog(staleAfter: 0.6, rebuildAfter: 2.0)
        watchdog.noteConnect(at: 0)
        watchdog.noteSample(at: 0)

        var rebuildRequests = 0
        for tick in 20...25 {   // 连续 6 个 tick，跨越 2.0s 一次
            let now = Double(tick) * 0.1
            if case .shouldRebuild = watchdog.evaluate(now: now, isConnected: true) {
                rebuildRequests += 1
            }
        }
        XCTAssertEqual(rebuildRequests, 1, "0.5s 窗口内应只请求一次重建，实际 \(rebuildRequests)")
    }

    /// reset 之后回到初始状态
    func testResetClearsEverything() {
        var watchdog = StalenessWatchdog()
        watchdog.noteConnect(at: 0)
        watchdog.noteSample(at: 0)
        _ = watchdog.evaluate(now: 3, isConnected: true)
        watchdog.reset()
        XCTAssertEqual(watchdog.attempts, 0)
        XCTAssertEqual(watchdog.evaluate(now: 3, isConnected: true), .waitingForFirstSample)
    }
}
