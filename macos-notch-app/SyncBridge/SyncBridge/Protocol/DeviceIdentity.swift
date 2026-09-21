//
//  DeviceIdentity.swift
//  SyncBridge
//

import Foundation

public struct DeviceIdentity: Codable, Equatable, Hashable {
    public var deviceId: String
    public var deviceName: String
    public var deviceType: String
    public var protocolVersion: Int
    public var incomingCapabilities: [String]
    public var outgoingCapabilities: [String]
    public var tcpPort: Int?
    
    public init(
        deviceId: String,
        deviceName: String,
        deviceType: String = "laptop",
        protocolVersion: Int = PacketTypes.defaultProtocolVersion,
        incomingCapabilities: [String] = PacketTypes.defaultCapabilities,
        outgoingCapabilities: [String] = PacketTypes.defaultCapabilities,
        tcpPort: Int? = Int(PacketTypes.defaultTcpPort)
    ) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.deviceType = deviceType
        self.protocolVersion = protocolVersion
        self.incomingCapabilities = incomingCapabilities
        self.outgoingCapabilities = outgoingCapabilities
        self.tcpPort = tcpPort
    }
    
    public static var currentDevice: DeviceIdentity {
        let name = Host.current().localizedName ?? "MacBook"
        var uuid = UserDefaults.standard.string(forKey: "syncbridge_device_id")
        if uuid == nil {
            uuid = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            UserDefaults.standard.set(uuid, forKey: "syncbridge_device_id")
        }
        return DeviceIdentity(
            deviceId: uuid!,
            deviceName: name,
            deviceType: "laptop",
            protocolVersion: PacketTypes.defaultProtocolVersion,
            incomingCapabilities: PacketTypes.defaultCapabilities,
            outgoingCapabilities: PacketTypes.defaultCapabilities,
            tcpPort: Int(PacketTypes.defaultTcpPort)
        )
    }
}
