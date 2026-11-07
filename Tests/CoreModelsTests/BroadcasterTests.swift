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
        XCTAssertEqual(r1, [1, 2])
        XCTAssertEqual(r2, [1, 2])
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
        XCTAssertEqual(r, [2, 3])
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
        var count = 0
        for await _ in s { count += 1 }
        XCTAssertEqual(count, 100)
    }
}
