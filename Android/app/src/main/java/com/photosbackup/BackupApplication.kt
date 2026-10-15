package com.photosbackup

import android.app.Application
import com.chaquo.python.Python
import com.chaquo.python.android.AndroidPlatform

class BackupApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        cacheDir.listFiles()?.filter { it.name.startsWith("upload-") }?.forEach { it.delete() }
        if (!Python.isStarted()) Python.start(AndroidPlatform(this))
        Python.getInstance().getModule("android_bridge").callAttr("initialize")
    }
}
