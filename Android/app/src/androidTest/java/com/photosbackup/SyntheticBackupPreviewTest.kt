package com.photosbackup

import android.graphics.Bitmap
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.photosbackup.data.MediaItem
import com.photosbackup.data.Store
import com.photosbackup.presentation.MainActivity
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Optional documentation capture: only generated names and a synthetic debug account. */
@RunWith(AndroidJUnit4::class)
class SyntheticBackupPreviewTest {
    @get:Rule val compose = createEmptyComposeRule()

    @Test fun captureSyntheticBackupScreen() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        assertEquals("com.photosbackup.debug", context.packageName)
        val store = Store.get(context)
        store.disconnect()
        store.connect("Email=preview%40example.test&Token=synthetic-preview-only")
        store.update {
            it.copy(
                notice = "",
                items = listOf(
                    MediaItem("synthetic-photo", "file:///synthetic-photo", "Coastal walk.jpg"),
                    MediaItem("synthetic-video", "file:///synthetic-video", "Evening sky.mp4"),
                ),
            )
        }
        try {
            ActivityScenario.launch(MainActivity::class.java).use {
                compose.onNodeWithText("Start backup").assertIsDisplayed().assertIsEnabled()
                compose.onNodeWithText("Select media").assertIsDisplayed()
                compose.onNodeWithText("Device folders").assertIsDisplayed()
                val image = compose.onRoot().captureToImage().asAndroidBitmap()
                val output = File(context.getExternalFilesDir("layout-preview"), "backup-synthetic.png")
                output.outputStream().use { image.compress(Bitmap.CompressFormat.PNG, 100, it) }
            }
        } finally {
            store.disconnect()
        }
    }
}
