import CoreServices
import Foundation
import HerdrCore
import JavaScriptCore
import Observation

/// One running mod: its JavaScriptCore context, timers, folder watches and the tree its
/// `render()` last returned. Main thread only.
@MainActor @Observable
final class ModInstance {
    let name: String
    private(set) var tree: ModNode?
    private(set) var error: String?
    private(set) var log: [String] = []
    /// The height the mod asked for with Herdr's `layout.resize` (its block's px), e.g.
    /// a usage meter sizing itself to its rows. Used where the mod sits in the sidebar.
    private(set) var preferredHeight: CGFloat?

    @ObservationIgnored private let host: ModHost
    @ObservationIgnored private var context: JSContext!
    @ObservationIgnored private var timers: [Timer] = []
    @ObservationIgnored private var watches: [Int: FSEventStreamRef] = [:]
    @ObservationIgnored private var nextWatch = 1
    @ObservationIgnored private var renderQueued = false
    @ObservationIgnored private var closed = false

    private var folder: URL { ModHost.appHome.appendingPathComponent("mods/\(name)") }

    init(name: String, host: ModHost) {
        self.name = name
        self.host = host
        start()
    }

    // MARK: Lifecycle

    private func start() {
        guard let context = JSContext() else { error = "JavaScriptCore didn't start"; return }
        self.context = context
        context.name = "mod \(name)"
        context.exceptionHandler = { [weak self] _, exception in
            let stack = exception?.objectForKeyedSubscript("stack")?.toString() ?? ""
            let message = (exception?.toString() ?? "error") + (stack.isEmpty || stack == "undefined" ? "" : "\n" + stack)
            MainActor.assumeIsolated { self?.fail(message) }
        }
        context.setObject(bridge(), forKeyedSubscript: "__host" as NSString)
        context.evaluateScript(ModPrelude.source, withSourceURL: URL(string: "herdr-mac://prelude.js"))
        guard error == nil else { return }
        let main = folder.appendingPathComponent("main.js").path
        context.objectForKeyedSubscript("__start").call(withArguments: [main, "{}"])
        guard error == nil else { return }
        render()
    }

    func close() {
        guard !closed else { return }
        closed = true
        context?.objectForKeyedSubscript("__close")?.call(withArguments: [])
        timers.forEach { $0.invalidate() }
        timers.removeAll()
        for id in Array(watches.keys) { unwatch(id) }
    }

    private func fail(_ message: String) {
        error = message
        appendLog("error: \(message)")
    }

