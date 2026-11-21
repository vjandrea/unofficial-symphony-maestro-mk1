/// Sends raw AV/C frames to a FireWire unit through ASFireWire's loopback MCP
/// control plane (`asfw_fcp_send_command_dev`).
///
/// ponytail: development-only route. The control plane exists only in self-built
/// ASFW (Debug entitlements, SIP off); signed releases refuse third-party
/// clients (mrmidi/ASFireWire#202, #259, #262). Swap for a supported ASFW API
/// when one exists.

import Foundation

public enum ASFWControlPlaneError: Error, Sendable, Equatable {
    case unreachable(String)
    case notReady(String)
    case unitNotFound
    case rpc(String)
    case commandFailed(String)
}

public actor ASFWControlPlane {

    public struct Unit: Sendable, Equatable {
        public let guid: UInt64
        public let nodeId: Int
        public let modelName: String
    }

    public let endpoint: URL
    private var sessionID: String?
    private var requestID = 0
    private let protocolVersion = "2025-11-25"

    public init(endpoint: URL = URL(string: "http://127.0.0.1:8765/mcp")!) {
        self.endpoint = endpoint
    }

    /// Current bus generation; commands carry it so a bus reset can't misroute them.
    public func generation() async throws -> Int {
        let health = try await readResource("asfw://control-plane/health")
        let data = health["data"] as? [String: Any] ?? health
        guard data["status"] as? String == "ready", let gen = data["expectedGeneration"] as? Int else {
            throw ASFWControlPlaneError.notReady("\(data["reasons"] ?? data["status"] ?? "unknown")")
        }
        return gen
    }

    /// First node whose GUID carries Apogee's OUI and whose model name matches.
    public func findUnit(model: String = "Ensemble") async throws -> Unit {
        let nodes = try await readResource("asfw://nodes")
        let list = (nodes["data"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? nodes["nodes"] as? [[String: Any]] ?? []
        for node in list {
            guard let name = node["modelName"] as? String, name == model,
                  let guidText = node["guid"] as? String,
                  let guid = UInt64(guidText.replacingOccurrences(of: "0x", with: ""), radix: 16),
                  guid >> 40 == 0x0003DB,
                  let nodeId = node["nodeId"] as? Int
            else { continue }
            return Unit(guid: guid, nodeId: nodeId, modelName: name)
        }
        throw ASFWControlPlaneError.unitNotFound
    }

    /// Bus generation from the last health read; only a bus reset changes it.
    private var cachedGeneration: Int?

    /// Writes `frame` to the unit's FCP command register and returns the response frame.
    /// Uses the cached bus generation; on failure re-reads it once and retries.
    public func send(_ frame: [UInt8], to unit: Unit) async throws -> [UInt8] {
        if let gen = cachedGeneration, let reply = try? await send(frame, to: unit, generation: gen) { return reply }
        let gen = try await generation()
        cachedGeneration = gen
        return try await send(frame, to: unit, generation: gen)
    }

    private func send(_ frame: [UInt8], to unit: Unit, generation: Int) async throws -> [UInt8] {
        // STATUS goes through ASFW's read-only tool; everything else needs the developer
        // tool, which checks the declared intent against the ctype and opcode.
        let isStatus = frame.first == 0x01
        let intent = isStatus ? "status" : (frame.count > 2 && frame[2] == 0x00 ? "vendorDependent" : "control")
        let args: [String: Any] = [
            "targetGuid": String(format: "0x%016llX", unit.guid),
            "nodeId": unit.nodeId,
            "generation": generation,
            "addressHigh": 0xFFFF,
            "addressLow": 0xF000_0B00,
            "intent": intent,
            "payload": frame.map(Int.init),
        ]
        let tool = isStatus ? "asfw_fcp_send_command" : "asfw_fcp_send_command_dev"
        let result = try await request("tools/call", ["name": tool, "arguments": args])
        let structured = result["structuredContent"] as? [String: Any] ?? [:]
        let data = structured["data"] as? [String: Any] ?? [:]
        guard structured["ok"] as? Bool == true, data["status"] as? String == "ok",
              let response = data["response"] as? [Int] else {
            throw ASFWControlPlaneError.commandFailed("\(data["status"] ?? "?"): \((data["policy"] as? [String: Any])?["reason"] ?? structured["errors"] ?? "")")
        }
        return response.map { UInt8(truncatingIfNeeded: $0) }
    }

    // MARK: JSON-RPC over HTTP

    private func readResource(_ uri: String) async throws -> [String: Any] {
        let result = try await request("resources/read", ["uri": uri])
        guard let contents = result["contents"] as? [[String: Any]], let text = contents.first?["text"] as? String,
              let json = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        else { return result }
        return json
    }

    private func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        if sessionID == nil { try await initialize() }
        return try await post(["jsonrpc": "2.0", "id": nextID(), "method": method, "params": params])
    }

    private func initialize() async throws {
        let params: [String: Any] = ["protocolVersion": protocolVersion, "capabilities": [:],
                                     "clientInfo": ["name": "Maestro Ensemble", "version": "1"]]
        _ = try await post(["jsonrpc": "2.0", "id": nextID(), "method": "initialize", "params": params], initializing: true)
    }

    private func nextID() -> Int { requestID += 1; return requestID }

    private func post(_ body: [String: Any], initializing: Bool = false) async throws -> [String: Any] {
        var req = URLRequest(url: endpoint, timeoutInterval: 5)
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionID, !initializing { req.setValue(sessionID, forHTTPHeaderField: "MCP-Session-Id") }
        // ASFW answers every request with `Connection: close`; without this URLSession
        // reuses the dead socket and fails with "The network connection was lost".
        req.setValue("close", forHTTPHeaderField: "Connection")

        let (data, response): (Data, URLResponse)
        do { (data, response) = try await URLSession.shared.data(for: req) }
        catch let error as URLError where error.code == .networkConnectionLost {
            // One retry: the request never reached ASFW, so resending is safe.
            do { (data, response) = try await URLSession.shared.data(for: req) }
            catch { throw ASFWControlPlaneError.unreachable(error.localizedDescription) }
        }
        catch { throw ASFWControlPlaneError.unreachable(error.localizedDescription) }
        let http = response as? HTTPURLResponse
        let text = String(decoding: data, as: UTF8.self)
        if initializing {
            // ASFW hosts one session; a second initialize returns 400 with the active session's id.
            sessionID = http?.value(forHTTPHeaderField: "MCP-Session-Id")
            if http?.statusCode == 400, text.contains("Session already initialized"), sessionID != nil { return [:] }
        }
        guard http?.statusCode == 200 else {
            if http?.statusCode == 404 { sessionID = nil }  // session expired: re-initialize next call
            throw ASFWControlPlaneError.rpc("HTTP \(http?.statusCode ?? 0): \(text.prefix(200))")
        }
        // Plain JSON, or the first SSE `data:` message.
        let json = text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{")
            ? text
            : text.split(separator: "\n").filter { $0.hasPrefix("data:") }.map { $0.dropFirst(5) }.joined(separator: "\n")
        guard let message = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw ASFWControlPlaneError.rpc("unparseable reply")
        }
        if let error = message["error"] as? [String: Any] { throw ASFWControlPlaneError.rpc("\(error["message"] ?? error)") }
        return message["result"] as? [String: Any] ?? [:]
    }
}
