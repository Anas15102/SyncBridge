package com.syncbridge.android

import android.app.Activity
import android.content.ClipboardManager
import android.content.Context
import android.os.Bundle
import android.util.Log

class ClipboardSenderActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        
        try {
            val clipboardManager = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            val action = intent.action

            if (action == "COPY_TO_CLIPBOARD") {
                // Incoming from Mac fallback
                val content = intent.getStringExtra("content_to_copy")
                if (content != null) {
                    val clip = android.content.ClipData.newPlainText("SyncBridge", content)
                    clipboardManager.setPrimaryClip(clip)
                    Log.d("ClipboardSender", "Successfully pasted received content to clipboard.")
                }
            } else if (action == "SEND_SPECIFIC_TEXT") {
                // Sending specific text (from Accessibility detecting a copy)
                val content = intent.getStringExtra("text_to_send")
                if (content != null && content.isNotEmpty()) {
                    val manager = getSystemService(Context.NOTIFICATION_SERVICE) as android.app.NotificationManager
                    manager.cancel(1718) // Cancel the prompt notification
                    
                    Log.d("ClipboardSender", "Sending explicitly intercepted text: $content")
                    SyncForegroundService.networkEngine?.devices?.value?.filter { it.isPaired }?.forEach { device ->
                        SyncForegroundService.networkEngine?.sendPacket(device, NetworkPacket.clipboardPacket(content))
                    }
                }
            } else {
                // Read directly from current system clipboard to send
                val item = clipboardManager.primaryClip?.getItemAt(0)
                val text = item?.text?.toString()
                
                if (text != null && text.isNotEmpty()) {
                    Log.d("ClipboardSender", "User tapped 'Send Clipboard': '\$text'")
                    
                    // Dispatch exactly mapped packet
                    SyncForegroundService.networkEngine?.devices?.value?.filter { it.isPaired }?.forEach { device ->
                        SyncForegroundService.networkEngine?.sendPacket(device, NetworkPacket.clipboardPacket(text))
                    }
                } else {
                    Log.d("ClipboardSender", "Clipboard is empty")
                }
            }
        } catch (e: Exception) {
            Log.e("ClipboardSender", "Failed to interact with clipboard upon action launch: \$e")
        }

        // Close the transparent activity instantly so the user stays in their current app
        finish()
    }
}
