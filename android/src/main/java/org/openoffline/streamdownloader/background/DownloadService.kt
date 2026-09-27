package org.openoffline.streamdownloader.background

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.media3.common.util.UnstableApi
import org.openoffline.streamdownloader.NativeRuntime
import org.openoffline.streamdownloader.R

/** Library-owned service. No media or credentials appear in notifications. */
@UnstableApi
class DownloadService : TimeoutAwareService() {
    companion object {
        private const val CHANNEL = "org.openoffline.downloads"
        private const val NOTIFICATION = 0x53444c
    }
    private var runtime: NativeRuntime? = null
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        try {
            val manager = getSystemService(NotificationManager::class.java)
            if (Build.VERSION.SDK_INT >= 26) manager.createNotificationChannel(
                NotificationChannel(CHANNEL, getString(R.string.stream_downloader_channel), NotificationManager.IMPORTANCE_LOW),
            )
            val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL) else Notification.Builder(this)
            builder.setSmallIcon(android.R.drawable.stat_sys_download)
                .setContentTitle(getString(R.string.stream_downloader_notification_title))
                .setContentText(getString(R.string.stream_downloader_notification_text))
                .setOngoing(true).setOnlyAlertOnce(true).setCategory(Notification.CATEGORY_PROGRESS)
            packageManager.getLaunchIntentForPackage(packageName)?.let { launch ->
                builder.setContentIntent(PendingIntent.getActivity(this, 0, launch, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
            }
            if (Build.VERSION.SDK_INT >= 29) startForeground(NOTIFICATION, builder.build(), ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
            else startForeground(NOTIFICATION, builder.build())
            val accepted = NativeRuntime.get(this).also { runtime = it }.serviceReady()
            if (!accepted) { removeForeground(); stopSelf(); return START_NOT_STICKY }
            return START_STICKY
        } catch (_: RuntimeException) {
            NativeRuntime.existing()?.serviceStopped("E_BACKGROUND_START_DENIED: Android did not allow the download service. Bring the app to the foreground to retry pending downloads.")
            stopSelf(); return START_NOT_STICKY
        }
    }
    override fun handleTimeout() {
        runtime?.serviceStopped("E_BACKGROUND_TIMEOUT: Android's background transfer time limit was reached. Downloads remain pending until the app returns to the foreground.")
        removeForeground(); stopSelf()
    }
    override fun onDestroy() {
        runtime?.serviceStopped()
        removeForeground()
        super.onDestroy()
    }

    private fun removeForeground() {
        if (Build.VERSION.SDK_INT >= 24) stopForeground(STOP_FOREGROUND_REMOVE)
        else @Suppress("DEPRECATION") stopForeground(true)
    }
}
