//
//  AppState.swift
//  SyncBridge
//

import Foundation
import SwiftUI
import Network
import Combine

public class AppState: ObservableObject, UDPDiscoveryDelegate, TCPServerDelegate, TCPClientDelegate, PairingManagerDelegate, ClipboardSyncDelegate, FileShareDelegate {
    public static let shared = AppState()
    
    // MARK: - Published Properties
    
    @Published public var devices: [RemoteDevice] = []
    @Published public var selectedDevice: RemoteDevice?
    @Published public var pendingPairingDevice: RemoteDevice?
    @Published public var clipboardHistory: [ClipboardItem] = []
    @Published public var transfers: [TransferItem] = []
    @Published public var isClipboardSyncEnabled: Bool = true {
        didSet {
            clipboardService.isEnabled = isClipboardSyncEnabled
        }
    }
    @Published public var isDiscoveryActive: Bool = false
    @Published public var localIdentity: DeviceIdentity = DeviceIdentity.currentDevice
    
    // MARK: - Core Services
    
    private let discoveryService = UDPDiscoveryService()
    private let tcpServer = TCPServer()
    private let pairingManager = PairingManager()
    private let clipboardService = ClipboardSyncService()
    public let fileShareService = FileShareService()
    
    
    private var tcpClients: [String: TCPClient] = [:]
    private var pingTimer: Timer?
    
    public init() {
        discoveryService.delegate = self
        tcpServer.delegate = self
        pairingManager.delegate = self
        clipboardService.delegate = self
        fileShareService.delegate = self
        
        startServices()
    }
    
    // MARK: - Lifecycle
    
    public func startServices() {
        tcpServer.start()
        discoveryService.start()
        clipboardService.start()
        isDiscoveryActive = true
        
        startPingTimer()
    }
    
    public func stopServices() {
        discoveryService.stop()
        tcpServer.stop()
        clipboardService.stop()
        pingTimer?.invalidate()
        isDiscoveryActive = false
    }
    
