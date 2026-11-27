import Foundation
import Testing
@testable import HerdrCore

/// A stand-in for `hc` that runs `script` (sh) when called as `hc connect`.
private func fakeHc(_ script: String) throws -> String {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fake-hc-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("hc").path
    try ("#!/bin/sh\n" + script).write(toFile: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    return path
}

@Test func aCoreThatGoesAwayFailsCallsWithoutKillingTheApp() async throws {
    let hc = try fakeHc("""
    read line
    printf '%s\\n' '{"jsonrpc":"2.0","id":0,"result":{"framed":true,"version":"test"}}'
    exit 0
    """)
    let client = try HcClient(hcPath: hc)
    #expect(client.version == "test")
    try await Task.sleep(for: .milliseconds(300))
    // Writing to the exited process must not raise SIGPIPE; the call fails once, promptly.
    client.credit(channel: 1, bytes: 10)
    let start = Date()
    await #expect(throws: HcError.self) { try await client.call("terminal.list", timeout: 60) }
    await #expect(throws: HcError.self) { try await client.call("terminal.list", timeout: 60) }
    #expect(Date().timeIntervalSince(start) < 2, "a lost core fails calls at once, not at their timeout")
}

@Test func aCoreThatNeverAnswersHelloTimesOut() throws {
    let hc = try fakeHc("read line\nsleep 30\n")
    let start = Date()
    #expect(throws: HcError.self) { try HcClient(hcPath: hc, helloTimeout: 0.5) }
    #expect(Date().timeIntervalSince(start) < 5)
}

@Test func aFreshEventStateDropsHalfLinesFromAnOldStream() {
    var events = TerminalEvents()
    _ = events.push(Data(#"{"method":"event","params":{"seq":9,"type":"title","#.utf8))
    events = TerminalEvents()
    events.reset(snapshot: ["seq": 1, "terminals": [["address": "t1", "state": "live"]]])
    let line: JSON = ["method": "event", "params": ["seq": 2, "type": "title", "terminal": "t1", "data": ["title": "ok"]]]
    _ = events.push(line.data() + Data("\n".utf8))
    #expect(events.byAddress["t1"]?.title == "ok")
}

private final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

@Test func framesForAClosedChannelAreDroppedButEarlyFramesAreKept() async throws {
    // After hello: a DATA frame "old" on channel 5, then "new" on channel 6.
    let hc = try fakeHc("""
    read line
    printf '%s\\n' '{"jsonrpc":"2.0","id":0,"result":{"framed":true,"version":"test"}}'
    sleep 0.3
    printf '\\005\\000\\000\\000\\000\\003\\000\\000\\000old'
    printf '\\006\\000\\000\\000\\000\\003\\000\\000\\000new'
    sleep 5
    """)
    let client = try HcClient(hcPath: hc)
    defer { client.shutdown() }
    client.closeStream(channel: 5)
    try await Task.sleep(for: .milliseconds(700))
    let got = Received()
    let text = { (item: HcClient.StreamItem) -> String in if case .data(let d) = item { return String(decoding: d, as: UTF8.self) }; return "other" }
    client.route(channel: 5) { got.add("5:" + text($0)) }
    client.route(channel: 6) { got.add("6:" + text($0)) }
    #expect(got.all == ["6:new"])
}
