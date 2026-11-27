import Darwin
import Foundation
import HerdrCore

// herdr-mac-attach [--hc PATH] [--active] [--history N] ADDRESS
//
// What a libghostty surface in HerdrMac runs: its pty becomes a view of a herdr-core terminal,
// over herdr-core's framed protocol. Unlike `hc attach` it shares the terminal politely with
// other windows (herdr-app, other HerdrMac copies):
// - it attaches without taking the terminal's size (`resumed`), unless --active (the one shown);
// - it learns keyboard focus from the surface (focus reporting, ESC[?1004h, on its own pty),
//   tells herdr-core (FOCUS) and takes the size (RESIZE) only on focus, as herdr-app does;
// - without focus, what the surface writes can only be its replies to a program's queries:
//   those go as AUTOMATIC_INPUT, which never takes the size;
// - no detach key: ctrl+\ reaches the program.

setvbuf(stdout, nil, _IONBF, 0)
var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    defer { args.removeSubrange(i...(i + 1)) }
    return args[i + 1]
}
let hcPath = option("--hc")
let history = Int(option("--history") ?? "5000") ?? 5000
let active = args.contains("--active")
args.removeAll { $0 == "--active" }
guard let address = args.last else {
    FileHandle.standardError.write(Data("usage: herdr-mac-attach [--hc PATH] [--active] [--history N] ADDRESS\n".utf8))
    exit(2)
}

// Raw pty: every byte as typed, no echo; restored on exit.
var saved = termios()
let isTTY = tcgetattr(STDIN_FILENO, &saved) == 0
if isTTY {
    var raw = saved
    cfmakeraw(&raw)
    tcsetattr(STDIN_FILENO, TCSANOW, &raw)
}
func finish(_ code: Int32, _ message: String? = nil) -> Never {
    if isTTY { tcsetattr(STDIN_FILENO, TCSANOW, &saved) }
    if let message { FileHandle.standardError.write(Data((message + "\r\n").utf8)) }
    exit(code)
}

func size() -> (cols: UInt16, rows: UInt16) {
    var ws = winsize()
    guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0 else { return (80, 24) }
    return (ws.ws_col, ws.ws_row)
}

func write(_ data: Data) {
    data.withUnsafeBytes { buf in
        var p = buf.baseAddress!, left = buf.count
        while left > 0 {
            let n = Darwin.write(STDOUT_FILENO, p, left)
            if n <= 0 { if errno == EINTR { continue }; return }
            p += n; left -= n
        }
    }
}

let focusOn = Data("\u{1b}[?1004h".utf8)
let focusOff = Data("\u{1b}[?1004l".utf8)
let focusIn = Data("\u{1b}[I".utf8), focusOut = Data("\u{1b}[O".utf8)

let client: HcClient
do { client = try HcClient(hcPath: hcPath) } catch { finish(1, "herdr-mac-attach: \(error)") }
let automaticInput = client.hello["features"].array?.contains(.string("automatic_input")) == true

/// Shared between the stdin thread, SIGWINCH and the stream.
final class State: @unchecked Sendable {
    let lock = NSLock()
    var channel: UInt32?
    var focused = active
    var automatic = false
}
let state = State()

func send(_ kind: FrameKind, _ payload: Data) {
    state.lock.lock(); let ch = state.channel; state.lock.unlock()
    if let ch { client.send(Frame(channel: ch, kind: kind, payload: payload)) }
}
func sendSize() {
    let s = size()
    var p = Data()
    withUnsafeBytes(of: s.cols.littleEndian) { p.append(contentsOf: $0) }
    withUnsafeBytes(of: s.rows.littleEndian) { p.append(contentsOf: $0) }
    send(.resize, p)
}

// Ask the surface for focus reports before anything else is drawn.
write(focusOn)

let attachDone = DispatchSemaphore(value: 0)
Task.detached {
    do {
        let s = size()
        var params: JSON = ["terminal": .string(address), "cols": .number(Double(s.cols)), "rows": .number(Double(s.rows)),
                            "history": .number(Double(history))]
        if !active { params["resumed"] = true }
        let result = try await client.call("terminal.attach", params)
        guard let channel = result["channel"].int.map(UInt32.init) else { finish(1, "herdr-mac-attach: no channel") }
        state.lock.withLock {
            state.channel = channel
            state.automatic = automaticInput && result["automatic_input"].bool == true
        }
        client.route(channel: channel) { item in
            switch item {
            case .data(let bytes):
                write(bytes)
                // A program turning focus reports off would leave us blind to focus: keep them on
                // (herdr-core still decides what the program itself is told).
                if bytes.range(of: focusOff) != nil { write(focusOn) }
                client.credit(channel: channel, bytes: bytes.count)
            case .closed, .lost:
                finish(0)
            }
        }
        if active { send(.focus, Data([1])) }
        attachDone.signal()
    } catch {
        finish(1, "herdr-mac-attach: \(address): \(error)")
    }
}
client.onLost { finish(0) }

// The surface resized: take the size only while it's the one with focus.
signal(SIGWINCH, SIG_IGN)
let winch = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .global())
winch.setEventHandler {
    state.lock.lock(); let focused = state.focused; state.lock.unlock()
    if focused { sendSize() }
}
winch.resume()

// Keys and replies from the surface.
attachDone.wait()
var buffer = [UInt8](repeating: 0, count: 64 * 1024)
while true {
    let n = read(STDIN_FILENO, &buffer, buffer.count)
    if n < 0 && errno == EINTR { continue }
    if n <= 0 { finish(0) }
    var data = Data(buffer[0..<n])
    // Focus reports from the surface: herdr-core hears them as FOCUS, the program never sees
    // them raw. Focus in also takes the size, as a click does in herdr-app.
    for (report, on) in [(focusIn, true), (focusOut, false)] {
        while let r = data.range(of: report) {
            data.removeSubrange(r)
            state.lock.lock(); state.focused = on; state.lock.unlock()
            send(.focus, Data([on ? 1 : 0]))
            if on { sendSize() }
        }
    }
    guard !data.isEmpty else { continue }
    state.lock.lock(); let focused = state.focused, automatic = state.automatic; state.lock.unlock()
    send(!focused && automatic ? .automaticInput : .data, data)
}
