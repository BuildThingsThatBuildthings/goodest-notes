import Foundation
import CryptoKit
import Network

struct AgentPairingCode: Equatable {
    let address: String
    let port: UInt16
    let key: String

    var value: String { "BB1:\(address):\(port):\(key)" }

    init(address: String, port: UInt16, key: String) {
        self.address = address
        self.port = port
        self.key = key
    }

    init?(_ value: String) {
        let parts = value.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "BB1", let port = UInt16(parts[2]), port > 0,
              let key = Data(base64Encoded: String(parts[3])), key.count == 32 else { return nil }
        let ip = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        guard ip.count == 4, ip.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && UInt8($0) != nil }),
              let first = UInt8(ip[0]), let second = UInt8(ip[1]),
              first == 10 || first == 172 && (16...31).contains(second) ||
                first == 192 && second == 168 || first == 169 && second == 254 || first == 127 else { return nil }
        self.init(address: String(parts[1]), port: port, key: String(parts[3]))
    }
}

enum AgentWire {
    static let limit = 2 * 1024 * 1024
    private static let requestContext = Data("Blockbook MCP request v1".utf8)
    private static let replyContext = Data("Blockbook MCP response v1".utf8)

    enum Failure: Error { case closed, tooLarge, invalidFrame }

    static func request(_ json: Data, key: SymmetricKey) throws -> Data {
        var stamp = Int64(Date().timeIntervalSince1970).bigEndian
        var packet = withUnsafeBytes(of: &stamp) { Data($0) }
        packet.append(json)
        return try seal(packet, key: key, context: requestContext)
    }

    static func openRequest(_ encrypted: Data, key: SymmetricKey, now: Date = .now) throws -> Data {
        let clear = try open(encrypted, key: key, context: requestContext)
        guard clear.count >= 8 else { throw Failure.invalidFrame }
        let time = clear.prefix(8).reduce(Int64(0)) { ($0 << 8) | Int64($1) }
        guard abs(Double(time) - now.timeIntervalSince1970) < 90 else { throw Failure.invalidFrame }
        return Data(clear.dropFirst(8))
    }

    static func reply(_ json: Data, for request: Data, key: SymmetricKey) throws -> Data {
        try seal(json, key: key, context: replyContext + request.prefix(12))
    }

    static func openReply(_ encrypted: Data, for request: Data, key: SymmetricKey) throws -> Data {
        try open(encrypted, key: key, context: replyContext + request.prefix(12))
    }

    private static func seal(_ clear: Data, key: SymmetricKey, context: Data) throws -> Data {
        guard clear.count <= limit - 28, let sealed = try AES.GCM.seal(clear, using: key, authenticating: context).combined else { throw Failure.tooLarge }
        return sealed
    }

    private static func open(_ encrypted: Data, key: SymmetricKey, context: Data) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: encrypted), using: key, authenticating: context)
    }

    static func frame(_ encrypted: Data) throws -> Data {
        guard encrypted.count <= limit else { throw Failure.tooLarge }
        var count = UInt32(encrypted.count).bigEndian
        return withUnsafeBytes(of: &count) { Data($0) } + encrypted
    }

    static func receive(_ connection: NWConnection, completion: @escaping (Result<Data, Error>) -> Void) {
        read(connection, count: 4) { result in
            do {
                let header = try result.get()
                let size = header.reduce(0) { ($0 << 8) | Int($1) }
                guard (28...limit).contains(size) else { throw Failure.invalidFrame }
                read(connection, count: size, completion: completion)
            } catch { completion(.failure(error)) }
        }
    }

    private static func read(_ connection: NWConnection, count: Int, completion: @escaping (Result<Data, Error>) -> Void) {
        connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
            if let error { completion(.failure(error)) }
            else if let data, data.count == count { completion(.success(data)) }
            else { completion(.failure(Failure.closed)) }
        }
    }
}
