/// EnsembleControl: development test app for the Apogee Ensemble (FireWire).
///
/// Talks to the unit through ASFireWire's loopback MCP control plane, so it only
/// works with a self-built ASFW (control plane on, developer writes allowed).
///
///   swift run --package-path Apps/Maestro EnsembleControl          # window
///   swift run --package-path Apps/Maestro EnsembleControl --probe  # read-only check
///   ASFW_MCP_ENDPOINT=http://127.0.0.1:8765/mcp to override the endpoint.

import AppKit
import Foundation
import MaestroDevice
import SwiftUI

let endpoint = URL(string: ProcessInfo.processInfo.environment["ASFW_MCP_ENDPOINT"] ?? "http://127.0.0.1:8765/mcp")!

if CommandLine.arguments.contains("--probe") {
    let plane = ASFWControlPlane(endpoint: endpoint)
    do {
        let unit = try await plane.findUnit()
        print(String(format: "Ensemble GUID 0x%016llX, node %d", unit.guid, unit.nodeId))
        let v = try EnsembleVersions(reply: try await plane.send(EnsembleProtocol.readVersions, to: unit))
        print("BCD \(v.bcd)  CPLD \(v.cpld)  FPGA \(v.fpga)")
        let s = try EnsembleSettings(reply: try await plane.send(EnsembleProtocol.readSettings, to: unit))
        print("mic gain \(s.micGain) dB, phantom \(s.phantom), main -\(s.mainAttenuation) dB, HP -\(s.headphone1Attenuation)/-\(s.headphone2Attenuation) dB")
        let m = try EnsembleMeters(reply: try await plane.send(EnsembleProtocol.readMeters, to: unit))
        print("meters in \(m.inputs) main \(m.main) out \(m.outputs)")
        exit(0)
    } catch {
        print("probe failed: \(error)")
        exit(1)
    }
}

// MARK: - Model

@MainActor @Observable
final class EnsembleModel {
    var status = "Connecting…"
    var versions: EnsembleVersions?
    var settings: EnsembleSettings?
    var meters: EnsembleMeters?

    private let plane = ASFWControlPlane(endpoint: endpoint)
    private var unit: ASFWControlPlane.Unit?
    private var pending: [[UInt8]] = []

    /// Queue a write; the loop sends it right away, then re-reads settings.
    /// `apply` updates the UI immediately; the re-read corrects it if the unit disagrees.
    func send(_ frame: [UInt8], apply: (inout EnsembleSettings) -> Void = { _ in }) {
        pending.append(frame)
        if var s = settings { apply(&s); settings = s }
    }
    func send(_ make: () throws -> [UInt8], apply: (inout EnsembleSettings) -> Void = { _ in }) {
        do { send(try make(), apply: apply) } catch { status = "Not sent: \(error)" }
    }

