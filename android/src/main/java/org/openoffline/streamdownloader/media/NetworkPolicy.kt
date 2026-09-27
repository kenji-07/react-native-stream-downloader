package org.openoffline.streamdownloader.media

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.TransferListener
import org.openoffline.streamdownloader.core.DownloadFailure

/** Process-owned monitor. The queue owns waiting/resume; each source also gates IO. */
internal class NetworkPolicy(context: Context) {
    private val connectivity = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    @Volatile var wifiOnly = false
    @Volatile private var current = state()
    @Volatile private var observer: ((Boolean, Boolean) -> Unit)? = null
    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) = changed()
        override fun onLost(network: Network) = changed()
        override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) = changed()
    }
    private fun state(): Pair<Boolean, Boolean> {
        val capabilities = connectivity.getNetworkCapabilities(connectivity.activeNetwork)
        return (capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) == true) to
            (capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true)
    }
    private fun changed() {
        val snapshot = state(); current = snapshot
        observer?.invoke(snapshot.first, snapshot.second)
    }
    fun observe(observer: (Boolean, Boolean) -> Unit) {
        this.observer = observer
        if (Build.VERSION.SDK_INT >= 24) connectivity.registerDefaultNetworkCallback(callback)
        else connectivity.registerNetworkCallback(NetworkRequest.Builder().addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET).build(), callback)
        changed()
    }
    // Read the callback snapshot rather than crossing Binder on every media chunk.
    fun allowed(): Boolean = !wifiOnly || current.let { it.first && it.second }
    fun guard() { if (!allowed()) { changed(); throw DownloadFailure("E_NETWORK_POLICY", "Waiting for a Wi-Fi connection.", true) } }
    fun wrap(factory: DataSource.Factory): DataSource.Factory = DataSource.Factory {
        val source = factory.createDataSource()
        object : DataSource {
            override fun addTransferListener(listener: TransferListener) = source.addTransferListener(listener)
            override fun open(dataSpec: DataSpec): Long { guard(); return source.open(dataSpec) }
            override fun read(buffer: ByteArray, offset: Int, length: Int): Int { guard(); return source.read(buffer, offset, length) }
            override fun getUri() = source.uri
            override fun getResponseHeaders() = source.responseHeaders
            override fun close() = source.close()
        }
    }
}
