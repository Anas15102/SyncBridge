package com.syncbridge.android

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat

class SyncForegroundService : Service() {

    companion object {
        var networkEngine: NetworkEngine? = null
        var isRunning = false
    }

    private lateinit var clipboardManager: ClipboardManager
    private var lastReceivedClip = ""

    private val clipListener = ClipboardManager.OnPrimaryClipChangedListener {
        if (!clipboardManager.hasPrimaryClip()) return@OnPrimaryClipChangedListener
        val item = clipboardManager.primaryClip?.getItemAt(0) ?: return@OnPrimaryClipChangedListener
        val text = item.text?.toString() ?: return@OnPrimaryClipChangedListener

        if (text == lastReceivedClip || text.isEmpty()) return@OnPrimaryClipChangedListener
        
        Log.d("SyncBridge", "Clipboard changed: Sending '$text'")
        networkEngine?.devices?.value?.filter { it.isPaired }?.forEach {
            networkEngine?.sendPacket(it, NetworkPacket.clipboardPacket(text))
        }
    }

    override fun onCreate() {
        super.onCreate()
        isRunning = true
        createNotificationChannel()

        val sendClipIntent = Intent(this, ClipboardSenderActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK
        }
        val pendingIntentFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        val sendClipPendingIntent = PendingIntent.getActivity(this, 101, sendClipIntent, pendingIntentFlags)

        val notification = NotificationCompat.Builder(this, "SyncBridgeChannel")
            .setContentTitle("SyncBridge Active")
            .setContentText("Connected to paired Mac")
            .setSmallIcon(android.R.drawable.sym_def_app_icon)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .addAction(android.R.drawable.ic_menu_send, "Send Clipboard", sendClipPendingIntent)
            .build()
        startForeground(1716, notification)

        if (networkEngine == null) {
            networkEngine = NetworkEngine(applicationContext)
            networkEngine?.start()
        }

        clipboardManager = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        clipboardManager.addPrimaryClipChangedListener(clipListener)

        networkEngine?.addClipboardListener { content ->
            Log.d("SyncBridge", "Received clip from network: $content")
            lastReceivedClip = content
            val clip = ClipData.newPlainText("SyncBridge", content)
            
            try {
                clipboardManager.setPrimaryClip(clip)
            } catch (e: Exception) {
                Log.e("SyncBridge", "Failed to write clipboard natively. Displaying notification fallback.")
                showCopyNotificationFallback(content)
            }
        }
    }

    private fun showCopyNotificationFallback(content: String) {
        val copyIntent = Intent(this, ClipboardSenderActivity::class.java).apply {
            action = "COPY_TO_CLIPBOARD"
            putExtra("content_to_copy", content)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK
        }
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        val pi = PendingIntent.getActivity(this, 102, copyIntent, flags)

        val notification = NotificationCompat.Builder(this, "SyncBridgeChannel")
            .setContentTitle("New clipboard from Mac")
            .setContentText("Tap to paste: " + content.take(40))
            .setSmallIcon(android.R.drawable.sym_def_app_icon)
            .setAutoCancel(true)
            .setContentIntent(pi)
            .build()
        
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(1717, notification)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        return START_STICKY
    }

    override fun onDestroy() {
        super.onDestroy()
        clipboardManager.removePrimaryClipChangedListener(clipListener)
        networkEngine?.stop()
        networkEngine = null
        isRunning = false
    }

    override fun onBind(intent: Intent?): IBinder? {
        return null
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                "SyncBridgeChannel",
                "SyncBridge Background Sync",
                NotificationManager.IMPORTANCE_LOW
            )
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
        }
    }
}
