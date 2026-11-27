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

    /// Where releases may be: `override` if set, else every `herdr-mac` folder at the top of a
    /// synced cloud folder (`~/Library/CloudStorage/OneDrive-*`) or one level deeper (a shared
    /// folder someone added to their own OneDrive).
    public static func folders(cloudStorage: URL, override: String?) -> [URL] {
        if let override, !override.isEmpty { return [URL(fileURLWithPath: (override as NSString).expandingTildeInPath)] }
        let fm = FileManager.default
        let clouds = ((try? fm.contentsOfDirectory(atPath: cloudStorage.path)) ?? [])
            .filter { $0.hasPrefix("OneDrive") }.sorted().map { cloudStorage.appendingPathComponent($0) }
        var out: [URL] = []
        for cloud in clouds {
            let top = cloud.appendingPathComponent(folderName)
            if fm.fileExists(atPath: top.path) { out.append(top) }
            for sub in ((try? fm.contentsOfDirectory(atPath: cloud.path)) ?? []).sorted() where !sub.hasPrefix(".") {
                let nested = cloud.appendingPathComponent(sub).appendingPathComponent(folderName)
                if fm.fileExists(atPath: nested.path) { out.append(nested) }
            }
        }
        return out
    }

    /// The newest release in `folders` with a build above `current`.
    public static func newest(in folders: [URL], newerThan current: Int) -> Release? {
        folders.compactMap(read).filter { $0.build > current }.max { $0.build < $1.build }
    }
}
