//
//  TransferItem.swift
//  SyncBridge
//

import Foundation

public enum TransferStatus: String, Codable {
    case pending
    case inProgress
    case completed
    case failed
    case cancelled
}

public class TransferItem: Identifiable, ObservableObject {
    public let id: String
    public let filename: String
    public let fileSize: Int64
    @Published public var bytesTransferred: Int64
    @Published public var status: TransferStatus
    @Published public var errorMessage: String?
    public let isIncoming: Bool
    public let localURL: URL?
    public let remoteDeviceName: String
    public let date: Date
    
    public init(
        id: String = UUID().uuidString,
        filename: String,
        fileSize: Int64,
        bytesTransferred: Int64 = 0,
        status: TransferStatus = .pending,
        errorMessage: String? = nil,
        isIncoming: Bool,
        localURL: URL? = nil,
        remoteDeviceName: String,
        date: Date = Date()
    ) {
        self.id = id
        self.filename = filename
        self.fileSize = fileSize
        self.bytesTransferred = bytesTransferred
        self.status = status
        self.errorMessage = errorMessage
        self.isIncoming = isIncoming
        self.localURL = localURL
        self.remoteDeviceName = remoteDeviceName
        self.date = date
    }
    
    public var progress: Double {
        guard fileSize > 0 else { return 0 }
        return min(1.0, max(0.0, Double(bytesTransferred) / Double(fileSize)))
    }
    
    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }
    
    public var formattedTransferred: String {
        ByteCountFormatter.string(fromByteCount: bytesTransferred, countStyle: .file)
    }
}
