package kz.mystartups.otel_flutter_native

/** What a native crash's tombstone tells about it. */
internal data class NativeCrash(val type: String?, val message: String?, val stack: String?) {
    fun fields(): Map<String, Any?> = mapOf("type" to type, "message" to message, "stack" to stack)
}

/**
 * Reads the tombstone protobuf that `ApplicationExitInfo.getTraceInputStream`
 * returns for native crashes (API 31+), see AOSP
 * `system/core/debuggerd/proto/tombstone.proto`. The exit record itself only
 * says "crash", so this is the only source of the signal and backtrace.
 * Frames keep their build ids for a later symbolication step.
 */
internal object Tombstone {
    private const val MAX_FRAMES = 64

    fun parse(bytes: ByteArray): NativeCrash? = try {
        decode(bytes)
    } catch (_: RuntimeException) {
        null // Truncated or unexpected data: report the crash without details.
    }

    private fun decode(bytes: ByteArray): NativeCrash? {
        var tid = 0L
        var signal: Proto? = null
        var abortMessage: String? = null
        var cause: String? = null
        val threads = HashMap<Long, Proto>()
        Proto(bytes).forEach { field, value, sub ->
            when (field) {
                6 -> tid = value
                10 -> signal = sub
                14 -> abortMessage = sub?.string()
                15 -> if (cause == null) sub?.forEach { f, _, s -> if (f == 1) cause = s?.string() }
                16 -> { // map<uint32, Thread>: entry key = 1, value = 2
                    var key = 0L
                    var thread: Proto? = null
                    sub?.forEach { f, v, s -> if (f == 1) key = v else if (f == 2) thread = s }
                    thread?.let { threads[key] = it }
                }
            }
        }
        val sig = signal ?: return null

        var number = 0L
        var name: String? = null
        var code = 0L
        var codeName: String? = null
        var hasFaultAddress = false
        var faultAddress = 0L // proto3 omits zero: a null dereference has no field 9
        sig.forEach { f, v, s ->
            when (f) {
                1 -> number = v
                2 -> name = s?.string()
                3 -> code = v
                4 -> codeName = s?.string()
                8 -> hasFaultAddress = v != 0L
                9 -> faultAddress = v
            }
        }
        val header = buildString {
            append("signal $number ($name), code ${code.toInt()} ($codeName)")
            if (hasFaultAddress) append(", fault addr 0x%x".format(faultAddress))
        }
        return NativeCrash(
            type = name,
            message = abortMessage?.takeIf { it.isNotEmpty() } ?: cause ?: header,
            stack = threads[tid]?.let(::backtrace),
        )
    }

    /** Formatted like logcat's tombstone, e.g. `#00 pc 00000000000d5108  /x/libc.so (kill+8) (BuildId: f2ee...)`. */
    private fun backtrace(thread: Proto): String {
        val lines = ArrayList<String>()
        thread.forEach { f, _, frame ->
            if (f != 4 || frame == null || lines.size >= MAX_FRAMES) return@forEach
            var relPc = 0L
            var function: String? = null
            var offset = 0L
            var file = ""
            var buildId: String? = null
            frame.forEach { ff, v, s ->
                when (ff) {
                    1 -> relPc = v
                    4 -> function = s?.string()?.takeIf { it.isNotEmpty() }
                    5 -> offset = v
                    6 -> file = s?.string() ?: ""
                    8 -> buildId = s?.string()?.takeIf { it.isNotEmpty() }
                }
            }
            lines += buildString {
                append("#%02d pc %016x  %s".format(lines.size, relPc, file))
                function?.let { append(" ($it+$offset)") }
                buildId?.let { append(" (BuildId: $it)") }
            }
        }
        return lines.joinToString("\n")
    }
}

/** Minimal protobuf wire-format reader: just enough to walk a tombstone. */
internal class Proto(
    private val bytes: ByteArray,
    private val start: Int = 0,
    private val end: Int = bytes.size,
) {
    fun string(): String = String(bytes, start, end - start, Charsets.UTF_8)

    /**
     * Calls [onField] with each field number and either its varint value or,
     * for length-delimited fields, the embedded bytes. Fixed-width fields are
     * skipped (nothing read here uses them).
     */
    fun forEach(onField: (field: Int, value: Long, sub: Proto?) -> Unit) {
        var pos = start
        fun varint(): Long {
            var result = 0L
            var shift = 0
            while (true) {
                val b = bytes[pos++].toInt()
                result = result or ((b and 0x7f).toLong() shl shift)
                if (b and 0x80 == 0) return result
                shift += 7
            }
        }
        while (pos < end) {
            val tag = varint()
            val field = (tag ushr 3).toInt()
            when ((tag and 7).toInt()) {
                0 -> onField(field, varint(), null)
                1 -> pos += 8
                2 -> {
                    val length = varint().toInt()
                    require(length >= 0 && pos + length <= end) { "bad length" }
                    onField(field, 0, Proto(bytes, pos, pos + length))
                    pos += length
                }
                5 -> pos += 4
                else -> throw IllegalArgumentException("unsupported wire type")
            }
        }
    }
}
