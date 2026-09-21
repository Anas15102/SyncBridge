package com.syncbridge.android

import android.content.Context
import android.net.wifi.WifiManager
import android.os.Environment
import android.util.Log
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.BufferedReader
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.ServerSocket
import java.net.Socket
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

data class RemoteDevice(
    val id: String,
    val name: String,
    val type: String,
    val ip: String,
    val port: Int,
    val isPaired: Boolean = false
)

class NetworkEngine(private val context: Context) {
    private val _devices = MutableStateFlow<List<RemoteDevice>>(emptyList())
    val devices = _devices.asStateFlow()

    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private var udpSocket: DatagramSocket? = null
    private var tcpServer: ServerSocket? = null
    private var multicastLock: WifiManager.MulticastLock? = null
    private val connectionLock = Any()
    private val activeConnections = ConcurrentHashMap<String, Socket>()
    private val writers = ConcurrentHashMap<String, OutputStreamWriter>()

    val myDeviceId: String = UUID.randomUUID().toString().replace("-", "").take(16)
    val myDeviceName: String = android.os.Build.MODEL ?: "Android Device"

    private val clipboardListeners = java.util.concurrent.CopyOnWriteArrayList<(String) -> Unit>()
    var onFileReceived: ((String) -> Unit)? = null
    var onStatus: ((String) -> Unit)? = null

    fun addClipboardListener(listener: (String) -> Unit) {
        if (!clipboardListeners.contains(listener)) {
            clipboardListeners.add(listener)
        }
    }

    fun removeClipboardListener(listener: (String) -> Unit) {
        clipboardListeners.remove(listener)
    }

    fun dispatchClipboard(content: String) {
        android.os.Handler(android.os.Looper.getMainLooper()).post {
            try {
                val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
                val clip = android.content.ClipData.newPlainText("SyncBridge", content)
                cm.setPrimaryClip(clip)
                Log.d("NetworkEngine", "Auto-set primary clip to: '$content'")
            } catch (e: Exception) {
                Log.e("NetworkEngine", "Error setting primary clip on main thread: $e")
            }
            for (listener in clipboardListeners) {
                try {
                    listener(content)
                } catch (e: Exception) {
                    Log.e("NetworkEngine", "Listener invocation error: $e")
                }
            }
        }
    }

