import Foundation
import CryptoKit
import Network

enum BridgeError: LocalizedError {
    case usage, invalidAddress, invalidCode, invalidKey, timeout, missingPairing
    var errorDescription: String? {
        switch self {
        case .usage: "Usage: blockbook-mcp pair, blockbook-mcp status, blockbook-mcp, or blockbook-mcp forget"
        case .invalidAddress: "Enter the IPv4 address and port shown in Goodest Notes."
        case .invalidCode: "Copy the full connection code from Goodest Notes on your iPad."
        case .invalidKey: "BLOCKBOOK_MCP_KEY must contain the current Goodest Notes pairing code."
        case .timeout: "The iPad did not reply. Check its address, session, and Wi-Fi connection."
        case .missingPairing: "Open Goodest Notes on your iPad, start an encrypted agent session, and open Connect Goodest Notes on your Mac."
        }
    }
}

struct Pairing: Codable {
    let address: String
    let port: UInt16
    let key: String
    let created: Date

    static var file: URL {
        URL.cachesDirectory.appendingPathComponent("com.btbt.blockbook", isDirectory: true).appendingPathComponent("mcp-session.json")
    }

    func connection() throws -> (IPv4Address, NWEndpoint.Port, SymmetricKey) {
        guard let host = IPv4Address(address), port != 0, let nwPort = NWEndpoint.Port(rawValue: port) else { throw BridgeError.invalidAddress }
        guard let bytes = Data(base64Encoded: key), bytes.count == 32 else { throw BridgeError.invalidKey }
        return (host, nwPort, SymmetricKey(data: bytes))
    }

    func save() throws {
        try FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(self).write(to: Self.file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.file.path)
    }

    static func load() throws -> Self {
        guard let data = try? Data(contentsOf: file), let pairing = try? JSONDecoder().decode(Self.self, from: data),
              Date().timeIntervalSince(pairing.created) < 1800 else { throw BridgeError.missingPairing }
        return pairing
    }
}

func exchange(_ request: Data, host: IPv4Address, port: NWEndpoint.Port, key: SymmetricKey) throws -> Data {
    let packet = try AgentWire.request(request, key: key)
    let bytes = try AgentWire.frame(packet)
    let queue = DispatchQueue(label: "blockbook.mcp.request")
    let connection = NWConnection(host: .ipv4(host), port: port, using: .tcp)
    let finished = DispatchSemaphore(value: 0)
    var result: Result<Data, Error> = .failure(BridgeError.timeout)
    var resolved = false
    func finish(_ value: Result<Data, Error>) {
        guard !resolved else { return }
        resolved = true
        result = value
        finished.signal()
    }
    connection.stateUpdateHandler = { state in
        switch state {
        case .ready:
            connection.send(content: bytes, completion: .contentProcessed { error in
                if let error { finish(.failure(error)); return }
                AgentWire.receive(connection) { response in
                    finish(Result { try AgentWire.openReply(response.get(), for: packet, key: key) })
                }
            })
        case let .failed(error), let .waiting(error): finish(.failure(error))
        default: break
        }
    }
    connection.start(queue: queue)
    defer { connection.stateUpdateHandler = nil; connection.cancel() }
    guard finished.wait(timeout: .now() + 8) == .success else { throw BridgeError.timeout }
    return try result.get()
}

func writeError(_ error: Error, request: Data) {
    guard let object = (try? JSONSerialization.jsonObject(with: request)) as? [String: Any], let id = object["id"] else { return }
    let explanation = "Goodest Notes bridge: " + error.localizedDescription
    var message = ["jsonrpc": "2.0", "id": id] as [String: Any]
    if object["method"] as? String == "tools/call" {
        message["result"] = ["isError": true, "content": [["type": "text", "text": explanation]]]
    } else {
        message["error"] = ["code": -32000, "message": explanation]
    }
    if let output = try? JSONSerialization.data(withJSONObject: message) { writeLine(output) }
}

func writeLine(_ data: Data) { FileHandle.standardOutput.write(data + Data([10])) }

func handleDiscovery(_ request: Data) throws -> Bool {
    guard let object = try JSONSerialization.jsonObject(with: request) as? [String: Any],
          object["jsonrpc"] as? String == "2.0", let method = object["method"] as? String else { return false }
    guard let id = object["id"] else { return true }
    let result: [String: Any]
    switch method {
    case "initialize": result = AgentCatalog.initialize(object["params"] as? [String: Any] ?? [:])
    case "ping": result = [:]
    case "tools/list": result = ["tools": AgentCatalog.tools]
    default: return false
    }
    writeLine(try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result]))
    return true
}

func verify(_ pairing: Pairing) throws {
    let (host, port, key) = try pairing.connection()
    let response = try exchange(Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8), host: host, port: port, key: key)
    guard let reply = try JSONSerialization.jsonObject(with: response) as? [String: Any], reply["result"] != nil else { throw BridgeError.timeout }
}

do {
    let args = Array(CommandLine.arguments.dropFirst())
    if args == ["forget"] {
        if FileManager.default.fileExists(atPath: Pairing.file.path) { try FileManager.default.removeItem(at: Pairing.file) }
        exit(0)
    }
    if args.first == "pair" {
        guard args.count == 1 || args.count == 3 else { throw BridgeError.usage }
        guard let raw = readLine() else { throw BridgeError.invalidCode }
        let code: AgentPairingCode
        if args.count == 1 {
            guard let input = AgentPairingCode(raw) else { throw BridgeError.invalidCode }
            code = input
        } else {
            guard let port = UInt16(args[2]) else { throw BridgeError.invalidAddress }
            code = AgentPairingCode(address: args[1], port: port, key: raw.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let pairing = Pairing(address: code.address, port: code.port, key: code.key, created: .now)
        try verify(pairing)
        try pairing.save()
        FileHandle.standardError.write(Data("Paired with Goodest Notes.\n".utf8))
        exit(0)
    }
    if args == ["status"] {
        try verify(Pairing.load())
        print("The encrypted iPad session is reachable.")
        exit(0)
    }
    let fixedPairing: Pairing?
    if args.count == 2, let number = UInt16(args[1]), let key = ProcessInfo.processInfo.environment["BLOCKBOOK_MCP_KEY"] {
        fixedPairing = Pairing(address: args[0], port: number, key: key, created: .now)
    } else if args.isEmpty { fixedPairing = nil }
    else { throw BridgeError.usage }
    while let line = readLine() {
        let request = Data(line.utf8)
        do {
            // Long-lived clients can discover tools before pairing. iPad authorization
            // is still checked on every call, including after a new pairing.
            if fixedPairing == nil, try handleDiscovery(request) { continue }
            let pairing = try fixedPairing ?? Pairing.load()
            let (host, port, key) = try pairing.connection()
            let response = try exchange(request, host: host, port: port, key: key)
            if !response.isEmpty { writeLine(response) }
        } catch { writeError(error, request: request) }
    }
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
