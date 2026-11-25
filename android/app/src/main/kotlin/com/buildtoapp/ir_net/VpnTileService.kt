package com.buildtoapp.ir_net

import android.app.ActivityManager
import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import android.util.Log
import com.github.blueboytm.flutter_v2ray.v2ray.V2rayController
import com.github.blueboytm.flutter_v2ray.v2ray.services.V2rayProxyOnlyService
import com.github.blueboytm.flutter_v2ray.v2ray.services.V2rayVPNService
import com.github.blueboytm.flutter_v2ray.v2ray.utils.AppConfigs
import org.json.JSONObject

/**
 * The "IRNet VPN" Quick Settings tile: turns IRNet's VPN on and off from
 * the notification shade, with or without the app open.
 */
class VpnTileService : TileService() {

    companion object {
        private val main = Handler(Looper.getMainLooper())

        /** The tile while the shade shows it. */
        private var listening: VpnTileService? = null

        /** Set by a tap until the VPN connects (or [CONNECT_TIMEOUT_MS] passes). */
        private var connectingUntil = 0L
        private const val CONNECT_TIMEOUT_MS = 25_000L

        /** Set by a tap until the VPN stops (or [DISCONNECT_TIMEOUT_MS] passes). */
        private var disconnectingUntil = 0L
        private const val DISCONNECT_TIMEOUT_MS = 8_000L

        /** Redraws the tile after the VPN changed. */
        fun refresh(context: Context) {
            if (IpMonitor.isVpnConnected) connectingUntil = 0 else disconnectingUntil = 0
            val tile = listening
            if (tile != null) {
                tile.render()
            } else {
                try {
                    requestListeningState(context, ComponentName(context, VpnTileService::class.java))
                } catch (_: Exception) {
                    // Tile not added.
                }
            }
        }

        /**
         * IRNet's VPN is on. The VPN's own status reports win: they say
         * "disconnected" the moment it stops, while its service takes a
         * second or two more to go away. The service check only covers the
         * time before any report (IRNet just started, VPN already on).
         */
        fun vpnRunning(context: Context): Boolean {
            IpMonitor.vpnStatus?.let { return it }
            val am = context.getSystemService(ActivityManager::class.java) ?: return false
            val names = setOf(V2rayVPNService::class.java.name, V2rayProxyOnlyService::class.java.name)
            @Suppress("DEPRECATION") // still lists the caller's own services
            return am.getRunningServices(50).any { it.started && it.service.className in names }
        }
    }

    override fun onStartListening() {
        super.onStartListening()
        listening = this
        render()
    }

    override fun onStopListening() {
        if (listening === this) listening = null
        super.onStopListening()
    }

    override fun onTileAdded() {
        super.onTileAdded()
        render()
    }

    override fun onClick() {
        super.onClick()
        // A tap right after "Exit IRNet" turns the VPN on: the exit must not
        // finish afterwards and kill it.
        AppExit.cancel()
        if (vpnRunning(this) && SystemClock.elapsedRealtime() >= disconnectingUntil) {
            // Show it off right away; the VPN's report confirms it.
            connectingUntil = 0
            disconnectingUntil = SystemClock.elapsedRealtime() + DISCONNECT_TIMEOUT_MS
            render()
            IpMonitor.requestDisconnect(this)
            main.postDelayed({ refresh(applicationContext) }, DISCONNECT_TIMEOUT_MS + 100)
            return
        }
        disconnectingUntil = 0
        when {
            // The app is running: connect as its own button does (fresh config
            // from the current settings and selection).
            IpMonitor.requestConnect() -> startConnecting()
            quickStart() -> startConnecting()
            // Nothing to connect to yet, or Android's VPN permission is needed.
            else -> if (isLocked) unlockAndRun { openApp() } else openApp()
        }
    }

    /**
     * Starts the last connection with the app closed. IRNet's own service and
     * monitor come up first: the VPN service's notification shares its id
     * with IRNet's, and they replace the plugin's own content with IRNet's
     * (location, Disconnect, Exit) as soon as the VPN connects.
     */
    private fun quickStart(): Boolean {
        IpMonitor.start(applicationContext)
        IpForegroundService.start(applicationContext)
        return QuickConnect.start(this)
    }

    private fun startConnecting() {
        connectingUntil = SystemClock.elapsedRealtime() + CONNECT_TIMEOUT_MS
        render()
        main.postDelayed({ refresh(applicationContext) }, CONNECT_TIMEOUT_MS + 100)
    }

    private fun render() {
        val tile = qsTile ?: return
        val now = SystemClock.elapsedRealtime()
        val running = vpnRunning(this)
        // A tap shows its outcome at once; the VPN's report then confirms it.
        val disconnecting = running && now < disconnectingUntil
        val connecting = !running && now < connectingUntil
        val on = running && !disconnecting
        tile.label = "IRNet VPN"
        tile.state = if (on || connecting) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            tile.subtitle = when {
                connecting -> "Connecting\u2026"
                disconnecting -> "Turning off\u2026"
                on -> IpMonitor.connectedName ?: "Connected"
                else -> "Off"
            }
        }
        tile.updateTile()
    }

    private fun openApp() {
        val intent = Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startActivityAndCollapse(
                PendingIntent.getActivity(this, 3, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            )
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }
}

/**
 * Starts IRNet's last VPN connection without the Flutter UI: the app saves
 * what it started ("v2ray.quickConnect") on every successful connect.
 */
object QuickConnect {
    private const val TAG = "IRNetQuickConnect"
    private const val FLUTTER_PREFS = "FlutterSharedPreferences"
    private const val KEY = "flutter.v2ray.quickConnect"
    private const val RECOVERY = "flutter.v2ray.recovery"

    /** Returns false when the app has to connect instead. */
    fun start(context: Context): Boolean {
        val prefs = context.getSharedPreferences(FLUTTER_PREFS, Context.MODE_PRIVATE)
        val record = try {
            JSONObject(prefs.getString(KEY, null) ?: return false)
        } catch (e: Exception) {
            return false
        }
        val config = record.optString("config").takeIf { it.isNotEmpty() } ?: return false
        val proxyOnly = record.optBoolean("proxyOnly")
        // Tunnel mode needs Android's VPN permission, which only the app can ask for.
        if (!proxyOnly && VpnService.prepare(context) != null) return false
        return try {
            val app = context.applicationContext
            V2rayController.init(app, app.resources.getIdentifier("ic_launcher", "mipmap", app.packageName), "Flutter V2ray")
            AppConfigs.NOTIFICATION_DISCONNECT_BUTTON_NAME = "Disconnect"
            // Lets the app pick the connection up when it opens.
            prefs.edit().putString(
                RECOVERY,
                JSONObject()
                    .put("profileId", record.optString("profileId"))
                    .put("httpProxy", record.optString("httpProxy"))
                    .put("udpProxy", record.optString("udpProxy"))
                    .toString()
            ).apply()
            V2rayController.StartV2ray(
                app,
                record.optString("remark", "IRNet"),
                config,
                strings(record, "blockedApps"),
                strings(record, "bypassSubnets"),
                if (proxyOnly) AppConfigs.V2RAY_CONNECTION_MODES.PROXY_ONLY else AppConfigs.V2RAY_CONNECTION_MODES.VPN_TUN,
            )
            true
        } catch (t: Throwable) {
            Log.w(TAG, "Quick connect failed", t)
            false
        }
    }

    private fun strings(o: JSONObject, key: String): ArrayList<String>? {
        val a = o.optJSONArray(key) ?: return null
        return ArrayList<String>().apply { for (i in 0 until a.length()) add(a.getString(i)) }
    }
}
