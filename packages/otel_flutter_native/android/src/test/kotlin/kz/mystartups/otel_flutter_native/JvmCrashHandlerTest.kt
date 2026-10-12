package kz.mystartups.otel_flutter_native

import java.io.File
import java.nio.file.Files
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

internal class JvmCrashHandlerTest {
    private val dir = Files.createTempDirectory("jvm_crash").toFile()
    private val file = File(dir, "nested/jvm_crash")

    @AfterTest
    fun cleanUp() {
        dir.deleteRecursively()
    }

    private class Recorder : Thread.UncaughtExceptionHandler {
        val calls = mutableListOf<Pair<Thread, Throwable>>()
        override fun uncaughtException(t: Thread, e: Throwable) {
            calls += t to e
        }
    }

    @Test
    fun savesTheCrashThenCallsThePreviousHandler() {
        val previous = Recorder()
        val error = IllegalStateException("boom", RuntimeException("cause"))

        JvmCrashHandler(file, previous) { 4242 }.uncaughtException(Thread.currentThread(), error)

        assertEquals(1, previous.calls.size, "previous handler (platform, Crashlytics) still runs")
        assertSame(error, previous.calls.single().second)
        val crash = JvmCrashHandler.take(file)!!
        assertEquals("java.lang.IllegalStateException", crash.type)
        assertEquals("boom", crash.message)
        assertTrue(crash.stack.startsWith("java.lang.IllegalStateException: boom"))
        assertTrue("Caused by: java.lang.RuntimeException: cause" in crash.stack)
        assertEquals(4242, crash.pid)
        assertTrue(System.currentTimeMillis() - crash.time < 10_000)
        assertFalse(file.exists(), "taken once")
        assertNull(JvmCrashHandler.take(file))
    }

    @Test
    fun aFailingWriteStillCallsThePreviousHandler() {
        val previous = Recorder()
        val blocked = File(dir, "not-a-dir").apply { writeText("x") }
        JvmCrashHandler(File(blocked, "jvm_crash"), previous) { 1 }
            .uncaughtException(Thread.currentThread(), RuntimeException())
        assertEquals(1, previous.calls.size)
    }

    @Test
    fun installChainsOntoTheCurrentDefaultHandler() {
        val original = Thread.getDefaultUncaughtExceptionHandler()
        val previous = Recorder()
        try {
            Thread.setDefaultUncaughtExceptionHandler(previous)
            JvmCrashHandler.install(file) { 7 }
            JvmCrashHandler.install(file) { 8 } // once per process

            val error = RuntimeException("x")
            Thread.getDefaultUncaughtExceptionHandler()!!
                .uncaughtException(Thread.currentThread(), error)

            assertSame(error, previous.calls.single().second)
            assertEquals(7, JvmCrashHandler.take(file)!!.pid)
        } finally {
            Thread.setDefaultUncaughtExceptionHandler(original)
        }
    }

    @Test
    fun unreadableFileIsDropped() {
        file.parentFile!!.mkdirs()
        file.writeText("garbage without required keys")
        assertNull(JvmCrashHandler.take(file))
        assertFalse(file.exists())
    }
}
