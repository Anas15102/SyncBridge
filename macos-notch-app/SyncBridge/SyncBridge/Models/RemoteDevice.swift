//
//  RemoteDevice.swift
//  SyncBridge
//

import Foundation

public enum DevicePairingState: String, Codable {
    case unpaired
    case pairingRequested
    case incomingPairRequest
    case paired
}

public class RemoteDevice: Identifiable, ObservableObject, Hashable {
    public let id: String
    @Published public var name: String
    @Published public var type: String
    @Published public var ipAddress: String
    @Published public var tcpPort: UInt16
    @Published public var pairingState: DevicePairingState
    @Published public var isReachable: Bool
    @Published public var lastSeen: Date
    @Published public var incomingCapabilities: [String]
    @Published public var outgoingCapabilities: [String]
    
    public init(
        id: String,
        name: String,
        type: String = "phone",
        ipAddress: String,
        tcpPort: UInt16 = PacketTypes.defaultTcpPort,
        pairingState: DevicePairingState = .unpaired,
        isReachable: Bool = true,
        lastSeen: Date = Date(),
        incomingCapabilities: [String] = [],
        outgoingCapabilities: [String] = []
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.ipAddress = ipAddress
        self.tcpPort = tcpPort
        self.pairingState = pairingState
        self.isReachable = isReachable
        self.lastSeen = lastSeen
        self.incomingCapabilities = incomingCapabilities
        self.outgoingCapabilities = outgoingCapabilities
    }
    
    public static func == (lhs: RemoteDevice, rhs: RemoteDevice) -> Bool {
        lhs.id == rhs.id
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
