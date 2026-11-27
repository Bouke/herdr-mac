import Foundation

/// A mod's `localStorage`, kept between launches like Herdr keeps it. herdr-mac keeps its own
/// copy (Application Support), first filled from Herdr's (`data/<mod>/store.json`), so a mod
/// starts as the person left it in Herdr. Herdr's file is never written: Herdr owns it.
@MainActor
enum ModStorage {
    static let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("HerdrMac/data")

    static func url(_ mod: String) -> URL { folder.appendingPathComponent("\(mod)/store.json") }

    static func load(_ mod: String) -> String {
        for url in [url(mod), ModHost.appHome.appendingPathComponent("data/\(mod)/store.json")] {
            if let data = try? Data(contentsOf: url), (try? JSONSerialization.jsonObject(with: data)) is [String: Any] {
                return String(decoding: data, as: UTF8.self)
            }
        }
        return "{}"
    }

    static func save(_ mod: String, _ json: String) {
        let url = url(mod)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(json.utf8).write(to: url, options: .atomic)
    }
}