    fun start() {
        try {
            val wifiManager = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            multicastLock = wifiManager.createMulticastLock("SyncBridgeMulticastLock").apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (e: Exception) {
            Log.e("NetworkEngine", "Error acquiring multicast lock: $e")
        }

        startUdpListener()
        startTcpServer()
        broadcastIdentity()
        
        scope.launch {
            while (isActive) {
                delay(4_000)
                broadcastIdentity()
            }
        }
    }

    fun stop() {
        scope.cancel()
        udpSocket?.close()
        tcpServer?.close()
        multicastLock?.release()
        multicastLock = null
        
        synchronized(connectionLock) {
            writers.values.forEach { runCatching { it.close() } }
            activeConnections.values.forEach { runCatching { it.close() } }
            writers.clear()
            activeConnections.clear()
        }
    }

    fun normalizeIp(ip: String): String {
        var res = ip.trim()
        if (res.startsWith("::ffff:")) {
            res = res.substring(7)
        }
        val pct = res.indexOf('%')
        if (pct != -1) {
            res = res.substring(0, pct)
        }
        return res
    }

    private fun startUdpListener() {
        scope.launch {
            try {
                val socket = DatagramSocket(null)
                socket.reuseAddress = true
                socket.broadcast = true
                socket.bind(InetSocketAddress(PacketTypes.DEFAULT_PORT))
                udpSocket = socket
                val buffer = ByteArray(65535)
                onStatus?.invoke("Listening on UDP ${PacketTypes.DEFAULT_PORT}")
                
                while (isActive) {
                    val packet = DatagramPacket(buffer, buffer.size)
                    socket.receive(packet)
                    val rawIp = packet.address.hostAddress ?: continue
                    val ip = normalizeIp(rawIp)
                    val text = String(packet.data, 0, packet.length, Charsets.UTF_8)
                    handleRawJson(text, ip)
                }
            } catch (e: Exception) {
                Log.e("NetworkEngine", "UDP Error: ${e.message}")
            }
        }
    }

    private fun startTcpServer() {
        scope.launch {
            try {
                tcpServer = ServerSocket().apply {
                    reuseAddress = true
                    bind(InetSocketAddress(PacketTypes.DEFAULT_PORT))
                }
                onStatus?.invoke("Listening on TCP ${PacketTypes.DEFAULT_PORT}")
                
                while (isActive) {
                    val client = tcpServer?.accept() ?: continue
                    client.keepAlive = true
                    client.tcpNoDelay = true
                    val rawIp = client.inetAddress.hostAddress ?: continue
                    val ip = normalizeIp(rawIp)
                    storeConnection(ip, client)
                    launch { handleTcpClient(client, ip) }
                }
            } catch (e: Exception) {
                Log.e("NetworkEngine", "TCP Server Error: ${e.message}")
            }
        }
    }

    private fun storeConnection(ip: String, socket: Socket) {
        val cleanIp = normalizeIp(ip)
        synchronized(connectionLock) {
            val existing = activeConnections[cleanIp]
            if (existing != null && existing !== socket && !existing.isClosed && existing.isConnected) {
                return
            }
            activeConnections[cleanIp] = socket
            writers[cleanIp] = OutputStreamWriter(socket.getOutputStream(), Charsets.UTF_8)
        }
    }

    private fun handleTcpClient(socket: Socket, ip: String) {
        val cleanIp = normalizeIp(ip)
        try {
            val reader = BufferedReader(InputStreamReader(socket.getInputStream(), Charsets.UTF_8))
            while (scope.isActive && !socket.isClosed) {
                val line = reader.readLine() ?: break
                val trimmed = line.trim()
                if (trimmed.isEmpty()) continue
                handleRawJson(trimmed, cleanIp)
            }
        } catch (e: Exception) {
            Log.e("NetworkEngine", "TCP Client read error: ${e.message}")
        } finally {
            synchronized(connectionLock) {
                if (activeConnections[cleanIp] === socket) {
                    activeConnections.remove(cleanIp)
                    writers.remove(cleanIp)
                }
            }
            runCatching { socket.close() }
        }
    }

    private fun handleRawJson(json: String, ip: String) {
        val cleanIp = normalizeIp(ip)
        try {
            val trimmed = json.trim()
            if (trimmed.isEmpty()) return
            val root = JsonParser.parseString(trimmed).asJsonObject
            val type = root.get("type")?.asString ?: return
            val body = root.get("body")?.asJsonObject

            when (type) {
                PacketTypes.IDENTITY -> {
                    val devId = body?.get("deviceId")?.asString ?: return
                    if (devId == myDeviceId) return
                    val name = body.get("deviceName")?.asString ?: "Unknown"
                    val devType = body.get("deviceType")?.asString ?: "laptop"
                    val port = jsonInt(body, "tcpPort") ?: PacketTypes.DEFAULT_PORT
                    val existing = _devices.value.find { it.id == devId || normalizeIp(it.ip) == cleanIp }
                    
                    val newDevice = RemoteDevice(
                        id = devId,
                        name = name,
                        type = devType,
                        ip = cleanIp,
                        port = port,
                        isPaired = existing?.isPaired == true
                    )
                    addOrUpdateDevice(newDevice)
                    
                    // Reply back to ensure mutual discovery
                    sendPacket(newDevice, NetworkPacket.identityPacket(myDeviceId, myDeviceName))
                }

                PacketTypes.PAIR -> {
                    val isPair = body?.get("pair")?.asBoolean ?: false
                    val device = _devices.value.find { normalizeIp(it.ip) == cleanIp }
                        ?: _devices.value.firstOrNull()
                    if (device != null) {
                        addOrUpdateDevice(device.copy(isPaired = isPair))
                        if (isPair) {
                            sendPacket(device.copy(isPaired = true), NetworkPacket.pairPacket(true))
                            onStatus?.invoke("Paired with ${device.name}")
                        } else {
                            onStatus?.invoke("Unpaired from ${device.name}")
                        }
                    }
                }

                PacketTypes.CLIPBOARD -> {
                    val content = body?.get("content")?.asString ?: return
                    dispatchClipboard(content)
                }

                PacketTypes.SHARE_REQUEST -> {
                    val filename = body?.get("filename")?.asString
                    val text = body?.get("text")?.asString
                    val url = body?.get("url")?.asString
                    val payloadInfo = root.get("payloadTransferInfo")?.asJsonObject
                    val payloadPort = payloadInfo?.let { jsonInt(it, "port") }
                    val payloadSize = jsonLong(root, "payloadSize") ?: 0L

                    when {
                        payloadPort != null && filename != null -> {
                            receiveFile(cleanIp, payloadPort, filename, payloadSize)
                        }
                        filename != null && payloadSize > 0 -> {
                            receiveFileAsServer(cleanIp, filename, payloadSize)
                        }
                        text != null -> dispatchClipboard(text)
                        url != null -> dispatchClipboard(url)
                    }
                }
            }
        } catch (e: Exception) {
            Log.e("NetworkEngine", "JSON Parse Error: ${e.message}\nJson: $json")
        }
    }

    private fun jsonInt(obj: JsonObject, key: String): Int? {
        val el = obj.get(key) ?: return null
        return try {
            el.asInt
        } catch (_: Exception) {
            el.asString.toIntOrNull()
        }
    }

    private fun jsonLong(obj: JsonObject, key: String): Long? {
        val el = obj.get(key) ?: return null
        return try {
            el.asLong
        } catch (_: Exception) {
            el.asString.toLongOrNull()
        }
    }

    private fun addOrUpdateDevice(device: RemoteDevice) {
        val current = _devices.value.toMutableList()
        val index = current.indexOfFirst { it.id == device.id || normalizeIp(it.ip) == normalizeIp(device.ip) }
        if (index >= 0) {
            current[index] = device.copy(isPaired = current[index].isPaired || device.isPaired)
        } else {
            current.add(device)
        }
        _devices.value = current
    }

    fun broadcastIdentity() {
        scope.launch {
            try {
                val packet = NetworkPacket.identityPacket(myDeviceId, myDeviceName)
                val json = packet.toJson() + "\n"
                val data = json.toByteArray(Charsets.UTF_8)

                DatagramSocket().use { socket ->
                    socket.broadcast = true
                    
                    // 1. General broadcast
                    val generalPacket = DatagramPacket(
                        data,
                        data.size,
                        InetAddress.getByName("255.255.255.255"),
                        PacketTypes.DEFAULT_PORT
                    )
                    socket.send(generalPacket)

                    // 2. All interface subnet broadcasts
                    try {
                        val interfaces = NetworkInterface.getNetworkInterfaces()
                        while (interfaces.hasMoreElements()) {
                            val networkInterface = interfaces.nextElement()
                            if (networkInterface.isLoopback || !networkInterface.isUp) continue
                            for (interfaceAddress in networkInterface.interfaceAddresses) {
                                val broadcast = interfaceAddress.broadcast ?: continue
                                val ifPacket = DatagramPacket(
                                    data,
                                    data.size,
                                    broadcast,
                                    PacketTypes.DEFAULT_PORT
                                )
                                socket.send(ifPacket)
                            }
                        }
                    } catch (e: Exception) {
                        Log.w("NetworkEngine", "Interface broadcast warning: ${e.message}")
                    }
                }
            } catch (e: Exception) {
                Log.e("NetworkEngine", "Broadcast error: ${e.message}")
            }
        }
    }

    fun sendPacket(device: RemoteDevice, packet: NetworkPacket) {
        scope.launch {
            val cleanIp = normalizeIp(device.ip)
            try {
                val json = packet.toJson() + "\n"
                val socket = getOrOpenSocket(device)
                val writer = synchronized(connectionLock) {
                    writers[cleanIp] ?: OutputStreamWriter(socket.getOutputStream(), Charsets.UTF_8).also {
                        writers[cleanIp] = it
                    }
                }
                synchronized(writer) {
                    writer.write(json)
                    writer.flush()
                }
                Log.d("NetworkEngine", "Sent ${packet.type} to ${device.name} ($cleanIp)")
            } catch (e: Exception) {
                Log.e("NetworkEngine", "Send error to $cleanIp: ${e.message}")
                synchronized(connectionLock) {
                    activeConnections.remove(cleanIp)
                    writers.remove(cleanIp)
                }
            }
        }
    }

    private fun getOrOpenSocket(device: RemoteDevice): Socket {
        val cleanIp = normalizeIp(device.ip)
        synchronized(connectionLock) {
            val existing = activeConnections[cleanIp]
            if (existing != null && !existing.isClosed && existing.isConnected) {
                return existing
            }
        }
        val socket = Socket()
        socket.keepAlive = true
        socket.tcpNoDelay = true
        socket.connect(InetSocketAddress(cleanIp, device.port), 4000)
        storeConnection(cleanIp, socket)
        scope.launch { handleTcpClient(socket, cleanIp) }
        return socket
    }

    fun requestPair(device: RemoteDevice) {
        addOrUpdateDevice(device.copy(isPaired = true))
        sendPacket(device.copy(isPaired = true), NetworkPacket.pairPacket(true))
        onStatus?.invoke("Pairing with ${device.name}...")
    }

    fun sendClipboard(device: RemoteDevice, text: String) {
        sendPacket(device, NetworkPacket.clipboardPacket(text))
    }

    fun sendFile(device: RemoteDevice, file: File, customDisplayName: String? = null) {
        scope.launch {
            val displayName = customDisplayName ?: file.name
            try {
                val payloadServer = ServerSocket(0)
                val payloadPort = payloadServer.localPort
                val packet = NetworkPacket.shareFilePacket(displayName, file.length(), payloadPort)
                sendPacket(device, packet)

                payloadServer.soTimeout = 45_000
                val client = payloadServer.accept()
                client.tcpNoDelay = true
                BufferedOutputStream(client.getOutputStream()).use { out ->
                    FileInputStream(file).use { input ->
                        val buffer = ByteArray(64 * 1024)
                        var bytesRead: Int
                        while (input.read(buffer).also { bytesRead = it } != -1) {
                            out.write(buffer, 0, bytesRead)
                        }
                    }
                    out.flush()
                }
                client.close()
                payloadServer.close()
                onStatus?.invoke("Sent $displayName successfully")
            } catch (e: Exception) {
                Log.e("NetworkEngine", "Send file error: ${e.message}")
                onStatus?.invoke("File send failed: ${e.message}")
            } finally {
                if (file.parentFile?.absolutePath == context.cacheDir.absolutePath) {
                    runCatching { file.delete() }
                }
            }
        }
    }

    private fun receiveFile(host: String, port: Int, filename: String, size: Long) {
        scope.launch {
            try {
                val (outputStream, savedName) = FileUtils.openDownloadOutputStream(context, filename)
                Socket().use { socket ->
                    socket.soTimeout = 45_000
                    socket.tcpNoDelay = true
                    socket.connect(InetSocketAddress(host, port), 10_000)
                    BufferedInputStream(socket.getInputStream()).use { input ->
                        outputStream.use { output ->
                            val buffer = ByteArray(64 * 1024)
                            var remaining = if (size > 0) size else Long.MAX_VALUE
                            while (remaining > 0) {
                                val toRead = minOf(buffer.size.toLong(), remaining).toInt()
                                val read = input.read(buffer, 0, toRead)
                                if (read <= 0) break
                                output.write(buffer, 0, read)
                                remaining -= read
                            }
                            output.flush()
                        }
                    }
                }
                onFileReceived?.invoke(savedName)
                onStatus?.invoke("Saved $savedName to Downloads")
            } catch (e: Exception) {
                Log.e("NetworkEngine", "Receive file error: ${e.message}")
                onStatus?.invoke("File receive failed: ${e.message}")
            }
        }
    }

    private fun receiveFileAsServer(senderIp: String, filename: String, size: Long) {
        scope.launch {
            try {
                val cleanIp = normalizeIp(senderIp)
                val device = _devices.value.find { normalizeIp(it.ip) == cleanIp }
                    ?: RemoteDevice(id = "temp-$cleanIp", name = "Mac", type = "laptop", ip = cleanIp, port = PacketTypes.DEFAULT_PORT, isPaired = true)

                val serverSocket = ServerSocket(0)
                val port = serverSocket.localPort

                val ackPacket = NetworkPacket(
                    type = PacketTypes.SHARE_REQUEST,
                    body = mapOf("filename" to filename),
                    payloadSize = size,
                    payloadTransferInfo = mapOf("port" to port)
                )
                sendPacket(device, ackPacket)

                serverSocket.soTimeout = 45_000
                val client = serverSocket.accept()
                client.tcpNoDelay = true

                val (outputStream, savedName) = FileUtils.openDownloadOutputStream(context, filename)

                BufferedInputStream(client.getInputStream()).use { input ->
                    outputStream.use { output ->
                        val buffer = ByteArray(64 * 1024)
                        var remaining = if (size > 0) size else Long.MAX_VALUE
                        while (remaining > 0) {
                            val toRead = minOf(buffer.size.toLong(), remaining).toInt()
                            val read = input.read(buffer, 0, toRead)
                            if (read <= 0) break
                            output.write(buffer, 0, read)
                            remaining -= read
                        }
                        output.flush()
                    }
                }
                client.close()
                serverSocket.close()

                onFileReceived?.invoke(savedName)
                onStatus?.invoke("Saved $savedName to Downloads")
            } catch (e: Exception) {
                Log.e("NetworkEngine", "Receive file as server error: ${e.message}")
                onStatus?.invoke("File receive failed: ${e.message}")
            }
        }
    }
}
