import Foundation

/// Builds 12-byte RTP headers for Discord voice (payload type 120, Opus).
/// Maintains sequence number and timestamp state across packets.
struct RTPPacketBuilder {
    private static let payloadType: UInt8 = 0x78 // 120, Opus
    private static let versionFlags: UInt8 = 0x80 // RTP version 2, no padding/extension/CSRCs

    let ssrc: UInt32
    private(set) var sequence: UInt16 = 0
    private(set) var timestamp: UInt32

    init(ssrc: UInt32, initialTimestamp: UInt32 = .random(in: 0...UInt32.max)) {
        self.ssrc = ssrc
        self.timestamp = initialTimestamp
    }

    /// Build the 12-byte RTP header for the next outgoing packet and advance
    /// the sequence + timestamp counters. `samplesPerChannel` is the number
    /// of PCM samples per channel encoded in this packet (e.g. 960 for 20 ms
    /// at 48 kHz).
    mutating func nextHeader(samplesPerChannel: UInt32) -> Data {
        var header = Data(count: 12)
        header[0] = Self.versionFlags
        header[1] = Self.payloadType
        header[2] = UInt8((sequence >> 8) & 0xff)
        header[3] = UInt8(sequence & 0xff)
        header[4] = UInt8((timestamp >> 24) & 0xff)
        header[5] = UInt8((timestamp >> 16) & 0xff)
        header[6] = UInt8((timestamp >> 8) & 0xff)
        header[7] = UInt8(timestamp & 0xff)
        header[8] = UInt8((ssrc >> 24) & 0xff)
        header[9] = UInt8((ssrc >> 16) & 0xff)
        header[10] = UInt8((ssrc >> 8) & 0xff)
        header[11] = UInt8(ssrc & 0xff)

        sequence &+= 1
        timestamp &+= samplesPerChannel
        return header
    }

    /// 20 ms of silence as a single Opus frame, useful as a keepalive between
    /// announcements so the Discord client renders the speaker as still
    /// connected.
    static var opusSilenceFrame: Data {
        Data([0xF8, 0xFF, 0xFE])
    }
}
