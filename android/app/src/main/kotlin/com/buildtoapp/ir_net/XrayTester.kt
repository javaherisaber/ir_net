package com.buildtoapp.ir_net

import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import libv2ray.CoreCallbackHandler
import libv2ray.CoreController
import libv2ray.Libv2ray
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/**
 * Runs short-lived Xray cores inside the app process for delay tests
 * (channel "ir_net/xray"). One core serves a whole batch of configs on
 * separate local ports, so "test all" runs in parallel instead of one
 * config at a time. IRNet is excluded from its own VPN, so these cores
 * reach the servers directly.
 */
class XrayTester(private val context: Context) : MethodChannel.MethodCallHandler {
    private val executor = Executors.newCachedThreadPool()
    private val main = Handler(Looper.getMainLooper())
    private val cores = ConcurrentHashMap<Int, CoreController>()
    private val nextId = AtomicInteger(1)

    @Volatile
    private var envReady = false

    /** Same folder flutter_v2ray's VPN service gives Xray for .dat files. */
    private fun assetDir(): String? {
        val ext = context.getExternalFilesDir("assets") ?: return null
        return if (ext.exists()) ext.absolutePath else context.getDir("assets", 0).absolutePath
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "assetDir" -> result.success(assetDir())
            // Apps for split tunnelling: everything with a launcher icon.
            "listApps" -> executor.execute {
                val pm = context.packageManager
                val launcher = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
                val apps = pm.queryIntentActivities(launcher, 0)
                    .map { mapOf("package" to it.activityInfo.packageName, "label" to it.loadLabel(pm).toString()) }
                    .filter { it["package"] != context.packageName }
                    .distinctBy { it["package"] }
                    .sortedBy { it["label"]?.lowercase() }
                main.post { result.success(apps) }
            }
            // Android's own kill switch lives here (Always-on VPN + Block
            // connections without VPN); apps can't turn Wi-Fi off themselves.
            "openVpnSettings" -> {
                val intent = Intent(Settings.ACTION_VPN_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                try {
                    context.startActivity(intent)
                    result.success(true)
                } catch (e: Exception) {
                    result.success(false)
                }
            }
            "start" -> {
                val config = call.argument<String>("config")
                if (config == null) {
                    result.error("bad_args", "Missing config", null)
                    return
                }
                executor.execute {
                    try {
                        synchronized(this) {
                            if (!envReady) {
                                Libv2ray.initCoreEnv(assetDir() ?: "", "")
                                envReady = true
                            }
                        }
                        val controller = Libv2ray.newCoreController(object : CoreCallbackHandler {
                            override fun startup(): Long = 0
                            override fun shutdown(): Long = 0
                            override fun onEmitStatus(code: Long, message: String?): Long = 0
                        })
                        controller.startLoop(config, 0)
                        if (!controller.isRunning) throw IllegalStateException("The Xray core did not start")
                        val id = nextId.getAndIncrement()
                        cores[id] = controller
                        main.post { result.success(id) }
                    } catch (e: Throwable) {
                        main.post { result.error("start_failed", e.message ?: e.toString(), null) }
                    }
                }
            }
            "stop" -> {
                val id = call.argument<Int>("id")
                executor.execute {
                    try {
                        if (id != null) cores.remove(id)?.stopLoop()
                    } catch (_: Throwable) {
                    }
                    main.post { result.success(null) }
                }
            }
            else -> result.notImplemented()
        }
    }
}
