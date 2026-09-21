//
//  FileShareView.swift
//  SyncBridge Notch
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FileShareView: View {
    @EnvironmentObject private var vm: BoringViewModel
    @ObservedObject private var appState = AppState.shared

    @State private var hostView: NSView?
    @State private var isProcessing = false
    @State private var lastSentFilename: String?
    
    private var pairedDevice: RemoteDevice? {
        appState.devices.first(where: { $0.pairingState == .paired })
    }

    var body: some View {
        dropArea
            .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data, .image], isTargeted: $vm.dropZoneTargeting) { providers in
                vm.dropEvent = true
                Task { await handleDrop(providers) }
                return true
            }
            .onTapGesture {
                Task {
                    await handleClick()
                }
            }
    }

    private var dropArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(
                    LinearGradient(colors: [Color.black.opacity(0.40), Color.black.opacity(0.25)], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(
                            vm.dropZoneTargeting
                                ? Color.accentColor.opacity(0.9)
                                : Color.white.opacity(0.12),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [10])
                        )
                )
                .shadow(color: Color.black.opacity(0.6), radius: 6, x: 0, y: 2)

            // Content
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(
                            vm.dropZoneTargeting ? 0.16 : 0.09
                        ))
                        .frame(width: 55, height: 55)

                    Image(systemName: pairedDevice != nil ? "iphone.and.arrow.forward" : "exclamationmark.triangle.fill")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 26, height: 26)
                        .foregroundStyle(
                            vm.dropZoneTargeting ? Color.accentColor : (pairedDevice != nil ? Color.green : Color.orange)
                        )
                        .scaleEffect(
                            vm.dropZoneTargeting ? 1.10 : 1.0
                        )
                        .animation(.spring(response: 0.36, dampingFraction: 0.7), value: vm.dropZoneTargeting)
                }

                if let device = pairedDevice {
                    Text("Beam to \(device.name)")
                        .font(.system(.headline, design: .rounded))
                        .foregroundColor(.white.opacity(0.9))
                        .lineLimit(1)
                    Text("Wi-Fi AirDrop to Android")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundColor(.green.opacity(0.8))
                } else {
                    Text("No Android Paired")
                        .font(.system(.headline, design: .rounded))
                        .foregroundColor(.white.opacity(0.8))
                    Text("Click to open Hub & Pair")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundColor(.orange.opacity(0.8))
                }
            }
            .padding(14)
            
            // Loading / Transfer overlay
            if isProcessing {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.black.opacity(0.5))
                    .overlay(
                        VStack(spacing: 4) {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(0.8)
                            if let name = lastSentFilename {
                                Text(name)
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundColor(.white)
                                    .lineLimit(1)
                            }
                        }
                    )
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Actions

    private func handleDrop(_ providers: [NSItemProvider]) async {
        isProcessing = true
        defer { isProcessing = false }

        guard let device = pairedDevice else {
            DispatchQueue.main.async {
                AppDelegate.shared?.openMainWindow()
            }
            return
        }

        for provider in providers {
            if let fileURL = await provider.extractFileURL() {
                let resolvedURL = fileURL.startAccessingSecurityScopedResource() ? fileURL : fileURL
                DispatchQueue.main.async {
                    self.lastSentFilename = resolvedURL.lastPathComponent
                    appState.sendFile(url: resolvedURL, to: device)
                }
                if fileURL != resolvedURL {
                    fileURL.stopAccessingSecurityScopedResource()
                }
            } else if let text = await provider.extractText() {
                DispatchQueue.main.async {
                    appState.sendText(text, to: device)
                }
            }
        }
    }
    
    private func handleClick() async {
        guard let device = pairedDevice else {
            DispatchQueue.main.async {
                AppDelegate.shared?.openMainWindow()
            }
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Beam to \(device.name)"

        if panel.runModal() == .OK {
            isProcessing = true
            for url in panel.urls {
                self.lastSentFilename = url.lastPathComponent
                appState.sendFile(url: url, to: device)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self.isProcessing = false
            }
        }
    }
}
