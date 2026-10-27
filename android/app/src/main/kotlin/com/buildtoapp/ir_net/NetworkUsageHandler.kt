package com.buildtoapp.ir_net

import android.app.AppOpsManager
import android.app.usage.NetworkStats
import android.app.usage.NetworkStatsManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.provider.Settings
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Per-app traffic from [NetworkStatsManager] for the Data usage section.
 *
 * Needs the "Usage access" special permission, which only the user can grant
 * in system settings. Android charges traffic that goes through a VPN to the
 * app that generated it, so the VPN app itself only shows its own overhead.
 */
class NetworkUsageHandler(private val context: Context) : MethodChannel.MethodCallHandler {

    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "hasUsageAccess" -> result.success(hasUsageAccess())
            "openUsageAccessSettings" -> {
                val intent = Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                context.startActivity(intent)
                result.success(null)
            }
            "querySummary" -> {
                val start = (call.argument<Number>("start") ?: 0).toLong()
                val end = (call.argument<Number>("end") ?: System.currentTimeMillis()).toLong()
                // Binder calls into the stats service can be slow: keep them
                // off the UI thread.
                Thread {
                    try {
                        val rows = querySummary(start, end)
                        mainHandler.post { result.success(rows) }
                    } catch (e: SecurityException) {
                        mainHandler.post { result.error("NO_ACCESS", e.message, null) }
                    } catch (e: Exception) {
                        mainHandler.post { result.error("FAILED", e.message, null) }
                    }
                }.start()
            }
            else -> result.notImplemented()
        }
    }

    private fun hasUsageAccess(): Boolean {
        val appOps = context.getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
        val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            appOps.unsafeCheckOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), context.packageName
            )
        } else {
            @Suppress("DEPRECATION")
            appOps.checkOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), context.packageName
            )
        }
        if (mode == AppOpsManager.MODE_DEFAULT) {
            return context.checkCallingOrSelfPermission(android.Manifest.permission.PACKAGE_USAGE_STATS) ==
                PackageManager.PERMISSION_GRANTED
        }
        return mode == AppOpsManager.MODE_ALLOWED
    }

    /** Bytes per app (uid) over [start, end) on Wi-Fi, mobile and Ethernet. */
    private fun querySummary(start: Long, end: Long): List<Map<String, Any?>> {
        val manager = context.getSystemService(Context.NETWORK_STATS_SERVICE) as NetworkStatsManager
        val totals = HashMap<Int, LongArray>()
        @Suppress("DEPRECATION")
        val types = intArrayOf(
            ConnectivityManager.TYPE_WIFI,
            ConnectivityManager.TYPE_MOBILE,
            ConnectivityManager.TYPE_ETHERNET,
        )
        for (type in types) {
            val stats = try {
                manager.querySummary(type, null, start, end)
            } catch (e: SecurityException) {
                throw e
            } catch (e: Exception) {
                null // network type not supported on this device
            } ?: continue
            val bucket = NetworkStats.Bucket()
            while (stats.hasNextBucket()) {
                stats.getNextBucket(bucket)
                val sums = totals.getOrPut(bucket.uid) { LongArray(2) }
                sums[0] += bucket.rxBytes
                sums[1] += bucket.txBytes
            }
            stats.close()
        }
        return totals.map { (uid, sums) ->
            val (pkg, name) = describe(uid)
            mapOf("uid" to uid, "package" to pkg, "name" to name, "rx" to sums[0], "tx" to sums[1])
        }
    }

    private fun describe(uid: Int): Pair<String?, String> = when (uid) {
        NetworkStats.Bucket.UID_REMOVED -> null to "Removed apps"
        NetworkStats.Bucket.UID_TETHERING -> null to "Hotspot & tethering"
        Process.SYSTEM_UID -> "android" to "Android system"
        0 -> null to "Android system (root)"
        else -> {
            val pm = context.packageManager
            val pkg = pm.getPackagesForUid(uid)?.firstOrNull()
            val label = pkg?.let {
                try {
                    pm.getApplicationLabel(pm.getApplicationInfo(it, 0)).toString()
                } catch (e: Exception) {
                    null
                }
            }
            pkg to (label ?: pkg ?: "App $uid")
        }
    }
}
