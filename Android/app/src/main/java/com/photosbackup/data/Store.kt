package com.photosbackup.data

import android.content.Context
import android.net.Uri
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import com.photosbackup.domain.Policy
import java.io.File
import java.security.KeyStore
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import kotlinx.coroutines.flow.MutableStateFlow
import org.json.JSONArray
import org.json.JSONObject

data class MediaItem(
    val id: String,
    val uri: String,
    val name: String,
    val status: String = "Ready",
    val key: String = "",
    val progress: Float = 0f,
    /** Name is user-visible only; remoteId is Google's acknowledged stable identifier. */
    val albumName: String = "",
    val albumId: String = "",
    val membership: String = "",
    val sha256: String = "",
    /** Stable MediaStore volume + bucket id. Folder names are not unique. */
    val folderId: String = "",
    /** A name-based create may have reached Google before Android crashed. Never retry it blindly. */
    val albumCreation: String = "",
) {
    fun json() =
        JSONObject()
            .put("id", id)
            .put("uri", uri)
            .put("name", name)
            .put("status", status)
            .put("key", key)
            .put("progress", progress)
            .put("albumName", albumName)
            .put("albumId", albumId)
            .put("membership", membership)
            .put("sha256", sha256)
            .put("folderId", folderId)
            .put("albumCreation", albumCreation)

    companion object {
        fun from(j: JSONObject) =
            MediaItem(
                j.getString("id"),
                j.getString("uri"),
                j.getString("name"),
                j.getString("status"),
                j.optString("key"),
                j.optDouble("progress", 0.0).toFloat(),
                j.optString("albumName"),
                j.optString("albumId"),
                j.optString("membership"),
                j.optString("sha256"),
                j.optString("folderId"),
                j.optString("albumCreation"),
            )
    }
}

data class BackupState(
    val email: String? = null,
    val items: List<MediaItem> = emptyList(),
    val running: Boolean = false,
    val connecting: Boolean = false,
    val notice: String = "",
    val quality: String = "original",
    val generation: String = UUID.randomUUID().toString(),
)

class Store private constructor(private val context: Context) {
    private val file = AtomicFile(File(context.noBackupFilesDir, "queue.json"))
    private val credential = File(context.noBackupFilesDir, "account.enc")
    val state = MutableStateFlow(load())

    private fun load(): BackupState =
        runCatching {
                val j = JSONObject(String(file.readFully()))
                BackupState(
                    j.optString("email").takeIf { it.isNotBlank() },
                    (j.getJSONArray("items")).let { a ->
                        (0 until a.length()).map { MediaItem.from(a.getJSONObject(it)) }
                    },
                    running = false,
                    notice = "",
                    quality = j.optString("quality", "original"),
                    generation = j.optString("generation", UUID.randomUUID().toString()),
                )
            }
            .getOrDefault(BackupState())

    @Synchronized
    fun update(change: (BackupState) -> BackupState) {
        val next = change(state.value)
        val j =
            JSONObject()
                .put("generation", next.generation)
                .put("email", next.email ?: "")
                .put("quality", next.quality)
                .put("items", JSONArray(next.items.map { it.json() }))
        var out: java.io.FileOutputStream? = null
        try {
            out = file.startWrite()
            out.write(j.toString().toByteArray())
            file.finishWrite(out)
            check(file.readFully().contentEquals(j.toString().toByteArray())) {
                "Queue was not persisted"
            }
        } catch (e: Exception) {
            if (out != null) file.failWrite(out)
            state.value =
                state.value.copy(
                    running = false,
                    notice = "Could not save backup state. Free device storage and retry.",
                )
            throw e
        }
        state.value = next
    }

    private fun key(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        return (ks.getKey("photos-backup", null) as? SecretKey)
            ?: KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
                .apply {
                    init(
                        KeyGenParameterSpec.Builder(
                                "photos-backup",
                                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                            )
                            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                            .build()
                    )
                }
                .generateKey()
    }

    @Synchronized
    fun auth(generation: String): String {
        require(state.value.generation == generation)
        val bytes = credential.readBytes()
        require(bytes.size > 28)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
        val payload = JSONObject(String(cipher.doFinal(bytes.copyOfRange(12, bytes.size))))
        require(payload.getString("generation") == generation)
        return payload.getString("auth")
    }

    @Synchronized
    fun beginConnection(): Boolean {
        if (state.value.running || state.value.connecting) return false
        state.value = state.value.copy(connecting = true)
        return true
    }

