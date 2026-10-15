package com.photosbackup.data

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.pm.ServiceInfo
import android.net.Uri
import androidx.core.app.NotificationCompat
import androidx.work.*
import com.chaquo.python.Python
import com.photosbackup.domain.Policy
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean
import org.json.JSONArray
import org.json.JSONObject

open class BackupWorker(context: Context, params: WorkerParameters) : Worker(context, params) {
    private val cancellation = AtomicBoolean(false)
    private val store = Store.get(applicationContext)
    private val generation = inputData.getString("generation") ?: ""

    override fun onStopped() {
        cancellation.set(true)
        super.onStopped()
    }

    private fun foreground(): ForegroundInfo {
        val manager = applicationContext.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel("backup", "Media backup", NotificationManager.IMPORTANCE_LOW)
        )
        val notification =
            NotificationCompat.Builder(applicationContext, "backup")
                .setSmallIcon(android.R.drawable.stat_sys_upload)
                .setContentTitle("Backing up selected media")
                .setContentText("You can cancel at any time")
                .setOngoing(true)
                .addAction(
                    0,
                    "Cancel",
                    WorkManager.getInstance(applicationContext).createCancelPendingIntent(id),
                )
                .build()
        return if (android.os.Build.VERSION.SDK_INT >= 29)
            ForegroundInfo(14, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        else ForegroundInfo(14, notification)
    }

    override fun doWork(): Result {
        var failed = true
        try {
            setForegroundAsync(foreground()).get()
            val selected = inputData.getStringArray("selection")?.toSet().orEmpty()
            val items = store.state.value.items.filter { it.key.isEmpty() && it.id in selected }
            if (
                items.isEmpty() ||
                    store.state.value.email == null ||
                    store.state.value.generation != generation
            )
                return Result.failure()
            store.updateFor(generation) {
                it.copy(running = true, notice = "Preparing selected media…")
            }
            failed = false
            val auth = store.auth(generation)
            for (item in items) {
                if (isStopped || cancellation.get() || store.state.value.generation != generation)
                    break
                store.updateFor(generation) { s ->
                    s.copy(
                        items =
                            s.items.map {
                                if (it.id == item.id) it.copy(status = "Preparing", progress = 0f)
                                else it
                            }
                    )
                }
                val temp =
                    File.createTempFile(
                        "upload-",
                        "." +
                            item.name
                                .substringAfterLast('.', "bin")
                                .filter { it.isLetterOrDigit() }
                                .take(10),
                        applicationContext.cacheDir,
                    )
                try {
                    applicationContext.contentResolver.openInputStream(Uri.parse(item.uri)).use {
                        input ->
                        requireNotNull(input) { "Selection is no longer accessible" }
                        temp.outputStream().use { output ->
                            val buffer = ByteArray(1024 * 1024)
                            while (true) {
                                if (isStopped || cancellation.get()) throw InterruptedException()
                                val count = input.read(buffer)
                                if (count < 0) break
                                output.write(buffer, 0, count)
                            }
                        }
                    }
                    if (isStopped) break
                    val request =
                        JSONObject()
                            .put("command", "upload")
                            .put("auth_data", auth)
                            .put("quality", store.state.value.quality)
                            .put("timeout", 60)
                            .put("threads", 1)
                            .put(
                                "items",
                                JSONArray()
                                    .put(
                                        JSONObject()
                                            .put("id", item.id)
                                            .put("path", temp.absolutePath)
                                            .put("filename", item.name)
                                    ),
                            )
                    upload(
                        request.toString(),
                        EventListener(store, item.id, generation),
                        cancellation,
                    )
                    if (
                        store.state.value.items
                            .firstOrNull { it.id == item.id }
                            ?.key
                            .isNullOrBlank()
                    )
                        failed = true
                } catch (e: Exception) {
                    failed = true
                    store.updateFor(generation) { s ->
                        s.copy(
                            items =
                                s.items.map {
                                    if (it.id == item.id)
                                        it.copy(
                                            status =
                                                if (isStopped) "Cancelled"
                                                else
                                                    "Could not upload. Check connection and sign-in."
                                        )
                                    else it
                                }
                        )
                    }
                } finally {
                    temp.delete()
                }
            }
        } catch (e: Exception) {
            failed = true
            runCatching {
                store.updateFor(generation) {
                    it.copy(
                        notice =
                            "Backup could not continue. Check device storage and reconnect if needed."
                    )
                }
            }
        } finally {
            runCatching {
                store.updateFor(generation) { s ->
                    s.copy(
                        running = false,
                        items =
                            s.items.map {
                                if (
                                    it.key.isBlank() &&
                                        it.status in listOf("Preparing", "Uploading")
                                )
                                    it.copy(status = "Cancelled")
                                else it
                            },
                        notice =
                            if (s.items.none { it.key.isEmpty() }) "Selected media is backed up."
                            else if (isStopped || cancellation.get())
                                "Backup cancelled. Confirmed items are kept."
                            else if (failed) "Some items need attention. Start again to retry."
                            else "Ready to back up your remaining selection.",
                    )
                }
            }
        }
        return if (failed) Result.failure() else Result.success()
    }

