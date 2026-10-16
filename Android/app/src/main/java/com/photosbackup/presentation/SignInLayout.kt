package com.photosbackup.presentation

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

@Composable
internal fun SignInLayout(
    message: String,
    onCancel: () -> Unit,
    webContent: @Composable (Modifier) -> Unit,
) {
    Surface {
        BoxWithConstraints(Modifier.fillMaxSize().safeDrawingPadding().imePadding()) {
            val guidanceHeight = maxHeight * 0.45f
            Column(Modifier.fillMaxSize()) {
                // Keep cancel visible and reserve space for Google's own
                // scrollable page in landscape, with the keyboard or large text.
                Column(Modifier.fillMaxWidth().heightIn(max = guidanceHeight)) {
                    Column(
                        Modifier.weight(1f, fill = false).verticalScroll(rememberScrollState())
                            .padding(start = 20.dp, end = 20.dp, top = 20.dp),
                        verticalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        Text("Connect Google Photos", style = MaterialTheme.typography.titleLarge)
                        Text(message)
                    }
                    TextButton(onClick = onCancel, modifier = Modifier.padding(horizontal = 12.dp)) {
                        Text("Cancel sign-in")
                    }
                }
                webContent(Modifier.weight(1f).fillMaxWidth())
            }
        }
    }
}
