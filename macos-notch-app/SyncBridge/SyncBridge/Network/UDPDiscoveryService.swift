//
//  UDPDiscoveryService.swift
//  SyncBridge
//

import Foundation
import Network

public protocol UDPDiscoveryDelegate: AnyObject {
    func udpDiscoveryDidDiscoverDevice(identity: DeviceIdentity, fromAddress: String)
}

public class UDPDiscoveryService {
    public weak var delegate: UDPDiscoveryDelegate?
    private var isRunning: Bool = false
    private var listenSocket: Int32 = -1
    private var receiveQueue = DispatchQueue(label: "com.syncbridge.udp.receive", qos: .userInitiated)
    private var broadcastTimer: DispatchSourceTimer?
    private var myIdentity: DeviceIdentity
    
    public init(identity: DeviceIdentity = DeviceIdentity.currentDevice) {
        self.myIdentity = identity
    }
    
    public func updateIdentity(_ identity: DeviceIdentity) {
        self.myIdentity = identity
    }
    
    public func start() {
        guard !isRunning else { return }
        isRunning = true
        
        setupListenSocket()
        startReceiving()
        startBroadcastTimer()
        
        // Broadcast immediately
        broadcastIdentity()
    }
    
    public func stop() {
        guard isRunning else { return }
        isRunning = false
        
        broadcastTimer?.cancel()
        broadcastTimer = nil
        
        if listenSocket >= 0 {
            close(listenSocket)
            listenSocket = -1
        }
    }
    
    private func setupListenSocket() {
        listenSocket = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard listenSocket >= 0 else {
            print("[UDP] Failed to create socket")
            return
        }
        
        var reuseOn: Int32 = 1
        setsockopt(listenSocket, SOL_SOCKET, SO_REUSEADDR, &reuseOn, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(listenSocket, SOL_SOCKET, SO_REUSEPORT, &reuseOn, socklen_t(MemoryLayout<Int32>.size))
        
        var broadcastOn: Int32 = 1
        setsockopt(listenSocket, SOL_SOCKET, SO_BROADCAST, &broadcastOn, socklen_t(MemoryLayout<Int32>.size))
        
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(PacketTypes.defaultUdpPort).bigEndian
        addr.sin_addr.s_addr = in_addr_t(INADDR_ANY).bigEndian
        
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenSocket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        
        if bindResult < 0 {
            print("[UDP] Failed to bind to port \(PacketTypes.defaultUdpPort)")
        } else {
            print("[UDP] Successfully listening on UDP port \(PacketTypes.defaultUdpPort)")
        }
    }
    
    private func startReceiving() {
        receiveQueue.async { [weak self] in
            guard let self = self else { return }
            var buffer = [UInt8](repeating: 0, count: 65535)
            
            while self.isRunning && self.listenSocket >= 0 {
                var clientAddr = sockaddr_in()
                var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                
                let bytesRead = withUnsafeMutablePointer(to: &clientAddr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(self.listenSocket, &buffer, buffer.count, 0, $0, &addrLen)
                    }
                }
                
                guard bytesRead > 0 else { continue }
                
                let ipStr = String(cString: inet_ntoa(clientAddr.sin_addr))
                let data = Data(buffer[0..<bytesRead])
                
                self.processIncomingPacket(data: data, fromAddress: ipStr)
            }
        }
    }
    
    private func processIncomingPacket(data: Data, fromAddress: String) {
        guard let packet = NetworkPacket.from(data: data) else { return }
        
        if packet.type == PacketTypes.identity {
            guard let devId = packet.string(for: "deviceId"),
                  let devName = packet.string(for: "deviceName") else { return }
            
            // Ignore own broadcast
            if devId == myIdentity.deviceId { return }
            
            let devType = packet.string(for: "deviceType") ?? "phone"
            let protoVer = packet.int(for: "protocolVersion") ?? PacketTypes.defaultProtocolVersion
            let inCaps = packet.stringArray(for: "incomingCapabilities") ?? []
            let outCaps = packet.stringArray(for: "outgoingCapabilities") ?? []
            let tcpPort = packet.int(for: "tcpPort") ?? Int(PacketTypes.defaultTcpPort)
            
            let remoteIdentity = DeviceIdentity(
                deviceId: devId,
                deviceName: devName,
                deviceType: devType,
                protocolVersion: protoVer,
                incomingCapabilities: inCaps,
                outgoingCapabilities: outCaps,
                tcpPort: tcpPort
            )
            
            // Immediately reply with our identity directly to the sender's UDP IP
            self.sendDirectIdentity(to: fromAddress)
            
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.udpDiscoveryDidDiscoverDevice(identity: remoteIdentity, fromAddress: fromAddress)
            }
        }
    }
    
    public func broadcastIdentity() {
        let packet = NetworkPacket.createIdentityPacket(identity: myIdentity)
        guard let data = packet.toData() else { return }
        
        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else { return }
        defer { close(sock) }
        
        var broadcastOn: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &broadcastOn, socklen_t(MemoryLayout<Int32>.size))
        
        // Send to general broadcast
        sendUDPData(data, to: "255.255.255.255", on: sock)
        
        // Also send to all local interface broadcast addresses
        for broadcastAddr in getLocalBroadcastAddresses() {
            sendUDPData(data, to: broadcastAddr, on: sock)
        }
    }
    
    public func sendDirectIdentity(to ipAddress: String) {
        let packet = NetworkPacket.createIdentityPacket(identity: myIdentity)
        guard let data = packet.toData() else { return }
        
        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else { return }
        defer { close(sock) }
        
        sendUDPData(data, to: ipAddress, on: sock)
    }
    
    private func sendUDPData(_ data: Data, to ipAddress: String, on sock: Int32) {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(PacketTypes.defaultUdpPort).bigEndian
        addr.sin_addr.s_addr = inet_addr(ipAddress)
        
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    _ = sendto(sock, baseAddress, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }
    
    private func getLocalBroadcastAddresses() -> [String] {
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        
        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            let addr = ptr.pointee.ifa_addr.pointee
            
            // Check for IPv4, UP, and BROADCAST flags
            if (flags & (IFF_UP | IFF_BROADCAST | IFF_RUNNING)) == (IFF_UP | IFF_BROADCAST | IFF_RUNNING) &&
                addr.sa_family == UInt8(AF_INET) {
                if let dstAddr = ptr.pointee.ifa_dstaddr {
                    var dstSockAddr = dstAddr.pointee
                    var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    withUnsafePointer(to: &dstSockAddr) {
                        $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                            var saddr = sin.pointee.sin_addr
                            inet_ntop(AF_INET, &saddr, &buffer, socklen_t(INET_ADDRSTRLEN))
                        }
                    }
                    let ipStr = String(cString: buffer)
                    if !ipStr.isEmpty && !addresses.contains(ipStr) {
                        addresses.append(ipStr)
                    }
                }
            }
        }
        return addresses
    }
    
    private func startBroadcastTimer() {
        let timer = DispatchSource.makeTimerSource(queue: receiveQueue)
        timer.schedule(deadline: .now() + 1.0, repeating: 5.0)
        timer.setEventHandler { [weak self] in
            self?.broadcastIdentity()
        }
        timer.resume()
        self.broadcastTimer = timer
    }
}
