import Foundation

package struct TransportStreamTimeline {
    private static let packetSize = 188
    private static let wrap: Int64 = 1 << 33
    private static let tolerance: Int64 = 2 * 90_000
    private static let frame: Int64 = 3600

    private var previousEnd: Int64?
    private var shiftedEnd: Int64 = 0
    private var offset: Int64 = 0

    package init() {}

    package mutating func continued(_ part: Data) -> Data {
        let bytes = [UInt8](part)
        let packets = bytes.count / Self.packetSize
        guard packets > 0, bytes[0] == 0x47 else { return part }
        var times: [Int64] = []
        for packet in 0..<packets {
            let base = packet * Self.packetSize
            guard bytes[base] == 0x47 else { return part }
            guard let header = Self.headerOffset(in: bytes, at: base) else { continue }
            let hasDTS = bytes[header + 7] & 0x40 != 0
            times.append(Self.timestamp(in: bytes, at: header + (hasDTS ? 14 : 9)))
        }
        guard let start = times.min(), let end = times.max() else { return part }
        if let previousEnd, abs(start - previousEnd) > Self.tolerance { offset = shiftedEnd + Self.frame - start }
        previousEnd = end
        shiftedEnd = end + offset
        let delta = offset
        guard delta != 0 else { return part }
        var shifted = bytes
        for packet in 0..<packets {
            let base = packet * Self.packetSize
            if let pcr = Self.pcrOffset(in: shifted, at: base) { Self.shiftPCR(&shifted, at: pcr, by: delta) }
            guard let header = Self.headerOffset(in: shifted, at: base) else { continue }
            Self.shiftTimestamp(&shifted, at: header + 9, by: delta)
            if shifted[header + 7] & 0x40 != 0 { Self.shiftTimestamp(&shifted, at: header + 14, by: delta) }
        }
        return Data(shifted)
    }

    private static func payloadOffset(in bytes: [UInt8], at base: Int) -> Int? {
        let control = bytes[base + 3]
        guard control & 0x10 != 0 else { return nil }
        guard control & 0x20 != 0 else { return base + 4 }
        let length = Int(bytes[base + 4])
        return base + 5 + length < base + packetSize ? base + 5 + length : nil
    }

    private static func headerOffset(in bytes: [UInt8], at base: Int) -> Int? {
        guard bytes[base + 1] & 0x40 != 0, let payload = payloadOffset(in: bytes, at: base), payload + 14 <= base + packetSize,
              bytes[payload] == 0, bytes[payload + 1] == 0, bytes[payload + 2] == 1,
              bytes[payload + 6] & 0xC0 == 0x80, bytes[payload + 7] & 0x80 != 0, bytes[payload + 8] >= 5
        else { return nil }
        if bytes[payload + 7] & 0x40 != 0 && (bytes[payload + 8] < 10 || payload + 19 > base + packetSize) { return nil }
        return payload
    }

    private static func pcrOffset(in bytes: [UInt8], at base: Int) -> Int? {
        guard bytes[base + 3] & 0x20 != 0, bytes[base + 4] >= 7, bytes[base + 5] & 0x10 != 0 else { return nil }
        return base + 6
    }

    private static func timestamp(in bytes: [UInt8], at index: Int) -> Int64 {
        var value = Int64((bytes[index] >> 1) & 0x7) << 30
        value |= Int64(bytes[index + 1]) << 22
        value |= Int64(bytes[index + 2] >> 1) << 15
        value |= Int64(bytes[index + 3]) << 7
        value |= Int64(bytes[index + 4] >> 1)
        return value
    }

    private static func shiftTimestamp(_ bytes: inout [UInt8], at index: Int, by delta: Int64) {
        let value = ((timestamp(in: bytes, at: index) + delta) % wrap + wrap) % wrap
        bytes[index] = (bytes[index] & 0xF0) | UInt8(((value >> 30) & 0x7) << 1) | 1
        bytes[index + 1] = UInt8((value >> 22) & 0xFF)
        bytes[index + 2] = UInt8((((value >> 15) & 0x7F) << 1) | 1)
        bytes[index + 3] = UInt8((value >> 7) & 0xFF)
        bytes[index + 4] = UInt8(((value & 0x7F) << 1) | 1)
    }

    private static func shiftPCR(_ bytes: inout [UInt8], at index: Int, by delta: Int64) {
        var base = Int64(bytes[index]) << 25
        base |= Int64(bytes[index + 1]) << 17
        base |= Int64(bytes[index + 2]) << 9
        base |= Int64(bytes[index + 3]) << 1
        base |= Int64(bytes[index + 4] >> 7)
        let value = ((base + delta) % wrap + wrap) % wrap
        bytes[index] = UInt8((value >> 25) & 0xFF)
        bytes[index + 1] = UInt8((value >> 17) & 0xFF)
        bytes[index + 2] = UInt8((value >> 9) & 0xFF)
        bytes[index + 3] = UInt8((value >> 1) & 0xFF)
        let low = UInt8(value & 1) << 7
        bytes[index + 4] = low | (bytes[index + 4] & 0x7F)
    }
}
