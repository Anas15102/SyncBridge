//
//  ClipboardSyncService.swift
//  SyncBridge
//

import Foundation
import AppKit

public protocol ClipboardSyncDelegate: AnyObject {
    func clipboardDidChangeLocally(content: String)
    func clipboardDidReceiveRemote(content: String, from deviceName: String)
}

public class ClipboardSyncService {
    public weak var delegate: ClipboardSyncDelegate?
    private var monitoringTimer: Timer?
    private var lastChangeCount: Int = NSPasteboard.general.changeCount
    private var lastReceivedContent: String = ""
    public var isEnabled: Bool = true
    
    public init() {}
    
    public func start() {
        stop()
        lastChangeCount = NSPasteboard.general.changeCount
        
        // Poll pasteboard every 400ms for swift, low-latency sync
        monitoringTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.checkLocalPasteboard()
        }
    }
    
    public func stop() {
        monitoringTimer?.invalidate()
        monitoringTimer = nil
    }
    
    private func checkLocalPasteboard() {
        guard isEnabled else { return }
        
        let currentChangeCount = NSPasteboard.general.changeCount
        guard currentChangeCount != lastChangeCount else { return }
        lastChangeCount = currentChangeCount
        
        guard let content = NSPasteboard.general.string(forType: .string) else { return }
        guard !content.isEmpty else { return }
        
        // Prevent echo if this was received from remote
        if content == lastReceivedContent {
            return
        }
        
        delegate?.clipboardDidChangeLocally(content: content)
    }
    
    public func handleIncomingClipboard(content: String, fromDeviceName: String) {
        guard isEnabled else { return }
        guard !content.isEmpty else { return }
        
        lastReceivedContent = content
        
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
        lastChangeCount = NSPasteboard.general.changeCount
        
        delegate?.clipboardDidReceiveRemote(content: content, from: fromDeviceName)
    }
}
