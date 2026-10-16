package com.photosbackup.presentation

import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Folder
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp

@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun BackupActions(
    busy: Boolean,
    backingUp: Boolean,
    loadingFolders: Boolean,
    canStart: Boolean,
    onSelect: () -> Unit,
    onFolders: () -> Unit,
    onStart: () -> Unit,
) {
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        // Measure each secondary action at its natural width and move it to
        // the next line when the screen or the user's text size requires it.
        FlowRow(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
            maxItemsInEachRow = 2,
        ) {
            OutlinedButton(onClick = onSelect, enabled = !busy) {
                Icon(Icons.Rounded.Add, null, Modifier.size(ButtonDefaults.IconSize))
                Spacer(Modifier.width(ButtonDefaults.IconSpacing))
                Text("Select media", textAlign = TextAlign.Center)
            }
            OutlinedButton(onClick = onFolders, enabled = !busy && !loadingFolders) {
                Icon(Icons.Rounded.Folder, null, Modifier.size(ButtonDefaults.IconSize))
                Spacer(Modifier.width(ButtonDefaults.IconSpacing))
                Text(if (loadingFolders) "Loading folders…" else "Device folders", textAlign = TextAlign.Center)
            }
        }
        Button(
            onClick = onStart,
            enabled = !busy && canStart,
            modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
        ) {
            Text(if (backingUp) "Backup in progress" else "Start backup", textAlign = TextAlign.Center)
        }
    }
}

@Composable
internal fun BackupProgress(onCancel: () -> Unit) {
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            LinearProgressIndicator(Modifier.fillMaxWidth())
            Text("Backing up your selection…")
            TextButton(onClick = onCancel, modifier = Modifier.fillMaxWidth()) {
                Text("Cancel backup", textAlign = TextAlign.Center)
            }
        }
    }
}
