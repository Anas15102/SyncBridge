//
//  PacketTypes.swift
//  SyncBridge
//
//  Created for SyncBridge Mac & Android integration.
//

import Foundation

public enum PacketTypes {
    public static let identity = "kdeconnect.identity"
    public static let pair = "kdeconnect.pair"
    public static let clipboard = "kdeconnect.clipboard"
    public static let clipboardConnect = "kdeconnect.clipboard.connect"
    public static let shareRequest = "kdeconnect.share.request"
    public static let shareRequestUpdate = "kdeconnect.share.request.update"
    public static let ping = "kdeconnect.ping"
    
    public static let defaultProtocolVersion: Int = 7
    public static let defaultUdpPort: UInt16 = 1716
    public static let defaultTcpPort: UInt16 = 1716
    public static let minTcpPort: UInt16 = 1716
    public static let maxTcpPort: UInt16 = 1764
    public static let defaultPayloadPortStart: UInt16 = 1739
    public static let defaultPayloadPortEnd: UInt16 = 1764
    
    public static let defaultCapabilities: [String] = [
        PacketTypes.identity,
        PacketTypes.pair,
        PacketTypes.clipboard,
        PacketTypes.clipboardConnect,
        PacketTypes.shareRequest,
        PacketTypes.shareRequestUpdate,
        PacketTypes.ping
    ]
}
