import Testing
@testable import MaestroDevice

/// Fixtures are real replies from an Ensemble (BCD 1.9.30, FPGA 1.34.4) captured 2026-11-21.
@Suite("Ensemble protocol")
struct EnsembleProtocolTests {
    static func hex(_ s: String) -> [UInt8] { s.split(separator: " ").map { UInt8($0, radix: 16)! } }

    static let ed = hex("09 FF 00 00 03 DB ED 06 01 09 1E 01 06 01 01 22 04 01")
    static let ea = hex("09 FF 00 00 03 DB EA 00 00 01 00 00 00 00 00 00 00 02 02 02 02 00 00 00 00 01 01 00 00 00 00 00 00 11 26 41 00 00 00 00 50 00 25 2E 2F 2E 01 02 04 08 01 00 02 00 00 00 00 04 00 00 00 00 02 08 1E 01 03 00 00 00 00")
    static let fc = hex("09 FF 00 00 03 DB FC 00 25 2E 2F 31 01 41 26 19")
    static let ff01 = hex("09 FF 00 00 03 DB FF 01 25 2E 2F 31 01 41 26 19 FE BF 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 F8 F7 00 00 00 F8 F7 F8 F7 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00")

    @Test func framesMatchWhatTheUnitAccepted() throws {
        #expect(EnsembleProtocol.readVersions.count == 152)
        #expect(Array(EnsembleProtocol.readVersions.prefix(7)) == [0x00, 0xFF, 0x00, 0x00, 0x03, 0xDB, 0xED])
        #expect(Array(try EnsembleProtocol.setPhantom(input: 0, on: true).prefix(9)) == Self.hex("00 FF 00 00 03 DB E5 00 01"))
        #expect(Array(try EnsembleProtocol.setMicGain(input: 0, dB: 39).prefix(9)) == Self.hex("00 FF 00 00 03 DB E6 00 27"))
        #expect(Array(EnsembleProtocol.setIdentify(true).prefix(9)) == Self.hex("00 FF 00 00 03 DB EB 08 01"))
        #expect(Array(EnsembleProtocol.setOutputLevel(.main, attenuationDB: 200).prefix(9)) == Self.hex("00 FF 00 00 03 DB F6 00 7F"))
        #expect(Array(EnsembleProtocol.setOutputLevel(.headphone1, attenuationDB: 100).prefix(9)) == Self.hex("00 FF 00 00 03 DB F6 01 40"))
    }

    @Test func referenceLevelAndMainModeFrames() throws {
        // `E8 04 00 01` set output 5 to code 1 on hardware (EA R+0x16: 0 -> 1).
        #expect(Array(try EnsembleProtocol.setReferenceLevel(output: 4, .minus10dBV).prefix(10)) == Self.hex("00 FF 00 00 03 DB E8 04 00 01"))
        #expect(Array(try EnsembleProtocol.setReferenceLevel(input: 0, .mic).prefix(10)) == Self.hex("00 FF 00 00 03 DB E8 00 01 02"))
        #expect(Array(EnsembleProtocol.setMainOutputMode(.surround51).prefix(8)) == Self.hex("00 FF 00 00 03 DB F4 06"))
        #expect(throws: EnsembleError.self) { try EnsembleProtocol.setReferenceLevel(output: 0, .mic) }
        #expect(throws: EnsembleError.self) { try EnsembleProtocol.setReferenceLevel(input: 4, .mic) }
    }

    static let b5 = hex("09 FF 00 00 03 DB B5 08 09 08 09 0C 0D 0E 0F 00 01 02 03 04 05 06 07 1A 1B 1C 1D 1E 1F 20 21 22 23 10 11 12 13 14 15 16 17 18 19 08 09 08 09")
    static let b7 = hex("09 FF 00 00 03 DB B7 7B 00 01 FF 00 9F 9F 9F 9F A0 A0 A0 A0 9F 9F 9F 9F 9F 9F 9F 9F 9F 9F 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 A0 A0 A0 A0 7B 00 01 FF 00 9F 9F 9F 9F A0 9F 9F 9F 9F 9F 9F 9F 9F 9F 9F 9F 9F 9F 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 A0 A0 A0 A0")

    @Test func parsesRouting() throws {
        let r = try EnsembleRouting(reply: Self.b5)
        #expect(r.sources.count == 40)
        #expect(Array(r.sources[0..<2]) == [EnsembleRouting.playback(0), EnsembleRouting.playback(1)])
        #expect(r.sources[Int(EnsembleRouting.headphone2)] == EnsembleRouting.playback(0))
        #expect(Array(try EnsembleProtocol.setRoute(destination: 6, source: 0x0F).prefix(9)) == Self.hex("00 FF 00 00 03 DB EF 06 0F"))
        #expect(throws: EnsembleError.self) { try EnsembleProtocol.setRoute(destination: 40, source: 0) }
    }

    @Test func mixerReadEditAndWordSwappedWrite() throws {
        let mixers = try EnsembleMixer.parse(reply: Self.b7)
        #expect(mixers.count == 2 && mixers[0].fader(0) == -97 && mixers[0].fader(4) == -96 && mixers[0].master == -96)
        // The unchanged write the unit accepted and read back identically (2026-11-21).
        let write = EnsembleProtocol.writeMixers(mixers[0], mixers[1])
        #expect(Array(write.prefix(16)) == Self.hex("00 FF 00 00 03 DB B7 01 FF 01 00 7B 9F 9F 9F 00"))
        #expect(write.count == 152)
        var a = mixers[0]
        a.setFader(0, dB: -20)
        #expect(a.fader(0) == -20)
        #expect(EnsembleProtocol.writeMixers(a, mixers[1])[8 + 6] == UInt8(bitPattern: -20))  // byte 5 lands at 6 after the swap
        a.setMaster(dB: 12)
        #expect(a.master == 0)  // capped
    }

