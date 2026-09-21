//
//  FileTransferService.swift
//  SyncBridge
//

import Foundation
import Network

public protocol FileTransferDelegate: AnyObject {
    func fileTransferDidProgress(itemId: String, bytesTransferred: Int64, totalBytes: Int64)
    func fileTransferDidComplete(itemId: String, success: Bool, fileURL: URL?, error: String?)
}

public class FileTransferService {
    public weak var delegate: FileTransferDelegate?
    private let queue = DispatchQueue(label: "com.syncbridge.filetransfer", qos: .userInitiated)
    private var activeListeners: [String: NWListener] = [:]
    private var activeConnections: [String: NWConnection] = [:]
    
    public init() {}
    
    // MARK: - Sending Files
    
    public func sendStreamToFileServer(
        fileURL: URL,
        to host: String,
        port: UInt16,
        fileSize: Int64,
        transferId: String
    ) {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
            let nwHost = NWEndpoint.Host(host)
            let params = NWParameters.tcp
            let connection = NWConnection(host: nwHost, port: nwPort, using: params)
            self.activeConnections[transferId] = connection
            
            connection.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    print("[FileTransfer] Connected outbound to Android at \(host):\(port)")
                    self.streamFile(fileURL: fileURL, fileSize: fileSize, to: connection, transferId: transferId)
                case .failed(let error):
                    self.notifyFailure(transferId: transferId, error: error.localizedDescription)
                default:
                    break
                }
            }
            connection.start(queue: self.queue)
        }
    }

    public func sendFile(
        fileURL: URL,
        to host: String,
        controlConnection: NWConnection?,
        transferItem: TransferItem,
        completion: @escaping (Bool, UInt16?) -> Void
    ) {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            do {
                let fileAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
                let fileSize = fileAttributes[.size] as? Int64 ?? 0
                
                // Find an open port dynamically using .any
                var assignedPort: UInt16? = nil
                var payloadListener: NWListener? = nil
                
                let params = NWParameters.tcp
                params.allowLocalEndpointReuse = true
                
                if let listener = try? NWListener(using: params, on: .any) {
                    payloadListener = listener
                }
                
                guard let listener = payloadListener else {
                    DispatchQueue.main.async {
                        self.delegate?.fileTransferDidComplete(itemId: transferItem.id, success: false, fileURL: fileURL, error: "Count not create listener")
                    }
                    completion(false, nil)
                    return
                }
                
                let transferId = transferItem.id
                self.activeListeners[transferId] = listener
                
                listener.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready:
                        assignedPort = listener.port?.rawValue
                        print("[FileTransfer] Payload server ready on port \(assignedPort ?? 0)")
                        // We must call completion HERE once port is assigned and ready
                        completion(true, assignedPort)
                    case .failed(let error):
                        print("[FileTransfer] Payload listener failed: \(error)")
                        self?.cleanupTransfer(transferId: transferId)
                        completion(false, nil)
                    default:
                        break
                    }
                }
                
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self = self else { return }
                    self.activeConnections[transferId] = connection
                    connection.start(queue: self.queue)
                    
                    connection.stateUpdateHandler = { state in
                        if case .ready = state {
                            self.streamFile(fileURL: fileURL, fileSize: fileSize, to: connection, transferId: transferId)
                        }
                    }
                }
                
                listener.start(queue: queue)
                
            } catch {
                DispatchQueue.main.async {
                    self.delegate?.fileTransferDidComplete(itemId: transferItem.id, success: false, fileURL: fileURL, error: error.localizedDescription)
                }
                completion(false, nil)
            }
        }
    }
    
    private func streamFile(fileURL: URL, fileSize: Int64, to connection: NWConnection, transferId: String) {
        guard let fileHandle = try? FileHandle(forReadingFrom: fileURL) else {
            notifyFailure(transferId: transferId, error: "Could not open file for reading")
            return
        }
        
        var totalBytesSent: Int64 = 0
        let chunkSize = 64 * 1024 // 64 KB chunks
        
        func sendNextChunk() {
            let data = fileHandle.readData(ofLength: chunkSize)
            if data.isEmpty {
                // Send final EOF marker and allow connection to close gracefully
                connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
                    try? fileHandle.close()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        self?.cleanupTransfer(transferId: transferId)
                    }
                    DispatchQueue.main.async {
                        self?.delegate?.fileTransferDidComplete(itemId: transferId, success: true, fileURL: fileURL, error: nil)
                    }
                })
                return
            }
            
            connection.send(content: data, isComplete: false, completion: .contentProcessed { [weak self] error in
                guard let self = self else { return }
                if let error = error {
                    try? fileHandle.close()
                    self.notifyFailure(transferId: transferId, error: error.localizedDescription)
                    return
                }
                
                totalBytesSent += Int64(data.count)
                DispatchQueue.main.async {
                    self.delegate?.fileTransferDidProgress(itemId: transferId, bytesTransferred: totalBytesSent, totalBytes: fileSize)
                }
                
                sendNextChunk()
            })
        }
        
        sendNextChunk()
    }
    
    // MARK: - Receiving Files
    
    private class ReceiveSession {
        let transferId: String
        let fileHandle: FileHandle
        let targetURL: URL
        let fileSize: Int64
        var bytesReceived: Int64 = 0
        
        init(transferId: String, fileHandle: FileHandle, targetURL: URL, fileSize: Int64) {
            self.transferId = transferId
            self.fileHandle = fileHandle
            self.targetURL = targetURL
            self.fileSize = fileSize
        }
    }
    
    public func receiveFile(
        from host: String,
        port: UInt16,
        filename: String,
        fileSize: Int64,
        transferId: String,
        destinationDirectory: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
    ) {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                self.notifyFailure(transferId: transferId, error: "Invalid port \(port)")
                return
            }
            
            let nwHost = NWEndpoint.Host(host)
            let params = NWParameters.tcp
            let connection = NWConnection(host: nwHost, port: nwPort, using: params)
            self.activeConnections[transferId] = connection
            
            let targetURL = self.uniqueFileURL(for: filename, in: destinationDirectory)
            FileManager.default.createFile(atPath: targetURL.path, contents: nil, attributes: nil)
            
            guard let fileHandle = try? FileHandle(forWritingTo: targetURL) else {
                self.notifyFailure(transferId: transferId, error: "Could not create destination file: \(targetURL.path)")
                return
            }
            
            let session = ReceiveSession(
                transferId: transferId,
                fileHandle: fileHandle,
                targetURL: targetURL,
                fileSize: fileSize
            )
            
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    print("[FileTransfer] Connected to receive payload from \(host):\(port)")
                    self.readPayloadChunk(connection: connection, session: session)
                case .failed(let error):
                    try? fileHandle.close()
                    self.notifyFailure(transferId: transferId, error: error.localizedDescription)
                default:
                    break
                }
            }
            
            connection.start(queue: self.queue)
        }
    }
    
    private func readPayloadChunk(
        connection: NWConnection,
        session: ReceiveSession
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            
            if let data = data, !data.isEmpty {
                session.fileHandle.write(data)
                session.bytesReceived += Int64(data.count)
                let currentTotal = session.bytesReceived
                let totalSize = session.fileSize
                let tid = session.transferId
                DispatchQueue.main.async {
                    self.delegate?.fileTransferDidProgress(itemId: tid, bytesTransferred: currentTotal, totalBytes: totalSize)
                }
            }
            
            if isComplete || (session.fileSize > 0 && session.bytesReceived >= session.fileSize) {
                try? session.fileHandle.close()
                self.cleanupTransfer(transferId: session.transferId)
                let finalURL = session.targetURL
                let tid = session.transferId
                DispatchQueue.main.async {
                    self.delegate?.fileTransferDidComplete(itemId: tid, success: true, fileURL: finalURL, error: nil)
                }
            } else if let error = error {
                try? session.fileHandle.close()
                self.notifyFailure(transferId: session.transferId, error: error.localizedDescription)
            } else {
                self.readPayloadChunk(connection: connection, session: session)
            }
        }
    }
    
    private func uniqueFileURL(for filename: String, in directory: URL) -> URL {
        var targetURL = directory.appendingPathComponent(filename)
        var counter = 1
        let nameWithoutExt = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        
        while FileManager.default.fileExists(atPath: targetURL.path) {
            let newName = ext.isEmpty ? "\(nameWithoutExt) (\(counter))" : "\(nameWithoutExt) (\(counter)).\(ext)"
            targetURL = directory.appendingPathComponent(newName)
            counter += 1
        }
        return targetURL
    }
    
    private func notifyFailure(transferId: String, error: String) {
        cleanupTransfer(transferId: transferId)
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.fileTransferDidComplete(itemId: transferId, success: false, fileURL: nil, error: error)
        }
    }
    
    private func cleanupTransfer(transferId: String) {
        activeConnections[transferId]?.cancel()
        activeConnections.removeValue(forKey: transferId)
        activeListeners[transferId]?.cancel()
        activeListeners.removeValue(forKey: transferId)
    }
}
