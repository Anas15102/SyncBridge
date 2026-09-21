//
//  TCPServer.swift
//  SyncBridge
//

import Foundation
import Network

public protocol TCPServerDelegate: AnyObject {
    func tcpServerDidReceivePacket(_ packet: NetworkPacket, from address: String, connection: NWConnection)
    func tcpServerConnectionStateChanged(isConnected: Bool, address: String)
}

public class TCPServer {
    public weak var delegate: TCPServerDelegate?
    private var listener: NWListener?
    private var activeConnections: [String: NWConnection] = [:]
    private var connectionBuffers: [String: Data] = [:]
    private let serverQueue = DispatchQueue(label: "com.syncbridge.tcp.server", qos: .userInitiated)
    public private(set) var activePort: UInt16 = PacketTypes.defaultTcpPort
    public private(set) var isRunning: Bool = false
    
    public init() {}
    
    public func start(preferredPort: UInt16 = PacketTypes.defaultTcpPort) {
        guard !isRunning else { return }
        
        var currentPort = preferredPort
        while currentPort <= PacketTypes.maxTcpPort {
            do {
                let params = NWParameters.tcp
                params.allowLocalEndpointReuse = true
                guard let nwPort = NWEndpoint.Port(rawValue: currentPort) else {
                    currentPort += 1
                    continue
                }
                
                let nwListener = try NWListener(using: params, on: nwPort)
                self.listener = nwListener
                self.activePort = currentPort
                
                nwListener.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready:
                        print("[TCPServer] Listening on TCP port \(currentPort)")
                        self?.isRunning = true
                    case .failed(let error):
                        print("[TCPServer] Listener failed with error: \(error)")
                        self?.stop()
                    case .cancelled:
                        self?.isRunning = false
                    default:
                        break
                    }
                }
                
                nwListener.newConnectionHandler = { [weak self] newConnection in
                    self?.handleNewConnection(newConnection)
                }
                
                nwListener.start(queue: serverQueue)
                break
            } catch {
                print("[TCPServer] Port \(currentPort) unavailable, trying next...")
                currentPort += 1
            }
        }
    }
    
    public func stop() {
        isRunning = false
        listener?.cancel()
        listener = nil
        
        for (_, conn) in activeConnections {
            conn.cancel()
        }
        activeConnections.removeAll()
        connectionBuffers.removeAll()
    }
    
    private func handleNewConnection(_ connection: NWConnection) {
        connection.start(queue: serverQueue)
        
        let rawAddress = extractIP(from: connection.endpoint)
        let remoteAddress = TCPServer.normalizeIP(rawAddress)
        activeConnections[remoteAddress] = connection
        connectionBuffers[remoteAddress] = Data()
        
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                print("[TCPServer] Accepted connection from \(remoteAddress)")
                DispatchQueue.main.async {
                    self.delegate?.tcpServerConnectionStateChanged(isConnected: true, address: remoteAddress)
                }
                self.receiveNextMessage(from: connection, address: remoteAddress)
            case .failed(let error):
                print("[TCPServer] Connection failed from \(remoteAddress): \(error)")
                self.cleanupConnection(remoteAddress)
            case .cancelled:
                self.cleanupConnection(remoteAddress)
            default:
                break
            }
        }
    }
    
    private func receiveNextMessage(from connection: NWConnection, address: String) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            
            if let data = data, !data.isEmpty {
                self.processIncomingData(data, from: address, connection: connection)
            }
            
            if isComplete || error != nil {
                self.cleanupConnection(address)
            } else {
                self.receiveNextMessage(from: connection, address: address)
            }
        }
    }
    
    private func processIncomingData(_ incomingData: Data, from address: String, connection: NWConnection) {
        var buffer = connectionBuffers[address] ?? Data()
        buffer.append(incomingData)
        
        // Find newline delimiters (0x0A)
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let packetData = buffer.subdata(in: 0..<newlineIndex)
            buffer.removeSubrange(0...newlineIndex)
            
            if let packet = NetworkPacket.from(data: packetData) {
                DispatchQueue.main.async {
                    self.delegate?.tcpServerDidReceivePacket(packet, from: address, connection: connection)
                }
            }
        }
        
        connectionBuffers[address] = buffer
    }
    
    private func cleanupConnection(_ address: String) {
        activeConnections[address]?.cancel()
        activeConnections.removeValue(forKey: address)
        connectionBuffers.removeValue(forKey: address)
        
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.tcpServerConnectionStateChanged(isConnected: false, address: address)
        }
    }
    
    public func sendPacket(_ packet: NetworkPacket, to address: String, completion: ((Bool) -> Void)? = nil) {
        guard let data = packet.toData() else {
            completion?(false)
            return
        }
        
        let normAddr = TCPServer.normalizeIP(address)
        if let conn = activeConnections[normAddr] {
            conn.send(content: data, completion: .contentProcessed { error in
                completion?(error == nil)
            })
        } else {
            // Need to open an outbound TCP connection if not active
            completion?(false)
        }
    }
    
    public func sendPacket(_ packet: NetworkPacket, on connection: NWConnection, completion: ((Bool) -> Void)? = nil) {
        guard let data = packet.toData() else {
            completion?(false)
            return
        }
        connection.send(content: data, completion: .contentProcessed { error in
            completion?(error == nil)
        })
    }
    
    public func registerConnection(_ connection: NWConnection, for address: String) {
        let normAddr = TCPServer.normalizeIP(address)
        activeConnections[normAddr] = connection
        if connectionBuffers[normAddr] == nil {
            connectionBuffers[normAddr] = Data()
        }
    }
    
    public static func normalizeIP(_ ip: String) -> String {
        var result = ip
        if result.hasPrefix("::ffff:") {
            result = String(result.dropFirst(7))
        }
        if let percentIdx = result.firstIndex(of: "%") {
            result = String(result[..<percentIdx])
        }
        return result
    }
    
    private func extractIP(from endpoint: NWEndpoint) -> String {
        switch endpoint {
        case .hostPort(let host, _):
            switch host {
            case .ipv4(let ip): return "\(ip)"
            case .ipv6(let ip): return "\(ip)"
            case .name(let name, _): return name
            @unknown default: return "\(host)"
            }
        default:
            return "unknown"
        }
    }
}
