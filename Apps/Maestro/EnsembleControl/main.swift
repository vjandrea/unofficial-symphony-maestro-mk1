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
    var mixers: [EnsembleMixer]?
    var routing: EnsembleRouting?

    /// Edit one mixer locally and queue the write of both (the unit only takes both).
    func editMixer(_ index: Int, _ change: (inout EnsembleMixer) -> Void) {
        guard var m = mixers else { return }
        change(&m[index])
        mixers = m
        pending.append(EnsembleProtocol.writeMixers(m[0], m[1]))
    }

    /// Point an L/R destination pair at an L/R source pair.
    func route(destinationL: UInt8, sourceL: UInt8) {
        send({ try EnsembleProtocol.setRoute(destination: destinationL, source: sourceL) })
        send({ try EnsembleProtocol.setRoute(destination: destinationL + 1, source: sourceL + 1) })
        if var r = routing { r.sources[Int(destinationL)] = sourceL; r.sources[Int(destinationL) + 1] = sourceL + 1; routing = r }
    }

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

    private func readState(_ unit: ASFWControlPlane.Unit) async throws {
        settings = try EnsembleSettings(reply: try await plane.send(EnsembleProtocol.readSettings, to: unit))
        routing = try EnsembleRouting(reply: try await plane.send(EnsembleProtocol.readRouting, to: unit))
        mixers = try EnsembleMixer.parse(reply: try await plane.send(EnsembleProtocol.readMixers, to: unit))
    }

    /// One loop owns the bus: writes first, then a meter poll every ~120 ms.
    func run() async {
        while !Task.isCancelled {
            do {
                if unit == nil {
                    unit = try await plane.findUnit()
                    versions = try EnsembleVersions(reply: try await plane.send(EnsembleProtocol.readVersions, to: unit!))
                    try await readState(unit!)
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
                    if pending.isEmpty { try await readState(unit) }  // skip while more edits are queued (fader drags)
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

/// Vertical fader drawn by hand: a rotated `Slider` doesn't render on macOS.
/// Calls `onEditingChanged(false)` once when the drag ends.
struct VerticalFader: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var onEditingChanged: (Bool) -> Void = { _ in }
    @State private var dragging = false
    @State private var start: Double = 0

    var body: some View {
        GeometryReader { g in
            let h = g.size.height
            let frac = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            ZStack(alignment: .bottom) {
                Capsule().fill(.quaternary).frame(width: 6)
                Capsule().fill(Color.accentColor).frame(width: 6, height: h * frac)
                RoundedRectangle(cornerRadius: 3).fill(.white).frame(width: 24, height: 10)
                    .shadow(radius: 1).offset(y: 5 - h * frac)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    // Relative to where the cap was, so a click never jumps the level (Main at 0 dB is loud).
                    if !dragging { dragging = true; start = value; onEditingChanged(true) }
                    let delta = -drag.translation.height / h * (range.upperBound - range.lowerBound)
                    value = min(max((start + delta).rounded(), range.lowerBound), range.upperBound)
                }
                .onEnded { _ in dragging = false; onEditingChanged(false) })
        }
    }
}

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
                VerticalFader(value: $gain, range: 10...75) { editing = $0; if !$0 { commit() } }
                    .frame(width: 30, height: 90)
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
    /// Level in dB (0 at the top); the unit stores the attenuation, i.e. -level.
    @State private var level: Double = -60
    @State private var editing = false

    var body: some View {
        VStack(spacing: 4) {
            VerticalFader(value: $level, range: -127...0) { editing = $0
                if !$0 { model.send(EnsembleProtocol.setOutputLevel(output, attenuationDB: Int(-level))) }
            }
            .frame(width: 34, height: 140)
            Text("\(Int(level)) dB").font(.caption2).monospacedDigit()
            Text(label).font(.caption2).lineLimit(1).fixedSize()
        }
        .onChange(of: attenuation) { _, new in if !editing, let new { level = Double(-new) } }
        .onAppear { if let attenuation { level = Double(-attenuation) } }
    }
}

/// One analog output: meter plus its +4 dBu / -10 dBV switch.
struct OutputStrip: View {
    let output: Int
    @Bindable var model: EnsembleModel

    var body: some View {
        VStack(spacing: 4) {
            MeterBar(value: model.meters?.outputs[output] ?? 0)
            Text("\(output + 1)").font(.caption2)
            Picker("", selection: Binding(
                get: { model.settings.flatMap { EnsembleReferenceLevel(rawValue: UInt8($0.outputRefLevel[output])) } ?? .plus4dBu },
                set: { level in model.send({ try EnsembleProtocol.setReferenceLevel(output: output, level) }) { $0.outputRefLevel[output] = Int(level.rawValue) } })) {
                Text("+4").tag(EnsembleReferenceLevel.plus4dBu)
                Text("-10").tag(EnsembleReferenceLevel.minus10dBV)
            }
            .labelsHidden()
            .frame(width: 58)
        }
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

            TabView {
                ioPage.tabItem { Text("I/O") }
                MixerPage(model: model).tabItem { Text("Mixer") }
            }
        }
        .padding(20)
        .frame(minWidth: 560)
        .task { await model.run() }
    }

    private var ioPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Mic inputs") {
                HStack(alignment: .top, spacing: 12) { ForEach(0..<4, id: \.self) { MicStrip(input: $0, model: model) } }
            }
            GroupBox("Outputs") {
                VStack {
                    Picker("Main knob drives", selection: Binding(
                        get: { model.settings.flatMap { EnsembleMainOutputMode(rawValue: UInt8($0.mainOutputMode)) } ?? .stereo },
                        set: { mode in model.send(EnsembleProtocol.setMainOutputMode(mode)) { $0.mainOutputMode = Int(mode.rawValue) } })) {
                        ForEach(EnsembleMainOutputMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    HStack(alignment: .bottom, spacing: 6) {
                        LevelControl(output: .main, label: "Main", attenuation: model.settings?.mainAttenuation, model: model)
                        ForEach(0..<2, id: \.self) { i in VStack { MeterBar(value: model.meters?.main[i] ?? 0); Text(i == 0 ? "M L" : "M R").font(.caption2) } }
                        LevelControl(output: .headphone1, label: "HP 1", attenuation: model.settings?.headphone1Attenuation, model: model)
                        LevelControl(output: .headphone2, label: "HP 2", attenuation: model.settings?.headphone2Attenuation, model: model)
                        Divider().frame(height: 90)
                        Divider().frame(height: 90)
                        ForEach(0..<8, id: \.self) { i in OutputStrip(output: i, model: model) }
                    }
                }
            }
        }
        .padding(8)
    }
}

