/// Apogee Ensemble (2007, FireWire) control protocol.
///
/// Every command is an AV/C VENDOR-DEPENDENT frame with Apogee's OUI, written
/// to the unit's FCP command register. Reads use ctype CONTROL too. Layouts are
/// from Apogee's 2014 `ensembleDaemon` (symbols intact) and were checked on a
/// real unit; see `legacy/ENSEMBLE_PROTOCOL.md` in the maintainer's checkout.
///
/// Only commands confirmed on hardware, or with a layout read straight from the
/// daemon's setter, are exposed. Firmware/flash opcodes (AA, AC, AF, E0, E1,
/// E3, B4, B8, B9, EB F3, reset) are deliberately absent.

import Foundation

public enum EnsembleProtocol {

    /// Apogee Electronics IEEE OUI, carried in every vendor-dependent frame.
    public static let apogeeOUI: [UInt8] = [0x00, 0x03, 0xDB]
    /// Apogee's daemon always sent 152-byte frames; the unit accepts them.
    public static let frameLength = 152
    /// AV/C response code ACCEPTED.
    public static let accepted: UInt8 = 0x09
    /// Mic preamp inputs (1-4).
    public static let micChannels = 4
    /// `setMicGain` rejects anything outside this range (dB).
    public static let micGainRange: ClosedRange<Int> = 10...75

    // MARK: Frames

    /// `00 FF 00 | 00 03 DB | opcode args…`, zero-padded to 152 bytes.
    public static func frame(_ opcode: UInt8, _ args: [UInt8] = []) -> [UInt8] {
        var bytes: [UInt8] = [0x00, 0xFF, 0x00] + apogeeOUI + [opcode] + args
        bytes += [UInt8](repeating: 0, count: max(0, frameLength - bytes.count))
        return bytes
    }

    /// Validates a reply and returns the bytes after the echoed opcode ("R").
    public static func payload(of reply: [UInt8], opcode: UInt8) throws -> ArraySlice<UInt8> {
        guard reply.count >= 7 else { throw EnsembleError.shortReply(reply.count) }
        guard reply[0] == accepted else { throw EnsembleError.rejected(ctype: reply[0]) }
        guard Array(reply[3..<6]) == apogeeOUI, reply[6] == opcode else { throw EnsembleError.unexpectedReply }
        return reply[7...]
    }

    // MARK: Reads

    public static let readVersions = frame(0xED)
    public static let readSettings = frame(0xEA)
    public static let readFrontPanel = frame(0xFC)
    /// Mixer A meter poll, as Maestro 2 sent it.
    public static let readMeters = frame(0xFF, [0x01, 0x00, 0x00, 0x08])
    public static let readRouting = frame(0xB5)
    public static let readMixers = frame(0xB7, [0x00])

    // MARK: Writes

    public static func setPhantom(input: Int, on: Bool) throws -> [UInt8] {
        try frame(0xE5, [micChannel(input), on ? 1 : 0])
    }

    public static func setMicGain(input: Int, dB: Int) throws -> [UInt8] {
        guard micGainRange.contains(dB) else { throw EnsembleError.outOfRange("mic gain \(dB) dB") }
        return try frame(0xE6, [micChannel(input), UInt8(dB)])
    }

    public static func setPolarity(input: Int, inverted: Bool) throws -> [UInt8] {
        try frame(0xF5, [micChannel(input), inverted ? 1 : 0])
    }

    public static func setSoftLimit(input: Int, on: Bool) throws -> [UInt8] {
        guard (0..<8).contains(input) else { throw EnsembleError.outOfRange("input \(input + 1)") }
        return frame(0xE4, [UInt8(input), on ? 1 : 0])
    }

    /// Output levels are dB of attenuation, 0...127 (the daemon clamps the same way).
    public static func setOutputLevel(_ output: EnsembleOutput, attenuationDB: Int) -> [UInt8] {
        frame(0xF6, [output.rawValue, UInt8(min(max(attenuationDB, 0), 127))])
    }

    public static func setIdentify(_ on: Bool) -> [UInt8] { frame(0xEB, [0x08, on ? 1 : 0]) }

    private static func micChannel(_ input: Int) throws -> UInt8 {
        guard (0..<micChannels).contains(input) else { throw EnsembleError.outOfRange("mic input \(input + 1)") }
        return UInt8(input)
    }
}

/// `F6` output index. HP1/HP2 come from `setOutLevel(bool, bool, int)`.
public enum EnsembleOutput: UInt8, Sendable, CaseIterable {
    case main = 0, headphone1 = 1, headphone2 = 2
}

