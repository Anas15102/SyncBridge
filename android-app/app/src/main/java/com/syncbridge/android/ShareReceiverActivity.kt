package com.syncbridge.android

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.util.Log
import android.widget.Toast
import java.io.File

class ShareReceiverActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val action = intent.action
        val type = intent.type

        if (Intent.ACTION_SEND == action && type != null) {
            val engine = SyncForegroundService.networkEngine ?: return
            val pairedDevices = engine.devices.value.filter { it.isPaired }

            if (pairedDevices.isEmpty()) {
                Toast.makeText(this, "No Mac paired first.", Toast.LENGTH_LONG).show()
                finish()
                return
            }

            if ("text/plain" == type) {
                val sharedText = intent.getStringExtra(Intent.EXTRA_TEXT)
                if (sharedText != null) {
                    pairedDevices.forEach { device ->
                        engine.sendPacket(device, NetworkPacket.clipboardPacket(sharedText))
                    }
                    Toast.makeText(this, "Sent to Mac", Toast.LENGTH_SHORT).show()
                }
            } else {
                val uri = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
                if (uri != null) {
                    val fileName = FileUtils.getFileName(this, uri)
                    Toast.makeText(this, "Sending $fileName to Mac...", Toast.LENGTH_SHORT).show()
                    
                    val tempFile = File(cacheDir, fileName)
                    try {
                        contentResolver.openInputStream(uri)?.use { input ->
                            tempFile.outputStream().use { output ->
                                input.copyTo(output)
                            }
                        }
                        pairedDevices.forEach { device ->
                            engine.sendFile(device, tempFile, customDisplayName = fileName)
                        }
                    } catch (e: Exception) {
                        Log.e("ShareReceiver", "Error processing shared file: $e")
                        Toast.makeText(this, "Failed to read $fileName", Toast.LENGTH_SHORT).show()
                    }
                }
            }
        }
        
        finish() // Closes instantly after routing the data
    }
}
