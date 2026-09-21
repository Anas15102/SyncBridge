//
//  TCPClient.swift
//  SyncBridge
//

import Foundation
import Network

public protocol TCPClientDelegate: AnyObject {
    func tcpClientDidConnect(to address: String)
    func tcpClientDidDisconnect(from address: String, error: Error?)
    func tcpClientDidReceivePacket(_ packet: NetworkPacket, from address: String)
}

public class TCPClient {
    public weak var delegate: TCPClientDelegate?
    private var connection: NWConnection?
    private var buffer = Data()
    private let clientQueue = DispatchQueue(label: "com.syncbridge.tcp.client", qos: .userInitiated)
    public private(set) var isConnected: Bool = false
    public let host: String
    public let port: UInt16
    private var pendingPackets: [(NetworkPacket, ((Bool) -> Void)?)] = []
    private var isConnecting: Bool = false
    
    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }
    
    public func connect() {
        guard !isConnected && !isConnecting else { return }
        isConnecting = true
        
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let nwHost = NWEndpoint.Host(host)
        
        let params = NWParameters.tcp
        let conn = NWConnection(host: nwHost, port: nwPort, using: params)
        self.connection = conn
        
        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                print("[TCPClient] Connected to \(self.host):\(self.port)")
                self.isConnected = true
                self.isConnecting = false
                self.flushPendingPackets()
                DispatchQueue.main.async {
                    self.delegate?.tcpClientDidConnect(to: self.host)
                }
                self.receiveNext()
            case .failed(let error):
                print("[TCPClient] Connection failed to \(self.host):\(self.port) - \(error)")
                self.disconnect(error: error)
            case .cancelled:
                self.isConnecting = false
                self.disconnect(error: nil)
            default:
                break
            }
        }
        
        conn.start(queue: clientQueue)
    }
    
    private func flushPendingPackets() {
        clientQueue.async { [weak self] in
            guard let self = self, let conn = self.connection, self.isConnected else { return }
            let packetsToSend = self.pendingPackets
            self.pendingPackets.removeAll()
            
            for (packet, completion) in packetsToSend {
                guard let data = packet.toData() else {
                    completion?(false)
                    continue
                }
                conn.send(content: data, completion: .contentProcessed { error in
                    completion?(error == nil)
                })
            }
        }
    }
    
    public func disconnect(error: Error? = nil) {
        isConnecting = false
        guard isConnected || connection != nil else { return }
        isConnected = false
        connection?.cancel()
        connection = nil
        buffer.removeAll()
        
        let dropped = pendingPackets
        pendingPackets.removeAll()
        for (_, completion) in dropped {
            completion?(false)
        }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.tcpClientDidDisconnect(from: self.host, error: error)
        }
    }
    
    private func receiveNext() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            
            if let data = data, !data.isEmpty {
                self.processIncomingData(data)
            }
            
            if isComplete || error != nil {
                self.disconnect(error: error)
            } else if self.isConnected {
                self.receiveNext()
            }
        }
    }
    
    private func processIncomingData(_ incomingData: Data) {
        buffer.append(incomingData)
        
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let packetData = buffer.subdata(in: 0..<newlineIndex)
            buffer.removeSubrange(0...newlineIndex)
            
            if let packet = NetworkPacket.from(data: packetData) {
                DispatchQueue.main.async {
                    self.delegate?.tcpClientDidReceivePacket(packet, from: self.host)
                }
            }
        }
    }
    
    public func sendPacket(_ packet: NetworkPacket, completion: ((Bool) -> Void)? = nil) {
        clientQueue.async { [weak self] in
            guard let self = self else {
                completion?(false)
                return
            }
            
            if self.isConnected, let conn = self.connection {
                guard let data = packet.toData() else {
                    completion?(false)
                    return
                }
                conn.send(content: data, completion: .contentProcessed { error in
                    completion?(error == nil)
                })
            } else {
                self.pendingPackets.append((packet, completion))
                self.connect()
            }
        }
    }
}