// MARK: - Mixer

/// A vertical dB fader that writes on release (-97 = off, capped at 0 dB).
struct MixerFader: View {
    let label: String
    let value: Int?
    let commit: (Int) -> Void
    @State private var dB: Double = -97
    @State private var editing = false

    var body: some View {
        VStack(spacing: 4) {
            VerticalFader(value: $dB, range: -97...0) { editing = $0; if !$0 { commit(Int(dB)) } }
                .frame(width: 34, height: 140)
            Text(dB <= -97 ? "-∞" : "\(Int(dB))").font(.caption2).monospacedDigit()
            Text(label).font(.caption2).lineLimit(1).fixedSize()
        }
        .onChange(of: value) { _, new in if !editing, let new { dB = Double(new) } }
        .onAppear { if let value { dB = Double(value) } }
    }
}

struct MixerPage: View {
    @Bindable var model: EnsembleModel
    @State private var mix = 0

    /// Inferred order of the 18 mixer sources.
    static let sourceNames = (1...8).map { "In \($0)" } + ["S/PDIF L", "S/PDIF R"] + (1...8).map { "Opt \($0)" }

    /// Output pairs that can be fed from a playback pair or a mix.
    static let destinations: [(String, UInt8)] = [
        ("Out 1-2", EnsembleRouting.analogOut(0)), ("Out 3-4", EnsembleRouting.analogOut(2)),
        ("Out 5-6", EnsembleRouting.analogOut(4)), ("Out 7-8", EnsembleRouting.analogOut(6)),
        ("Headphone 1", EnsembleRouting.headphone1), ("Headphone 2", EnsembleRouting.headphone2),
    ]
    static let sources: [(String, UInt8)] = stride(from: 0, to: 18, by: 2).map { ("Playback \($0 + 1)-\($0 + 2)", EnsembleRouting.playback($0)) }
        + [("Mix A", EnsembleRouting.mixA), ("Mix B", EnsembleRouting.mixB)]

    var body: some View {
        let m = model.mixers?[mix]
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $mix) { Text("Mix A").tag(0); Text("Mix B").tag(1) }
                .pickerStyle(.segmented).labelsHidden().frame(width: 200)
            ScrollView(.horizontal) {
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(0..<18, id: \.self) { i in
                        MixerFader(label: Self.sourceNames[i], value: m?.fader(i)) { dB in model.editMixer(mix) { $0.setFader(i, dB: dB) } }
                    }
                    Divider().frame(height: 160)
                    MixerFader(label: "Software", value: m?.softwareReturn) { dB in model.editMixer(mix) { $0.setSoftwareReturn(dB: dB) } }
                    MixerFader(label: "Master", value: m?.master) { dB in model.editMixer(mix) { $0.setMaster(dB: dB) } }
                }
                .padding(.vertical, 4)
            }
            .id(mix)  // reset fader state when switching mixes

            GroupBox("Output sources") {
                Grid(alignment: .leading) {
                    ForEach(Self.destinations, id: \.1) { name, dest in
                        GridRow {
                            Text(name)
                            Picker("", selection: Binding(
                                get: { model.routing?.sources[Int(dest)] ?? EnsembleRouting.none },
                                set: { model.route(destinationL: dest, sourceL: $0) })) {
                                ForEach(Self.sources, id: \.1) { Text($0.0).tag($0.1) }
                                if let s = model.routing?.sources[Int(dest)], !Self.sources.contains(where: { $0.1 == s }) {
                                    Text(String(format: "Other (0x%02X)", s)).tag(s)
                                }
                            }
                            .labelsHidden().frame(width: 160)
                        }
                    }
                }
            }
        }
        .padding(8)
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
