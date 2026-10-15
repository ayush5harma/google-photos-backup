package com.photosbackup

import android.graphics.Bitmap
import android.net.Uri
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.work.testing.TestWorkerBuilder
import androidx.work.workDataOf
import com.photosbackup.data.*
import java.io.File
import java.util.concurrent.Executors
import kotlinx.coroutines.launch
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class QueueSmokeTest {
    private val context = ApplicationProvider.getApplicationContext<android.content.Context>()

    private fun runFixture(mode: String): MediaItem {
        val store = Store.get(context)
        store.disconnect()
        store.connect("Email=synthetic%40example.test&Token=synthetic-test-only")
        val fixture = File(context.cacheDir, "synthetic.png")
        Bitmap.createBitmap(2, 2, Bitmap.Config.ARGB_8888).also { bitmap ->
            fixture.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
            bitmap.recycle()
        }
        val item = MediaItem("synthetic-id", Uri.fromFile(fixture).toString(), "synthetic.png")
        store.update { it.copy(items = listOf(item)) }
        val generation = store.state.value.generation
        val executor = Executors.newSingleThreadExecutor()
        try {
            val worker =
                TestWorkerBuilder<DebugBackupWorker>(
                        context,
                        executor,
                        workDataOf(
                            "generation" to generation,
                            "selection" to arrayOf(item.id),
                            "fixture" to mode,
                        ),
                    )
                    .build()
            worker.doWork()
            return store.state.value.items.single()
        } finally {
            executor.shutdownNow()
            fixture.delete()
        }
    }

    @Test
    fun successRequiresKeyAndCleansStaging() {
        val item = runFixture("success")
        assertEquals("synthetic-media-key", item.key)
        assertEquals("Backed up", item.status)
        assertTrue(context.cacheDir.listFiles().orEmpty().none { it.name.startsWith("upload-") })
    }

    @Test
    fun failureNeverConfirms() {
        assertEquals("", runFixture("failure").key)
    }

    @Test
    fun cancellationNeverConfirms() {
        assertEquals("", runFixture("cancel").key)
    }

    @Test
    fun staleAccountCallbackCannotConfirmNewAccount() {
        val store = Store.get(context)
        store.disconnect()
        store.connect("Email=first%40example.test&Token=synthetic")
        val generation = store.state.value.generation
        store.connect("Email=second%40example.test&Token=synthetic")
        store.update {
            it.copy(items = listOf(MediaItem("same-id", "file:///synthetic", "synthetic.png")))
        }
        EventListener(store, "same-id", generation)
            .event(JSONObject().put("type", "item").put("media_key", "wrong-account").toString())
        assertTrue(store.state.value.items.single().key.isEmpty())
    }

    @Test
    fun interruptedAccountPersistenceFailsClosed() {
        val store = Store.get(context)
        store.disconnect()
        store.connect("Email=first%40example.test&Token=synthetic-first")
        val previousGeneration = store.state.value.generation
        val queue = File(context.noBackupFilesDir, "queue.json.new")
        queue.deleteRecursively()
        assertTrue(queue.mkdir())
        File(queue, "blocker").writeText("synthetic persistence failure")
        try {
            assertTrue(
                runCatching { store.connect("Email=second%40example.test&Token=synthetic-second") }
                    .isFailure
            )
            assertTrue(runCatching { store.auth(previousGeneration) }.isFailure)
        } finally {
            queue.deleteRecursively()
            store.disconnect()
        }
    }

    @Test
    fun accountConnectionAndBackupAreMutuallyExclusive() {
        val store = Store.get(context)
        store.disconnect()
        store.update { it.copy(running = true) }
        assertFalse(store.beginConnection())
        assertTrue(
            runCatching { store.connect("Email=other%40example.test&Token=synthetic") }.isFailure
        )
        store.update { it.copy(running = false) }
        assertTrue(store.beginConnection())
        BackupWorker.start(context)
        assertFalse(store.state.value.running)
        store.endConnection()
    }

    @Test
    fun embeddedGpmcImportsWithoutNetwork() {
        val python = com.chaquo.python.Python.getInstance()
        assertNotNull(python.getModule("gpmc").get("Client"))
        assertNotNull(python.getModule("requests"))
        assertNotNull(python.getModule("blackboxprotobuf"))
        assertNotNull(python.getModule("rich"))
    }

    @Test
    fun cancelledValidationReleasesAccountReservation() =
        kotlinx.coroutines.runBlocking {
            val store = Store.get(context)
            store.disconnect()
            val validation =
                launch(start = kotlinx.coroutines.CoroutineStart.UNDISPATCHED) {
                    store.connectValidated("synthetic") { kotlinx.coroutines.awaitCancellation() }
                }
            assertTrue(store.state.value.connecting)
            validation.cancel()
            validation.join()
            assertFalse(store.state.value.connecting)
            assertNull(store.state.value.email)
        }

    @Test
    fun albumFailureKeepsConfirmedMediaForMembershipRetry() {
        val store = Store.get(context)
        store.disconnect()
        store.connect("Email=album%40example.test&Token=synthetic")
        val item = MediaItem(
            "album-item", "file:///synthetic", "synthetic.png", key = "confirmed-key",
            albumName = "Camera", membership = "Adding to album",
        )
        store.update { it.copy(items = listOf(item)) }
        AlbumListener(store, setOf(item.id), store.state.value.generation)
            .event(JSONObject().put("type", "album_failed").toString())
        val retry = store.state.value.items.single()
        assertEquals("confirmed-key", retry.key)
        assertEquals("Album retry needed", retry.membership)
    }

    @Test
    fun albumAcknowledgementPersistsExactRemoteId() {
        val store = Store.get(context)
        store.disconnect()
        store.connect("Email=album%40example.test&Token=synthetic")
        val item = MediaItem(
            "album-item", "file:///synthetic", "synthetic.png", key = "confirmed-key",
            albumName = "Camera", membership = "Adding to album",
        )
        store.update { it.copy(items = listOf(item)) }
        AlbumListener(store, setOf(item.id), store.state.value.generation)
            .event(JSONObject().put("type", "album").put("album_id", "remote-album-42").toString())
        val confirmed = store.state.value.items.single()
        assertEquals("confirmed-key", confirmed.key)
        assertEquals("remote-album-42", confirmed.albumId)
        assertEquals("Added", confirmed.membership)
    }

    @Test
    fun sameNamedBucketsKeepSeparateQueues() {
        val store = Store.get(context)
        store.disconnect()
        store.connect("Email=folders%40example.test&Token=synthetic")
        val generation = store.state.value.generation
        store.replaceFolderFor(
            generation,
            DeviceFolder("external:camera", "Camera", 1),
            listOf(DeviceMedia("external:1", "content://media/1", "one.jpg")),
        )
        store.replaceFolderFor(
            generation,
            DeviceFolder("external:shared-camera", "Camera", 1),
            listOf(DeviceMedia("external:2", "content://media/2", "two.jpg")),
        )
        assertEquals(setOf("external:camera", "external:shared-camera"), store.state.value.items.map { it.folderId }.toSet())
    }

    @Test
    fun staleFolderQueryCannotPopulateNewAccount() {
        val store = Store.get(context)
        store.disconnect()
        store.connect("Email=first%40example.test&Token=synthetic")
        val oldGeneration = store.state.value.generation
        store.connect("Email=second%40example.test&Token=synthetic")
        store.replaceFolderFor(
            oldGeneration,
            DeviceFolder("external:camera", "Camera", 1),
            listOf(DeviceMedia("external:1", "content://media/1", "one.jpg")),
        )
        assertTrue(store.state.value.items.isEmpty())
    }

    @Test
    fun interruptedNameCreationNeverAutomaticallyRetries() {
        val store = Store.get(context)
        store.disconnect()
        store.connect("Email=album%40example.test&Token=synthetic")
        val item = MediaItem(
            "uncertain-album", "file:///synthetic", "synthetic.png", key = "confirmed-key",
            albumName = "Camera", membership = "Remote album creation needs review",
            folderId = "external:camera", albumCreation = "Attempted",
        )
        store.update { it.copy(items = listOf(item)) }
        val executor = Executors.newSingleThreadExecutor()
        try {
            TestWorkerBuilder<DebugBackupWorker>(
                    context, executor,
                    workDataOf("generation" to store.state.value.generation, "selection" to arrayOf(item.id)),
                ).build().doWork()
        } finally { executor.shutdownNow() }
        val result = store.state.value.items.single()
        assertEquals("confirmed-key", result.key)
        assertEquals("", result.albumId)
        assertEquals("Remote album creation needs review", result.membership)
    }

    @Test
    fun userCanExplicitlyRecoverUncertainAlbumCreationButNotAcknowledgedAlbum() {
        val store = Store.get(context)
        store.disconnect()
        store.connect("Email=album%40example.test&Token=synthetic")
        val uncertain = MediaItem(
            "uncertain", "file:///one", "one.png", key = "key-one", albumName = "Camera",
            folderId = "external:camera", albumCreation = "Attempted",
            membership = "Remote album creation needs review",
        )
        val acknowledged = MediaItem(
            "acknowledged", "file:///two", "two.png", key = "key-two", albumName = "Camera",
            folderId = "external:camera", albumId = "known-google-id", albumCreation = "Acknowledged",
            membership = "Added",
        )
        store.update { it.copy(items = listOf(uncertain, acknowledged)) }
        assertTrue(store.confirmAlbumCreateRetry("external:camera"))
        val recovered = store.state.value.items.first { it.id == "uncertain" }
        assertEquals("User confirmed retry", recovered.albumCreation)
        assertEquals("Pending album", recovered.membership)
        val known = store.state.value.items.first { it.id == "acknowledged" }
        assertEquals("Acknowledged", known.albumCreation)
        assertEquals("Added", known.membership)
        assertFalse(store.confirmAlbumCreateRetry("external:unknown"))
    }
}
