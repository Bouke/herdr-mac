import Foundation

public struct HcError: Error, CustomStringConvertible, Sendable {
    public let message: String
    public let kind: String?
    public init(_ message: String, kind: String? = nil) { self.message = message; self.kind = kind }
    init(rpc: JSON) { self.init(rpc["message"].string ?? "\(rpc)", kind: rpc["data"]["kind"].string) }
    public var description: String { kind.map { "\(message) (\($0))" } ?? message }
}

/// One connection to herdr-core through `hc connect`, in framed mode.
/// A Swift port of herdr-app's `src/hc.rs`.
public final class HcClient: @unchecked Sendable {
    public enum StreamItem: Sendable { case data(Data), closed(JSON), lost }

    public static let generation = 1

    public let hcPath: String
    public let hello: JSON
    private let process: Process
    private let input: FileHandle
    private let writer = DispatchQueue(label: "herdr.hc.writer")
    private let lock = NSLock()
    private var nextId: UInt64 = 1
    private var replies: [UInt64: (Result<JSON, HcError>) -> Void] = [:]
    private var streams: [UInt32: @Sendable (StreamItem) -> Void] = [:]
    private var early: [UInt32: [StreamItem]] = [:]
    /// Channels this side closed: their late frames are dropped, not kept in `early`.
    private var closedChannels: Set<UInt32> = []
    private var closed = false
    private var lostHandlers: [@Sendable () -> Void] = []

