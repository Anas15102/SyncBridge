package com.syncbridge.android

import android.app.Application
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.stateIn

class MainViewModel(application: Application) : AndroidViewModel(application) {
    // Wait for the service to start, or initialize standard NetworkEngine if UI opens first
    val networkEngine: NetworkEngine
        get() {
            if (SyncForegroundService.networkEngine == null) {
                SyncForegroundService.networkEngine = NetworkEngine(getApplication())
                SyncForegroundService.networkEngine?.start()
            }
            return SyncForegroundService.networkEngine!!
        }
    
    val devices: StateFlow<List<RemoteDevice>> = networkEngine.devices.stateIn(
        viewModelScope,
        SharingStarted.WhileSubscribed(5000),
        emptyList()
    )

    private val mainHandler = Handler(Looper.getMainLooper())
    private var isFirstInit = true

    private val _clipboardHistory = MutableStateFlow<List<String>>(emptyList())
    val clipboardHistory = _clipboardHistory.asStateFlow()

    init {
        if (isFirstInit) {
            isFirstInit = false
            networkEngine.addClipboardListener { content ->
                mainHandler.post {
                    val list = _clipboardHistory.value.toMutableList()
                    list.add(0, "Received & Copied: $content")
                    _clipboardHistory.value = list
                }
            }
            networkEngine.onFileReceived = { path ->
                val list = _clipboardHistory.value.toMutableList()
                list.add(0, "File Rcvd & Saved: $path")
                _clipboardHistory.value = list
            }
            networkEngine.onStatus = { status ->
                val list = _clipboardHistory.value.toMutableList()
                list.add(0, "Status: $status")
                _clipboardHistory.value = list
            }
        }
    }

    override fun onCleared() {
        super.onCleared()
        // Do NOT stop networkEngine here, because we want it to run in the background service!
    }

    fun requestPair(device: RemoteDevice) {
        networkEngine.requestPair(device)
    }

    fun sendClipboard(device: RemoteDevice, text: String) {
        val list = _clipboardHistory.value.toMutableList()
        list.add(0, "Sent Text: $text")
        _clipboardHistory.value = list
        networkEngine.sendClipboard(device, text)
    }

    fun sendFile(device: RemoteDevice, uri: android.net.Uri) {
        val context = getApplication<Application>()
        viewModelScope.launch(kotlinx.coroutines.Dispatchers.IO) {
            val fileName = FileUtils.getFileName(context, uri)
            val list = _clipboardHistory.value.toMutableList()
            list.add(0, "Sending File -> $fileName")
            _clipboardHistory.value = list
            
            val tempFile = java.io.File(context.cacheDir, fileName)
            try {
                context.contentResolver.openInputStream(uri)?.use { input ->
                    tempFile.outputStream().use { output ->
                        input.copyTo(output)
                    }
                }
                networkEngine.sendFile(device, tempFile, customDisplayName = fileName)
            } catch (e: Exception) {
                Log.e("MainViewModel", "Error sending file: $e")
                val errList = _clipboardHistory.value.toMutableList()
                errList.add(0, "Failed to send $fileName: ${e.message}")
                _clipboardHistory.value = errList
            }
        }
    }
}
