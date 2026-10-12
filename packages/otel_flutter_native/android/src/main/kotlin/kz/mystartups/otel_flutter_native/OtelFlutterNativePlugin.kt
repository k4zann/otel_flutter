package kz.mystartups.otel_flutter_native

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.Process
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import kotlin.concurrent.thread

/**
 * Reports how previous processes ended. Records are only read on request
 * (`getPendingCrashes`, once per launch); nothing runs in between except the
 * passive JVM crash handler.
 */
class OtelFlutterNativePlugin : FlutterPlugin, MethodCallHandler {
    private var channel: MethodChannel? = null
    private lateinit var context: Context

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        JvmCrashHandler.install(PendingCrashes.crashFile(context)) { Process.myPid() }
        channel = MethodChannel(binding.binaryMessenger, "otel_flutter_native").also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        if (call.method != "getPendingCrashes") return result.notImplemented()
        val main = Handler(Looper.getMainLooper())
        // A binder call plus trace reads: keep them off the main thread.
        thread(name = "otel_flutter_native") {
            try {
                val records = PendingCrashes(context).take()
                main.post { result.success(records) }
            } catch (e: Exception) {
                main.post { result.error("unavailable", e.toString(), null) }
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
    }
}
