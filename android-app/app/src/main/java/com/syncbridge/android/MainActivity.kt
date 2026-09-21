package com.syncbridge.android

import android.net.Uri
import android.os.Bundle
import android.content.Intent
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp

class MainActivity : ComponentActivity() {
    private val viewModel: MainViewModel by viewModels()

    @OptIn(ExperimentalMaterial3Api::class)
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        
        // Start foreground service
        val serviceIntent = Intent(this, SyncForegroundService::class.java)
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
            startForegroundService(serviceIntent)
        } else {
            startService(serviceIntent)
        }

        setContent {
            MaterialTheme {
                Scaffold(
                    topBar = {
                        TopAppBar(
                            title = { Text("SyncBridge") },
                            colors = TopAppBarDefaults.topAppBarColors(
                                containerColor = MaterialTheme.colorScheme.primaryContainer,
                                titleContentColor = MaterialTheme.colorScheme.primary
                            )
                        )
                    }
                ) { innerPadding ->
                    Column(
                        modifier = Modifier
                            .fillMaxSize()
                            .padding(innerPadding)
                    ) {
                        AppScreen(viewModel)
                    }
                }
            }
        }
    }
}

@Composable
fun AppScreen(viewModel: MainViewModel) {
    val devices by viewModel.devices.collectAsState()
    val clipboardHistory by viewModel.clipboardHistory.collectAsState()
    var selectedDevice by remember { mutableStateOf<RemoteDevice?>(null) }
    var textToSend by remember { mutableStateOf("") }
    var customIp by remember { mutableStateOf("") }
    
    val fileLauncher = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri: Uri? ->
        if (uri != null && selectedDevice != null) {
            viewModel.sendFile(selectedDevice!!, uri)
        }
    }

    Column(modifier = Modifier.fillMaxSize().padding(16.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text("KDE Connect Devices", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
            Button(
                onClick = { viewModel.networkEngine.broadcastIdentity() },
                contentPadding = PaddingValues(horizontal = 12.dp, vertical = 4.dp)
            ) {
                Text("Scan / Refresh")
            }
        }
        Spacer(Modifier.height(8.dp))

        // Direct Connect Option
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically
        ) {
            OutlinedTextField(
                value = customIp,
                onValueChange = { customIp = it },
                modifier = Modifier.weight(1f),
                placeholder = { Text("Enter Mac IP (e.g. 192.168.0.165)") },
                singleLine = true
            )
            Spacer(Modifier.width(8.dp))
            Button(
                onClick = {
                    if (customIp.isNotBlank()) {
                        val ip = customIp.trim()
                        val dev = RemoteDevice("custom-$ip", "Mac ($ip)", "laptop", ip, PacketTypes.DEFAULT_PORT)
                        viewModel.networkEngine.sendPacket(dev, NetworkPacket.identityPacket(viewModel.networkEngine.myDeviceId, viewModel.networkEngine.myDeviceName))
                    }
                }
            ) {
                Text("Connect")
            }
        }

        Spacer(Modifier.height(8.dp))

        if (devices.isEmpty()) {
            Text("Scanning LAN via UDP 1716... (Tap Scan or enter Mac IP above)", color = Color.Gray, modifier = Modifier.padding(16.dp))
        }

        LazyColumn(modifier = Modifier.fillMaxWidth().weight(1f)) {
            items(devices, key = { it.id }) { device ->
                Card(
                    modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
                    colors = CardDefaults.cardColors(containerColor = if (selectedDevice?.id == device.id) MaterialTheme.colorScheme.primaryContainer else MaterialTheme.colorScheme.surfaceVariant)
                ) {
                    Column(modifier = Modifier.padding(16.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(device.name, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
                            Spacer(Modifier.weight(1f))
                            if (device.isPaired) {
                                Text("✅ Paired", color = MaterialTheme.colorScheme.primary, style = MaterialTheme.typography.labelMedium)
                            }
                        }
                        Text("${device.ip}:${device.port} • ${device.type}", style = MaterialTheme.typography.bodySmall)
                        
                        Spacer(Modifier.height(8.dp))
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            if (!device.isPaired) {
                                Button(onClick = { viewModel.requestPair(device) }) {
                                    Text("Pair")
                                }
                            } else {
                                Button(onClick = { selectedDevice = device }) {
                                    Text("Select for File Share")
                                }
                            }
                        }
                    }
                }
            }
        }

        HorizontalDivider(modifier = Modifier.padding(vertical = 16.dp))

        if (selectedDevice != null) {
            Text("Share with ${selectedDevice?.name}", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
            Row(modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                OutlinedTextField(
                    value = textToSend,
                    onValueChange = { textToSend = it },
                    modifier = Modifier.weight(1f),
                    placeholder = { Text("Clipboard text...") }
                )
                Spacer(Modifier.width(8.dp))
                Button(onClick = { 
                    viewModel.sendClipboard(selectedDevice!!, textToSend)
                    textToSend = ""
                }) {
                    Text("Send Text")
                }
            }
            Button(
                onClick = { fileLauncher.launch("*/*") },
                modifier = Modifier.fillMaxWidth()
            ) {
                Text("Select & Send File")
            }
        }

        Spacer(Modifier.height(16.dp))
        Text("Event History", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
        LazyColumn(modifier = Modifier.fillMaxWidth().weight(1f)) {
            items(clipboardHistory) { clip ->
                Card(modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
                    Text(clip, modifier = Modifier.padding(16.dp))
                }
            }
        }
    }
}


