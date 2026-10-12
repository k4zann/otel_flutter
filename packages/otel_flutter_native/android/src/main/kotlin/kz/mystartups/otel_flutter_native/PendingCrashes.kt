package kz.mystartups.otel_flutter_native

import android.annotation.TargetApi
import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import java.io.File
import java.io.InputStream

/**
 * Exits of previous processes that Dart has not seen yet, oldest first, as
 * plain maps for the method channel:
 * `{reason, time (ms), description?, type?, message?, stack?}`.
 *
 * Each record is returned once: the newest processed timestamp is kept in
 * SharedPreferences and only newer records are returned.
 */
internal class PendingCrashes(private val context: Context) {

    fun take(): List<Map<String, Any>> = synchronized(lock) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val after = prefs.getLong(KEY_LAST_EXIT, 0L)
        val jvmCrash = JvmCrashHandler.take(crashFile(context))
        val records = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            fromExitInfo(after, jvmCrash)
        } else {
            // No exit history before API 30: the JVM handler's file is all
            // there is (native crashes and ANRs stay invisible).
            listOfNotNull(
                jvmCrash?.takeIf { it.time > after }
                    ?.let { record("crash", it.time, null, it.fields()) },
            )
        }
        records.maxOfOrNull { it["time"] as Long }
            ?.let { prefs.edit().putLong(KEY_LAST_EXIT, it).commit() }
        records
    }

    @TargetApi(Build.VERSION_CODES.R)
    private fun fromExitInfo(after: Long, jvmCrash: JvmCrash?): List<Map<String, Any>> {
        val am = context.getSystemService(ActivityManager::class.java) ?: return emptyList()
        // Only the app's main process: a crashed helper process (`:remote`)
        // is not the app the user was looking at.
        val mainProcess = context.applicationInfo.processName
        return am.getHistoricalProcessExitReasons(null, 0, 0)
            .filter { it.timestamp > after && it.processName == mainProcess }
            .sortedBy { it.timestamp }
            .map { info ->
                val reason = ExitReasons.name(info.reason)
                val details = when (reason) {
                    "crash" -> jvmCrash?.takeIf { it.pid == info.pid }?.fields()
                    "native_crash" -> trace(info) { Tombstone.parse(it.readBytes()) }?.fields()
                    "anr" -> mapOf(
                        "message" to info.description,
                        "stack" to trace(info, AnrTrace::mainThread),
                    )
                    else -> null
                }
                record(reason, info.timestamp, info.description, details.orEmpty())
            }
    }

    /** One unreadable trace must not lose the other records. */
    @TargetApi(Build.VERSION_CODES.R)
    private fun <T> trace(info: ApplicationExitInfo, read: (InputStream) -> T?): T? =
        try {
            info.traceInputStream?.use(read)
        } catch (_: Exception) {
            null
        }

    private fun record(
        reason: String,
        time: Long,
        description: String?,
        details: Map<String, Any?>,
    ): Map<String, Any> = buildMap {
        put("reason", reason)
        put("time", time)
        description?.let { put("description", it) }
        details.forEach { (key, value) -> if (value != null) put(key, value) }
    }

    companion object {
        private const val PREFS = "otel_flutter_native"
        private const val KEY_LAST_EXIT = "last_exit_time"
        private val lock = Any()

        /** Not backed up: a crash file must not be restored onto another device. */
        fun crashFile(context: Context) =
            File(context.noBackupFilesDir, "otel_flutter_native/jvm_crash")
    }
}

/** Bounded `app.exit.reason` values for `ApplicationExitInfo` reasons. */
internal object ExitReasons {
    fun name(reason: Int): String = when (reason) {
        ApplicationExitInfo.REASON_CRASH -> "crash"
        ApplicationExitInfo.REASON_CRASH_NATIVE -> "native_crash"
        ApplicationExitInfo.REASON_ANR -> "anr"
        ApplicationExitInfo.REASON_LOW_MEMORY -> "low_memory"
        ApplicationExitInfo.REASON_USER_REQUESTED,
        ApplicationExitInfo.REASON_USER_STOPPED -> "user_request"
        // Android has no reason for an OS update; unknown and OEM-specific
        // values land here too, so the attribute stays bounded.
        else -> "other"
    }
}

/** The main thread's stack from an ANR trace, which dumps every thread. */
internal object AnrTrace {
    private const val MAX_CHARS = 64 * 1024

    fun mainThread(trace: InputStream): String? {
        val block = StringBuilder()
        var inMain = false
        trace.bufferedReader().useLines { lines ->
            for (line in lines) {
                if (!inMain) {
                    if (!line.startsWith("\"main\"")) continue
                    inMain = true
                }
                if (line.isBlank() || block.length >= MAX_CHARS) break
                block.append(line).append('\n')
            }
        }
        return block.toString().trimEnd().take(MAX_CHARS).ifEmpty { null }
    }
}
