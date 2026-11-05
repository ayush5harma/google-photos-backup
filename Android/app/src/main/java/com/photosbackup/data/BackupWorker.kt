package com.photosbackup.data

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.os.storage.StorageManager
import android.provider.OpenableColumns
import androidx.core.app.NotificationCompat
import androidx.core.net.toUri
import androidx.work.*
import com.chaquo.python.PyObject
import com.chaquo.python.Python
import com.photosbackup.domain.Policy
import com.photosbackup.domain.StagingWindow
import com.photosbackup.domain.ThroughputMeter
import com.photosbackup.domain.UploadFailure
import com.photosbackup.domain.UploadParallelism
import com.photosbackup.domain.UploadSample
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.Callable
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock
import org.json.JSONArray
import org.json.JSONObject

/** One selected item copied into the app's cache and hashed, ready for the bridge. */
class StagedItem(val item: MediaItem, val file: File, val bytes: Long, val sha256: String)

open class BackupWorker(context: Context, params: WorkerParameters) : Worker(context, params) {
    private val cancellation = AtomicBoolean(false)
    private val failed = AtomicBoolean(true)
    private val store = Store.get(applicationContext)
    private val generation = inputData.getString("generation") ?: ""
    private val meter = ThroughputMeter()
    /** Each uploading item's latest fraction sent, not yet on the screen. */
    private val progress = ConcurrentHashMap<String, Float>()
    private val staging = StagingBudget()
    private val notifyLock = Any()
    private var notifiedAt = 0L
    @Volatile private var selected = emptySet<String>()
    /** android_bridge.Session: one gpmc client and its kept connections for this run (#59). */
    private var bridgeSession: PyObject? = null

    override fun onStopped() {
        cancellation.set(true)
        super.onStopped()
    }

    private fun stopping() =
        isStopped || cancellation.get() || store.state.value.generation != generation

    private fun notification(text: String): Notification {
        val manager = applicationContext.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel("backup", "Media backup", NotificationManager.IMPORTANCE_LOW)
        )
        return NotificationCompat.Builder(applicationContext, "backup")
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setContentTitle("Backing up selected media")
            .setContentText(text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .addAction(
                0,
                "Cancel",
                WorkManager.getInstance(applicationContext).createCancelPendingIntent(id),
            )
            .build()
    }

