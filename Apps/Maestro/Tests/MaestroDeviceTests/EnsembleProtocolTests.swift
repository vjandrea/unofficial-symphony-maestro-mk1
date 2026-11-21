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
        #expect(m.main == [0xF8, 0xF7] && m.inputs.allSatisfy { $0 == 0 })
        #expect(abs(EnsembleMeters.dBFS(248) - -0.276) < 0.01)
        #expect(EnsembleMeters.dBFS(1) == -48)
    }
}
