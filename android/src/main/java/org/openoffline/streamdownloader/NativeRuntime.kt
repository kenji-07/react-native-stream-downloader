package org.openoffline.streamdownloader

import android.content.Context
import android.os.Handler
import android.os.Looper
import androidx.media3.common.util.UnstableApi
import com.brentvatne.react.ReactNativeVideoManager
import java.util.concurrent.CompletableFuture
import org.openoffline.streamdownloader.core.OfflineQueue
import org.openoffline.streamdownloader.media.Media3Engine
import org.openoffline.streamdownloader.media.OfflineRoutes
import org.openoffline.streamdownloader.media.OfflineVideoPlugin
import org.openoffline.streamdownloader.storage.SQLiteStore
import org.openoffline.streamdownloader.background.BackgroundWorker

@UnstableApi
internal class NativeRuntime private constructor(context: Context) {
    companion object {
        @Volatile private var instance: NativeRuntime? = null
        fun existing(): NativeRuntime? = instance
        fun get(context: Context): NativeRuntime = instance ?: synchronized(this) {
            instance ?: NativeRuntime(context.applicationContext).also { instance = it }
        }
    }
    private val routes = OfflineRoutes()
    private val store = SQLiteStore(context, routes::committed)
    private val engine = Media3Engine(context, routes)
    private val plugin = OfflineVideoPlugin(routes, engine)
    private var installed = false
    @Volatile private var observer: StreamDownloaderModule? = null
    private val background = BackgroundWorker(context, { workerReady() }, { message -> workerUnavailable(message) })
    val queue = OfflineQueue(store, engine, { event, payload -> observer?.emit(event, payload) },
        requestWorker = { background.ensureStarted() }, workChanged = background::setNeeded,
        playbackEnabled = routes::setPlaybackEnabled)
    init {
        engine.observeNetwork(queue::setNetworkState)
        store.load().filter { engine.valid(it) }.forEach { routes.committed(it) }
        queue.restoreBackground()
    }

    private fun workerReady() { queue.workerReady() }
    private fun workerUnavailable(message: String) { queue.workerUnavailable(message) }
    fun serviceReady(): Boolean {
        if (!background.serviceReady()) return false
        queue.restoreBackground()
        return true
    }
    fun serviceStopped(message: String? = null) { background.serviceStopped(message) }

    fun attach(module: StreamDownloaderModule) { observer = module }
    fun tracks(url: String): CompletableFuture<Map<String, Any?>> = queue.execute("getConfig", emptyMap()).thenCompose { engine.tracks(url) }
    fun detach(module: StreamDownloaderModule) { if (observer === module) observer = null }
    fun install(): CompletableFuture<Unit> {
        val result = CompletableFuture<Unit>()
        Handler(Looper.getMainLooper()).post {
            try {
                if (!installed) { ReactNativeVideoManager.getInstance().registerPlugin(plugin); installed = true }
                result.complete(Unit)
            } catch (error: Throwable) { result.completeExceptionally(error) }
        }
        return result
    }
}
