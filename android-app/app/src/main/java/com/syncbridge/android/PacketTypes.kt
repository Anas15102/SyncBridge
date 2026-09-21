package com.syncbridge.android

object PacketTypes {
    const val IDENTITY = "kdeconnect.identity"
    const val PAIR = "kdeconnect.pair"
    const val CLIPBOARD = "kdeconnect.clipboard"
    const val SHARE_REQUEST = "kdeconnect.share.request"
    const val PING = "kdeconnect.ping"
    
    const val DEFAULT_PORT = 1716
}

data class NetworkPacket(
    val id: Long = System.currentTimeMillis(),
    val type: String,
    val body: Map<String, Any> = mapOf(),
    val payloadSize: Long? = null,
    val payloadTransferInfo: Map<String, Any>? = null
) {
    fun toJson(): String {
        return com.google.gson.Gson().toJson(this)
    }

    companion object {
        fun identityPacket(deviceId: String, deviceName: String): NetworkPacket {
            return NetworkPacket(
                type = PacketTypes.IDENTITY,
                body = mapOf(
                    "deviceId" to deviceId,
                    "deviceName" to deviceName,
                    "deviceType" to "phone",
                    "protocolVersion" to 7,
                    "tcpPort" to PacketTypes.DEFAULT_PORT,
                    "incomingCapabilities" to listOf(PacketTypes.CLIPBOARD, PacketTypes.PAIR, PacketTypes.SHARE_REQUEST, PacketTypes.PING),
                    "outgoingCapabilities" to listOf(PacketTypes.CLIPBOARD, PacketTypes.PAIR, PacketTypes.SHARE_REQUEST, PacketTypes.PING)
                )
            )
        }

        fun pairPacket(pair: Boolean): NetworkPacket {
            return NetworkPacket(
                type = PacketTypes.PAIR,
                body = mapOf("pair" to pair)
            )
        }

        fun clipboardPacket(content: String): NetworkPacket {
            return NetworkPacket(
                type = PacketTypes.CLIPBOARD,
                body = mapOf("content" to content)
            )
        }
        fun shareFilePacket(filename: String, size: Long, payloadPort: Int): NetworkPacket {
            return NetworkPacket(
                type = PacketTypes.SHARE_REQUEST,
                body = mapOf(
                    "filename" to filename,
                    "numberOfFiles" to 1,
                    "totalPayloadSize" to size,
                    "open" to false
                ),
                payloadSize = size,
                payloadTransferInfo = mapOf("port" to payloadPort)
            )
        }
    }
}
