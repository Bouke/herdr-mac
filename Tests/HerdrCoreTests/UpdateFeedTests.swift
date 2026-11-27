import Foundation
import Testing
@testable import HerdrCore

private func folder(_ base: URL, _ path: String, build: Int?, zip: Bool = true) throws -> URL {
    let dir = base.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    if let build {
        try #"{"version": "0.\#(build)", "build": \#(build), "notes": "n\#(build)"}"#.write(to: dir.appendingPathComponent("version.json"), atomically: true, encoding: .utf8)
    }
    if zip { try Data([1]).write(to: dir.appendingPathComponent("HerdrMac.zip")) }
    return dir
}

@Test func findsReleasesInOneDriveFoldersAndPicksTheNewest() throws {
    let cloud = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-\(UUID().uuidString)")
    _ = try folder(cloud, "OneDrive-Acme/herdr-mac", build: 5)
    _ = try folder(cloud, "OneDrive-Acme/Shared with me/herdr-mac", build: 7)
    _ = try folder(cloud, "OneDrive-Other/herdr-mac", build: 9, zip: false) // no zip yet: still syncing
    _ = try folder(cloud, "Dropbox/herdr-mac", build: 99)                    // not a OneDrive
    let folders = UpdateFeed.folders(cloudStorage: cloud, override: nil)
    #expect(folders.count == 3)
    #expect(UpdateFeed.newest(in: folders, newerThan: 4)?.build == 7)
    #expect(UpdateFeed.newest(in: folders, newerThan: 7) == nil)
    #expect(UpdateFeed.newest(in: folders, newerThan: 4)?.notes == "n7")
}

@Test func anOverrideFolderIsTheOnlyPlaceLooked() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("rel-\(UUID().uuidString)")
    let dir = try folder(base, "mine", build: 3)
    #expect(UpdateFeed.folders(cloudStorage: base, override: dir.path).map(\.path) == [dir.path])
    #expect(UpdateFeed.read(folder: base.appendingPathComponent("missing")) == nil)
}

@Test func aZipStillSyncingIsNotOfferedYet() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("sync-\(UUID().uuidString)")
    let dir = try folder(base, "herdr-mac", build: nil)
    try #"{"version": "0.3", "build": 3, "size": 5}"#.write(to: dir.appendingPathComponent("version.json"), atomically: true, encoding: .utf8)
    #expect(UpdateFeed.read(folder: dir) == nil, "1 byte of 5")
    try Data([1, 2, 3, 4, 5]).write(to: dir.appendingPathComponent("HerdrMac.zip"))
    #expect(UpdateFeed.read(folder: dir)?.build == 3)
}

@Test func checkForUpdatesExplainsEachPlace() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("why-\(UUID().uuidString)")
    let cloud = base.appendingPathComponent("CloudStorage")
    try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
    #expect(UpdateFeed.explain(folders: [], cloudStorage: cloud, current: 1)[0].contains("No OneDrive"))
    try FileManager.default.createDirectory(at: cloud.appendingPathComponent("OneDrive-Acme"), withIntermediateDirectories: true)
    #expect(UpdateFeed.explain(folders: [], cloudStorage: cloud, current: 1)[0].contains("Add the shared herdr-mac folder"))

    let empty = try folder(base, "empty/herdr-mac", build: nil, zip: false)
    let older = try folder(base, "older/herdr-mac", build: 3)
    let newer = try folder(base, "newer/herdr-mac", build: 9)
    let syncing = try folder(base, "syncing/herdr-mac", build: nil)
    try #"{"version": "0.9", "build": 9, "size": 5}"#.write(to: syncing.appendingPathComponent("version.json"), atomically: true, encoding: .utf8)
    let why = UpdateFeed.explain(folders: [empty, older, newer, syncing], cloudStorage: cloud, current: 5)
    #expect(why[0].hasSuffix("no version.json yet."))
    #expect(why[1].contains("not newer"))
    #expect(why[2].contains("is newer"))
    #expect(why[3].contains("still syncing (1 of 5 bytes)"))
}

@Test func aFolderSharedBySomeoneElseIsFound() throws {
    // How OneDrive syncs a folder someone shared with you.
    let cloud = FileManager.default.temporaryDirectory.appendingPathComponent("shared-\(UUID().uuidString)")
    _ = try folder(cloud, "OneDrive-SharedLibraries-Acme/Jane Doe - herdr-mac", build: 7)
    _ = try folder(cloud, "OneDrive-Acme/Documents/herdr-mac-notes", build: 99) // not ours: another name
    let folders = UpdateFeed.folders(cloudStorage: cloud, override: nil)
    #expect(folders.map(\.lastPathComponent) == ["Jane Doe - herdr-mac"])
    #expect(UpdateFeed.newest(in: folders, newerThan: 1)?.build == 7)
}
