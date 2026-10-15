package com.photosbackup.data

import android.content.ContentUris
import android.content.Context
import android.os.Build
import android.provider.MediaStore

data class DeviceFolder(val id: String, val name: String, val count: Int)
data class DeviceMedia(val stableId: String, val uri: String, val name: String)

/** MediaStore only returns media the user has granted this app access to. */
class DeviceLibrary(private val context: Context) {
    private val resolver get() = context.contentResolver
    private val collection = MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL)
    private val projection = arrayOf(
        MediaStore.Files.FileColumns._ID,
        MediaStore.Files.FileColumns.DISPLAY_NAME,
        MediaStore.Files.FileColumns.BUCKET_ID,
        MediaStore.Files.FileColumns.BUCKET_DISPLAY_NAME,
        MediaStore.Files.FileColumns.MEDIA_TYPE,
    )
    private val visualSelection = "${MediaStore.Files.FileColumns.MEDIA_TYPE} IN (?, ?)"
    private val visualArgs = arrayOf(
        MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE.toString(),
        MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO.toString(),
    )

    fun folders(): List<DeviceFolder> {
        val groups = linkedMapOf<String, Pair<String, Int>>()
        resolver.query(collection, projection, visualSelection, visualArgs, null)?.use { cursor ->
            val bucket = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.BUCKET_ID)
            val name = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.BUCKET_DISPLAY_NAME)
            while (cursor.moveToNext()) {
                val id = cursor.getString(bucket) ?: continue
                val title = cursor.getString(name)?.takeIf { it.isNotBlank() } ?: "Unnamed folder"
                val current = groups[id]
                groups[id] = title to ((current?.second ?: 0) + 1)
            }
        }
        return groups.map { (id, value) -> DeviceFolder(id, value.first, value.second) }
            .sortedBy { it.name.lowercase() }
    }

    fun media(folder: DeviceFolder): List<DeviceMedia> {
        val selection = "$visualSelection AND ${MediaStore.Files.FileColumns.BUCKET_ID} = ?"
        val args = visualArgs + folder.id
        return buildList {
            resolver.query(collection, projection, selection, args, "${MediaStore.Files.FileColumns.DATE_MODIFIED} DESC")?.use { cursor ->
                val id = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns._ID)
                val name = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.DISPLAY_NAME)
                while (cursor.moveToNext()) {
                    val mediaId = cursor.getLong(id)
                    val displayName = cursor.getString(name)?.takeIf { it.isNotBlank() } ?: "Selected media"
                    add(DeviceMedia("external:$mediaId", ContentUris.withAppendedId(collection, mediaId).toString(), displayName))
                }
            }
        }
    }

    companion object {
        fun permissionState(context: Context): String {
            if (Build.VERSION.SDK_INT < 33) return "Granted access"
            val images = context.checkSelfPermission(android.Manifest.permission.READ_MEDIA_IMAGES) == android.content.pm.PackageManager.PERMISSION_GRANTED
            val videos = context.checkSelfPermission(android.Manifest.permission.READ_MEDIA_VIDEO) == android.content.pm.PackageManager.PERMISSION_GRANTED
            if (images && videos) return "Full library access"
            if (Build.VERSION.SDK_INT >= 34 && context.checkSelfPermission(android.Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED) == android.content.pm.PackageManager.PERMISSION_GRANTED) return "Partial library access"
            return "No library access"
        }
    }
}
