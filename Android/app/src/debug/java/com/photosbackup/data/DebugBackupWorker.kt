package com.photosbackup.data

import android.content.Context
import androidx.work.WorkerParameters
import com.chaquo.python.Python
import java.util.concurrent.atomic.AtomicBoolean

/** Only packaged in debug APKs. Does not make network requests. */
class DebugBackupWorker(context: Context, params: WorkerParameters) :
    BackupWorker(context, params) {
    override fun upload(payload: String, listener: EventListener, cancellation: AtomicBoolean) {
        Python.getInstance()
            .getModule("debug_backend")
            .callAttr(
                "run",
                payload,
                listener,
                cancellation,
                inputData.getString("fixture") ?: "success",
            )
    }

    override fun addToAlbum(payload: String, listener: AlbumListener, cancellation: AtomicBoolean) {
        Python.getInstance()
            .getModule("debug_backend")
            .callAttr("run", payload, listener, cancellation, inputData.getString("fixture") ?: "success")
    }
}
