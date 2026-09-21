//
//  ClipboardItem.swift
//  SyncBridge
//

import Foundation

public struct ClipboardItem: Identifiable, Codable, Equatable {
    public let id: String
    public let content: String
    public let timestamp: Date
    public let sourceDeviceName: String
    public let isOutgoing: Bool
    
    public init(
        id: String = UUID().uuidString,
        content: String,
        timestamp: Date = Date(),
        sourceDeviceName: String,
        isOutgoing: Bool
    ) {
        self.id = id
        self.content = content
        self.timestamp = timestamp
        self.sourceDeviceName = sourceDeviceName
        self.isOutgoing = isOutgoing
    }
    
    public var preview: String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > 120 {
            return String(trimmed.prefix(120)) + "..."
        }
        return trimmed
    }
}