    protected open fun upload(
        payload: String,
        listener: EventListener,
        cancellation: AtomicBoolean,
    ) {
        Python.getInstance()
            .getModule("android_bridge")
            .callAttr("run", payload, listener, cancellation)
    }

    companion object {
        fun start(context: Context) {
            val store = Store.get(context)
            val current = store.state.value
            if (current.running || current.connecting || current.email == null) return
            val selection = current.items.filter { it.key.isEmpty() }.map { it.id }.toTypedArray()
            if (selection.isEmpty()) return
            store.update { it.copy(running = true, notice = "Waiting for a network connection…") }
            try {
                WorkManager.getInstance(context)
                    .enqueueUniqueWork(
                        "backup",
                        ExistingWorkPolicy.KEEP,
                        OneTimeWorkRequestBuilder<BackupWorker>()
                            .setInputData(
                                workDataOf(
                                    "generation" to current.generation,
                                    "selection" to selection,
                                )
                            )
                            .setConstraints(
                                Constraints.Builder()
                                    .setRequiredNetworkType(NetworkType.CONNECTED)
                                    .build()
                            )
                            .build(),
                    )
            } catch (error: Exception) {
                store.updateFor(current.generation) {
                    it.copy(
                        running = false,
                        notice = "Could not schedule backup. Please try again.",
                    )
                }
            }
        }

        fun cancel(context: Context) {
            WorkManager.getInstance(context).cancelUniqueWork("backup")
            Store.get(context).update {
                it.copy(
                    running = false,
                    notice = "Cancellation requested. In-flight requests may finish.",
                )
            }
        }
    }
}

class EventListener(
    private val store: Store,
    private val id: String,
    private val generation: String,
) {
    @Suppress("unused")
    fun event(raw: String) {
        val e = JSONObject(raw)
        val type = e.optString("type")
        val key = e.optString("media_key")
        store.updateFor(generation) { s ->
            s.copy(
                items =
                    s.items.map { item ->
                        if (item.id != id) item
                        else
                            when {
                                Policy.confirmed(type, key) ->
                                    item.copy(
                                        status =
                                            if (e.optString("status") == "existing")
                                                "Already backed up"
                                            else "Backed up",
                                        key = key,
                                        progress = 1f,
                                    )
                                type == "progress" ->
                                    item.copy(
                                        status = "Uploading",
                                        progress =
                                            if (e.optLong("bytes_total") > 0)
                                                (e.optLong("bytes_completed").toFloat() /
                                                        e.optLong("bytes_total"))
                                                    .coerceIn(0f, 1f)
                                            else 0f,
                                    )
                                type in listOf("fatal", "item_failed") ->
                                    item.copy(
                                        status = "Upload failed. Check connection or reconnect."
                                    )
                                else -> item
                            }
                    }
            )
        }
    }
}
