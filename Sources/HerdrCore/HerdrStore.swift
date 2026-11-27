import Foundation
import Observation

/// The live world from herdr-core: every terminal, and Herdr's spaces and tabs.
/// Mutated on the main actor only; the client's reader thread hops here.
@MainActor @Observable
public final class HerdrStore {
    public enum Connection: Equatable { case connecting, connected(version: String), failed(String) }

    public private(set) var connection: Connection = .connecting
    public private(set) var terminals: [String: CoreTerminal] = [:]
    /// Herdr's spaces and tabs: its document, plus tabs this app started that Herdr hasn't
    /// written into the document yet (so a new tab shows at once, not after Herdr's round trip),
    /// plus labelled terminals no tab holds (Herdr not running to adopt them).
    public var spaces: [Space] {
        let placed = Set(documentSpaces.flatMap { $0.tabs.flatMap(\.terminals) })
        return HerdrDocument.merge(documentSpaces, pending: pendingTabs + HerdrDocument.labelledTabs(Array(terminals.values), placed: placed))
    }
    private var documentSpaces: [Space] = []
    private var pendingTabs: [PendingTab] = []
    public private(set) var documentVersion: Int = 0

    @ObservationIgnored public private(set) var client: HcClient?
    @ObservationIgnored private var events = TerminalEvents()

    public init() {}

    public var hcPath: String? { client?.hcPath ?? HcClient.locate() }

    /// Connects (again) and keeps the store in step with the core. A previous connection
    /// is shut down; anything it still reports is ignored.
    public func start() {
        client?.shutdown()
        client = nil
        connection = .connecting
        attempt += 1
        let attempt = attempt
        Task.detached { [weak self] in
            do {
                let client = try HcClient()
                guard let self else { client.shutdown(); return }
                await self.attach(client, attempt: attempt)
            } catch {
                await self?.failAttempt(attempt, "\(error)")
            }
        }
    }

    /// Bumped by every `start()`: a connection that finishes its hello after a newer
    /// `start()` is shut down instead of replacing the newer one.
    @ObservationIgnored private var attempt = 0

    private func failAttempt(_ attempt: Int, _ message: String) {
        if attempt == self.attempt { fail(message) }
    }

    private func fail(_ message: String) { connection = .failed(message) }

