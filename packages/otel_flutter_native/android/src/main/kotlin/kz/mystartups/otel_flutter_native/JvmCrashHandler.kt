package kz.mystartups.otel_flutter_native

import java.io.File
import java.util.Properties

/** An uncaught JVM exception, saved while the process was dying. */
internal data class JvmCrash(
    val type: String,
    val message: String?,
    val stack: String,
    val time: Long,
    val pid: Int,
) {
    fun fields(): Map<String, Any?> = mapOf("type" to type, "message" to message, "stack" to stack)
}

/**
 * Saves uncaught JVM exceptions to [file], then hands them to the handler
 * that was installed before (the platform's, Crashlytics, Sentry...), so the
 * app still dies and other crash reporters still see the crash.
 *
 * Needed on every API level: the OS exit record of a JVM crash carries no
 * exception class, message or stack.
 */
internal class JvmCrashHandler(
    private val file: File,
    private val previous: Thread.UncaughtExceptionHandler?,
    private val pid: () -> Int,
) : Thread.UncaughtExceptionHandler {

    override fun uncaughtException(thread: Thread, error: Throwable) {
        try {
            save(error)
        } catch (_: Throwable) {
            // Never get in the way of the crash itself.
        }
        previous?.uncaughtException(thread, error)
    }

    private fun save(error: Throwable) {
        val props = Properties()
        props["type"] = error.javaClass.name
        error.message?.let { props["message"] = it.take(MAX_TEXT) }
        props["stack"] = error.stackTraceToString().take(MAX_STACK)
        props["time"] = System.currentTimeMillis().toString()
        props["pid"] = pid().toString()
        file.parentFile?.mkdirs()
        // Temp file + rename: a half-written file is never read.
        val tmp = File(file.path + ".tmp")
        tmp.outputStream().use { props.store(it, null) }
        tmp.renameTo(file)
    }

    companion object {
        private const val MAX_TEXT = 4 * 1024
        private const val MAX_STACK = 64 * 1024

        private var installed = false

        /** Chains onto the current default handler, once per process. */
        @Synchronized
        fun install(file: File, pid: () -> Int) {
            if (installed) return
            installed = true
            Thread.setDefaultUncaughtExceptionHandler(
                JvmCrashHandler(file, Thread.getDefaultUncaughtExceptionHandler(), pid),
            )
        }

        /** Reads and deletes the saved crash, if any. */
        fun take(file: File): JvmCrash? {
            if (!file.exists()) return null
            return try {
                val props = Properties().apply { file.inputStream().use { load(it) } }
                JvmCrash(
                    type = props.getProperty("type") ?: return null,
                    message = props.getProperty("message"),
                    stack = props.getProperty("stack") ?: "",
                    time = props.getProperty("time")?.toLongOrNull() ?: return null,
                    pid = props.getProperty("pid")?.toIntOrNull() ?: 0,
                )
            } catch (_: Exception) {
                null
            } finally {
                file.delete()
            }
        }
    }
}
