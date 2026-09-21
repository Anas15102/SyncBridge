//
//  PairingManager.swift
//  SyncBridge
//

import Foundation

public protocol PairingManagerDelegate: AnyObject {
    func pairingDidUpdate(device: RemoteDevice)
    func incomingPairRequestReceived(from device: RemoteDevice)
}

public class PairingManager {
    public weak var delegate: PairingManagerDelegate?
    private let pairedDevicesKey = "syncbridge_paired_device_ids"
    private var pairedDeviceIds: Set<String> = []
    
    public init() {
        loadPairedDevices()
    }
    
    private func loadPairedDevices() {
        if let array = UserDefaults.standard.stringArray(forKey: pairedDevicesKey) {
            pairedDeviceIds = Set(array)
        }
    }
    
    private func savePairedDevices() {
        UserDefaults.standard.set(Array(pairedDeviceIds), forKey: pairedDevicesKey)
    }
    
    public func isPaired(deviceId: String) -> Bool {
        return pairedDeviceIds.contains(deviceId)
    }
    
    public func requestPairing(device: RemoteDevice, sender: (NetworkPacket) -> Void) {
        device.pairingState = .pairingRequested
        let packet = NetworkPacket.createPairPacket(pair: true)
        sender(packet)
        delegate?.pairingDidUpdate(device: device)
    }
    
    public func acceptPairing(device: RemoteDevice, sender: (NetworkPacket) -> Void) {
        pairedDeviceIds.insert(device.id)
        savePairedDevices()
        device.pairingState = .paired
        
        let packet = NetworkPacket.createPairPacket(pair: true)
        sender(packet)
        delegate?.pairingDidUpdate(device: device)
    }
    
    public func rejectPairing(device: RemoteDevice, sender: (NetworkPacket) -> Void) {
        pairedDeviceIds.remove(device.id)
        savePairedDevices()
        device.pairingState = .unpaired
        
        let packet = NetworkPacket.createPairPacket(pair: false)
        sender(packet)
        delegate?.pairingDidUpdate(device: device)
    }
    
    public func unpair(device: RemoteDevice, sender: (NetworkPacket) -> Void) {
        pairedDeviceIds.remove(device.id)
        savePairedDevices()
        device.pairingState = .unpaired
        
        let packet = NetworkPacket.createPairPacket(pair: false)
        sender(packet)
        delegate?.pairingDidUpdate(device: device)
    }
    
    public func handlePairPacket(_ packet: NetworkPacket, for device: RemoteDevice, sender: (NetworkPacket) -> Void) {
        let isPair = packet.bool(for: "pair") ?? false
        
        if isPair {
            if isPaired(deviceId: device.id) {
                // Already paired, acknowledge
                device.pairingState = .paired
                delegate?.pairingDidUpdate(device: device)
            } else if device.pairingState == .pairingRequested {
                // The peer accepted our request
                pairedDeviceIds.insert(device.id)
                savePairedDevices()
                device.pairingState = .paired
                delegate?.pairingDidUpdate(device: device)
            } else {
                // Peer is requesting to pair with us
                device.pairingState = .incomingPairRequest
                delegate?.incomingPairRequestReceived(from: device)
            }
        } else {
            // Unpair packet
            pairedDeviceIds.remove(device.id)
            savePairedDevices()
            device.pairingState = .unpaired
            delegate?.pairingDidUpdate(device: device)
        }
    }
}
