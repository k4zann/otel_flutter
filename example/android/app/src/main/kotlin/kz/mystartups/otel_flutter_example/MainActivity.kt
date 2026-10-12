package kz.mystartups.otel_flutter_example

import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "example/native")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // Posted: the channel would catch an exception thrown here.
                    "crash" -> Handler(Looper.getMainLooper()).post {
                        throw RuntimeException("Native crash from the example")
                    }
                    "block" -> Thread.sleep(20_000)
                }
                result.success(null)
            }
    }
}