    @Test func clockSourceFrames() {
        // Frames the unit answered on 2026-11-21 (firmware BCD 1.9.30).
        #expect(EnsembleClockSource.readFrame == Self.hex("01 FF 1A FF FF FE 60 05"))
        #expect(EnsembleClockSource.internal.setFrame == Self.hex("00 FF 1A 0F 60 05 60 05"))  // accepted (09)
        #expect(EnsembleClockSource.wordClock.setFrame == Self.hex("00 FF 1A 0F FF 86 60 05"))
        #expect(EnsembleClockSource(statusReply: Self.hex("0C FF 1A 10 60 05 60 05")) == .internal)
        #expect(EnsembleClockSource(statusReply: Self.hex("0C FF 1A 30 FF FE 60 07")) == nil)  // no connection
    }

    @Test func rejectsOutOfRangeArguments() {
        #expect(throws: EnsembleError.self) { try EnsembleProtocol.setMicGain(input: 0, dB: 76) }
        #expect(throws: EnsembleError.self) { try EnsembleProtocol.setMicGain(input: 0, dB: 9) }
        #expect(throws: EnsembleError.self) { try EnsembleProtocol.setPhantom(input: 4, on: true) }
    }

    @Test func rejectedAndForeignRepliesThrow() {
        var rejected = Self.ea; rejected[0] = 0x0A
        #expect(throws: EnsembleError.rejected(ctype: 0x0A)) { try EnsembleSettings(reply: rejected) }
        #expect(throws: EnsembleError.unexpectedReply) { try EnsembleSettings(reply: Self.fc) }
    }

    @Test func parsesVersions() throws {
        let v = try EnsembleVersions(reply: Self.ed)
        #expect(v.bcd == [1, 9, 30] && v.cpld == [1, 6, 1] && v.fpga == [1, 34, 4])
    }

    @Test func parsesSettings() throws {
        let s = try EnsembleSettings(reply: Self.ea)
        #expect(s.micGain == [37, 46, 47, 46])
        #expect(s.phantom == [false, false, false, false])
        #expect(s.inputRefLevel == [2, 2, 2, 2, 0, 0, 0, 0])
        #expect(s.mainAttenuation == 17 && s.headphone1Attenuation == 38 && s.headphone2Attenuation == 65)
        #expect(s.mainOutputMode == 2 && !s.identify && !s.wordClockDivide)
        #expect(s.headphone1Source == 1 && s.headphone2Source == 3)
    }

    @Test func parsesFrontPanelAndMeters() throws {
        let f = try EnsembleFrontPanel(reply: Self.fc)
        #expect(f.micGain == [37, 46, 47, 49] && f.activeKnob == 1)
        #expect(f.mainAttenuation == 25 && f.headphone1Attenuation == 38 && f.headphone2Attenuation == 65)
        let m = try EnsembleMeters(reply: Self.ff01)
        #expect(m.front == f)
        #expect(m.outputs == [0xF8, 0xF7, 0xF8, 0xF7, 0, 0, 0, 0])
        #expect(m.softwareReturn == [0xF8, 0xF7] && m.inputs.allSatisfy { $0 == 0 })
        #expect(abs(EnsembleMeters.dBFS(248) - -0.276) < 0.01)
        #expect(EnsembleMeters.dBFS(1) == -48)
    }

    @Test func coefficientsFromModel() throws {
        var bytes = [UInt8](repeating: 0, count: EnsembleMixer.length)
        bytes[0] = 0x7B; bytes[2] = 1                     // software return = playback 1/2
        for i in 5..<23 { bytes[i] = UInt8(bitPattern: -97) }  // inputs off
        bytes[5] = 0                                      // input 1 at 0 dB, centre
        bytes[6] = 0; bytes[29] = 64                      // input 2 at 0 dB, hard right
        bytes[23] = 0b0100                                // ...but input 2 muted
        bytes[46] = 0; bytes[47] = UInt8(bitPattern: -6)  // software return L 0 dB, R -6 dB
        bytes[48] = 0; bytes[49] = 0                      // output faders 0 dB
        let c = EnsembleCoefficients(model: EnsembleMixer(bytes: bytes))
        #expect(c.left[0] == 11585 && c.right[0] == 11585)      // -3 dB each side
        #expect(c.left[1] == 0 && c.right[1] == 0)
        #expect(c.left[8] == 0x4000 && c.right[9] == 8211)
        #expect(c.left[26] == 0 && c.right[35] == 0)

        bytes[24] = 0b10                                  // solo input 5: everything else drops
        bytes[9] = 0
        let solo = EnsembleCoefficients(model: EnsembleMixer(bytes: bytes))
        #expect(solo.left[4] == 11585 && solo.left[0] == 0 && solo.left[8] == 0)
    }

    @Test func coefficientBlocksRoundTrip() throws {
        var c = EnsembleCoefficients()
        c.left[9] = 0x4000; c.right[9] = 0x1234; c.right[35] = 0xFFFF
        let frames = c.writeFrames(mixer: 1)
        #expect(frames.map { $0[6] } == [0xB0, 0xB1, 0xB2, 0xB3] && frames.allSatisfy { $0[7] == 1 })
        #expect(Array(frames[1][8..<12]) == [0x00, 0x40, 0x34, 0x12])
        var back = EnsembleCoefficients()
        for (b, f) in frames.enumerated() {
            let reply = [EnsembleProtocol.accepted] + Array(f[1..<6]) + [0xB6] + Array(f[8..<44])
            try back.absorb(reply: reply, block: b)
        }
        #expect(back == c)
    }
}