public enum EnsembleError: Error, Sendable, Equatable {
    case shortReply(Int)
    case rejected(ctype: UInt8)
    case unexpectedReply
    case outOfRange(String)
}

// MARK: - Parsed replies

/// `ED` reply: three version triplets.
public struct EnsembleVersions: Sendable, Equatable {
    public var bcd: [Int], cpld: [Int], fpga: [Int]

    public init(reply: [UInt8]) throws {
        let r = Array(try EnsembleProtocol.payload(of: reply, opcode: 0xED))
        guard r.count >= 10 else { throw EnsembleError.shortReply(reply.count) }
        bcd = r[1...3].map(Int.init); cpld = r[4...6].map(Int.init); fpga = r[7...9].map(Int.init)
    }
}

/// `EA` reply (71 bytes): the unit's full control state.
public struct EnsembleSettings: Sendable, Equatable {
    public var softLimit: [Bool]          // inputs 1-8
    public var inputRefLevel: [Int]       // 0/1 line levels, 2 = mic (inputs 1-4)
    public var outputRefLevel: [Int]      // outputs 1-8
    public var mainAttenuation: Int       // dB below full scale
    public var headphone1Attenuation: Int
    public var headphone2Attenuation: Int
    public var phantom: [Bool]            // inputs 1-4
    public var micGain: [Int]             // dB, inputs 1-4
    public var mainOutputMode: Int        // channels the main volume drives: 0, 2, 6, 8
    public var identify: Bool
    public var wordClockDivide: Bool
    public var headphone1Source: Int      // odd assign codes: 1 = outputs 1-2, 3 = 3-4 …
    public var headphone2Source: Int

    public init(reply: [UInt8]) throws {
        let r = Array(try EnsembleProtocol.payload(of: reply, opcode: 0xEA))
        guard r.count >= 0x40 else { throw EnsembleError.shortReply(reply.count) }
        softLimit = r[0x02..<0x0A].map { $0 != 0 }
        inputRefLevel = r[0x0A..<0x12].map(Int.init)
        outputRefLevel = r[0x12..<0x1A].map(Int.init)
        mainAttenuation = Int(r[0x1A]); headphone1Attenuation = Int(r[0x1B]); headphone2Attenuation = Int(r[0x1C])
        phantom = r[0x1D..<0x21].map { $0 != 0 }
        micGain = r[0x23..<0x27].map(Int.init)
        mainOutputMode = Int(r[0x37])
        identify = r[0x39] & 0x40 != 0
        wordClockDivide = r[0x39] & 0x20 != 0
        headphone1Source = Int(r[0x3A]); headphone2Source = Int(r[0x3B])
    }
}

/// `FC` (and the head of `FF 0x`) reply: what the front-panel knobs are doing.
public struct EnsembleFrontPanel: Sendable, Equatable {
    public var micGain: [Int]
    /// Encoder the panel is driving (1 main, 2 HP1, 4 HP2).
    public var activeKnob: Int
    public var mainAttenuation: Int, headphone1Attenuation: Int, headphone2Attenuation: Int

    public init(reply: [UInt8], opcode: UInt8 = 0xFC) throws {
        let r = Array(try EnsembleProtocol.payload(of: reply, opcode: opcode))
        guard r.count >= 9 else { throw EnsembleError.shortReply(reply.count) }
        micGain = r[1...4].map(Int.init)
        activeKnob = Int(r[5] & 7)
        headphone2Attenuation = Int(r[6]); headphone1Attenuation = Int(r[7]); mainAttenuation = Int(r[8])
    }
}

/// `FF 01 00 00 08` reply. Layout holds while the I/O allocation is 8 channels
/// (`numChannels` = 8, the test unit's state); other allocations shift it.
public struct EnsembleMeters: Sendable, Equatable {
    public var front: EnsembleFrontPanel
    /// Analog inputs 1-8 (not yet confirmed with an input signal).
    public var inputs: [UInt8]
    /// Main L/R (tracked outputs 1-2 in testing).
    public var main: [UInt8]
    /// Analog outputs 1-8 (confirmed).
    public var outputs: [UInt8]

    public init(reply: [UInt8]) throws {
        front = try EnsembleFrontPanel(reply: reply, opcode: 0xFF)
        guard reply.count >= 0x33 else { throw EnsembleError.shortReply(reply.count) }
        inputs = Array(reply[0x14..<0x1C]); main = Array(reply[0x26..<0x28]); outputs = Array(reply[0x2B..<0x33])
    }

    /// Meter byte → dBFS, as the daemon computed it (20·log10(v/256), floor -48).
    public static func dBFS(_ value: UInt8) -> Double {
        guard value > 0 else { return -.infinity }
        return max(20 * log10(Double(value) / 256), -48)
    }
}
