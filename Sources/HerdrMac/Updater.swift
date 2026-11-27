import AppKit
import HerdrCore
import Observation

/// Updates from a synced folder (OneDrive): a newer build there is offered in the toolbar,
/// installed over this app and restarted. See UpdateFeed for where it looks.
@MainActor @Observable
final class Updater {
    static let shared = Updater()

    private(set) var available: Release?
    /// A message for the person: an install that failed, or "up to date" after Check for Updates.
    var message: String?
    private(set) var installing = false
    /// Check for Updates found one: ask the person now (the toolbar button is easy to miss).
    var askToInstall = false

    @ObservationIgnored private var timer: Timer?

    let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    let currentBuild = Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0

    func start() {
        guard timer == nil else { return }
        check(manual: false)
        timer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { _ in
            MainActor.assumeIsolated { Updater.shared.check(manual: false) }
        }
    }

    /// Where releases are: `HERDR_MAC_UPDATES`, herdr-mac.json's `"updates"`, else OneDrive.
    nonisolated private static let cloud = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage")

    nonisolated private static func folders() -> [URL] {
        let fromFile = (try? Data(contentsOf: ModPlaces.url)).flatMap { try? JSON.parse($0) }?["updates"].string
        let override = ProcessInfo.processInfo.environment["HERDR_MAC_UPDATES"] ?? fromFile
        return UpdateFeed.folders(cloudStorage: cloud, override: override)
    }

    func check(manual: Bool) {
        let current = currentBuild, version = currentVersion
        Task.detached {
            // Reading a OneDrive file can download it first: off the main thread.
            let folders = Self.folders()
            let release = UpdateFeed.newest(in: folders, newerThan: current)
            let why = manual && release == nil ? UpdateFeed.explain(folders: folders, cloudStorage: Self.cloud, current: current) : []
            await MainActor.run {
                let me = Updater.shared
                me.available = release
                guard manual else { return }
                if release != nil { me.askToInstall = true }
                else { me.message = (["HerdrMac \(version) (\(current)) is the newest version I can find."] + why).joined(separator: "\n\n") }
            }
        }
    }

    /// Unpacks the release, checks it is HerdrMac and intact, puts it in place of this app
    /// and restarts.
    func install() {
        guard let release = available, !installing else { return }
        let current = Bundle.main.bundleURL
        if current.path.contains("/AppTranslocation/") {
            message = "Move HerdrMac to Applications first (it runs from a temporary copy macOS made), then update."
            return
        }
        installing = true
        let bundleID = Bundle.main.bundleIdentifier
        Task.detached {
            do {
                let new = try Self.unpack(release, bundleID: bundleID)
                _ = try FileManager.default.replaceItemAt(current, withItemAt: new)
                await MainActor.run { Self.relaunch(current) }
            } catch {
                await MainActor.run {
                    Updater.shared.installing = false
                    Updater.shared.message = "The update didn't install: \(error.localizedDescription)"
                }
            }
        }
    }

    nonisolated private static func unpack(_ release: Release, bundleID: String?) throws -> URL {
        if let want = release.sha256?.lowercased() {
            let got = try output("/usr/bin/shasum", ["-a", "256", release.zip.path]).split(separator: " ").first.map(String.init)
            guard got == want else { throw UpdateError("the zip isn't complete yet (still syncing?); try again in a minute") }
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("HerdrMac-update-\(release.build)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", release.zip.path, dir.path])
        let app = dir.appendingPathComponent("HerdrMac.app")
        let info = Bundle(url: app)?.infoDictionary
        guard info?["CFBundleIdentifier"] as? String == bundleID else { throw UpdateError("the zip doesn't hold HerdrMac") }
        guard Int(info?["CFBundleVersion"] as? String ?? "") == release.build else { throw UpdateError("the zip isn't build \(release.build)") }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        // It came through the person's own synced folder, from an app they already run.
        try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        return app
    }

    nonisolated private static func output(_ tool: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated private static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw UpdateError("\((tool as NSString).lastPathComponent) failed (\(p.terminationStatus))") }
    }

    /// Opens the app again once this process has quit.
    private static func relaunch(_ app: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", app.path]
        try? p.run()
        NSApp.terminate(nil)
    }
}

struct UpdateError: LocalizedError {
    let errorDescription: String?
    init(_ s: String) { errorDescription = s }
}