    @Synchronized
    fun endConnection() {
        state.value = state.value.copy(connecting = false)
    }

    suspend fun connectValidated(auth: String, validate: suspend (String) -> Boolean) {
        check(beginConnection()) { "Another account operation or backup is running" }
        try {
            require(validate(auth)) { "Google Photos did not accept the account" }
            kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { connect(auth) }
        } finally {
            endConnection()
        }
    }

    @Synchronized
    fun connect(auth: String) {
        require(!state.value.running) { "Wait for backup to finish before connecting" }
        val email = Policy.email(auth) ?: error("Credential must include an account email")
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val generation = UUID.randomUUID().toString()
        val payload = JSONObject().put("generation", generation).put("auth", auth).toString()
        val f = AtomicFile(credential)
        val out = f.startWrite()
        try {
            out.write(cipher.iv + cipher.doFinal(payload.toByteArray()))
            f.finishWrite(out)
            val persisted = credential.readBytes()
            check(persisted.size > 28)
            val verify = Cipher.getInstance("AES/GCM/NoPadding")
            verify.init(
                Cipher.DECRYPT_MODE,
                key(),
                GCMParameterSpec(128, persisted.copyOfRange(0, 12)),
            )
            check(String(verify.doFinal(persisted.copyOfRange(12, persisted.size))) == payload)
        } catch (e: Exception) {
            f.failWrite(out)
            throw e
        }
        update {
            it.copy(
                email = email,
                running = false,
                connecting = false,
                items = emptyList(),
                notice = "Connected to Google Photos",
                generation = generation,
            )
        }
    }

    @Synchronized
    fun disconnect() {
        require(!state.value.running && !state.value.connecting)
        credential.delete()
        update { BackupState() }
    }

    fun add(uris: List<Uri>) {
        val added =
            uris.map { uri ->
                var name = "Selected media"
                context.contentResolver
                    .query(
                        uri,
                        arrayOf(android.provider.OpenableColumns.DISPLAY_NAME),
                        null,
                        null,
                        null,
                    )
                    ?.use { if (it.moveToFirst()) name = it.getString(0) }
                MediaItem(UUID.randomUUID().toString(), uri.toString(), name)
            }
        update { s ->
            s.copy(
                items = s.items + added.filter { a -> s.items.none { it.uri == a.uri } },
                notice = "${added.size} selected. Start when you're ready.",
            )
        }
    }

    /** Replaces the queued view of a device folder with its currently accessible media.
     * Existing confirmed keys and Google album ids survive refreshes, so refresh never reuploads.
     */
    fun replaceFolderFor(generation: String, folder: DeviceFolder, media: List<DeviceMedia>) {
        updateFor(generation) { state ->
            val old = state.items.filter { it.folderId == folder.id }.associateBy { it.uri }
            val refreshed = media.map { candidate ->
                old[candidate.uri]?.copy(name = candidate.name)
                    ?: MediaItem(
                        id = candidate.stableId,
                        uri = candidate.uri,
                        name = candidate.name,
                        albumName = folder.name,
                        membership = "Pending album",
                        folderId = folder.id,
                    )
            }
            state.copy(
                items = state.items.filterNot { it.folderId == folder.id } + refreshed,
                notice = "${refreshed.size} currently accessible items in ${folder.name}. Review before backup.",
            )
        }
    }

    /** This is deliberately user initiated after they inspect Google Photos. It never guesses
     * whether an interrupted name-based request created an album. */
    fun confirmAlbumCreateRetry(folderId: String): Boolean {
        var changed = false
        update { state ->
            val next = state.items.map { item ->
                if (item.folderId == folderId && item.albumId.isBlank() && item.albumCreation == "Attempted") {
                    changed = true
                    item.copy(albumCreation = "User confirmed retry", membership = "Pending album")
                } else item
            }
            if (changed)
                state.copy(
                    items = next,
                    notice = "Album creation retry confirmed. It may create another album with this name.",
                )
            else state
        }
        return changed
    }

    @Synchronized
    fun updateFor(generation: String, change: (BackupState) -> BackupState) {
        if (state.value.generation == generation) update(change)
    }

    companion object {
        @Volatile private var instance: Store? = null

        fun get(c: Context): Store =
            instance
                ?: synchronized(this) {
                    instance ?: Store(c.applicationContext).also { instance = it }
                }
    }
}
