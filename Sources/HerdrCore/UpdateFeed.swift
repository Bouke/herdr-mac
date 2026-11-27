import Foundation

/// Releases published to a folder that syncs to every Mac that uses the app (OneDrive):
/// `herdr-mac/version.json` (`{"version", "build", "notes"}`) next to `HerdrMac.zip`.
public struct Release: Equatable, Sendable {
    public let version: String
    public let build: Int
    public let notes: String
    public let zip: URL
    /// The zip's SHA-256 (hex), checked before installing.
    public let sha256: String?
}

public enum UpdateFeed {
    public static let folderName = "herdr-mac"

    /// The release in `folder`, if it has a valid version.json and its zip.
    public static func read(folder: URL) -> Release? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("version.json")),
              let json = try? JSON.parse(data), let build = json["build"].int, build > 0 else { return nil }
        let zip = folder.appendingPathComponent(json["zip"].string ?? "HerdrMac.zip")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: zip.path) else { return nil }
        // Synced files arrive one by one: until the zip is the size version.json names, it's
        // still the previous one (or half of the new one). Not offered yet.
        if let size = json["size"].int, (attrs[.size] as? NSNumber)?.intValue != size { return nil }
        return Release(version: json["version"].string ?? "?", build: build, notes: json["notes"].string ?? "", zip: zip,
                       sha256: json["sha256"].string)
    }

    /// Where releases may be: `override` if set, else every `herdr-mac` (or `<owner> - herdr-mac`)
    /// folder at the top of a synced cloud folder (`~/Library/CloudStorage/OneDrive-*`, the
    /// shared libraries included) or one level deeper.
    public static func folders(cloudStorage: URL, override: String?) -> [URL] {
        if let override, !override.isEmpty { return [URL(fileURLWithPath: (override as NSString).expandingTildeInPath)] }
        let fm = FileManager.default
        let clouds = ((try? fm.contentsOfDirectory(atPath: cloudStorage.path)) ?? [])
            .filter { $0.hasPrefix("OneDrive") }.sorted().map { cloudStorage.appendingPathComponent($0) }
        var out: [URL] = []
        for cloud in clouds {
            for top in ((try? fm.contentsOfDirectory(atPath: cloud.path)) ?? []).sorted() where !top.hasPrefix(".") {
                let dir = cloud.appendingPathComponent(top)
                if isRelease(top) { out.append(dir); continue }
                for sub in ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() where isRelease(sub) {
                    out.append(dir.appendingPathComponent(sub))
                }
            }
        }
        return out
    }

    /// `herdr-mac`, or `<owner> - herdr-mac`: how OneDrive names a folder someone shared with
    /// you (in OneDrive-SharedLibraries-<org>).
    static func isRelease(_ name: String) -> Bool { name == folderName || name.hasSuffix(" - \(folderName)") }

    /// The newest release in `folders` with a build above `current`.
    public static func newest(in folders: [URL], newerThan current: Int) -> Release? {
        folders.compactMap(read).filter { $0.build > current }.max { $0.build < $1.build }
    }

    /// For "Check for Updates": what each place holds, or why it doesn't count, in words
    /// a person can act on.
    public static func explain(folders: [URL], cloudStorage: URL, current: Int) -> [String] {
        guard !folders.isEmpty else {
            let clouds = ((try? FileManager.default.contentsOfDirectory(atPath: cloudStorage.path)) ?? []).filter { $0.hasPrefix("OneDrive") }
            return clouds.isEmpty
                ? ["No OneDrive on this Mac (nothing in \(cloudStorage.path))."]
                : ["No \(folderName) folder in \(clouds.joined(separator: ", ")). Add the shared \(folderName) folder to your own OneDrive (“Add shortcut to My files”) so it syncs here."]
        }
        return folders.map { folder in
            let place = folder.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
            let versionURL = folder.appendingPathComponent("version.json")
            let data: Data
            do { data = try Data(contentsOf: versionURL) } catch {
                let denied = (error as NSError).code == NSFileReadNoPermissionError
                    || ((error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError)?.code == Int(EPERM)
                if !FileManager.default.fileExists(atPath: versionURL.path) { return "\(place): no version.json yet." }
                return denied
                    ? "\(place): macOS doesn't let HerdrMac read it. Allow it under System Settings › Privacy & Security › Files and Folders (or Full Disk Access)."
                    : "\(place): version.json can't be read (\(error.localizedDescription))."
            }
            guard let json = try? JSON.parse(data), let build = json["build"].int else { return "\(place): version.json isn't valid." }
            let zip = folder.appendingPathComponent(json["zip"].string ?? "HerdrMac.zip")
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: zip.path) else { return "\(place): \(json["version"].string ?? "?") is announced, but its zip isn't there yet." }
            if let size = json["size"].int, (attrs[.size] as? NSNumber)?.intValue != size {
                return "\(place): \(json["version"].string ?? "?") is still syncing (\((attrs[.size] as? NSNumber)?.intValue ?? 0) of \(size) bytes)."
            }
            return build > current ? "\(place): \(json["version"].string ?? "?") (\(build)) is newer." : "\(place): \(json["version"].string ?? "?") (\(build)), not newer."
        }
    }
}
