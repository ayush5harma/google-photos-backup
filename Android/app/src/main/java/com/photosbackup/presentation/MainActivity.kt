package com.photosbackup.presentation

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.work.WorkManager
import com.photosbackup.BuildConfig
import com.photosbackup.R
import com.photosbackup.data.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@Composable
fun BackupTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme =
            if (isSystemInDarkTheme())
                darkColorScheme(
                    primary = Color(0xFFA8CCFF),
                    secondary = Color(0xFFA7D9C1),
                    background = Color(0xFF10151E),
                    surface = Color(0xFF151C27),
                )
            else
                lightColorScheme(
                    primary = Color(0xFF245DAB),
                    secondary = Color(0xFF256C51),
                    background = Color(0xFFF7F9FD),
                    surface = Color.White,
                ),
        content = content,
    )
}

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent { BackupTheme { App() } }
    }

    @Composable
    private fun App() {
        val store = remember { Store.get(this) }
        val state by store.state.collectAsStateWithLifecycle()
        var tab by remember { mutableIntStateOf(0) }
        var advanced by remember { mutableStateOf(false) }
        var secret by remember { mutableStateOf("") }
        var validating by remember { mutableStateOf(false) }
        var folders by remember { mutableStateOf<List<DeviceFolder>>(emptyList()) }
        var showFolders by remember { mutableStateOf(false) }
        var loadingFolders by remember { mutableStateOf(false) }
        DisposableEffect(advanced) {
            if (advanced) window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
            else window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
            onDispose { window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE) }
        }
        val scope = rememberCoroutineScope()
        val work by
            WorkManager.getInstance(this)
                .getWorkInfosForUniqueWorkLiveData("backup")
                .observeAsStateCompat()
        val busy =
            state.running ||
                state.connecting ||
                validating ||
                work?.any { !it.state.isFinished } == true
        val notificationPermission =
            rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {}
        fun refreshFolders() {
            loadingFolders = true
            scope.launch(Dispatchers.IO) {
                val result = runCatching { DeviceLibrary(this@MainActivity).folders() }
                withContext(Dispatchers.Main) {
                    loadingFolders = false
                    result.onSuccess { folders = it; showFolders = true }
                        .onFailure { store.update { state -> state.copy(notice = "Could not read accessible device folders.") } }
                }
            }
        }
        val libraryPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { refreshFolders() }
        val picker =
            rememberLauncherForActivityResult(
                ActivityResultContracts.PickMultipleVisualMedia(100)
            ) { uris ->
                scope.launch(Dispatchers.IO) {
                    runCatching {
                            uris.forEach {
                                contentResolver.takePersistableUriPermission(
                                    it,
                                    Intent.FLAG_GRANT_READ_URI_PERMISSION,
                                )
                            }
                            store.add(uris)
                        }
                        .onFailure {
                            store.update {
                                it.copy(
                                    notice =
                                        "Could not keep access to those items. Select them again."
                                )
                            }
                        }
                }
            }
        Scaffold(
            containerColor = MaterialTheme.colorScheme.background,
            bottomBar = {
                NavigationBar {
                    listOf(
                            "Backup" to Icons.Rounded.CloudUpload,
                            "Activity" to Icons.Rounded.History,
                            "Settings" to Icons.Rounded.Settings,
                        )
                        .forEachIndexed { i, (label, icon) ->
                            NavigationBarItem(
                                selected = tab == i,
                                onClick = { tab = i },
                                icon = { Icon(icon, contentDescription = null) },
                                label = { Text(label) },
                            )
                        }
                }
            },
        ) { padding ->
            LazyColumn(
                Modifier.fillMaxSize().padding(padding),
                contentPadding = PaddingValues(24.dp),
                verticalArrangement = Arrangement.spacedBy(18.dp),
            ) {
                item {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        Image(painterResource(R.drawable.app_icon), null, Modifier.size(48.dp))
                        Column {
                            Text(
                                "PHOTOS BACKUP",
                                style = MaterialTheme.typography.labelMedium,
                                color = MaterialTheme.colorScheme.primary,
                            )
                            Text(
                                listOf(
                                    "Your moments, preserved.",
                                    "Backup activity",
                                    "Your preferences",
                                )[tab],
                                style = MaterialTheme.typography.headlineSmall,
                                fontWeight = FontWeight.SemiBold,
                            )
                        }
                    }
                }
                if (tab == 0) {
                    item {
                        Card(
                            shape = RoundedCornerShape(28.dp),
                            colors =
                                CardDefaults.cardColors(
                                    containerColor = MaterialTheme.colorScheme.primaryContainer
                                ),
                        ) {
                            Column(
                                Modifier.padding(24.dp),
                                verticalArrangement = Arrangement.spacedBy(14.dp),
                            ) {
                                Icon(Icons.Rounded.CloudDone, null, Modifier.size(40.dp))
                                Text(
                                    if (state.email == null) "A home for every memory"
                                    else "Ready when you are",
                                    style = MaterialTheme.typography.headlineMedium,
                                )
                                Text(
                                    if (state.email == null)
                                        "Connect Google Photos, then choose the photos and videos you want to preserve."
                                    else
                                        "${state.items.count { it.key.isBlank() }} selected for backup · ${state.items.count { it.key.isNotBlank() }} confirmed",
                                    style = MaterialTheme.typography.bodyLarge,
                                )
                                if (state.email == null)
                                    Button(
                                        onClick = {
                                            startActivity(
                                                Intent(
                                                    this@MainActivity,
                                                    SignInActivity::class.java,
                                                )
                                            )
                                        }
                                    ) {
                                        Text("Connect Google Photos")
                                    }
                                else
                                    Text(state.email!!, style = MaterialTheme.typography.labelLarge)
                            }
                        }
                    }
                    item {
                        Text(
                            "Select. Review. Back up.",
                            style = MaterialTheme.typography.titleLarge,
                        )
                        Spacer(Modifier.height(8.dp))
                        Text(
                            "Only the items you choose are shared. You control when backup begins.",
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    item {
                        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                            OutlinedButton(
                                onClick = {
                                    picker.launch(
                                        PickVisualMediaRequest(
                                            ActivityResultContracts.PickVisualMedia.ImageAndVideo
                                        )
                                    )
                                },
                                enabled = !busy,
                            ) {
                                Icon(Icons.Rounded.Add, null)
                                Text("Select media")
                            }
                            OutlinedButton(
                                onClick = {
                                    val permissions = when {
                                        Build.VERSION.SDK_INT >= 34 -> arrayOf(
                                            Manifest.permission.READ_MEDIA_IMAGES,
                                            Manifest.permission.READ_MEDIA_VIDEO,
                                            Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED,
                                        )
                                        Build.VERSION.SDK_INT >= 33 -> arrayOf(
                                            Manifest.permission.READ_MEDIA_IMAGES,
                                            Manifest.permission.READ_MEDIA_VIDEO,
                                        )
                                        else -> arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)
                                    }
                                    libraryPermission.launch(permissions)
                                },
                                enabled = !busy && !loadingFolders,
                            ) {
                                Icon(Icons.Rounded.Folder, null)
                                Text("Device folders")
                            }
                            Button(
                                onClick = {
                                    if (
                                        Build.VERSION.SDK_INT >= 33 &&
                                            checkSelfPermission(
                                                Manifest.permission.POST_NOTIFICATIONS
                                            ) != PackageManager.PERMISSION_GRANTED
                                    )
                                        notificationPermission.launch(
                                            Manifest.permission.POST_NOTIFICATIONS
                                        )
                                    BackupWorker.start(this@MainActivity)
                                },
                                enabled =
                                    !busy &&
                                        state.email != null &&
                                        state.items.any { it.key.isEmpty() || (it.albumName.isNotBlank() && it.membership != "Added") },
                            ) {
                                Text("Start backup")
                            }
                        }
                    }
                    item {
                        Text(
                            "${DeviceLibrary.permissionState(this@MainActivity)} · Folder access lists only media Android makes available to this app. Refresh is always manual.",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    if (busy)
                        item {
                            Card {
                                Column(Modifier.padding(20.dp)) {
                                    LinearProgressIndicator(Modifier.fillMaxWidth())
                                    Spacer(Modifier.height(12.dp))
                                    Text("Backing up your selection…")
                                    TextButton(
                                        onClick = { BackupWorker.cancel(this@MainActivity) }
                                    ) {
                                        Text("Cancel backup")
                                    }
                                }
                            }
                        }
                    if (state.notice.isNotBlank())
                        item { Text(state.notice, color = MaterialTheme.colorScheme.primary) }
                    if (state.items.isEmpty())
                        item {
                            Empty(
                                "Your selection starts here",
                                "Choose photos and videos with Android's private photo picker.",
                            )
                        }
                    items(state.items.filter { it.key.isBlank() || (it.albumName.isNotBlank() && it.membership != "Added") }, key = { it.id }) {
                        MediaRow(it, !busy) {
                            store.update { s ->
                                s.copy(items = s.items.filter { row -> row.id != it.id })
                            }
                            runCatching {
                                contentResolver.releasePersistableUriPermission(
                                    android.net.Uri.parse(it.uri),
                                    Intent.FLAG_GRANT_READ_URI_PERMISSION,
                                )
                            }
                        }
                    }
                }
                if (tab == 1) {
                    item {
                        Text("Confirmed by Google", style = MaterialTheme.typography.titleLarge)
                        Text(
                            "An item appears as backed up only after Google returns its media key.",
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    if (state.items.isEmpty())
                        item {
                            Empty(
                                "No activity yet",
                                "Your selected items and confirmed backups will appear here.",
                            )
                        }
                    items(state.items, key = { it.id }) { MediaRow(it, false, {}) }
                }
                if (tab == 2) {
                    item {
                        SettingsCard("Google Photos") {
                            Text(state.email ?: "No account connected")
                            if (state.email != null)
                                TextButton(
                                    onClick = {
                                        BackupWorker.cancel(this@MainActivity)
                                        scope.launch(Dispatchers.IO) { store.disconnect() }
                                    },
                                    enabled = !busy,
                                ) {
                                    Text("Disconnect & clear history")
                                }
                            else
                                Button(
                                    onClick = {
                                        startActivity(
                                            Intent(this@MainActivity, SignInActivity::class.java)
                                        )
                                    }
                                ) {
                                    Text("Connect Google Photos")
                                }
                        }
                    }
                    item {
                        SettingsCard("Upload quality") {
                            Text(
                                "Choose how the unofficial gpmc client sends your media. Google controls quota and availability.",
                                style = MaterialTheme.typography.bodyMedium,
                            )
                            listOf(
                                    "original" to "Original · Pixel XL profile",
                                    "saver" to "Storage saver · Pixel 2 profile",
                                    "quota" to "Original · uses account storage",
                                )
                                .forEach { (value, label) ->
                                    Row(verticalAlignment = Alignment.CenterVertically) {
                                        RadioButton(
                                            selected = state.quality == value,
                                            onClick = { store.update { it.copy(quality = value) } },
                                            enabled = !busy,
                                        )
                                        Text(label)
                                    }
                                }
                        }
                    }
                    item {
                        SettingsCard("About your connection") {
                            Text(
                                "Uses gpmc 0.9.0 and unofficial Google authentication. This is an independent app, not a supported Google OAuth integration. Google can change or block this connection."
                            )
                            Text(
                                "Credentials are encrypted with Android Keystore. Android app backups are disabled. Selected media is staged privately only while uploading.",
                                style = MaterialTheme.typography.bodyMedium,
                            )
                            TextButton(onClick = { advanced = !advanced }, enabled = !busy) {
                                Text("Advanced credentials")
                            }
                            if (advanced) {
                                OutlinedTextField(
                                    value = secret,
                                    onValueChange = { secret = it },
                                    label = { Text("auth_data") },
                                    visualTransformation = PasswordVisualTransformation(),
                                    singleLine = true,
                                    keyboardOptions =
                                        androidx.compose.foundation.text.KeyboardOptions(
                                            keyboardType =
                                                androidx.compose.ui.text.input.KeyboardType
                                                    .Password,
                                            autoCorrectEnabled = false,
                                        ),
                                    modifier = Modifier.fillMaxWidth(),
                                    enabled = !validating,
                                )
                                Button(
                                    onClick = {
                                        validating = true
                                        val auth = secret
                                        secret = ""
                                        scope.launch(
                                            start = kotlinx.coroutines.CoroutineStart.UNDISPATCHED
                                        ) {
                                            try {
                                                store.connectValidated(auth) { value ->
                                                    withContext(Dispatchers.IO) {
                                                        GoogleAuth.validate(value)
                                                    }
                                                }
                                                advanced = false
                                            } catch (
                                                cancelled:
                                                    kotlinx.coroutines.CancellationException) {
                                                throw cancelled
                                            } catch (error: Exception) {
                                                runCatching {
                                                    store.update {
                                                        it.copy(
                                                            notice =
                                                                "Credentials were not accepted by Google Photos."
                                                        )
                                                    }
                                                }
                                            } finally {
                                                validating = false
                                            }
                                        }
                                    },
                                    enabled = secret.isNotBlank() && !busy,
                                ) {
                                    Text(if (validating) "Checking…" else "Check & connect")
                                }
                            }
                            Text(
                                "Version ${BuildConfig.VERSION_NAME}",
                                style = MaterialTheme.typography.labelMedium,
                            )
                        }
                    }
                    if (state.notice.isNotBlank()) item { Text(state.notice) }
                }
            }
        }
        if (showFolders) {
            AlertDialog(
                onDismissRequest = { showFolders = false },
                title = { Text("Accessible device folders") },
                text = {
                    LazyColumn {
                        if (folders.isEmpty()) item { Text("No accessible photos or videos were found.") }
                        items(folders, key = { it.id }) { folder ->
                            ListItem(
                                headlineContent = { Text(folder.name) },
                                supportingContent = { Text("${folder.count} currently accessible items") },
                                modifier = Modifier.fillMaxWidth().clickable {
                                    showFolders = false
                                    scope.launch(Dispatchers.IO) {
                                        val result = runCatching { DeviceLibrary(this@MainActivity).media(folder) }
                                        result.onSuccess { media -> store.replaceFolder(folder, media) }
                                            .onFailure { store.update { state -> state.copy(notice = "Could not read ${folder.name}.") } }
                                    }
                                },
                            )
                            HorizontalDivider()
                        }
                    }
                },
                confirmButton = { TextButton(onClick = { showFolders = false }) { Text("Close") } },
                dismissButton = { TextButton(onClick = { refreshFolders() }) { Text("Refresh") } },
            )
        }
    }
}

@Composable
private fun Empty(title: String, description: String) {
    Column(
        Modifier.fillMaxWidth().padding(vertical = 30.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Icon(
            Icons.Rounded.PhotoLibrary,
            null,
            Modifier.size(48.dp),
            tint = MaterialTheme.colorScheme.outline,
        )
        Text(title, style = MaterialTheme.typography.titleMedium)
        Text(description, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun MediaRow(item: MediaItem, removable: Boolean, onRemove: () -> Unit) {
    Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface)) {
        Row(
            Modifier.fillMaxWidth().padding(16.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Icon(
                if (item.key.isNotBlank()) Icons.Rounded.CheckCircle else Icons.Rounded.Image,
                null,
                tint =
                    if (item.key.isNotBlank()) MaterialTheme.colorScheme.secondary
                    else MaterialTheme.colorScheme.primary,
            )
            Column(Modifier.weight(1f)) {
                Text(item.name, maxLines = 1, style = MaterialTheme.typography.titleSmall)
                Text(
                    item.status,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                if (item.albumName.isNotBlank())
                    Text(
                        "Google album: ${item.albumName} · ${item.membership.ifBlank { "Pending album" }}",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                if (item.status == "Uploading")
                    LinearProgressIndicator(
                        progress = { item.progress },
                        modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                    )
            }
            if (removable)
                IconButton(onClick = onRemove) { Icon(Icons.Rounded.Close, "Remove ${item.name}") }
        }
    }
}

@Composable
private fun SettingsCard(title: String, content: @Composable ColumnScope.() -> Unit) {
    Card {
        Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(title, style = MaterialTheme.typography.titleLarge)
            content()
        }
    }
}

@Composable
private fun <T> androidx.lifecycle.LiveData<T>.observeAsStateCompat(): State<T?> {
    val result = remember { mutableStateOf(value) }
    val owner = androidx.lifecycle.compose.LocalLifecycleOwner.current
    DisposableEffect(this, owner) {
        val observer = androidx.lifecycle.Observer<T> { result.value = it }
        observe(owner, observer)
        onDispose { removeObserver(observer) }
    }
    return result
}
