package org.openoffline.streamdownloader

import androidx.media3.common.util.UnstableApi
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.modules.core.DeviceEventManagerModule
import java.util.concurrent.CompletionException
import java.util.concurrent.Executors
import org.openoffline.streamdownloader.core.DownloadFailure

@UnstableApi
class StreamDownloaderModule(private val context: ReactApplicationContext) : ReactContextBaseJavaModule(context) {
    private val initialization = Executors.newSingleThreadExecutor()
    @Volatile private var runtime: NativeRuntime? = null
    @Volatile private var runtimeId: String? = null
    @Volatile private var invalidated = false
    private var sequence = 0L
    private var progress = false
    override fun getName(): String = "StreamDownloader"

    @ReactMethod fun execute(command: ReadableMap, promise: Promise) {
        val input = command.toHashMap()
        initialization.execute {
            var method = "execute"
            try {
                if (invalidated) throw DownloadFailure("E_RUNTIME_INVALIDATED", "The JavaScript runtime is no longer active.")
                if (BridgeValidation.number(input["version"]) != 1L) throw DownloadFailure("E_BRIDGE", "Unsupported native bridge version.")
                val incoming = BridgeValidation.string(input["runtimeId"])
                BridgeValidation.string(input["operationId"])
                method = BridgeValidation.string(input["method"])
                val params = BridgeValidation.params(method, BridgeValidation.map(input["params"]))
                val native = runtime ?: NativeRuntime.get(context).also { runtime = it }
                if (method == "registerPlugin") {
                    synchronized(this) {
                        if (runtimeId != incoming) { runtimeId = incoming; sequence = 0 }
                        native.attach(this); native.queue.setProgressEnabled(progress)
                    }
                    native.install().get()
                } else if (runtimeId != incoming && method !in setOf("disablePlugin", "getConfig", "setConfig")) throw DownloadFailure("E_NOT_REGISTERED", "The JavaScript runtime is not registered.")
                val operation = method
                @Suppress("UNCHECKED_CAST")
                val task = if (method == "getAvailableTracks") native.tracks(params["url"] as String, params["headers"] as Map<String, String>) else native.queue.execute(method, params)
                task.whenComplete { result, error ->
                    if (error != null) reject(promise, error, operation) else promise.resolve(bridgeValue(result))
                }
            } catch (error: Throwable) { reject(promise, error, method) }
        }
    }

    @ReactMethod fun completeLicenseRequest(response: ReadableMap, promise: Promise) {
        reject(promise, DownloadFailure("E_UNSUPPORTED_CAPABILITY", "JavaScript license callbacks are only supported on iOS."), "completeLicenseRequest")
    }
    @ReactMethod fun setProgressEnabled(incomingRuntimeId: String, enabled: Boolean) {
        synchronized(this) {
            if (runtimeId != null && runtimeId != incomingRuntimeId) return
            progress = enabled
            runtime?.queue?.setProgressEnabled(enabled)
        }
    }
    @ReactMethod fun addListener(eventName: String) = Unit
    @ReactMethod fun removeListeners(count: Double) = Unit

    @Synchronized internal fun emit(event: String, payload: Any) {
        val id = runtimeId ?: return
        if (invalidated || !context.hasActiveReactInstance()) return
        context.getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter::class.java).emit("StreamDownloaderEvent", Arguments.makeNativeMap(mapOf(
            "runtimeId" to id, "sequence" to ++sequence, "event" to event, "payload" to payload,
        )))
    }

    private fun reject(promise: Promise, error: Throwable, operation: String) {
        val cause = if (error is CompletionException) error.cause ?: error else error
        val failure = cause as? DownloadFailure ?: DownloadFailure("E_NATIVE", "Native download operation failed.")
        promise.reject(failure.code, failure.message, Arguments.makeNativeMap(mapOf("operation" to operation, "retryable" to failure.retryable)))
    }
    private fun bridgeValue(value: Any?): Any? = when (value) {
        is Map<*, *> -> { @Suppress("UNCHECKED_CAST") Arguments.makeNativeMap(value as Map<String, Any?>) }
        is List<*> -> Arguments.makeNativeArray(value)
        else -> value
    }
    override fun invalidate() {
        invalidated = true
        runtime?.detach(this)
        runtime?.queue?.setProgressEnabled(false)
        initialization.shutdown()
        super.invalidate()
    }
}