    /// One loop owns the bus: writes first, then a meter poll every ~120 ms.
    func run() async {
        while !Task.isCancelled {
            do {
                if unit == nil {
                    unit = try await plane.findUnit()
                    versions = try EnsembleVersions(reply: try await plane.send(EnsembleProtocol.readVersions, to: unit!))
                    settings = try EnsembleSettings(reply: try await plane.send(EnsembleProtocol.readSettings, to: unit!))
                    status = "Connected"
                }
                guard let unit else { continue }
                if !pending.isEmpty {
                    // Drop a write only once the unit has accepted it, so a transport hiccup retries it.
                    while let frame = pending.first {
                        let reply = try await plane.send(frame, to: unit)
                        pending.removeFirst()
                        do { _ = try EnsembleProtocol.payload(of: reply, opcode: frame[6]) }
                        catch { status = String(format: "Unit rejected opcode %02X: \(error)", frame[6]) }
                    }
                    settings = try EnsembleSettings(reply: try await plane.send(EnsembleProtocol.readSettings, to: unit))
                }
                let m = try EnsembleMeters(reply: try await plane.send(EnsembleProtocol.readMeters, to: unit))
                meters = m
                // Front-panel knobs move gain/levels on their own; mirror them.
                if var s = settings {
                    s.micGain = m.front.micGain
                    s.mainAttenuation = m.front.mainAttenuation
                    s.headphone1Attenuation = m.front.headphone1Attenuation
                    s.headphone2Attenuation = m.front.headphone2Attenuation
                    settings = s
                }
                // Meter interval, cut short as soon as a write is queued.
                for _ in 0..<12 where pending.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
            } catch {
                status = "\(error)"
                unit = nil
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

// MARK: - Views

struct MeterBar: View {
    let value: UInt8
    var body: some View {
        let dB = EnsembleMeters.dBFS(value)
        let fill = dB.isFinite ? (dB + 48) / 48 : 0
        GeometryReader { g in
            ZStack(alignment: .bottom) {
                Rectangle().fill(.quaternary)
                Rectangle().fill(dB > -3 ? Color.red : dB > -12 ? .yellow : .green)
                    .frame(height: g.size.height * fill)
            }
        }
        .frame(width: 10, height: 90)
    }
}

struct MicStrip: View {
    let input: Int
    @Bindable var model: EnsembleModel
    @State private var gain: Double = 10
    @State private var editing = false

    var body: some View {
        let s = model.settings
        VStack(spacing: 8) {
            Text("In \(input + 1)").font(.headline)
            HStack(alignment: .bottom) {
                Slider(value: $gain, in: 10...75, step: 1) { editing = $0; if !$0 { commit() } }
                    .rotationEffect(.degrees(-90)).frame(width: 90, height: 90)
                MeterBar(value: model.meters?.inputs[input] ?? 0)
            }
            Text("\(Int(gain)) dB").monospacedDigit()
            Toggle("48V", isOn: Binding(
                get: { s?.phantom[input] ?? false },
                set: { on in model.send({ try EnsembleProtocol.setPhantom(input: input, on: on) }) { $0.phantom[input] = on } }))
            Toggle("Soft limit", isOn: Binding(
                get: { s?.softLimit[input] ?? false },
                set: { on in model.send({ try EnsembleProtocol.setSoftLimit(input: input, on: on) }) { $0.softLimit[input] = on } }))
            Text(s.map { $0.inputRefLevel[input] == 2 ? "Mic" : "Line \($0.inputRefLevel[input])" } ?? "–")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(width: 110)
        .onChange(of: s?.micGain[input]) { _, new in if !editing, let new { gain = Double(new) } }
        .onAppear { if let g = s?.micGain[input] { gain = Double(g) } }
    }

    private func commit() { model.send { try EnsembleProtocol.setMicGain(input: input, dB: Int(gain)) } }
}

struct LevelControl: View {
    let output: EnsembleOutput
    let label: String
    let attenuation: Int?
    @Bindable var model: EnsembleModel
    @State private var value: Double = 60
    @State private var editing = false

    var body: some View {
        HStack {
            Text(label).frame(width: 90, alignment: .leading)
            Slider(value: $value, in: 0...127, step: 1) { editing = $0; if !$0 { model.send(EnsembleProtocol.setOutputLevel(output, attenuationDB: Int(value))) } }
                .scaleEffect(x: -1)  // right = louder (less attenuation)
            Text("-\(Int(value)) dB").monospacedDigit().frame(width: 60, alignment: .trailing)
        }
        .onChange(of: attenuation) { _, new in if !editing, let new { value = Double(new) } }
        .onAppear { if let attenuation { value = Double(attenuation) } }
    }
}

struct ContentView: View {
    @State var model = EnsembleModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Apogee Ensemble").font(.title2.bold())
                if let v = model.versions {
                    Text("BCD \(v.bcd.map(String.init).joined(separator: ".")) · FPGA \(v.fpga.map(String.init).joined(separator: "."))")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Identify", isOn: Binding(
                    get: { model.settings?.identify ?? false },
                    set: { on in model.send(EnsembleProtocol.setIdentify(on)) { $0.identify = on } }))
            }
            Text(model.status).font(.caption).foregroundStyle(model.status == "Connected" ? Color.secondary : Color.red)

            GroupBox("Mic inputs") {
                HStack(alignment: .top, spacing: 12) { ForEach(0..<4, id: \.self) { MicStrip(input: $0, model: model) } }
            }
            GroupBox("Outputs") {
                VStack {
                    LevelControl(output: .main, label: "Main", attenuation: model.settings?.mainAttenuation, model: model)
                    LevelControl(output: .headphone1, label: "Headphone 1", attenuation: model.settings?.headphone1Attenuation, model: model)
                    LevelControl(output: .headphone2, label: "Headphone 2", attenuation: model.settings?.headphone2Attenuation, model: model)
                    HStack(alignment: .bottom, spacing: 6) {
                        ForEach(0..<2, id: \.self) { i in VStack { MeterBar(value: model.meters?.main[i] ?? 0); Text(i == 0 ? "M L" : "M R").font(.caption2) } }
                        Divider().frame(height: 90)
                        ForEach(0..<8, id: \.self) { i in VStack { MeterBar(value: model.meters?.outputs[i] ?? 0); Text("\(i + 1)").font(.caption2) } }
                    }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 560)
        .task { await model.run() }
    }
}

struct EnsembleControlApp: App {
    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()
    }
    var body: some Scene {
        WindowGroup("Ensemble Control") { ContentView() }.windowResizability(.contentSize)
    }
}

EnsembleControlApp.main()
