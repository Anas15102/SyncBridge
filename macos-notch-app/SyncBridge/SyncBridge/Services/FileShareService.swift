//
//  FileShareService.swift
//  SyncBridge
//

import Foundation
import AppKit
import UserNotifications


public protocol FileShareDelegate: AnyObject {
    func fileShareDidStartTransfer(_ item: TransferItem)
    func fileShareDidUpdateTransfer(_ item: TransferItem)
    func fileShareDidFinishTransfer(_ item: TransferItem, success: Bool)
    func fileShareDidReceiveText(_ text: String, from deviceName: String)
    func fileShareDidReceiveURL(_ url: URL, from deviceName: String)
}

public class FileShareService: FileTransferDelegate {
    public weak var delegate: FileShareDelegate?
    private let transferEngine = FileTransferService()
    public private(set) var activeTransfers: [String: TransferItem] = [:]
    private var activeOutgoingFiles: [String: (URL, Int64, String)] = [:] // filename -> (url, size, itemId)
    
    public init() {
        transferEngine.delegate = self    }

    public func requestNotificationPermission() {
        // Prevent crash when running as raw Swift executable without a bundle ID
        guard Bundle.main.bundleIdentifier != nil else { return }

        DispatchQueue.main.async {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, error in
                if let error = error {
                    print("[FileShare] Notification authorization error: \(error)")
                }
            }
        }
    }

    // MARK: - Sending
    
    public func sendFile(
        fileURL: URL,
        to device: RemoteDevice,
        packetSender: @escaping (NetworkPacket) -> Void
    ) -> TransferItem? {
        guard let attr = try? FileManager.default.attributesOfItem(atPath: fileURL.path) else { return nil }
        let fileSize = attr[.size] as? Int64 ?? 0
        let filename = fileURL.lastPathComponent
        
        let item = TransferItem(
            filename: filename,
            fileSize: fileSize,
            status: .inProgress,
            isIncoming: false,
            localURL: fileURL,
            remoteDeviceName: device.name
        )
        
        activeTransfers[item.id] = item
        delegate?.fileShareDidStartTransfer(item)
        
        // Save outgoing mapping so when Android replies with its server port, we connect outbound to it
        activeOutgoingFiles[filename] = (fileURL, fileSize, item.id)
        
        let packet = NetworkPacket(
            type: PacketTypes.shareRequest,
            body: [
                "filename": filename,
                "numberOfFiles": 1,
                "totalPayloadSize": fileSize,
                "open": false
            ],
            payloadSize: fileSize,
            payloadTransferInfo: nil
        )
        packetSender(packet)
        return item
    }
    
    public func sendText(_ text: String, to device: RemoteDevice, packetSender: (NetworkPacket) -> Void) {
        let packet = NetworkPacket.createShareTextPacket(text: text)
        packetSender(packet)
    }
    
    public func sendURL(_ url: String, to device: RemoteDevice, packetSender: (NetworkPacket) -> Void) {
        let packet = NetworkPacket.createShareUrlPacket(url: url)
        packetSender(packet)
    }
    
    // MARK: - Receiving
    
    public func handleIncomingSharePacket(_ packet: NetworkPacket, from device: RemoteDevice) {
        let filename = packet.string(for: "filename") ?? "SharedFile_\(UUID().uuidString.prefix(6)).dat"
        let fileSize = packet.payloadSize ?? 0
        
        if let port = packet.payloadPort {
            // Check if this is an ACK for our outgoing send file request
            if let (fileURL, size, itemId) = activeOutgoingFiles[filename] {
                activeOutgoingFiles.removeValue(forKey: filename)
                transferEngine.sendStreamToFileServer(
                    fileURL: fileURL,
                    to: device.ipAddress,
                    port: port,
                    fileSize: size,
                    transferId: itemId
                )
            } else {
                let item = TransferItem(
                    filename: filename,
                    fileSize: fileSize,
                    status: .inProgress,
                    isIncoming: true,
                    remoteDeviceName: device.name
                )
                
                activeTransfers[item.id] = item
                delegate?.fileShareDidStartTransfer(item)
                
                transferEngine.receiveFile(
                    from: device.ipAddress,
                    port: port,
                    filename: filename,
                    fileSize: fileSize,
                    transferId: item.id
                )
            }
        } else if let text = packet.string(for: "text") {
            delegate?.fileShareDidReceiveText(text, from: device.name)
            postNotification(title: "Text Received from \(device.name)", body: text)
        } else if let urlStr = packet.string(for: "url"), let url = URL(string: urlStr) {
            delegate?.fileShareDidReceiveURL(url, from: device.name)
            postNotification(title: "Link Received from \(device.name)", body: urlStr)
            NSWorkspace.shared.open(url)
        }
    }
    
    // MARK: - FileTransferDelegate
    
    public func fileTransferDidProgress(itemId: String, bytesTransferred: Int64, totalBytes: Int64) {
        guard let item = activeTransfers[itemId] else { return }
        item.bytesTransferred = bytesTransferred
        delegate?.fileShareDidUpdateTransfer(item)
    }
    
    public func fileTransferDidComplete(itemId: String, success: Bool, fileURL: URL?, error: String?) {
        guard let item = activeTransfers[itemId] else { return }
        item.status = success ? .completed : .failed
        item.errorMessage = error
        
        if success, fileURL != nil {
            let actionText = item.isIncoming ? "Saved to Downloads" : "Sent successfully"
            postNotification(
                title: "File Transfer Complete",
                body: "\(item.filename) (\(item.formattedSize)) - \(actionText)"
            )
        } else if !success {
            postNotification(
                title: "Transfer Failed",
                body: "Could not transfer \(item.filename): \(error ?? "Unknown error")"
            )
        }
        
        delegate?.fileShareDidFinishTransfer(item, success: success)
    }
    
    private func postNotification(title: String, body: String) {
        // Guard against crash when no bundle (swift run debug context)
        guard Bundle.main.bundleIdentifier != nil else {
            print("[Notification] \(title): \(body)")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}