    private func startPingTimer() {
        pingTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.pingAllPairedDevices()
        }
    }
    
    // MARK: - Device Management
    
    public func getOrCreateDevice(from identity: DeviceIdentity, address: String) -> RemoteDevice {
        let normAddr = TCPServer.normalizeIP(address)
        if let existing = devices.first(where: { $0.id == identity.deviceId || TCPServer.normalizeIP($0.ipAddress) == normAddr }) {
            existing.name = identity.deviceName
            existing.type = identity.deviceType
            existing.ipAddress = normAddr
            if let port = identity.tcpPort {
                existing.tcpPort = UInt16(port)
            }
            existing.isReachable = true
            existing.lastSeen = Date()
            existing.incomingCapabilities = identity.incomingCapabilities
            existing.outgoingCapabilities = identity.outgoingCapabilities
            return existing
        } else {
            let isPaired = pairingManager.isPaired(deviceId: identity.deviceId)
            let newDevice = RemoteDevice(
                id: identity.deviceId,
                name: identity.deviceName,
                type: identity.deviceType,
                ipAddress: normAddr,
                tcpPort: UInt16(identity.tcpPort ?? Int(PacketTypes.defaultTcpPort)),
                pairingState: isPaired ? .paired : .unpaired,
                isReachable: true,
                lastSeen: Date(),
                incomingCapabilities: identity.incomingCapabilities,
                outgoingCapabilities: identity.outgoingCapabilities
            )
            devices.append(newDevice)
            return newDevice
        }
    }
    
    public func connectTo(ipAddress: String) {
        let norm = TCPServer.normalizeIP(ipAddress.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !norm.isEmpty else { return }
        discoveryService.sendDirectIdentity(to: norm)
        let identityPacket = NetworkPacket.createIdentityPacket(identity: localIdentity)
        let client = TCPClient(host: norm, port: PacketTypes.defaultTcpPort)
        client.delegate = self
        tcpClients[norm] = client
        client.sendPacket(identityPacket)
    }
    
    // MARK: - Actions
    
    public func pair(device: RemoteDevice) {
        pairingManager.requestPairing(device: device) { [weak self] packet in
            self?.sendPacket(packet, to: device)
        }
    }
    
    public func acceptPairing(device: RemoteDevice) {
        pendingPairingDevice = nil
        pairingManager.acceptPairing(device: device) { [weak self] packet in
            self?.sendPacket(packet, to: device)
        }
    }
    
    public func rejectPairing(device: RemoteDevice) {
        pendingPairingDevice = nil
        pairingManager.rejectPairing(device: device) { [weak self] packet in
            self?.sendPacket(packet, to: device)
        }
    }
    
    public func unpair(device: RemoteDevice) {
        pairingManager.unpair(device: device) { [weak self] packet in
            self?.sendPacket(packet, to: device)
        }
    }
    
    public func sendFile(url: URL, to device: RemoteDevice) {
        _ = fileShareService.sendFile(fileURL: url, to: device) { [weak self] packet in
            self?.sendPacket(packet, to: device)
        }
    }
    
    public func sendText(_ text: String, to device: RemoteDevice) {
        fileShareService.sendText(text, to: device) { [weak self] packet in
            self?.sendPacket(packet, to: device)
        }
    }
    
    public func pingAllPairedDevices() {
        let paired = devices.filter { $0.pairingState == .paired }
        let packet = NetworkPacket.createPingPacket()
        for dev in paired {
            sendPacket(packet, to: dev)
        }
    }
    
    public func sendPacket(_ packet: NetworkPacket, to device: RemoteDevice) {
        let normAddr = TCPServer.normalizeIP(device.ipAddress)
        tcpServer.sendPacket(packet, to: normAddr) { [weak self] success in
            if !success {
                // If TCP Server couldn't route it, use or create outbound TCPClient
                self?.sendViaClient(packet: packet, device: device)
            }
        }
    }
    
    private func sendViaClient(packet: NetworkPacket, device: RemoteDevice) {
        let normAddr = TCPServer.normalizeIP(device.ipAddress)
        if let client = tcpClients[normAddr] {
            client.sendPacket(packet)
        } else {
            let client = TCPClient(host: normAddr, port: device.tcpPort)
            client.delegate = self
            tcpClients[normAddr] = client
            client.sendPacket(packet)
        }
    }
    
    // MARK: - UDPDiscoveryDelegate
    
    public func udpDiscoveryDidDiscoverDevice(identity: DeviceIdentity, fromAddress: String) {
        let device = getOrCreateDevice(from: identity, address: fromAddress)
        objectWillChange.send()
        
        // Exchange identity over TCP as well for instant connection
        let identityPacket = NetworkPacket.createIdentityPacket(identity: localIdentity)
        sendPacket(identityPacket, to: device)
    }
    
    // MARK: - TCPServerDelegate
    
    public func tcpServerDidReceivePacket(_ packet: NetworkPacket, from address: String, connection: NWConnection) {
        let norm = TCPServer.normalizeIP(address)
        guard let device = devices.first(where: { TCPServer.normalizeIP($0.ipAddress) == norm }) else {
            // Unregistered device connecting, process identity
            if packet.type == PacketTypes.identity {
                if let devId = packet.string(for: "deviceId"),
                   let devName = packet.string(for: "deviceName") {
                    let devType = packet.string(for: "deviceType") ?? "phone"
                    let inCaps = packet.stringArray(for: "incomingCapabilities") ?? []
                    let outCaps = packet.stringArray(for: "outgoingCapabilities") ?? []
                    let tcpPort = packet.int(for: "tcpPort") ?? Int(PacketTypes.defaultTcpPort)
                    
                    let ident = DeviceIdentity(
                        deviceId: devId,
                        deviceName: devName,
                        deviceType: devType,
                        incomingCapabilities: inCaps,
                        outgoingCapabilities: outCaps,
                        tcpPort: tcpPort
                    )
                    let newDev = getOrCreateDevice(from: ident, address: norm)
                    handlePacketForDevice(packet, device: newDev)
                }
            }
            return
        }
        
        handlePacketForDevice(packet, device: device)
    }
    
    // MARK: - TCPClientDelegate
    
    public func tcpClientDidConnect(to address: String) {
        let norm = TCPServer.normalizeIP(address)
        if let dev = devices.first(where: { TCPServer.normalizeIP($0.ipAddress) == norm }) {
            dev.isReachable = true
            objectWillChange.send()
        }
    }
    
    public func tcpClientDidDisconnect(from address: String, error: Error?) {
    }
    
    public func tcpClientDidReceivePacket(_ packet: NetworkPacket, from address: String) {
        let norm = TCPServer.normalizeIP(address)
        guard let device = devices.first(where: { TCPServer.normalizeIP($0.ipAddress) == norm }) else {
            if packet.type == PacketTypes.identity {
                if let devId = packet.string(for: "deviceId"),
                   let devName = packet.string(for: "deviceName") {
                    let devType = packet.string(for: "deviceType") ?? "phone"
                    let inCaps = packet.stringArray(for: "incomingCapabilities") ?? []
                    let outCaps = packet.stringArray(for: "outgoingCapabilities") ?? []
                    let tcpPort = packet.int(for: "tcpPort") ?? Int(PacketTypes.defaultTcpPort)
                    
                    let ident = DeviceIdentity(
                        deviceId: devId,
                        deviceName: devName,
                        deviceType: devType,
                        incomingCapabilities: inCaps,
                        outgoingCapabilities: outCaps,
                        tcpPort: tcpPort
                    )
                    let newDev = getOrCreateDevice(from: ident, address: norm)
                    handlePacketForDevice(packet, device: newDev)
                }
            }
            return
        }
        handlePacketForDevice(packet, device: device)
    }
    
    private func handlePacketForDevice(_ packet: NetworkPacket, device: RemoteDevice) {
        device.lastSeen = Date()
        device.isReachable = true
        
        switch packet.type {
        case PacketTypes.identity:
            if let name = packet.string(for: "deviceName") {
                device.name = name
            }
            if let type = packet.string(for: "deviceType") {
                device.type = type
            }
            
        case PacketTypes.pair:
            pairingManager.handlePairPacket(packet, for: device) { [weak self] replyPacket in
                self?.sendPacket(replyPacket, to: device)
            }
            
        case PacketTypes.clipboard, PacketTypes.clipboardConnect:
            guard device.pairingState == .paired else { return }
            if let content = packet.string(for: "content") {
                clipboardService.handleIncomingClipboard(content: content, fromDeviceName: device.name)
            }
            
        case PacketTypes.shareRequest:
            guard device.pairingState == .paired else { return }
            fileShareService.handleIncomingSharePacket(packet, from: device)
            
        case PacketTypes.ping:
            print("[Ping] Received ping from \(device.name)")
            
        default:
            print("[Packet] Received unhandled packet type: \(packet.type)")
        }
    }
    
    public func tcpServerConnectionStateChanged(isConnected: Bool, address: String) {
        if let dev = devices.first(where: { $0.ipAddress == address }) {
            dev.isReachable = isConnected
            objectWillChange.send()
        }
    }
    
    // MARK: - PairingManagerDelegate
    
    public func pairingDidUpdate(device: RemoteDevice) {
        objectWillChange.send()
    }
    
    public func incomingPairRequestReceived(from device: RemoteDevice) {
        pendingPairingDevice = device
        objectWillChange.send()
    }
    
    // MARK: - ClipboardSyncDelegate
    
    public func clipboardDidChangeLocally(content: String) {
        let item = ClipboardItem(content: content, sourceDeviceName: "MacBook (Local)", isOutgoing: true)
        clipboardHistory.insert(item, at: 0)
        if clipboardHistory.count > 50 {
            clipboardHistory.removeLast()
        }
        
        let packet = NetworkPacket.createClipboardPacket(content: content)
        for dev in devices where dev.pairingState == .paired && dev.isReachable {
            sendPacket(packet, to: dev)
        }
    }
    
    public func clipboardDidReceiveRemote(content: String, from deviceName: String) {
        let item = ClipboardItem(content: content, sourceDeviceName: deviceName, isOutgoing: false)
        clipboardHistory.insert(item, at: 0)
        if clipboardHistory.count > 50 {
            clipboardHistory.removeLast()
        }
    }
    
    // MARK: - FileShareDelegate
    
    public func fileShareDidStartTransfer(_ item: TransferItem) {
        if !transfers.contains(where: { $0.id == item.id }) {
            transfers.insert(item, at: 0)
        }
        objectWillChange.send()
    }
    
    public func fileShareDidUpdateTransfer(_ item: TransferItem) {
        objectWillChange.send()
    }
    
    public func fileShareDidFinishTransfer(_ item: TransferItem, success: Bool) {
        objectWillChange.send()
    }
    
    public func fileShareDidReceiveText(_ text: String, from deviceName: String) {
        clipboardService.handleIncomingClipboard(content: text, fromDeviceName: deviceName)
    }
    
    public func fileShareDidReceiveURL(_ url: URL, from deviceName: String) {
        print("[FileShare] Received URL: \(url) from \(deviceName)")
    }
}