    /// Runs `body` on the main actor if `client` is still the current one. Frames are
    /// delivered through the main queue, which keeps their order (a Task per frame wouldn't).
    nonisolated private func onMain(_ client: HcClient, _ body: @escaping @MainActor (HerdrStore) -> Void) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.client === client else { return }
                body(self)
            }
        }
    }

    private func attach(_ client: HcClient, attempt: Int) async {
        guard attempt == self.attempt else { client.shutdown(); return }
        self.client?.shutdown()
        self.client = client
        events = TerminalEvents()
        documentVersion = 0
        client.onLost { [weak self] in self?.onMain(client) { $0.fail("lost the connection to herdr-core") } }
        do {
            let sub = try await client.call("events.subscribe", [:])
            guard self.client === client else { return }
            guard let channel = sub["channel"].int.map(UInt32.init) else { throw HcError("subscribe returned no channel") }
            events.reset(snapshot: sub)
            terminals = events.byAddress
            connection = .connected(version: client.version)
            client.route(channel: channel) { [weak self] item in
                self?.onMain(client) { $0.receive(item, from: client, channel: channel) }
            }
            client.credit(channel: channel, bytes: 1 << 20)
            await reloadDocument(from: client)
        } catch {
            if self.client === client { fail("\(error)") }
        }
    }

    private func receive(_ item: HcClient.StreamItem, from client: HcClient, channel: UInt32) {
        switch item {
        case .data(let bytes):
            client.credit(channel: channel, bytes: bytes.count)
            let pushed = events.push(bytes)
            if pushed.terminals { terminals = events.byAddress }
            if pushed.docs { Task { await reloadDocument(from: client) } }
        case .closed, .lost:
            fail("the event stream ended")
        }
    }

    /// Reloads may overlap and answer out of order: only a reply at least as new as what
    /// we have, from the current connection, is applied.
    private func reloadDocument(from client: HcClient) async {
        guard let doc = try? await client.call("doc.get", ["name": .string(HerdrDocument.name)]),
              self.client === client else { return }
        let version = doc["version"].int ?? 0
        guard version >= documentVersion else { return }
        documentVersion = version
        documentSpaces = HerdrDocument.spaces(from: doc["value"])
        // Herdr has written (or dropped) them: the document is the truth again.
        let known = Set(documentSpaces.flatMap { $0.tabs.map(\.id) })
        pendingTabs.removeAll { known.contains($0.tab.id) || terminals[$0.tab.terminals[0]]?.isLive == false }
    }

    // MARK: Reading

    public var liveTerminals: [CoreTerminal] {
        terminals.values.filter(\.isLive).sorted { ($0.raw["created_ms"].double ?? 0) < ($1.raw["created_ms"].double ?? 0) }
    }

    /// Live terminals no Herdr tab shows (sub-agents, terminals started elsewhere).
    public var looseTerminals: [CoreTerminal] {
        let placed = Set(spaces.flatMap { $0.tabs.flatMap(\.terminals) })
        return liveTerminals.filter { !placed.contains($0.address) }
    }

    /// The sidebar's order for navigation: spaces → tabs → live terminals, then loose ones.
    public var navGroups: [NavGroup] {
        var groups = spaces.map { space in
            // Every tab, as Herdr numbers them; one without a live terminal stays empty.
            NavGroup(id: space.id, tabs: space.tabs.map { tab in
                NavTab(id: tab.id, terminals: tab.terminals.filter { terminals[$0]?.isLive == true })
            })
        }
        let loose = looseTerminals
        if !loose.isEmpty { groups.append(NavGroup(id: "loose", tabs: loose.map { NavTab(id: "loose:\($0.address)", terminals: [$0.address]) })) }
        return groups
    }

    public var agentAddresses: Set<String> { Set(terminals.values.filter { $0.isLive && $0.agentState != nil }.map(\.address)) }

    /// A space nobody named is called after where it is, as Herdr does; herdr-app writes
    /// that as each terminal's `where` label ("myrepo / 2").
    public func displayName(_ space: Space) -> String {
        if !space.name.isEmpty { return space.name }
        for address in space.tabs.flatMap(\.terminals) {
            if let w = terminals[address]?.label("where"), let name = w.components(separatedBy: " / ").first, !name.isEmpty {
                return name
            }
        }
        if let folder = space.folder { return (folder as NSString).lastPathComponent }
        return "Space"
    }

    /// The most urgent agent state among these terminals, as Herdr shows them:
    /// blocked > done > working > idle.
    public func state(of addresses: [String]) -> AgentState? {
        addresses.compactMap { terminals[$0]?.shownState }.min()
    }

    /// Someone is looking at this terminal: record its turn as seen (`herdr.seen`), as
    /// herdr-app does, so a finished agent stops asking for attention in every client.
    public func markSeen(_ address: String) {
        guard let t = terminals[address], t.needsSeen, let turn = t.turn, let client else { return }
        Task { _ = try? await client.call("terminal.label", ["terminal": .string(address), "labels": ["herdr.seen": .string(String(turn))]]) }
    }

    // MARK: Acting

    /// Starts a shell in a new Herdr tab of `space` (a new space when nil). herdr-app adopts
    /// a terminal labelled with ids it doesn't know as a new tab, so it shows up there too.
    /// `folder`: where the shell starts (default: where the space's last tab is).
    public func newShell(in space: Space?, folder: String? = nil) async throws -> String {
        guard let client else { throw HcError("not connected") }
        let cwd = folder ?? space.flatMap { s in s.tabs.last?.terminals.first.flatMap { terminals[$0]?.cwd } ?? s.folder }
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        let spaceID = space?.id ?? HerdrDocument.newId("sp"), tabID = HerdrDocument.newId("tb")
        let labels: JSON = ["herdr.space": .string(spaceID), "herdr.tab": .string(tabID)]
        let env: JSON = ["TERM": "xterm-256color", "COLORTERM": "truecolor", "TERM_PROGRAM": "herdr"]
        let result = try await client.call("terminal.run", ["cwd": .string(cwd), "keep": true, "labels": labels, "env": env])
        guard let address = result["address"].string else { throw HcError("terminal.run returned no address") }
        // Show it now: a provisional record until herdr-core's `created` event (the full
        // one) arrives, and a pending tab until Herdr writes it into its document.
        events.provisional(["address": .string(address), "state": "live", "cwd": .string(cwd), "labels": labels,
                            "created_ms": .number(Date().timeIntervalSince1970 * 1000)])
        terminals = events.byAddress
        pendingTabs.append(PendingTab(space: spaceID, folder: cwd, tab: SpaceTab(id: tabID, name: "", index: 0, terminals: [address])))
        return address
    }

    /// Starts a shell in `folder` in a new space (Herdr's `space.new`): a terminal with a
    /// space id Herdr doesn't know yet, which herdr-app adopts as a new space named after
    /// the folder or its repo.
    public func newSpace(folder: String) async throws -> String {
        try await newShell(in: nil, folder: folder)
    }

    /// Closes a tab the way Herdr does (`tab.close`, which ends its terminals and updates
    /// Herdr's document); a terminal no tab holds, or a tab while Herdr isn't running, is
    /// ended through herdr-core, and Herdr drops its pane when it sees the program exit.
    public func closeTab(id tabID: String?, terminals addresses: [String]) async throws {
        if let tabID, !isPendingTab(tabID), let herdr = Self.locateHerdrApp(),
           (try? await Self.run(herdr, ["do", "tab.close", "--id", tabID, "--confirmed", "true"])) == 0 {
            return
        }
        guard let client else { throw HcError("not connected") }
        for address in addresses { _ = try await client.call("terminal.kill", ["terminal": .string(address)]) }
    }

    private func isPendingTab(_ id: String) -> Bool { pendingTabs.contains { $0.tab.id == id } }

    /// herdr-app's command line, where it installs itself.
    static func locateHerdrApp() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/herdr-app", "/opt/homebrew/bin/herdr-app", "/usr/local/bin/herdr-app"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs a program off the main thread and returns its exit code.
    static func run(_ path: String, _ args: [String]) async throws -> Int32 {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }

    /// Whether `address` was just started here and Herdr hasn't placed it yet.
    public func isPending(_ address: String) -> Bool { pendingTabs.contains { $0.tab.terminals.contains(address) } }
}

