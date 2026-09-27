package org.openoffline.streamdownloader.storage

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import java.io.File
import org.openoffline.streamdownloader.core.Asset
import org.openoffline.streamdownloader.core.CacheRange
import org.openoffline.streamdownloader.core.PlaybackPlan
import org.openoffline.streamdownloader.core.OfflineDrm
import org.openoffline.streamdownloader.core.Record
import org.openoffline.streamdownloader.core.State
import org.openoffline.streamdownloader.core.Store

class SQLiteStore(context: Context, private val committed: (Record) -> Unit = {}) : SQLiteOpenHelper(context, File(context.noBackupFilesDir, "stream-downloader.sqlite").absolutePath, null, 1), Store {
    init { setWriteAheadLoggingEnabled(true) }
    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL("CREATE TABLE downloads (id TEXT PRIMARY KEY NOT NULL, document TEXT NOT NULL)")
        db.execSQL("CREATE TABLE settings (name TEXT PRIMARY KEY NOT NULL, value INTEGER NOT NULL)")
    }
    override fun onOpen(db: SQLiteDatabase) { super.onOpen(db); db.execSQL("CREATE TABLE IF NOT EXISTS configuration (id INTEGER PRIMARY KEY, document TEXT NOT NULL)") }
    override fun configuration(): Map<String, Any?> = readableDatabase.rawQuery("SELECT document FROM configuration WHERE id = 1", null).use { if (it.moveToFirst()) Json.decodeObject(it.getString(0)) else emptyMap() }
    override fun setConfiguration(value: Map<String, Any?>) {
        check(writableDatabase.insertWithOnConflict("configuration", null, ContentValues().apply { put("id", 1); put("document", Json.encode(value)) }, SQLiteDatabase.CONFLICT_REPLACE) != -1L)
    }
    override fun onConfigure(db: SQLiteDatabase) { db.setForeignKeyConstraintsEnabled(true) }
    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) { error("Unsupported downloader schema migration") }

    override fun load(): List<Record> = readableDatabase.rawQuery("SELECT document FROM downloads", null).use { cursor ->
        buildList {
            while (cursor.moveToNext()) {
                val data = Json.decodeObject(cursor.getString(0))
                val id = data["id"] as String
                val protected = (data["protected"] as? String)?.let { ProtectedStorage.open(it, "record:$id") }
                @Suppress("UNCHECKED_CAST") val storedOptions = data["options"] as Map<String, Any?>
                // Legacy documents are readable; their next save removes plaintext DRM fields.
                val options = storedOptions + (protected?.get("optionsDrm")?.let { mapOf("drm" to it) } ?: emptyMap())
                val offlineDrm = (protected?.get("playbackDrm") as? Map<*, *>)?.let {
                    OfflineDrm(it["scheme"] as String, it["keySetId"] as String)
                }
                val asset = (data["asset"] as? Map<*, *>)?.let { item ->
                    val playback = (item["playback"] as? Map<*, *>)?.let { plan ->
                        PlaybackPlan(plan["url"] as String, plan["mimeType"] as String,
                            (plan["streamKeys"] as List<*>).map { key -> (key as List<*>).map { (it as Number).toInt() } },
                            (plan["ranges"] as List<*>).map { range -> (range as Map<*, *>).let { CacheRange(it["key"] as String, (it["position"] as Number).toLong(), (it["length"] as Number).toLong()) } }, offlineDrm)
                    }
                    Asset(item["path"] as String, (item["duration"] as Number).toLong(), (item["date"] as Number).toLong(), playback)
                }
                add(Record(
                    data["id"] as String, data["url"] as String, options, data["fingerprint"] as String, (data["order"] as Number).toLong(),
                    generation = (data["generation"] as Number).toLong(), state = State.valueOf(data["state"] as String),
                    progress = (data["progress"] as Number).toDouble(), received = (data["received"] as? Number)?.toLong(),
                    total = (data["total"] as? Number)?.toLong(), error = data["error"] as? String, asset = asset,
                    expiresAt = (data["expiresAt"] as Number).toLong(), disableHeld = data["disableHeld"] == true, stopIntent = data["stopIntent"] as? String,
                    retryCount = (data["retryCount"] as? Number)?.toInt() ?: 0, nextRetryAt = (data["nextRetryAt"] as? Number)?.toLong(),
                ))
            }
        }
    }

    override fun put(record: Record) {
        val secrets = buildMap<String, Any?> {
            (record.options["drm"] as? Map<*, *>)?.let { drm ->
                // Android does not accept JS license callbacks. Never persist a runtime reference.
                put("optionsDrm", drm.filterKeys { it != "callbackRef" })
            }
            record.asset?.playback?.drm?.let { put("playbackDrm", mapOf("scheme" to it.scheme, "keySetId" to it.keySetId)) }
        }
        val document = mapOf(
            "id" to record.id, "url" to record.url, "options" to record.options - "drm", "fingerprint" to record.fingerprint,
            "protected" to secrets.takeIf { it.isNotEmpty() }?.let { ProtectedStorage.seal(it, "record:${record.id}") },
            "retryCount" to record.retryCount, "nextRetryAt" to record.nextRetryAt,
            "order" to record.order, "generation" to record.generation, "state" to record.state.name, "progress" to record.progress,
            "received" to record.received, "total" to record.total, "error" to record.error,
            "expiresAt" to record.expiresAt, "disableHeld" to record.disableHeld, "stopIntent" to record.stopIntent,
            "asset" to record.asset?.let { asset -> mapOf("path" to asset.path, "duration" to asset.duration, "date" to asset.date,
                "playback" to asset.playback?.let { plan -> mapOf("url" to plan.url, "mimeType" to plan.mimeType, "streamKeys" to plan.streamKeys,
                    "ranges" to plan.ranges.map { mapOf("key" to it.key, "position" to it.position, "length" to it.length) }) }) },
        )
        writableDatabase.insertWithOnConflict("downloads", null, ContentValues().apply {
            put("id", record.id); put("document", Json.encode(document))
        }, SQLiteDatabase.CONFLICT_REPLACE).also { check(it != -1L) { "Could not persist download" } }
        committed(record)
    }
    override fun remove(id: String) { writableDatabase.delete("downloads", "id = ?", arrayOf(id)) }
    override fun enabled(): Boolean = readableDatabase.rawQuery("SELECT value FROM settings WHERE name = 'enabled'", null).use { it.moveToFirst() && it.getInt(0) == 1 }
    override fun setEnabled(enabled: Boolean) {
        writableDatabase.insertWithOnConflict("settings", null, ContentValues().apply { put("name", "enabled"); put("value", if (enabled) 1 else 0) }, SQLiteDatabase.CONFLICT_REPLACE)
            .also { check(it != -1L) { "Could not persist enablement" } }
    }
}
