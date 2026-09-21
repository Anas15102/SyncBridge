//
//  NetworkPacket.swift
//  SyncBridge
//

import Foundation

public struct AnyCodableValue: Codable, Equatable, Hashable {
    public let value: Any
    
    public init(_ value: Any) {
        self.value = value
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let boolVal = try? container.decode(Bool.self) {
            self.value = boolVal
        } else if let intVal = try? container.decode(Int64.self) {
            self.value = intVal
        } else if let doubleVal = try? container.decode(Double.self) {
            self.value = doubleVal
        } else if let stringVal = try? container.decode(String.self) {
            self.value = stringVal
        } else if let arrayVal = try? container.decode([AnyCodableValue].self) {
            self.value = arrayVal.map { $0.value }
        } else if let dictVal = try? container.decode([String: AnyCodableValue].self) {
            self.value = dictVal.mapValues { $0.value }
        } else {
            self.value = ""
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self.value {
        case let boolVal as Bool:
            try container.encode(boolVal)
        case let intVal as Int:
            try container.encode(Int64(intVal))
        case let int64Val as Int64:
            try container.encode(int64Val)
        case let doubleVal as Double:
            try container.encode(doubleVal)
        case let stringVal as String:
            try container.encode(stringVal)
        case let arrayVal as [Any]:
            let codableArray = arrayVal.map { AnyCodableValue($0) }
            try container.encode(codableArray)
        case let dictVal as [String: Any]:
            let codableDict = dictVal.mapValues { AnyCodableValue($0) }
            try container.encode(codableDict)
        default:
            try container.encode(String(describing: self.value))
        }
    }
    
    public static func == (lhs: AnyCodableValue, rhs: AnyCodableValue) -> Bool {
        String(describing: lhs.value) == String(describing: rhs.value)
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(String(describing: value))
    }
}

public struct NetworkPacket: Codable {
    public var id: Int64
    public var type: String
    public var body: [String: AnyCodableValue]
    public var payloadSize: Int64?
    public var payloadTransferInfo: [String: AnyCodableValue]?
    
    public init(
        id: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        type: String,
        body: [String: Any] = [:],
        payloadSize: Int64? = nil,
        payloadTransferInfo: [String: Any]? = nil
    ) {
        self.id = id
        self.type = type
        self.body = body.mapValues { AnyCodableValue($0) }
        self.payloadSize = payloadSize
        if let pInfo = payloadTransferInfo {
            self.payloadTransferInfo = pInfo.mapValues { AnyCodableValue($0) }
        } else {
            self.payloadTransferInfo = nil
        }
    }
    
    // MARK: Serialization
    
    public func toData() -> Data? {
        let encoder = JSONEncoder()
        guard var data = try? encoder.encode(self) else { return nil }
        data.append(contentsOf: [0x0A]) // \n newline delimiter
        return data
    }
    
    public static func from(data: Data) -> NetworkPacket? {
        var cleanData = data
        while let last = cleanData.last, last == 0x0A || last == 0x0D || last == 0x20 || last == 0x09 {
            cleanData.removeLast()
        }
        while let first = cleanData.first, first == 0x0A || first == 0x0D || first == 0x20 || first == 0x09 {
            cleanData.removeFirst()
        }
        guard !cleanData.isEmpty else { return nil }
        let decoder = JSONDecoder()
        return try? decoder.decode(NetworkPacket.self, from: cleanData)
    }
    
    // MARK: Helper packet factories
    
    public static func createIdentityPacket(identity: DeviceIdentity) -> NetworkPacket {
        var body: [String: Any] = [
            "deviceId": identity.deviceId,
            "deviceName": identity.deviceName,
            "deviceType": identity.deviceType,
            "protocolVersion": identity.protocolVersion,
            "incomingCapabilities": identity.incomingCapabilities,
            "outgoingCapabilities": identity.outgoingCapabilities
        ]
        if let port = identity.tcpPort {
            body["tcpPort"] = port
        }
        return NetworkPacket(type: PacketTypes.identity, body: body)
    }
    
    public static func createPairPacket(pair: Bool) -> NetworkPacket {
        return NetworkPacket(type: PacketTypes.pair, body: ["pair": pair])
    }
    
    public static func createClipboardPacket(content: String) -> NetworkPacket {
        return NetworkPacket(type: PacketTypes.clipboard, body: ["content": content])
    }
    
    public static func createClipboardConnectPacket(content: String) -> NetworkPacket {
        return NetworkPacket(type: PacketTypes.clipboardConnect, body: ["content": content])
    }
    
    public static func createShareFileRequestPacket(
        filename: String,
        fileSize: Int64,
        payloadPort: UInt16,
        numberOfFiles: Int = 1
    ) -> NetworkPacket {
        return NetworkPacket(
            type: PacketTypes.shareRequest,
            body: [
                "filename": filename,
                "numberOfFiles": numberOfFiles,
                "totalPayloadSize": fileSize,
                "open": false
            ],
            payloadSize: fileSize,
            payloadTransferInfo: ["port": Int(payloadPort)]
        )
    }
    
    public static func createShareTextPacket(text: String) -> NetworkPacket {
        return NetworkPacket(
            type: PacketTypes.shareRequest,
            body: ["text": text]
        )
    }
    
    public static func createShareUrlPacket(url: String) -> NetworkPacket {
        return NetworkPacket(
            type: PacketTypes.shareRequest,
            body: ["url": url]
        )
    }
    
    public static func createPingPacket() -> NetworkPacket {
        return NetworkPacket(type: PacketTypes.ping, body: [:])
    }
    
    // MARK: Accessors
    
    public func string(for key: String) -> String? {
        return body[key]?.value as? String
    }
    
    public func bool(for key: String) -> Bool? {
        return body[key]?.value as? Bool
    }
    
    public func int(for key: String) -> Int? {
        if let intVal = body[key]?.value as? Int {
            return intVal
        }
        if let int64Val = body[key]?.value as? Int64 {
            return Int(int64Val)
        }
        return nil
    }
    
    public func stringArray(for key: String) -> [String]? {
        if let arr = body[key]?.value as? [String] {
            return arr
        }
        if let arrAny = body[key]?.value as? [Any] {
            return arrAny.compactMap { $0 as? String }
        }
        return nil
    }
    
    public var payloadPort: UInt16? {
        guard let pInfo = payloadTransferInfo, let portVal = pInfo["port"]?.value else { return nil }
        if let p = portVal as? Int { return UInt16(p) }
        if let p = portVal as? Int64 { return UInt16(p) }
        if let p = portVal as? Double { return UInt16(p) }
        return nil
    }
}