    private func appendLog(_ line: String) {
        log.append(line)
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    // MARK: Render and events

    func render() {
        guard !closed, error == nil, let r = context.objectForKeyedSubscript("__render")?.call(withArguments: []),
              let s = r.toString(), let json = try? JSON.parse(Data(s.utf8)) else { return }
        tree = ModNode(json)
    }

    /// `cx.notify()`, and live data changing: render once, after whatever else runs now.
    func queueRender() {
        guard !renderQueued else { return }
        renderQueued = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.renderQueued = false
                self?.render()
            }
        }
    }

    func input(_ id: Int, _ event: String, _ value: String) {
        context.objectForKeyedSubscript("__input")?.call(withArguments: [id, event, value])
        queueRender()
    }

    func click(_ id: Int) {
        context.objectForKeyedSubscript("__click")?.call(withArguments: [id])
        queueRender()
    }

    // MARK: The host object (`__host` in JavaScript)

    private func bridge() -> JSValue {
        let o = JSValue(newObjectIn: context)!
        func set(_ name: String, _ block: Any) { o.setObject(block, forKeyedSubscript: name as NSString) }

        set("log", { [weak self] (line: String) in MainActor.assumeIsolated { self?.appendLog(line) } } as @convention(block) (String) -> Void)
        set("notify", { [weak self] in MainActor.assumeIsolated { self?.queueRender() } } as @convention(block) () -> Void)
        set("after", { [weak self] (ms: Double, fn: JSValue) in
            MainActor.assumeIsolated { self?.schedule(ms, repeats: false, fn) }
        } as @convention(block) (Double, JSValue) -> Void)
        set("every", { [weak self] (ms: Double, fn: JSValue) in
            MainActor.assumeIsolated { self?.schedule(ms, repeats: true, fn) }
        } as @convention(block) (Double, JSValue) -> Void)
        set("data", { [weak self] (name: String) -> String in
            MainActor.assumeIsolated { self.map { String(decoding: $0.host.data(name, mod: $0.name).data(), as: UTF8.self) } ?? "null" }
        } as @convention(block) (String) -> String)
        set("shared", { [weak self] (key: String) -> String in
            MainActor.assumeIsolated { self.map { String(decoding: $0.host.shared(key).data(), as: UTF8.self) } ?? "null" }
        } as @convention(block) (String) -> String)
        set("setShared", { [weak self] (key: String, value: String) in
            MainActor.assumeIsolated { self?.host.setShared(key, (try? JSON.parse(Data(value.utf8))) ?? .null) }
        } as @convention(block) (String, String) -> Void)
        set("run", { [weak self] (name: String, args: String) in
            MainActor.assumeIsolated {
                guard let self else { return }
                let json = (try? JSON.parse(Data(args.utf8))) ?? [:]
                if name == "layout.resize", let px = json["px"].double { self.preferredHeight = CGFloat(px); return }
                self.host.run(name, json) { self.appendLog($0) }
            }
        } as @convention(block) (String, String) -> Void)
        set("exec", { [weak self] (cmd: String, args: String, cwd: JSValue, timeout: Double, ok: JSValue, fail: JSValue) in
            let argv = ((try? JSON.parse(Data(args.utf8)))?.array ?? []).compactMap(\.string)
            let dir = cwd.isString ? cwd.toString() : nil
            MainActor.assumeIsolated { self?.exec(cmd, argv, cwd: dir, timeout: timeout, ok: ok, fail: fail) }
        } as @convention(block) (String, String, JSValue, Double, JSValue, JSValue) -> Void)
        set("readTextFile", { (path: String, ok: JSValue, fail: JSValue) in
            let url = Self.url(path)
            Task.detached {
                let text = try? String(contentsOf: url, encoding: .utf8)
                await MainActor.run { if let text { ok.call(withArguments: [text]) } else { fail.call(withArguments: ["can't read \(path)"]) } }
            }
        } as @convention(block) (String, JSValue, JSValue) -> Void)
        set("writeTextFile", { (path: String, text: String, ok: JSValue, fail: JSValue) in
            // As in Herdr: writes only under the Herdr home.
            let url = Self.url(path)
            guard url.standardizedFileURL.path.hasPrefix(ModHost.appHome.path + "/") else {
                fail.call(withArguments: ["mods write only under \(ModHost.appHome.path)"]); return
            }
            do { try text.write(to: url, atomically: true, encoding: .utf8); ok.call(withArguments: []) }
            catch { fail.call(withArguments: ["\(error)"]) }
        } as @convention(block) (String, String, JSValue, JSValue) -> Void)
        set("watch", { [weak self] (dir: String, ok: JSValue, fail: JSValue) -> Int in
            MainActor.assumeIsolated { self?.watch(dir, ok: ok, fail: fail) ?? 0 }
        } as @convention(block) (String, JSValue, JSValue) -> Int)
        set("unwatch", { [weak self] (id: Int) in MainActor.assumeIsolated { self?.unwatch(id) } } as @convention(block) (Int) -> Void)
        set("home", { FileManager.default.homeDirectoryForCurrentUser.path } as @convention(block) () -> String)
        set("appHome", { ModHost.appHome.path } as @convention(block) () -> String)
        set("moduleSource", { (path: String) -> String in
            let source = (try? String(contentsOfFile: path, encoding: .utf8)) ?? "throw new Error('cannot read \(path)')"
            return ModSource.wrap(source, url: URL(fileURLWithPath: path).absoluteString)
        } as @convention(block) (String) -> String)
        set("resolve", { (from: String, spec: String) -> String in
            URL(fileURLWithPath: spec, relativeTo: URL(fileURLWithPath: from).deletingLastPathComponent()).standardizedFileURL.path
        } as @convention(block) (String, String) -> String)
        return o
    }

    private static func url(_ path: String) -> URL {
        if path.hasPrefix("~/") { return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(String(path.dropFirst(2))) }
        return path.hasPrefix("/") ? URL(fileURLWithPath: path) : ModHost.appHome.appendingPathComponent(path)
    }

    private func schedule(_ ms: Double, repeats: Bool, _ fn: JSValue) {
        guard !closed else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: max(ms, 1) / 1000, repeats: repeats) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                fn.call(withArguments: [])
            }
        }
        timers.append(timer)
        timers.removeAll { !$0.isValid }
    }

    /// `exec`: the program, found on the person's usual PATH (an app started from Finder
    /// has a minimal one), with a timeout.
    private func exec(_ cmd: String, _ args: [String], cwd: String?, timeout: Double, ok: JSValue, fail: JSValue) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin", env["PATH"] ?? ""]
            .joined(separator: ":")
        Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = [cmd] + args
            p.environment = env
            if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch {
                await MainActor.run { fail.call(withArguments: ["can't run \(cmd): \(error)"]) }
                return
            }
            let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + min(max(timeout, 100), 600_000) / 1000, execute: killer)
            async let stdout = out.fileHandleForReading.readDataToEndOfFile()
            async let stderr = err.fileHandleForReading.readDataToEndOfFile()
            let (o, e) = await (stdout, stderr)
            p.waitUntilExit()
            killer.cancel()
            let result: JSON = ["code": .number(Double(p.terminationStatus)), "stdout": .string(String(decoding: o, as: UTF8.self)),
                                "stderr": .string(String(decoding: e, as: UTF8.self))]
            await MainActor.run { ok.call(withArguments: [String(decoding: result.data(), as: UTF8.self)]) }
        }
    }

    /// `watchFolder`: resolves with the changed paths the next time anything under `dir`
    /// changes (FSEvents, recursive), then stops.
    private func watch(_ dir: String, ok: JSValue, fail: JSValue) -> Int {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            fail.call(withArguments: ["no such folder: \(dir)"])
            return 0
        }
        let id = nextWatch
        nextWatch += 1
        final class Box { let fire: ([String]) -> Void; init(_ f: @escaping ([String]) -> Void) { fire = f } }
        let box = Box { [weak self] paths in
            MainActor.assumeIsolated {
                guard let self, self.watches[id] != nil else { return }
                self.unwatch(id)
                ok.call(withArguments: [String(decoding: JSON.array(paths.map(JSON.string)).data(), as: UTF8.self)])
            }
        }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passRetained(box).toOpaque(), retain: nil,
                                       release: { info in info.map { Unmanaged<AnyObject>.fromOpaque($0).release() } },
                                       copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let list = (Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String]) ?? []
            let box = Unmanaged<AnyObject>.fromOpaque(info).takeUnretainedValue() as! Box
            DispatchQueue.main.async { box.fire(Array(list.prefix(count))) }
        }
        guard let stream = FSEventStreamCreate(nil, callback, &ctx, [dir] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents))
        else { fail.call(withArguments: ["can't watch \(dir)"]); return 0 }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream)
        watches[id] = stream
        return id
    }

    private func unwatch(_ id: Int) {
        guard let stream = watches.removeValue(forKey: id) else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
