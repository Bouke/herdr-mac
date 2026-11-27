import Foundation

/// herdr-core's framed mode (after `hello {framed: true}`):
/// `u32 channel LE | u8 kind | u32 length LE | payload`. Channel 0 carries JSON-RPC.
public enum FrameKind: UInt8, Sendable {
    case data = 0, credit = 1, close = 2, resize = 3, focus = 4, facts = 5, automaticInput = 6
}

public struct Frame: Sendable, Equatable {
    public var channel: UInt32
    public var kind: UInt8
    public var payload: Data

    public init(channel: UInt32, kind: FrameKind, payload: Data) {
        self.init(channel: channel, rawKind: kind.rawValue, payload: payload)
    }

    public init(channel: UInt32, rawKind: UInt8, payload: Data) {
        self.channel = channel
        self.kind = rawKind
        self.payload = payload
    }

    public static let headerSize = 9

    public func encoded() -> Data {
        var out = Data(capacity: Self.headerSize + payload.count)
        withUnsafeBytes(of: channel.littleEndian) { out.append(contentsOf: $0) }
        out.append(kind)
        withUnsafeBytes(of: UInt32(payload.count).littleEndian) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }
}

/// Splits a byte stream into frames, however the bytes arrive.
public struct FrameDecoder {
    private var buffer = Data()

    public init() {}

    public mutating func push(_ bytes: Data) -> [Frame] {
        buffer.append(bytes)
        var frames: [Frame] = []
        while buffer.count >= Frame.headerSize {
            let start = buffer.startIndex
            let channel = buffer.le32(at: start)
            let kind = buffer[start + 4]
            let length = Int(buffer.le32(at: start + 5))
            guard buffer.count >= Frame.headerSize + length else { break }
            let body = buffer.subdata(in: (start + Frame.headerSize)..<(start + Frame.headerSize + length))
            frames.append(Frame(channel: channel, rawKind: kind, payload: body))
            buffer.removeSubrange(start..<(start + Frame.headerSize + length))
        }
        return frames
    }
}

/// Splits newline-delimited JSON (event channels), however the bytes arrive.
public struct LineDecoder {
    private var buffer = Data()

    public init() {}

    public mutating func push(_ bytes: Data) -> [JSON] {
        buffer.append(bytes)
        var lines: [JSON] = []
        while let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            if let value = try? JSON.parse(line) { lines.append(value) }
        }
        return lines
    }
}

extension Data {
    func le32(at i: Index) -> UInt32 {
        UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }
}
