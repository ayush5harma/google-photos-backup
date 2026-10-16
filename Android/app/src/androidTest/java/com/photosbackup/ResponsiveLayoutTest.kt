package com.photosbackup

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.photosbackup.data.MediaItem
import com.photosbackup.presentation.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Synthetic presentation only: never loads Store, device media or account credentials. */
@RunWith(AndroidJUnit4::class)
class ResponsiveLayoutTest {
    @get:Rule val compose = createComposeRule()

    private fun content(fontScale: Float = 1f, body: @Composable () -> Unit) {
        compose.setContent {
            val density = LocalDensity.current.density
            CompositionLocalProvider(LocalDensity provides Density(density, fontScale)) {
                BackupTheme { body() }
            }
        }
    }

    private fun bounds(text: String): Rect = compose.onNodeWithText(text).fetchSemanticsNode().boundsInRoot

    private fun assertLabelFits(text: String, maximumLines: Int = 2) {
        val layouts = mutableListOf<TextLayoutResult>()
        compose.onNodeWithText(text, useUnmergedTree = true)
            .performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
        val layout = layouts.single()
        assertTrue("$text should use at most $maximumLines lines", layout.lineCount <= maximumLines)
        // Compose semantics can retain the parent's paragraph allocation even
        // when Text measures tighter. Check rendered lines against Text's size.
        for (line in 0 until layout.lineCount) {
            val width = layout.getLineRight(line) - layout.getLineLeft(line)
            assertTrue("$text line $line must fit its measured width", width <= layout.size.width + 1f)
            assertFalse("$text must remain fully readable", layout.isLineEllipsized(line))
        }
        assertFalse("$text must not overflow vertically", layout.didOverflowHeight)
    }

    @Composable
    private fun Actions(busy: Boolean = false, backingUp: Boolean = false, onAction: () -> Unit = {}) {
        BackupActions(busy, backingUp, false, true, onAction, onAction, onAction)
    }

    @Test fun compactBackupActionsHaveUsableLabelsAndSeparatePrimaryRow() {
        content { Column(Modifier.width(272.dp).testTag("actions")) { Actions() } }
        val primary = bounds("Start backup")
        val select = bounds("Select media")
        val folders = bounds("Device folders")
        val available = compose.onNodeWithTag("actions").fetchSemanticsNode().boundsInRoot
        assertEquals(available.width, primary.width, 1f)
        assertTrue(primary.top >= maxOf(select.bottom, folders.bottom))
        assertFalse(select.overlaps(folders))
        for (label in listOf("Select media", "Device folders", "Start backup")) {
            compose.onNodeWithText(label).assertIsDisplayed().assertIsEnabled()
            assertLabelFits(label)
        }
    }

    @Test fun largeTextActionsWrapWithoutTallPillsAndKeepEveryActionClickable() {
        var clicked = 0
        content(2f) { Column(Modifier.width(272.dp).testTag("actions")) { Actions(onAction = { clicked++ }) } }
        val available = compose.onNodeWithTag("actions").fetchSemanticsNode().boundsInRoot
        val primary = bounds("Start backup")
        assertEquals(available.width, primary.width, 1f)
        assertTrue(primary.top >= maxOf(bounds("Select media").bottom, bounds("Device folders").bottom))
        assertFalse(bounds("Select media").overlaps(bounds("Device folders")))
        for (label in listOf("Select media", "Device folders", "Start backup")) {
            val control = bounds(label)
            assertTrue(control.left >= available.left && control.right <= available.right)
            assertTrue("$label must not become a vertical pill", control.height <= with(compose.density) { 112.dp.toPx() })
            assertLabelFits(label)
            compose.onNodeWithText(label).performClick()
        }
        compose.runOnIdle { assertEquals(3, clicked) }
    }

    @Test fun runningBackupDisablesSelectionsAndLeavesCancelReachableAtLargeText() {
        var cancelled = false
        content(2f) {
            Column(Modifier.width(272.dp).height(320.dp).verticalScroll(rememberScrollState())) {
                Actions(busy = true, backingUp = true)
                BackupProgress { cancelled = true }
            }
        }
        compose.onNodeWithText("Select media").assertIsNotEnabled()
        compose.onNodeWithText("Device folders").assertIsNotEnabled()
        compose.onNodeWithText("Backup in progress").assertIsNotEnabled()
        compose.onNodeWithText("Cancel backup").performScrollTo().assertIsDisplayed().performClick()
        compose.runOnIdle { assertTrue(cancelled) }
    }

    @Test fun longActivityFilenameKeepsStatusAndRemoveActionWithinCompactWidth() {
        val name = "A very long original camera filename with a detailed description ".repeat(3) + ".jpg"
        var removed = false
        content(2f) {
            Column(Modifier.width(272.dp).testTag("media")) {
                MediaRow(MediaItem("synthetic", "file:///synthetic", name, status = "Backed up"), true, { removed = true })
            }
        }
        val row = compose.onNodeWithTag("media").fetchSemanticsNode().boundsInRoot
        val status = bounds("Backed up")
        val remove = compose.onNodeWithContentDescription("Remove $name").fetchSemanticsNode().boundsInRoot
        assertTrue(status.left >= row.left && status.right <= row.right)
        assertTrue(remove.right <= row.right)
        assertFalse(status.overlaps(remove))
        val layouts = mutableListOf<TextLayoutResult>()
        compose.onNodeWithText(name, useUnmergedTree = true)
            .performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
        assertTrue(layouts.single().lineCount <= 2)
        assertTrue(layouts.single().isLineEllipsized(layouts.single().lineCount - 1))
        compose.onNodeWithContentDescription("Remove $name").performClick()
        compose.runOnIdle { assertTrue(removed) }
    }

    @Test fun longSignInGuidanceLeavesCancelAndWebPageVisibleInShortWindow() {
        var cancelled = false
        content(2f) {
            Box(Modifier.width(272.dp).height(360.dp)) {
                SignInLayout(
                    message = "Google Photos did not accept this sign-in. Close and retry, or use advanced credentials in Settings. ".repeat(3),
                    onCancel = { cancelled = true },
                ) { modifier -> Box(modifier.testTag("web-page")) { Text("Google page") } }
            }
        }
        val web = compose.onNodeWithTag("web-page").assertIsDisplayed().fetchSemanticsNode().boundsInRoot
        val cancel = bounds("Cancel sign-in")
        assertTrue("Google page must keep usable height", web.height >= with(compose.density) { 120.dp.toPx() })
        assertTrue(cancel.bottom <= web.top)
        assertLabelFits("Cancel sign-in")
        compose.onNodeWithText("Cancel sign-in").assertIsDisplayed().performClick()
        compose.runOnIdle { assertTrue(cancelled) }
    }
}
