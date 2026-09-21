package com.syncbridge.android

import android.accessibilityservice.AccessibilityService
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import androidx.core.app.NotificationCompat

class SyncAccessibilityService : AccessibilityService() {
    private lateinit var clipboardManager: ClipboardManager
    private var lastReceivedClip = ""
    private var lastNotifiedClip = ""
    private var isListening = false

    private val clipListener = ClipboardManager.OnPrimaryClipChangedListener {
        checkAndNotifyClipboard()
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        Log.d("SyncAccessibility", "Accessibility service connected")
        clipboardManager = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        
        try {
            clipboardManager.addPrimaryClipChangedListener(clipListener)
            isListening = true
        } catch (e: Exception) {
            Log.e("SyncAccessibility", "Error starting listener: $e")
        }

        // When Mac sends text, write it to clipboard directly (AccessibilityService has permissions)
        SyncForegroundService.networkEngine?.addClipboardListener { content ->
            Log.d("SyncAccessibility", "Received clip from Mac: $content")
            lastReceivedClip = content
            lastNotifiedClip = content
            val clip = ClipData.newPlainText("SyncBridge", content)
            try {
                clipboardManager.setPrimaryClip(clip)
            } catch (e: Exception) {
                Log.e("SyncAccessibility", "Failed to write clipboard: $e")
            }
        }
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // When user copies or changes focus/text, check if clipboard changed
        if (event == null) return
        
        // Listen to window changes or click actions (like tapping 'Copy' popup menu)
        when (event.eventType) {
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED,
            AccessibilityEvent.TYPE_VIEW_CLICKED,
            AccessibilityEvent.TYPE_VIEW_TEXT_SELECTION_CHANGED -> {
                checkAndNotifyClipboard()
            }
        }
    }

    private fun checkAndNotifyClipboard() {
        try {
            if (!::clipboardManager.isInitialized) return
            if (!clipboardManager.hasPrimaryClip()) return
            val item = clipboardManager.primaryClip?.getItemAt(0) ?: return
            val text = item.text?.toString() ?: return

            if (text.isEmpty() || text == lastReceivedClip || text == lastNotifiedClip) {
                return
            }

            lastNotifiedClip = text
            Log.d("SyncAccessibility", "Detected copy event on Android: '$text'. Showing notification prompt.")
            showSendToMacNotification(text)
        } catch (e: Exception) {
            Log.e("SyncAccessibility", "Error reading clipboard: $e")
        }
    }

    private fun showSendToMacNotification(text: String) {
        val sendIntent = Intent(this, ClipboardSenderActivity::class.java).apply {
            action = "SEND_SPECIFIC_TEXT"
            putExtra("text_to_send", text)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK
        }
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        val pi = PendingIntent.getActivity(this, 201, sendIntent, flags)

        val preview = if (text.length > 50) text.take(50) + "..." else text

        val notification = NotificationCompat.Builder(this, "SyncBridgeChannel")
            .setContentTitle("Send copied text to Mac?")
            .setContentText(preview)
            .setSmallIcon(android.R.drawable.sym_def_app_icon)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
            .setContentIntent(pi)
            .addAction(android.R.drawable.ic_menu_send, "Send to Mac", pi)
            .build()

        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(1718, notification)
    }

    override fun onInterrupt() {
        if (isListening) {
            clipboardManager.removePrimaryClipChangedListener(clipListener)
            isListening = false
        }
    }
}

