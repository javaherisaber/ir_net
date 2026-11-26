package com.buildtoapp.ir_net

import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.UserManager
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
            // Xray TUN mode (see flutter_v2ray's IRNET.md): cloned apps,
            // their app ids, and the interface Xray's connections use.
            "cloneProfile" -> result.success(CloneSupport.needsXrayTun(context))
            "appIds" -> {
                val packages = call.argument<List<String>>("packages") ?: emptyList()
                result.success(CloneSupport.appIds(context, packages))
            }
            "physicalInterface" -> result.success(CloneSupport.physicalInterface(context))
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

/**
 * Samsung puts its cloned apps (Dual Messenger, another user) in a VPN only
 * when the VPN keeps no app out by package, so on phones with clones the VPN
 * runs in Xray TUN mode: Xray reads the VPN interface itself and binds its
 * own connections to the physical interface instead of IRNet being excluded.
 */
object CloneSupport {
    private const val PER_USER_RANGE = 100000

    /** A clone profile exists and Xray TUN mode can run here. */
    fun needsXrayTun(context: Context): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && kernelBindsWithoutRoot() && hasCloneProfile(context)

    /**
     * Binding a socket to an interface (SO_BINDTODEVICE) needs no privilege
     * since Linux 5.7; older kernels would refuse Xray's connections.
     */
    private fun kernelBindsWithoutRoot(): Boolean {
        val m = Regex("""^(\d+)\.(\d+)""").find(System.getProperty("os.version") ?: "") ?: return false
        val (major, minor) = m.destructured
        return major.toInt() > 5 || (major.toInt() == 5 && minor.toInt() >= 7)
    }

    private fun hasCloneProfile(context: Context): Boolean {
        // Samsung: getDualAppProfileId() is -10000 without Dual Messenger.
        try {
            val id = Class.forName("com.samsung.android.app.SemDualAppManager")
                .getMethod("getDualAppProfileId").invoke(null) as Int
            return id != -10000
        } catch (_: Throwable) {
        }
        // Otherwise: Samsung's dual-app users are 95 to 99 (UserHandle's hash is its id).
        val users = context.getSystemService(UserManager::class.java) ?: return false
        return try {
            users.userProfiles.any { it.hashCode() in 95..99 }
        } catch (_: Exception) {
            false
        }
    }

    /** The app id (uid without the user) of each installed package. */
    fun appIds(context: Context, packages: List<String>): List<String> =
        packages.mapNotNull { name ->
            try {
                (context.packageManager.getPackageUid(name, 0) % PER_USER_RANGE).toString()
            } catch (_: Exception) {
                null
            }
        }.distinct()

    /** The interface of the best network that isn't a VPN (Wi-Fi first). */
    fun physicalInterface(context: Context): String? {
        val cm = context.getSystemService(ConnectivityManager::class.java) ?: return null
        val active = cm.activeNetwork
        return cm.allNetworks.mapNotNull { n ->
            val caps = cm.getNetworkCapabilities(n) ?: return@mapNotNull null
            val name = cm.getLinkProperties(n)?.interfaceName ?: return@mapNotNull null
            if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN) ||
                !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            ) return@mapNotNull null
            val score = (if (caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)) 100 else 0) +
                (if (n == active) 50 else 0) +
                when {
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> 3
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> 2
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> 1
                    else -> 0
                }
            name to score
        }.maxByOrNull { it.second }?.first
    }
}
