import XCTest
@testable import CoreModels

final class BroadcasterTests: XCTestCase {
    func testMulticastToIndependentStreams() async {
        let b = Broadcaster<Int>()
        let s1 = b.stream()
        let s2 = b.stream()
        b.send(1)
        b.send(2)
        b.finish()
        var r1: [Int] = [], r2: [Int] = []
        for await v in s1 { r1.append(v) }
        for await v in s2 { r2.append(v) }
        XCTAssertEqual(r1, [2]) // bufferingNewest(1): 소비 전 연속 send는 최신만 남는다
        XCTAssertEqual(r2, [2])
    }

    func testNoReplayByDefault() async {
        let b = Broadcaster<Int>()
        b.send(1)
        let s = b.stream()
        b.send(2)
        b.finish()
        var r: [Int] = []
        for await v in s { r.append(v) }
        XCTAssertEqual(r, [2])
    }

    func testReplayLatest() async {
        let b = Broadcaster<Int>(replayLatest: true)
        b.send(1)
        b.send(2)
        let s = b.stream()
        b.send(3)
        b.finish()
        var r: [Int] = []
        for await v in s { r.append(v) }
        XCTAssertEqual(r, [3]) // 재생값(2)은 소비 전에 3으로 대체됨
    }

    func testReplayLatestDeliveredWhenConsumedBeforeNextSend() async {
        let b = Broadcaster<Int>(replayLatest: true)
        b.send(1)
        b.send(2)
        var it = b.stream().makeAsyncIterator()
        let first = await it.next()
        XCTAssertEqual(first, 2)
        b.send(3)
        let second = await it.next()
        XCTAssertEqual(second, 3)
    }

    func testSlowConsumerReceivesOnlyLatest() async {
        let b = Broadcaster<Int>()
        let s = b.stream()
        for i in 1...100 { b.send(i) }
        b.finish()
        var r: [Int] = []
        for await v in s { r.append(v) }
        XCTAssertEqual(r, [100])
    }

    func testFastConsumerSeesEveryValue() async {
        let b = Broadcaster<Int>()
        var it = b.stream().makeAsyncIterator()
        for i in 1...5 {
            b.send(i)
            let v = await it.next()
            XCTAssertEqual(v, i)
        }
    }

    func testCancelledSubscriberIsRemoved() async {
        let b = Broadcaster<Int>()
        let task = Task { for await _ in b.stream() {} }
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        _ = await task.value
        b.send(1) // 크래시 없이 통과해야 함
        let s = b.stream()
        b.send(2)
        b.finish()
        var r: [Int] = []
        for await v in s { r.append(v) }
        XCTAssertEqual(r, [2])
    }

    func testConcurrentSend() async {
        let b = Broadcaster<Int>()
        let s = b.stream()
        await withTaskGroup(of: Void.self) { g in
            for i in 0..<100 { g.addTask { b.send(i) } }
        }
        b.finish()
        var received: [Int] = []
        for await v in s { received.append(v) }
        XCTAssertEqual(received.count, 1) // 소비 전 100회 send → 최신 1개만 남음
        XCTAssertTrue((0..<100).contains(received[0]))
    }
}