    private fun foreground(text: String = "You can cancel at any time"): ForegroundInfo {
        val notification = notification(text)
        return if (android.os.Build.VERSION.SDK_INT >= 29)
            ForegroundInfo(14, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        else ForegroundInfo(14, notification)
    }

    /**
     * From the bridge's upload threads, once a second at most: the items' progress onto the
     * screen and "12 of 340 backed up · 3.4 MB/s" into the notification. Progress waits here
     * rather than going to the screen per event: a list copy per gpmc report from 8 threads.
     */
    private fun progressed() {
        val now = monotonicMillis()
        synchronized(notifyLock) {
            if (now - notifiedAt < NOTIFY_EVERY_MILLIS) return
            notifiedAt = now
        }
        val shown = HashMap(progress)
        if (shown.isNotEmpty()) {
            store.showFor(generation) { s ->
                s.copy(items = s.items.map { row ->
                    val fraction = shown[row.id]
                    // Only a row still on its way: an answer may have landed since the snapshot.
                    if (fraction == null || row.key.isNotBlank() || row.status !in listOf("Preparing", "Uploading")) row
                    else row.copy(status = "Uploading", progress = fraction)
                })
            }
            shown.forEach { (id, fraction) -> progress.remove(id, fraction) }
        }
        val rows = store.state.value.items.filter { it.id in selected }
        val done = rows.count { it.key.isNotBlank() }
        val speed = meter.bytesPerSecond(now)?.let { " · " + ThroughputMeter.speed(it) }.orEmpty()
        setForegroundAsync(foreground("$done of ${rows.size} backed up$speed"))
    }

    override fun doWork(): Result {
        try {
            setForegroundAsync(foreground()).get()
            selected = inputData.getStringArray("selection")?.toSet().orEmpty()
            val items = store.state.value.items.filter { it.key.isEmpty() && it.id in selected }
            val pendingMembership = store.state.value.items.any {
                it.id in selected && it.key.isNotBlank() && it.albumName.isNotBlank() && it.membership != "Added"
            }
            if (
                (items.isEmpty() && !pendingMembership) ||
                    store.state.value.email == null ||
                    store.state.value.generation != generation
            )
                return Result.failure()
            store.updateFor(generation) {
                it.copy(running = true, notice = "Preparing selected media…")
            }
            failed.set(false)
            val auth = store.auth(generation)
            uploadAll(items, auth)
            addMemberships(auth)
        } catch (e: Exception) {
            failed.set(true)
            runCatching {
                store.updateFor(generation) {
                    it.copy(
                        notice =
                            "Backup could not continue. Check device storage and reconnect if needed."
                    )
                }
            }
        } finally {
            closeBridge()
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
                            if (s.items.none { it.key.isEmpty() || (it.albumName.isNotBlank() && it.membership != "Added") }) "Selected media and albums are backed up."
                            else if (isStopped || cancellation.get())
                                "Backup cancelled. Confirmed items are kept."
                            else if (failed.get()) "Some items need attention. Start again to retry."
                            else "Ready to back up your remaining selection.",
                    )
                }
            }
        }
        return if (failed.get()) Result.failure() else Result.success()
    }

    /**
     * Sends [items] in batches of up to [StagingWindow.BATCH_ITEMS] items or
     * [StagingWindow.BATCH_BYTES] bytes, several uploads at once (issue #59). While one batch
     * uploads, a single staging thread copies and hashes the next, within the staging window.
     */
    private fun uploadAll(items: List<MediaItem>, auth: String) {
        if (items.isEmpty()) return
        // Touched by the staging thread only while a batch is being staged, and by this thread
        // only between a batch's Future completing and the next being submitted.
        val queue = ArrayDeque(items)
        val halt = AtomicBoolean(false)
        val stager = Executors.newSingleThreadExecutor()
        var parallelism =
            UploadParallelism.forSetting(store.state.value.parallelUploads, metered())
        var first = true
        var next: Future<List<StagedItem>>? = stager.submit(Callable { stageBatch(queue, halt) })
        try {
            while (next != null) {
                val batch = next.get()
                next = null
                if (queue.isNotEmpty() && !stopping())
                    next = stager.submit(Callable { stageBatch(queue, halt) })
                var rateLimited = false
                try {
                    if (stopping()) continue
                    parallelism = parallelism.recapped(UploadParallelism.networkCap(metered()))
                    val sample = send(batch, auth, parallelism.current, first) ?: continue
                    first = false
                    parallelism = parallelism.measured(sample)
                    rateLimited = sample.rateLimited
                } finally {
                    batch.forEach(::discard)
                }
                if (rateLimited) holdAfterRateLimit(parallelism)
            }
        } finally {
            halt.set(true)
            next?.let { pending -> runCatching { pending.get() }.getOrNull()?.forEach(::discard) }
            stager.shutdownNow()
        }
    }

    /**
     * Google answered 429: halving the uploads at once is not enough on its own, since the next
     * batch would go at once and its items fail the same way. The Mac holds every upload (its
     * RateLimiter); this is the simple form of that, a fixed pause that a cancel ends. 30 s is a
     * chosen margin, not a measured window.
     */
    private fun holdAfterRateLimit(parallelism: UploadParallelism) {
        store.updateFor(generation) { it.copy(notice = "Uploads go ${parallelism.summary}; they continue shortly…") }
        val until = monotonicMillis() + RATE_LIMIT_HOLD_MILLIS
        while (monotonicMillis() < until && !stopping()) Thread.sleep(250)
        store.updateFor(generation) { it.copy(notice = "Preparing selected media…") }
    }

    /** One batch, closed by its count or bytes, or early when the staging window is full. */
    private fun stageBatch(queue: ArrayDeque<MediaItem>, halt: AtomicBoolean): List<StagedItem> {
        val batch = mutableListOf<StagedItem>()
        var bytes = 0L
        try {
            while (queue.isNotEmpty() && !StagingWindow.full(batch.size, bytes)) {
                if (halt.get() || stopping()) break
                val item = queue.first()
                if (!staging.mayStage(sizeOf(item), cacheSpace())) {
                    // Send what is staged; with nothing staged, wait for the batch uploading.
                    if (batch.isNotEmpty()) break
                    staging.awaitRelease()
                    continue
                }
                queue.removeFirst()
                val staged = stage(item, halt) ?: continue
                batch += staged
                bytes += staged.bytes
            }
        } catch (e: Throwable) {
            batch.forEach(::discard)
            throw e
        }
        return batch
    }

    private fun stage(item: MediaItem, halt: AtomicBoolean): StagedItem? {
        store.showFor(generation) { s ->
            s.copy(items = s.items.map {
                if (it.id == item.id) it.copy(status = "Preparing", progress = 0f) else it
            })
        }
        val temp =
            File.createTempFile(
                "upload-",
                "." + item.name.substringAfterLast('.', "bin").filter { it.isLetterOrDigit() }.take(10),
                applicationContext.cacheDir,
            )
        try {
            val digest = MessageDigest.getInstance("SHA-256")
            var bytes = 0L
            applicationContext.contentResolver.openInputStream(item.uri.toUri()).use { input ->
                requireNotNull(input) { "Selection is no longer accessible" }
                temp.outputStream().use { output ->
                    val buffer = ByteArray(1024 * 1024)
                    while (true) {
                        if (halt.get() || stopping()) throw InterruptedException()
                        val count = input.read(buffer)
                        if (count < 0) break
                        output.write(buffer, 0, count)
                        digest.update(buffer, 0, count)
                        bytes += count
                    }
                }
            }
            val sha256 = digest.digest().joinToString("") { "%02x".format(it) }
            store.updateFor(generation) { state ->
                state.copy(items = state.items.map { row ->
                    if (row.id == item.id) row.copy(sha256 = sha256) else row
                })
            }
            // Counted once nothing can fail: the catch deletes the file without a release.
            staging.add(bytes)
            return StagedItem(item, temp, bytes, sha256)
        } catch (e: Exception) {
            temp.delete()
            failed.set(true)
            setStatus(
                item.id,
                if (isStopped || cancellation.get()) "Cancelled"
                else "Could not upload. Check connection and sign-in.",
            )
            return null
        }
    }

    /** A file that would not delete is removed at the next process start (BackupApplication). */
    private fun discard(staged: StagedItem) {
        staged.file.delete()
        staging.release(staged.bytes)
    }

    /** Sends one staged batch as one bridge request; null when nothing in it needed sending. */
    private fun send(batch: List<StagedItem>, auth: String, threads: Int, first: Boolean): UploadSample? {
        // The same bytes as an item already confirmed are that item: never sent twice. Within a
        // batch the first copy goes up and the others take its key afterwards.
        val leads = mutableListOf<StagedItem>()
        val followers = mutableListOf<Pair<StagedItem, StagedItem>>()
        for (staged in batch) {
            val known = store.state.value.items.firstOrNull {
                it.id != staged.item.id && it.sha256 == staged.sha256 && it.key.isNotBlank()
            }
            if (known != null) {
                markKnown(staged.item.id, known.key)
                continue
            }
            val lead = leads.firstOrNull { it.sha256 == staged.sha256 }
            if (lead != null) followers += staged to lead else leads += staged
        }
        if (leads.isEmpty() || stopping()) return null
        val ordered = StagingWindow.largestFirst(leads) { it.bytes }
        val request =
            JSONObject()
                .put("command", "upload")
                .put("auth_data", auth)
                .put("quality", store.state.value.quality)
                .put("timeout", 60)
                .put("threads", threads)
                .put(
                    "items",
                    JSONArray(ordered.map {
                        JSONObject()
                            .put("id", it.item.id)
                            .put("path", it.file.absolutePath)
                            .put("filename", it.item.name)
                    }),
                )
        val listener =
            EventListener(store, ordered.associate { it.item.id to it.bytes }, generation, meter, progress, ::progressed)
        val sentAt = System.nanoTime()
        try {
            upload(request.toString(), listener, cancellation)
        } catch (e: Exception) {
            failed.set(true)
            val status =
                if (isStopped) "Cancelled" else "Could not upload. Check connection and sign-in."
            ordered.filter { keyOf(it.item.id).isBlank() }.forEach { setStatus(it.item.id, status) }
        } finally {
            // Threads the bridge abandoned on a stop can still report; nothing may land later.
            listener.close()
        }
        for ((follower, lead) in followers) {
            val key = keyOf(lead.item.id)
            if (key.isNotBlank()) markKnown(follower.item.id, key)
            else setStatus(
                follower.item.id,
                if (isStopped || cancellation.get()) "Cancelled"
                else "Upload failed. Check connection or reconnect.",
            )
        }
        if (batch.any { keyOf(it.item.id).isBlank() }) failed.set(true)
        return listener.sample(sentAt, includesStartUp = first)
    }

    private fun keyOf(id: String) = store.state.value.items.firstOrNull { it.id == id }?.key.orEmpty()

    private fun markKnown(id: String, key: String) =
        store.updateFor(generation) { state ->
            state.copy(items = state.items.map { row ->
                if (row.id == id) row.copy(key = key, status = "Already backed up", progress = 1f) else row
            })
        }

    private fun setStatus(id: String, status: String) =
        store.updateFor(generation) { state ->
            state.copy(items = state.items.map { if (it.id == id) it.copy(status = status) else it })
        }

    private fun sizeOf(item: MediaItem): Long? =
        runCatching {
                applicationContext.contentResolver
                    .query(item.uri.toUri(), arrayOf(OpenableColumns.SIZE), null, null, null)
                    ?.use { if (it.moveToFirst() && !it.isNull(0)) it.getLong(0) else null }
            }
            .getOrNull()

    /** Unknown counts as metered: the lower cap is the safe side for a data plan. */
    private fun metered(): Boolean =
        applicationContext.getSystemService(ConnectivityManager::class.java)?.isActiveNetworkMetered
            ?: true

    /** What the cache volume could give, counting cached data Android would clear; null if unknown. */
    private fun cacheSpace(): Long? =
        runCatching {
                val storage = applicationContext.getSystemService(StorageManager::class.java)
                storage.getAllocatableBytes(storage.getUuidForPath(applicationContext.cacheDir))
            }
            .getOrNull()

    private fun addMemberships(auth: String) {
        // Upload confirmation and album membership are independent. Once a media key is
        // persisted, never send the bytes again just because Google album membership failed.
        val memberships = store.state.value.items
            .filter { it.id in selected && it.key.isNotBlank() && it.albumName.isNotBlank() && it.membership != "Added" }
            .groupBy { it.folderId.ifBlank { "legacy-name:${it.albumName}" } }
        for ((sourceFolderId, grouped) in memberships) {
            if (isStopped || cancellation.get() || store.state.value.generation != generation) break
            val albumName = grouped.first().albumName
            val priorIds = grouped.map { it.albumId }.filter { it.isNotBlank() }.distinct()
            if (priorIds.size > 1) {
                store.updateFor(generation) { state -> state.copy(notice = "Album $albumName needs review before retrying.") }
                failed.set(true)
                continue
            }
            val hasUncertainCreation = priorIds.isEmpty() && grouped.any { it.albumCreation == "Attempted" }
            if (hasUncertainCreation) {
                store.updateFor(generation) { state -> state.copy(items = state.items.map { item ->
                    if (item.folderId == sourceFolderId) item.copy(membership = "Remote album creation needs review") else item
                }, notice = "Google album creation for $albumName was interrupted. It will not be retried automatically.") }
                failed.set(true)
                continue
            }
            val album = JSONObject().apply {
                if (priorIds.singleOrNull() != null) put("id", priorIds.single()) else put("name", albumName)
            }
            // This must reach durable storage before a name-based Google call. If the
            // process dies before Google returns an ID, retrying could make a duplicate.
            if (priorIds.isEmpty()) store.updateFor(generation) { state -> state.copy(items = state.items.map { item ->
                if (item.folderId == sourceFolderId) item.copy(albumCreation = "Attempted", membership = "Creating remote album") else item
            }) }
            store.updateFor(generation) { state ->
                state.copy(items = state.items.map { item ->
                    if (item.id in grouped.map { it.id }) item.copy(membership = "Adding to album") else item
                })
            }
            try {
                val request = JSONObject()
                    .put("command", "add-to-album")
                    .put("auth_data", auth)
                    .put("timeout", 60)
                    .put("album", album)
                    .put("media_keys", JSONArray(grouped.map { it.key }))
                addToAlbum(request.toString(), AlbumListener(store, grouped.map { it.id }.toSet(), generation), cancellation)
                if (store.state.value.items.any { it.id in grouped.map { row -> row.id } && it.membership != "Added" }) failed.set(true)
            } catch (e: Exception) {
                failed.set(true)
                store.updateFor(generation) { state ->
                    state.copy(items = state.items.map { item ->
                    if (item.id in grouped.map { it.id }) item.copy(membership = if (priorIds.isEmpty()) "Remote album creation needs review" else "Album retry needed") else item
                    })
                }
            }
        }
    }

    private fun bridge(): PyObject =
        bridgeSession
            ?: Python.getInstance().getModule("android_bridge").callAttr("session").also {
                bridgeSession = it
            }

    /** Ends the run's gpmc client and closes its kept connections. */
    private fun closeBridge() {
        val session = bridgeSession ?: return
        bridgeSession = null
        runCatching { session.callAttr("close") }
        session.close()
    }

    protected open fun upload(
        payload: String,
        listener: EventListener,
        cancellation: AtomicBoolean,
    ) {
        bridge().callAttr("run", payload, listener, cancellation)
    }

    protected open fun addToAlbum(payload: String, listener: AlbumListener, cancellation: AtomicBoolean) {
        bridge().callAttr("run", payload, listener, cancellation)
    }

    companion object {
        private const val NOTIFY_EVERY_MILLIS = 1_000L
        private const val RATE_LIMIT_HOLD_MILLIS = 30_000L

        internal fun monotonicMillis() = System.nanoTime() / 1_000_000

        fun start(context: Context) {
            val store = Store.get(context)
            val current = store.state.value
            if (current.running || current.connecting || current.email == null) return
            val selection = current.items.filter { it.key.isEmpty() || (it.albumName.isNotBlank() && it.membership != "Added") }.map { it.id }.toTypedArray()
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

/** Bytes staged in the app's cache and not yet uploaded and deleted, across both threads. */
private class StagingBudget {
    private val lock = ReentrantLock()
    private val released = lock.newCondition()
    private var staged = 0L

    /** With nothing staged an item always may: the batch uploading goes whatever its size. */
    fun mayStage(next: Long?, freeSpace: Long?): Boolean =
        lock.withLock { staged == 0L || StagingWindow.mayStage(staged, next, freeSpace) }

    fun add(bytes: Long) = lock.withLock { staged += bytes }

    fun release(bytes: Long) =
        lock.withLock {
            staged -= bytes
            released.signalAll()
        }

    /** Bounded, so a stop is noticed even if no release comes. */
    fun awaitRelease() {
        lock.withLock { released.await(500, TimeUnit.MILLISECONDS) }
    }
}

/**
 * The bridge's events for one request: confirmations and failures persist per item, and the
 * request's outcome feeds the parallelism controller. Progress comes from all of the bridge's
 * upload threads, inside gpmc's upload stream, so it takes no lock that a confirmation's disk
 * write holds: it goes to the meter and to [shown], which the worker puts on the screen once a
 * second. Confirmations and failures come from the bridge's request thread, one at a time.
 */
class EventListener(
    private val store: Store,
    /** Each item's id and staged size. */
    private val sizes: Map<String, Long>,
    private val generation: String,
    private val meter: ThroughputMeter? = null,
    /** Latest fraction sent per item; null shows progress at once (single-item use). */
    private val shown: ConcurrentHashMap<String, Float>? = null,
    private val onProgress: () -> Unit = {},
) {
    /** One item of unknown size: the shape a single-item request and its tests use. */
    constructor(store: Store, id: String, generation: String) : this(store, mapOf(id to 0L), generation)

    @Volatile private var closed = false
    private val answered: MutableSet<String> = ConcurrentHashMap.newKeySet()
    private val lock = Any()
    private var uploadedItems = 0
    private var uploadedBytes = 0L
    private var serverFailures = 0
    private var rateLimited = false
    private var lastAnswerAt = 0L

    fun close() {
        synchronized(lock) { closed = true }
    }

    @Suppress("unused")
    fun event(raw: String) {
        if (closed) return
        val e = JSONObject(raw)
        val type = e.optString("type")
        // An id names one of this request's items; an event without one belongs to the request,
        // or to its only item.
        val id = if (e.isNull("id")) sizes.keys.singleOrNull() else e.optString("id").takeIf { it in sizes }
        if (type == "progress") {
            if (id == null || id in answered) return
            progress(id, e)
        } else synchronized(lock) {
            // Rechecked under the lock: close() after the request returns ends every answer.
            if (closed) return
            when {
                type == "fatal" -> {
                    if (e.optString("kind") == "rate_limit") rateLimited = true
                    (sizes.keys - answered).forEach { setStatus(it, "Upload failed. Check connection or reconnect.") }
                }
                id == null || id in answered -> return
                Policy.confirmed(type, e.optString("media_key")) -> confirm(id, e)
                type == "item_failed" -> fail(id, e)
                else -> return
            }
        }
        onProgress()
    }

    private fun confirm(id: String, e: JSONObject) {
        answer(id)
        val existing = e.optString("status") == "existing"
        if (!existing) {
            uploadedItems += 1
            uploadedBytes += sizes[id] ?: 0L
        }
        store.updateFor(generation) { s ->
            s.copy(items = s.items.map { item ->
                if (item.id != id) item
                else item.copy(
                    status = if (existing) "Already backed up" else "Backed up",
                    key = e.optString("media_key"),
                    progress = 1f,
                )
            })
        }
    }

    private fun progress(id: String, e: JSONObject) {
        val completed = e.optLong("bytes_completed")
        val total = e.optLong("bytes_total")
        if (e.optString("phase") == "uploading") meter?.sent(id, completed, BackupWorker.monotonicMillis())
        val fraction = if (total > 0) (completed.toFloat() / total).coerceIn(0f, 1f) else 0f
        if (shown != null) {
            shown[id] = fraction
            return
        }
        store.showFor(generation) { s ->
            s.copy(items = s.items.map { item ->
                if (item.id != id) item else item.copy(status = "Uploading", progress = fraction)
            })
        }
    }

    private fun fail(id: String, e: JSONObject) {
        answer(id)
        val retryable = if (e.has("retryable")) e.optBoolean("retryable") else null
        when (UploadFailure.classify(e.optString("message"), retryable)) {
            UploadFailure.Kind.RATE_LIMITED -> rateLimited = true
            UploadFailure.Kind.RETRYABLE -> serverFailures += 1
            UploadFailure.Kind.PERMANENT -> Unit
        }
        setStatus(id, "Upload failed. Check connection or reconnect.")
    }

    private fun answer(id: String) {
        answered += id
        shown?.remove(id)
        meter?.finished(id)
        lastAnswerAt = System.nanoTime()
    }

    private fun setStatus(id: String, status: String) =
        store.updateFor(generation) { s ->
            s.copy(items = s.items.map { if (it.id == id) it.copy(status = status) else it })
        }

    /** The request as the controller reads it, timed to its last item's answer. */
    fun sample(sentAtNanos: Long, includesStartUp: Boolean): UploadSample = synchronized(lock) {
        val end = if (lastAnswerAt != 0L) lastAnswerAt else System.nanoTime()
        UploadSample(
            bytes = uploadedBytes,
            seconds = (end - sentAtNanos) / 1e9,
            items = uploadedItems,
            rateLimited = rateLimited,
            serverFailures = serverFailures,
            includesStartUp = includesStartUp,
        )
    }
}

class AlbumListener(
    private val store: Store,
    private val ids: Set<String>,
    private val generation: String,
) {
    @Suppress("unused")
    fun event(raw: String) {
        val event = JSONObject(raw)
        store.updateFor(generation) { state ->
            state.copy(items = state.items.map { item ->
                if (item.id !in ids) item else when (event.optString("type")) {
                    "album" -> {
                        val remoteId = event.optString("album_id")
                        // An empty acknowledgement is ambiguous: keep it retryable rather than
                        // pretending we know which remote album Google chose.
                        if (remoteId.isBlank()) item.copy(membership = "Album retry needed")
                        else item.copy(albumId = remoteId, albumCreation = "Acknowledged", membership = "Added")
                    }
                    "album_failed", "fatal" -> item.copy(membership = "Album retry needed")
                    else -> item
                }
            })
        }
    }
}
