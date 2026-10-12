package kz.mystartups.otel_flutter_native_example

import android.os.Handler
import android.os.Looper
import android.os.Process
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** Test triggers for the harness: a Kotlin crash, a signal and an ANR. */
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "harness")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // Thrown outside the channel handler, which would catch it.
                    "crash" -> Handler(Looper.getMainLooper()).post {
                        throw IllegalStateException("harness crash")
                    }
                    "signal" -> Process.sendSignal(Process.myPid(), 11) // SIGSEGV
                    // Blocks the Android main thread: a tap during this is an ANR.
                    "hang" -> { Thread.sleep(60_000); result.success(null) }
                    else -> result.notImplemented()
                }
            }
    }
}