/// Applies `events.subscribe` lines to a terminal list, as herdr-app's `hc::Events` does.
struct TerminalEvents {
    private(set) var byAddress: [String: CoreTerminal] = [:]
    private var seq: Double = 0
    private var lines = LineDecoder()

    struct Pushed { var terminals = false, docs = false }

    /// A terminal we started, before its `created` event: kept until that (or the
    /// snapshot after a `missed`) replaces it.
    mutating func provisional(_ record: JSON) {
        let t = CoreTerminal(record)
        if byAddress[t.address] == nil { byAddress[t.address] = t }
    }

    mutating func reset(snapshot: JSON) {
        seq = snapshot["seq"].double ?? 0
        byAddress = Dictionary((snapshot["terminals"].array ?? []).map { (CoreTerminal($0).address, CoreTerminal($0)) },
                               uniquingKeysWith: { $1 })
    }

    mutating func push(_ bytes: Data) -> Pushed {
        var pushed = Pushed()
        for line in lines.push(bytes) {
            let p = line["params"]
            switch line["method"].string {
            case "missed":
                reset(snapshot: p)
                pushed = Pushed(terminals: true, docs: true)
            case "event":
                if let s = p["seq"].double { guard s > seq else { continue }; seq = s }
                if p["type"].string == "doc" { pushed.docs = true } else { pushed.terminals = apply(p) || pushed.terminals }
            default:
                break
            }
        }
        return pushed
    }

    private mutating func apply(_ p: JSON) -> Bool {
        guard let kind = p["type"].string, let address = p["terminal"].string else { return false }
        let data = p["data"]
        let whole: JSON? = switch kind {
        case "created", "restarted": data
        case "labels": data["record"].isNull ? nil : data["record"]
        default: nil
        }
        if let whole {
            byAddress[address] = CoreTerminal(whole)
            return true
        }
        guard var t = byAddress[address]?.raw else { return false }
        func set(_ keys: [String]) { for k in keys { t[k] = data[k] } }
        switch kind {
        case "removed":
            byAddress[address] = nil
            return true
        case "finished", "lost":
            set(["reason", "exit_code", "signal", "finished_ms"])
            t["state"] = kind == "lost" ? "live" : "finished"
            if kind == "lost" { t["pid"] = .null }
            t["foreground"] = .null
        case "status": set(["status", "records", "reported"])
        case "turn": set(["turn"])
        case "title": set(["title"])
        case "labels": set(["labels"])
        case "keep": set(["keep"])
        case "size":
            // Every resize step of a window showing it: kept, but not announced as a change.
            // Nothing shows cols and rows, and announcing it re-rendered every mod per step.
            set(["cols", "rows"])
            byAddress[address] = CoreTerminal(t)
            return false
        case "foreground": t["foreground"] = data
        default: return false
        }
        byAddress[address] = CoreTerminal(t)
        return true
    }
}