    /// Where `hc` is: `HERDR_HC`, the usual install folders, then PATH.
    /// An app started from Finder has a minimal PATH, so the folders come first.
    public static func locate() -> String? {
        let env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = [env["HERDR_HC"]].compactMap { $0 }
        candidates += ["\(home)/.local/bin/hc", "/opt/homebrew/bin/hc", "/usr/local/bin/hc"]
        candidates += (env["PATH"] ?? "").split(separator: ":").map { "\($0)/hc" }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public init(hcPath: String? = nil, helloTimeout: TimeInterval = 15) throws {
        guard let path = hcPath ?? Self.locate() else { throw HcError("cannot find `hc`: is herdr-core installed?") }
        self.hcPath = path
        // A write after `hc connect` exits must fail, not kill the app; the reader reports the loss.
        signal(SIGPIPE, SIG_IGN)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["connect"]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.standardError
        try process.run()
        self.process = process
        self.input = stdin.fileHandleForWriting

        // The hello reply is one JSON line; read it byte by byte so nothing framed is consumed.
        let fd = stdout.fileHandleForReading.fileDescriptor
        let request: JSON = ["jsonrpc": "2.0", "id": 0, "method": "hello",
                             "params": ["framed": true, "generation": .number(Double(Self.generation))]]
        try input.write(contentsOf: request.data() + Data("\n".utf8))
        var line = Data()
        var byte: UInt8 = 0
        let deadline = Date().addingTimeInterval(helloTimeout)
        while true {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let left = Int32(max(0, deadline.timeIntervalSinceNow) * 1000)
            guard left > 0, poll(&pfd, 1, left) > 0 else {
                process.terminate()
                throw HcError("herdr-core did not answer within \(Int(helloTimeout)) s")
            }
            guard read(fd, &byte, 1) == 1, byte != UInt8(ascii: "\n") else { break }
            line.append(byte)
        }
        let reply = (try? JSON.parse(line)) ?? .null
        if !reply["error"].isNull {
            process.terminate()
            throw HcError(rpc: reply["error"])
        }
        guard reply["result"]["framed"].bool == true else {
            process.terminate()
            throw HcError("herdr-core did not switch to framed mode: \(String(decoding: line, as: UTF8.self))")
        }
        self.hello = reply["result"]

        let thread = Thread { [weak self] in self?.readLoop(fd: fd) }
        thread.name = "herdr.hc.reader"
        thread.start()
    }

    deinit { process.terminate() }

    /// Ends the connection: `hc connect` exits, the reader sees end of file and reports
    /// `.lost` to every stream and pending call. The reader thread holds the client until
    /// then, so dropping the last reference alone would leave the process running.
    public func shutdown() {
        process.terminate()
        writer.async { [input] in try? input.close() }
    }

    public var version: String { hello["version"].string ?? "?" }

    // MARK: Calls

    public func call(_ method: String, _ params: JSON = [:], timeout: TimeInterval = 10) async throws -> JSON {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<JSON, Error>) in
            lock.lock()
            if closed {
                lock.unlock()
                cont.resume(throwing: HcError("\(method): lost the core"))
                return
            }
            let id = nextId
            nextId += 1
            replies[id] = { result in cont.resume(with: result.mapError { $0 as Error }) }
            lock.unlock()

            let request: JSON = ["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params]
            send(Frame(channel: 0, kind: .data, payload: request.data()))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(id, .failure(HcError("\(method): no reply from core")))
            }
        }
    }

    private func finish(_ id: UInt64, _ result: Result<JSON, HcError>) {
        lock.lock()
        let reply = replies.removeValue(forKey: id)
        lock.unlock()
        reply?(result)
    }

    // MARK: Streams

    /// Routes a channel's frames to `handler` (on the reader thread), including any that
    /// arrived before the reply that named the channel.
    public func route(channel: UInt32, _ handler: @escaping @Sendable (StreamItem) -> Void) {
        lock.lock()
        let pending = early.removeValue(forKey: channel) ?? []
        if closed { lock.unlock(); handler(.lost); return }
        streams[channel] = handler
        lock.unlock()
        pending.forEach(handler)
    }

    public func credit(channel: UInt32, bytes: Int) {
        var n = UInt32(clamping: bytes).littleEndian
        send(Frame(channel: channel, kind: .credit, payload: Data(bytes: &n, count: 4)))
    }

    public func closeStream(channel: UInt32) {
        lock.lock()
        streams.removeValue(forKey: channel)
        early.removeValue(forKey: channel)
        closedChannels.insert(channel)
        lock.unlock()
        send(Frame(channel: channel, kind: .close, payload: Data()))
    }

    public func onLost(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        let already = closed
        if !already { lostHandlers.append(handler) }
        lock.unlock()
        if already { handler() }
    }

    public func send(_ frame: Frame) {
        let bytes = frame.encoded()
        writer.async { [input] in try? input.write(contentsOf: bytes) }
    }

    // MARK: Reader

    private func readLoop(fd: Int32) {
        var decoder = FrameDecoder()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            for frame in decoder.push(Data(buffer[0..<n])) { dispatch(frame) }
        }
        lock.lock()
        closed = true
        let handlers = Array(streams.values)
        let waiting = Array(replies.values)
        let lost = lostHandlers
        streams.removeAll(); replies.removeAll(); lostHandlers.removeAll()
        lock.unlock()
        handlers.forEach { $0(.lost) }
        waiting.forEach { $0(.failure(HcError("lost the core"))) }
        lost.forEach { $0() }
    }

    private func dispatch(_ frame: Frame) {
        if frame.channel == 0 {
            guard let message = try? JSON.parse(frame.payload), let id = message["id"].double else { return }
            let error = message["error"]
            finish(UInt64(id), error.isNull ? .success(message["result"]) : .failure(HcError(rpc: error)))
            return
        }
        let item: StreamItem
        switch FrameKind(rawValue: frame.kind) {
        case .data: item = .data(frame.payload)
        case .close: item = .closed((try? JSON.parse(frame.payload)) ?? .null)
        default: return
        }
        lock.lock()
        if closedChannels.contains(frame.channel) {
            // The core's own CLOSE ends the channel for good; until then, drop what comes.
            if case .closed = item { closedChannels.remove(frame.channel) }
            lock.unlock()
            return
        }
        let handler = streams[frame.channel]
        if handler == nil { early[frame.channel, default: []].append(item) }
        if case .closed = item { streams.removeValue(forKey: frame.channel) }
        lock.unlock()
        handler?(item)
    }
}
