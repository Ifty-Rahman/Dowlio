@testable import DowlioEngine
import Foundation
import Testing

struct TransportStreamTimelineTests {
    private static let second: Int64 = 90_000

    private func packet(pid: Int, pts: Int64?, dts: Int64? = nil, pcr: Int64? = nil, counter: Int = 0) -> Data {
        var bytes = [UInt8](repeating: 0xFF, count: 188)
        bytes[0] = 0x47
        bytes[1] = UInt8((pts != nil ? 0x40 : 0) | ((pid >> 8) & 0x1F))
        bytes[2] = UInt8(pid & 0xFF)
        var offset = 4
        if let pcr {
            bytes[3] = 0x30 | UInt8(counter & 0xF)
            bytes[4] = 7
            bytes[5] = 0x10
            let base = UInt64(pcr)
            bytes[6] = UInt8((base >> 25) & 0xFF)
            bytes[7] = UInt8((base >> 17) & 0xFF)
            bytes[8] = UInt8((base >> 9) & 0xFF)
            bytes[9] = UInt8((base >> 1) & 0xFF)
            bytes[10] = UInt8(((base & 1) << 7) | 0x7E)
            bytes[11] = 0
            offset = 12
        } else {
            bytes[3] = 0x10 | UInt8(counter & 0xF)
        }
        if let pts {
            bytes[offset...offset + 5] = [0, 0, 1, 0xE0, 0, 0]
            bytes[offset + 6] = 0x80
            bytes[offset + 7] = dts == nil ? 0x80 : 0xC0
            bytes[offset + 8] = dts == nil ? 5 : 10
            Self.write(pts, prefix: dts == nil ? 0x2 : 0x3, into: &bytes, at: offset + 9)
            if let dts { Self.write(dts, prefix: 0x1, into: &bytes, at: offset + 14) }
        }
        return Data(bytes)
    }

    private static func write(_ value: Int64, prefix: UInt8, into bytes: inout [UInt8], at index: Int) {
        let v = UInt64(value)
        bytes[index] = (prefix << 4) | UInt8(((v >> 30) & 0x7) << 1) | 1
        bytes[index + 1] = UInt8((v >> 22) & 0xFF)
        bytes[index + 2] = UInt8((((v >> 15) & 0x7F) << 1) | 1)
        bytes[index + 3] = UInt8((v >> 7) & 0xFF)
        bytes[index + 4] = UInt8(((v & 0x7F) << 1) | 1)
    }

    private func timestamps(of data: Data) -> (pts: [Int64], dts: [Int64], pcr: [Int64]) {
        var found: (pts: [Int64], dts: [Int64], pcr: [Int64]) = ([], [], [])
        let bytes = [UInt8](data)
        for start in stride(from: 0, to: bytes.count, by: 188) {
            let p = Array(bytes[start..<start + 188])
            var offset = 4
            if p[3] & 0x20 != 0 {
                if p[4] > 0, p[5] & 0x10 != 0 {
                    let base = (Int64(p[6]) << 25) | (Int64(p[7]) << 17) | (Int64(p[8]) << 9) | (Int64(p[9]) << 1) | Int64(p[10] >> 7)
                    found.pcr.append(base)
                }
                offset = 5 + Int(p[4])
            }
            guard p[1] & 0x40 != 0, p[offset] == 0, p[offset + 1] == 0, p[offset + 2] == 1 else { continue }
            func read(_ i: Int) -> Int64 {
                (Int64((p[i] >> 1) & 0x7) << 30) | (Int64(p[i + 1]) << 22) | (Int64(p[i + 2] >> 1) << 15) | (Int64(p[i + 3]) << 7) | Int64(p[i + 4] >> 1)
            }
            found.pts.append(read(offset + 9))
            if p[offset + 7] & 0x40 != 0 { found.dts.append(read(offset + 14)) }
        }
        return found
    }

    private func part(from start: Int64, frames: Int = 5) -> Data {
        var data = Data()
        for index in 0..<frames {
            let time = start + Int64(index) * 3000
            data += packet(pid: 0x101, pts: time + 6000, dts: time, pcr: index == 0 ? time - 9000 : nil, counter: index)
            data += packet(pid: 0x100, pts: time + 500, counter: index)
        }
        return data
    }

    @Test func continuousSegmentsComeOutUntouched() {
        var timeline = TransportStreamTimeline()
        let first = part(from: 600 * Self.second)
        let second = part(from: 600 * Self.second + 15_000)

        #expect(timeline.continued(first) == first)
        #expect(timeline.continued(second) == second)
    }

    @Test func aSegmentThatJumpsAheadIsMovedBackToFollowThePreviousOne() {
        var timeline = TransportStreamTimeline()
        let first = part(from: 600 * Self.second)
        let jumped = part(from: 660 * Self.second + 15_000)

        _ = timeline.continued(first)
        let repaired = timeline.continued(jumped)

        let before = timestamps(of: first)
        let after = timestamps(of: repaired)
        let gap = after.dts[0] - before.dts.last!
        #expect(abs(gap) <= Self.second)
        #expect(after.dts.count == jumped.count / 188 / 2)
        #expect(after.pts.map { $0 - after.dts[0] }.prefix(2) == timestamps(of: jumped).pts.map { $0 - timestamps(of: jumped).dts[0] }.prefix(2))
        #expect(after.pcr[0] - after.dts[0] == timestamps(of: jumped).pcr[0] - timestamps(of: jumped).dts[0])
    }

    @Test func aSegmentThatRestartsAtZeroFollowsThePreviousOneToo() {
        var timeline = TransportStreamTimeline()
        _ = timeline.continued(part(from: 600 * Self.second))

        let repaired = timeline.continued(part(from: 10_000))

        #expect(timestamps(of: repaired).dts[0] > 600 * Self.second)
    }

    @Test func eachLaterSegmentKeepsFollowingAfterARepair() {
        var timeline = TransportStreamTimeline()
        _ = timeline.continued(part(from: 600 * Self.second))
        _ = timeline.continued(part(from: 900 * Self.second))

        let third = timeline.continued(part(from: 900 * Self.second + 15_000))

        let start = timestamps(of: third).dts[0]
        #expect(start > 600 * Self.second && start < 610 * Self.second)
    }

    @Test func dataThatIsNotATransportStreamPassesThrough() {
        var timeline = TransportStreamTimeline()
        let bytes = Data("ID3 not a transport stream".utf8)

        #expect(timeline.continued(bytes) == bytes)
    }

    @Test func aPartThatIsNotWholePacketsPassesThroughItsTrailingBytes() {
        var timeline = TransportStreamTimeline()
        let data = part(from: 600 * Self.second) + Data([1, 2, 3])

        #expect(timeline.continued(data).suffix(3) == Data([1, 2, 3]))
        #expect(timeline.continued(data).count == data.count)
    }
}
