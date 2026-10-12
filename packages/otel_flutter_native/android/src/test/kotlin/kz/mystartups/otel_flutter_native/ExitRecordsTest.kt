package kz.mystartups.otel_flutter_native

import android.app.ApplicationExitInfo
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull

internal class ExitRecordsTest {
    /**
     * A real tombstone (API 36 emulator, harness app sent itself SIGSEGV),
     * trimmed to the fields [Tombstone] reads: pid, tid, signal, abort
     * message, causes and the crashing thread's backtrace.
     */
    private fun fixture() = javaClass.getResourceAsStream("/tombstone_sigsegv.pb")!!.readBytes()

    @Test
    fun tombstoneGivesSignalAndBacktraceWithBuildIds() {
        val crash = Tombstone.parse(fixture())!!
        assertEquals("SIGSEGV", crash.type)
        assertEquals("signal 11 (SIGSEGV), code 0 (SI_USER)", crash.message)
        val frames = crash.stack!!.lines()
        assertEquals(26, frames.size)
        assertEquals(
            "#00 pc 00000000000d5108  /apex/com.android.runtime/lib64/bionic/libc.so (kill+8) " +
                "(BuildId: f2ee009c5f1631f9819057446c9d2fa3)",
            frames[0],
        )
        assertEquals(
            "#08 pc 00000000004ca534  /system/framework/arm64/boot-framework.oat " +
                "(android.os.Handler.dispatchMessage+68) (BuildId: c318a2dc09a2631cef596cd657294e6350f87945)",
            frames[8],
        )
    }

    @Test
    fun brokenTombstoneIsNull() {
        val bytes = fixture()
        assertNull(Tombstone.parse(bytes.copyOf(bytes.size / 2)), "truncated")
        assertNull(Tombstone.parse(byteArrayOf(0x0f, 0x01)), "bad wire type")
        assertNull(Tombstone.parse(ByteArray(0)), "no signal")
    }

    @Test
    fun anrTraceKeepsOnlyTheMainThread() {
        val trace = """
            ----- pid 6446 at 2026-10-12 13:05:00 -----
            Cmd line: kz.mystartups.otel_flutter_native_example

            "Signal Catcher" daemon prio=10 tid=7 Runnable
              at nothing.Here(Unknown)

            "main" prio=5 tid=1 Sleeping
              | group="main" sCount=1 ucsCount=0 flags=1 obj=0x7 self=0xb4
              at java.lang.Thread.sleep(Native method)
              at s1.b.onMethodCall(MainActivity.kt:24)

            "FinalizerDaemon" daemon prio=5 tid=10 Waiting
              at java.lang.Object.wait(Native method)
        """.trimIndent()
        assertEquals(
            """
            "main" prio=5 tid=1 Sleeping
              | group="main" sCount=1 ucsCount=0 flags=1 obj=0x7 self=0xb4
              at java.lang.Thread.sleep(Native method)
              at s1.b.onMethodCall(MainActivity.kt:24)
            """.trimIndent(),
            AnrTrace.mainThread(trace.byteInputStream()),
        )
        assertNull(AnrTrace.mainThread("no threads".byteInputStream()))
    }

    @Test
    fun exitReasonsAreBounded() {
        assertEquals("crash", ExitReasons.name(ApplicationExitInfo.REASON_CRASH))
        assertEquals("native_crash", ExitReasons.name(ApplicationExitInfo.REASON_CRASH_NATIVE))
        assertEquals("anr", ExitReasons.name(ApplicationExitInfo.REASON_ANR))
        assertEquals("low_memory", ExitReasons.name(ApplicationExitInfo.REASON_LOW_MEMORY))
        assertEquals("user_request", ExitReasons.name(ApplicationExitInfo.REASON_USER_REQUESTED))
        assertEquals("user_request", ExitReasons.name(ApplicationExitInfo.REASON_USER_STOPPED))
        assertEquals("other", ExitReasons.name(ApplicationExitInfo.REASON_EXIT_SELF))
        assertEquals("other", ExitReasons.name(ApplicationExitInfo.REASON_SIGNALED))
        assertNotNull(ExitReasons.name(9999), "OEM value")
        assertEquals("other", ExitReasons.name(9999))
    }
}
