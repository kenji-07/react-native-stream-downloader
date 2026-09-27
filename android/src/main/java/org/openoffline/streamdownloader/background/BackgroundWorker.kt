package org.openoffline.streamdownloader.background

import android.app.Activity
import android.app.Application
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import androidx.media3.common.util.UnstableApi

/** Process-local handshake; the queue owns every durable state transition. */
@UnstableApi
internal class BackgroundWorker(
    private val context: Context,
    private val readyCallback: () -> Unit,
    private val unavailable: (String) -> Unit,
) : Application.ActivityLifecycleCallbacks {
    private var needed = false
    private var ready = false
    private var starting = false
    private var stopping = false
    private var blocked = false
    init { (context.applicationContext as? Application)?.registerActivityLifecycleCallbacks(this) }

    @Synchronized fun ensureStarted(): Boolean {
        needed = true
        if (ready) return true
        if (starting || stopping || blocked) return false
        starting = true
        try {
            val intent = Intent(context, DownloadService::class.java)
            if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent) else context.startService(intent)
        } catch (_: RuntimeException) {
            starting = false; blocked = true
            unavailable("E_BACKGROUND_START_DENIED: Android could not start the download service. The download remains pending; bring the app to the foreground to retry.")
        }
        return false
    }
    @Synchronized fun setNeeded(value: Boolean) {
        needed = value
        if (!value && (ready || starting)) {
            stopping = true
            ready = false; starting = false
            // Wait for destruction before a subsequent admission starts another
            // worker. Otherwise the old onDestroy can revoke the new handshake.
            if (!context.stopService(Intent(context, DownloadService::class.java))) stopping = false
        }
    }
    @Synchronized fun serviceReady(): Boolean {
        // A start command can arrive after the queue cancelled its last item.
        // Keep its notification acknowledgement short and reject that late worker.
        if (stopping) return false
        ready = true; starting = false; blocked = false
        readyCallback()
        return true
    }
    @Synchronized fun serviceStopped(message: String? = null) {
        val interrupted = needed && (ready || starting)
        val requested = stopping
        stopping = false
        ready = false; starting = false
        if (message == null && requested) {
            // A new item admitted during a normal stop retries after its ack.
            if (needed) readyCallback()
        } else if (interrupted || message != null) {
            blocked = true
            unavailable(message ?: "E_BACKGROUND_INTERRUPTED: Android stopped the download service. Downloads will retry when the app returns to the foreground.")
        }
    }
    @Synchronized override fun onActivityResumed(activity: Activity) {
        blocked = false
        if (needed) readyCallback()
    }
    override fun onActivityCreated(activity: Activity, state: Bundle?) = Unit
    override fun onActivityStarted(activity: Activity) = Unit
    override fun onActivityPaused(activity: Activity) = Unit
    override fun onActivityStopped(activity: Activity) = Unit
    override fun onActivitySaveInstanceState(activity: Activity, state: Bundle) = Unit
    override fun onActivityDestroyed(activity: Activity) = Unit
}
