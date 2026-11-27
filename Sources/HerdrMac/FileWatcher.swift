import Foundation

/// Calls `onChange` on the main queue when a file changes: in place (an editor), or replaced
/// by an atomic save (a rename in its folder, as herdr-app writes it). Kernel events, so it
/// works while the app is in the background, where App Nap would hold back a polling timer.
///
/// The folder also sees every other file's saves (herdr-app writes view.json and friends
/// often), so events are debounced and `onChange` runs only when this file's identity,
/// size or modification time actually changed.
final class FileWatcher {
    private let url: URL
    private let onChange: () -> Void
    private var folder: DispatchSourceFileSystemObject?
    private var file: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var last: Stamp?

    private struct Stamp: Equatable { var inode: UInt64, size: Int64, mtime: timespec
        static func == (a: Stamp, b: Stamp) -> Bool {
            a.inode == b.inode && a.size == b.size && a.mtime.tv_sec == b.mtime.tv_sec && a.mtime.tv_nsec == b.mtime.tv_nsec
        }
    }

    init(_ url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        last = stamp()
        folder = source(url.deletingLastPathComponent().path, [.write, .rename, .delete]) { [weak self] in self?.event() }
        file = source(url.path, [.write, .extend, .delete, .rename, .attrib]) { [weak self] in self?.event() }
    }

    deinit { pending?.cancel(); folder?.cancel(); file?.cancel() }

    private func event() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.settle() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func settle() {
        let now = stamp()
        guard now != last else { return }
        if now?.inode != last?.inode {
            // Replaced (atomic save) or created: watch the new file.
            file?.cancel()
            file = source(url.path, [.write, .extend, .delete, .rename, .attrib]) { [weak self] in self?.event() }
        }
        last = now
        onChange()
    }

    private func stamp() -> Stamp? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        return Stamp(inode: st.st_ino, size: st.st_size, mtime: st.st_mtimespec)
    }

    private func source(_ path: String, _ mask: DispatchSource.FileSystemEvent, _ handler: @escaping () -> Void) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: .main)
        s.setEventHandler(handler: handler)
        s.setCancelHandler { close(fd) }
        s.resume()
        return s
    }
}
