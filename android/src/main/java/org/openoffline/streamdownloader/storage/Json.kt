package org.openoffline.streamdownloader.storage

import org.json.JSONArray
import org.json.JSONObject

object Json {
    fun encode(value: Any?): String = when (value) {
        null -> "null"
        is Map<*, *> -> value.entries.sortedBy { it.key as String }.joinToString(",", "{", "}") { JSONObject.quote(it.key as String) + ":" + encode(it.value) }
        is List<*> -> value.joinToString(",", "[", "]") { encode(it) }
        is String -> JSONObject.quote(value)
        is Boolean, is Number -> value.toString()
        else -> error("Non-JSON native value")
    }
    fun decodeObject(text: String): Map<String, Any?> = map(JSONObject(text))
    private fun map(value: JSONObject): Map<String, Any?> = value.keys().asSequence().associateWith { decode(value.get(it)) }
    private fun decode(value: Any?): Any? = when (value) {
        JSONObject.NULL -> null
        is JSONObject -> map(value)
        is JSONArray -> (0 until value.length()).map { decode(value.get(it)) }
        else -> value
    }
}
