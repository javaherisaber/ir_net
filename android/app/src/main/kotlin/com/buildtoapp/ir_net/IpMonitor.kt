package com.buildtoapp.ir_net

import android.annotation.SuppressLint
import android.app.Notification
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import androidx.core.content.ContextCompat
import com.github.blueboytm.flutter_v2ray.v2ray.V2rayController
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.net.Inet4Address
import java.util.concurrent.Executors

/**
 * Keeps the IP location notification current from inside the app process,
 * whether or not the Flutter UI is running: it reacts to the default
 * network changing (Wi-Fi, mobile data, another app's VPN), to IRNet's own
 * VPN connecting or dropping, and to the screen turning on, and checks
 * every minute while the screen is on. Results also go to the Dart side
 * ("onIpChanged") when the UI is attached.
 *
 * Everything runs on the main thread except the lookups themselves.
 */
@SuppressLint("StaticFieldLeak") // holds the application context only
object IpMonitor {
    private const val TAG = "IRNetIpMonitor"
    private const val PREFS = "ip_notification"
    private const val KEY_LAST = "last"
    private const val KEY_PROXY = "lookupProxy"
    private const val KEY_VPN_NAME = "vpnName"
    private const val OFFLINE = "offline"

    /** flutter_v2ray's status broadcast (sent every second while connected). */
    private const val V2RAY_STATUS = "V2RAY_CONNECTION_INFO"

    private const val POLL_MS = 60_000L
    private const val SETTLE_MS = 1_500L
    private const val CONFIRM_MS = 8_000L
    private val RETRY_MS = longArrayOf(3_000L, 10_000L)
    private const val AWAIT_PROXY_TRIES = 8

    private val main = Handler(Looper.getMainLooper())
    private val executor = Executors.newSingleThreadExecutor()
    private val lookup = IpLookup()

    private var app: Context? = null
    private var notifications: IpNotificationManager? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private var physicalCallback: ConnectivityManager.NetworkCallback? = null
    private var receiver: BroadcastReceiver? = null
    private var dart: MethodChannel? = null

    private var proxy: LookupProxy? = null
    private var last: IpInfo? = null
    private var lastAt = 0L
    private var state: IpState = IpState.Starting
    private var running = false
    private var again = false
    private var failures = 0
    private var networkKey: String? = null
    private var networkChangedAt = 0L
    private var vpnConnected = false

    /** The connected config's name, as the app last said. */
    private var vpnName: String? = null

    /** IRNet's VPN is connected (per its status broadcasts). */
    val isVpnConnected: Boolean get() = vpnConnected

    /** Whether the VPN has reported its state since the monitor started. */
    private var vpnReported = false

    /** The VPN's last reported state, or null before any report. */
    val vpnStatus: Boolean? get() = if (app != null && vpnReported) vpnConnected else null

    /** The connected config's name, when known. */
    val connectedName: String? get() = if (vpnConnected) vpnName else null

    /** A proxy that refused us; not tried again until the VPN changes. */
    private var refused: LookupProxy? = null

    private val lookupNow = Runnable { runLookup() }

    /** A second look once routes and DNS have surely settled. */
    private val confirm = Runnable { request(0) }

    private val poll = object : Runnable {
        override fun run() {
            if (interactive()) request(0, maxAgeMs = POLL_MS - 5_000)
            main.postDelayed(this, POLL_MS)
        }
    }

    fun start(context: Context) {
        if (app != null) return
        val ctx = context.applicationContext
        app = ctx
        notifications = IpNotificationManager(ctx)
        val prefs = prefs(ctx)
        proxy = LookupProxy.parse(prefs.getString(KEY_PROXY, null))
        vpnName = prefs.getString(KEY_VPN_NAME, null)
        last = IpInfo.parse(prefs.getString(KEY_LAST, null)) ?: legacyLast(ctx)
        state = last?.let { IpState.Located(it, checking = true) } ?: IpState.Starting
        IpLookup.installAuthenticator()
        registerNetworkCallback(ctx)
        registerReceiver(ctx)
        main.postDelayed(poll, POLL_MS)
        request(0)
    }

    fun stop() {
        val ctx = app ?: return
        listOfNotNull(networkCallback, physicalCallback).forEach {
            try {
                ctx.getSystemService(ConnectivityManager::class.java)?.unregisterNetworkCallback(it)
            } catch (_: Exception) {
            }
        }
        receiver?.let {
            try {
                ctx.unregisterReceiver(it)
            } catch (_: Exception) {
            }
        }
        networkCallback = null
        physicalCallback = null
        receiver = null
        main.removeCallbacks(poll)
        main.removeCallbacks(lookupNow)
        main.removeCallbacks(confirm)
        app = null
        vpnReported = false
        networkKey = null
        running = false
        again = false
    }

    /** The notification for the current state (for startForeground). */
    fun notification(context: Context): Notification =
        (notifications ?: IpNotificationManager(context.applicationContext)).build(state, vpnInfo())

    fun attach(channel: MethodChannel) {
        dart = channel
    }

    fun detach(channel: MethodChannel) {
        if (dart === channel) dart = null
    }

    /**
     * From the app: look up now through [proxySpec] (the VPN's local proxy,
     * or null), or with [maxAgeMs] reuse an answer that recent.
     */
    fun requestFromApp(context: Context, proxySpec: String?, maxAgeMs: Long, vpnName: String?) {
        start(context)
        if (vpnName != null && vpnName != this.vpnName) {
            this.vpnName = vpnName
            prefs(context).edit().putString(KEY_VPN_NAME, vpnName).apply()
            if (vpnConnected) show(state)
        }
        setProxy(proxySpec)
        // With the screen off, the app's periodic checks only need the last answer.
        val age = if (maxAgeMs > 0 && !interactive()) maxOf(maxAgeMs, 5 * 60_000L) else maxAgeMs
        request(300, age)
    }

    /** "Exit IRNet" in the notification. */
    fun requestExit(context: Context) {
        val channel = dart
        if (channel == null) {
            AppExit.now(context)
            return
        }
        // Let the app disconnect the VPN and save its data first, as its own
        // Exit button does; finish here if it doesn't get to it.
        try {
            channel.invokeMethod("onExitRequested", null)
        } catch (e: Exception) {
            AppExit.now(context)
            return
        }
        AppExit.later(context, 10_000L)
    }

    /**
     * The Quick Settings tile: asks the running app to connect as its own
     * button does. False when the app isn't running.
     */
    fun requestConnect(): Boolean {
        val channel = dart ?: return false
        return try {
            channel.invokeMethod("onConnectRequested", null)
            true
        } catch (e: Exception) {
            false
        }
    }

    /** "Disconnect" in the notification (shown while IRNet's VPN is connected). */
    fun requestDisconnect(context: Context) {
        val channel = dart
        if (channel == null) {
            stopVpn(context)
            return
        }
        // The app disconnects as its own button does (state, reconnect timers);
        // stop the VPN here if it doesn't get to it.
        try {
            channel.invokeMethod("onDisconnectRequested", null)
        } catch (e: Exception) {
            stopVpn(context)
            return
        }
        main.postDelayed({ if (vpnConnected) stopVpn(context) }, 4_000L)
    }

    private fun stopVpn(context: Context) {
        try {
            V2rayController.StopV2ray(context.applicationContext)
        } catch (t: Throwable) {
            Log.w(TAG, "Couldn't stop the VPN", t)
        }
    }

    // ───────────────────────────── lookups ─────────────────────────────

    private fun request(delayMs: Long, maxAgeMs: Long = 0) {
        if (app == null) return
        val cached = last
        if (maxAgeMs > 0 && cached != null && failures == 0 && !running &&
            System.currentTimeMillis() - lastAt < maxAgeMs
        ) {
            push(cached)
            return
        }
        if (running) {
            again = true
            return
        }
        // Give routes and DNS a moment after a network change.
        val settle = SETTLE_MS - (SystemClock.elapsedRealtime() - networkChangedAt)
        main.removeCallbacks(lookupNow)
        main.postDelayed(lookupNow, maxOf(delayMs, settle, 0L))
    }

    private fun runLookup() {
        val ctx = app ?: return
        if (running) return
        if (currentNetworkKey(ctx) == OFFLINE) {
            showOffline()
            return
        }
        running = true
        again = false
        // IRNet's VPN is up but the app hasn't said which proxy (it may not be
        // running): use the one it saved for picking the VPN back up.
        val via = proxy ?: if (vpnConnected) recoveryProxy(ctx)?.takeIf { it != refused } else null
        if (vpnConnected && via == null) {
            // IRNet itself is outside its VPN: a direct lookup would show the
            // real address as if it were the VPN's. Wait for the app to name
            // the VPN's proxy (it does right after connecting).
            awaitProxy()
            return
        }
        executor.execute {
            val outcome = lookup.run(via)
            main.post { finish(outcome, via) }
        }
    }

    private fun finish(outcome: LookupOutcome, via: LookupProxy?) {
        running = false
        val ctx = app ?: return
        when (outcome) {
            is LookupOutcome.Found -> {
                failures = 0
                last = outcome.info
                lastAt = System.currentTimeMillis()
                prefs(ctx).edit().putString(KEY_LAST, outcome.info.toJson()).apply()
                show(IpState.Located(outcome.info))
                push(outcome.info)
            }
            LookupOutcome.ProxyDown -> {
                // The VPN behind the proxy has stopped: look up directly.
                Log.i(TAG, "VPN proxy refused the connection")
                refused = via
                if (proxy == via) setProxy(null)
                again = true
            }
            LookupOutcome.ProxyRejected -> {
                // A password from an earlier connection: the app passes the new
                // one moments after connecting.
                Log.i(TAG, "VPN proxy turned the password down")
                refused = via
                if (proxy == via) setProxy(null)
                awaitProxy()
            }
            is LookupOutcome.Failed -> {
                Log.i(TAG, "IP lookup failed: ${outcome.reason}")
                if (currentNetworkKey(ctx) == OFFLINE) {
                    showOffline()
                } else if (failures < RETRY_MS.size && !again) {
                    main.removeCallbacks(lookupNow)
                    main.postDelayed(lookupNow, RETRY_MS[failures])
                    failures++
                } else {
                    failures++
                    show(IpState.Unavailable(last))
                    push(null)
                }
            }
        }
        if (again) {
            again = false
            request(300)
        }
    }

    /** Tries again shortly while IRNet's VPN has no usable proxy, then gives up. */
    private fun awaitProxy() {
        if (failures < AWAIT_PROXY_TRIES) {
            failures++
            main.removeCallbacks(lookupNow)
            main.postDelayed(lookupNow, 2_000L)
        } else {
            show(IpState.Unavailable(last))
            push(null)
        }
    }

    private fun setProxy(spec: String?) {
        val p = LookupProxy.parse(spec)
        if (p == proxy) return
        if (p != null) refused = null
        proxy = p
        // A different route: an earlier answer no longer counts.
        lastAt = 0
        failures = 0
        app?.let { prefs(it).edit().putString(KEY_PROXY, if (p == null) null else spec).apply() }
        if (app != null) showChecking()
    }

    /** The proxy the Dart side saved with its VPN ("v2ray.recovery"). */
    private fun recoveryProxy(ctx: Context): LookupProxy? = try {
        val raw = ctx.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            .getString("flutter.v2ray.recovery", null)
        LookupProxy.parse(raw?.let { JSONObject(it).optString("httpProxy") })
    } catch (e: Exception) {
        null
    }

    // ───────────────────────────── changes ─────────────────────────────

    private fun registerNetworkCallback(ctx: Context) {
        val cm = ctx.getSystemService(ConnectivityManager::class.java) ?: return
        fun watcher() = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                main.post { onNetwork() }
            }

            override fun onLost(network: Network) {
                main.post { onNetwork() }
            }

            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
                main.post { onNetwork() }
            }

            override fun onLinkPropertiesChanged(network: Network, lp: LinkProperties) {
                main.post { onNetwork() }
            }
        }
        try {
            // The network IRNet's own traffic uses: changes with Wi-Fi, mobile
            // data and VPNs (IRNet's own too in Xray TUN mode).
            val callback = watcher()
            cm.registerDefaultNetworkCallback(callback)
            networkCallback = callback
            // The real networks under a VPN, which can come and go while the
            // VPN (the default network) stays up.
            val physical = watcher()
            cm.registerNetworkCallback(
                NetworkRequest.Builder()
                    .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                    .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
                    .build(),
                physical,
            )
            physicalCallback = physical
        } catch (e: Exception) {
            Log.w(TAG, "Couldn't watch the network", e)
        }
    }

    private fun registerReceiver(ctx: Context) {
        val r = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                when (intent.action) {
                    Intent.ACTION_SCREEN_ON -> request(500, maxAgeMs = 30_000)
                    V2RAY_STATUS -> onVpnStatus(intent)
                }
            }
        }
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(V2RAY_STATUS)
        }
        ContextCompat.registerReceiver(ctx, r, filter, ContextCompat.RECEIVER_NOT_EXPORTED)
        receiver = r
    }

    private fun onNetwork() {
        val ctx = app ?: return
        val key = currentNetworkKey(ctx)
        if (key == networkKey) return
        val first = networkKey == null
        networkKey = key
        if (first) return // the callback reports the current network on registration
        Log.i(TAG, "Network changed: $key")
        changed(offline = key == OFFLINE)
    }

    @Suppress("DEPRECATION")
    private fun onVpnStatus(intent: Intent) {
        val connected = when (intent.getSerializableExtra("STATE")?.toString()) {
            "V2RAY_CONNECTED" -> true
            "V2RAY_DISCONNECTED" -> false
            else -> return
        }
        vpnReported = true
        if (connected == vpnConnected) {
            // The VPN service shares this notification's id and shows its own
            // content while it starts; don't let that outlive a failed start.
            if (!connected) show(state)
            return
        }
        vpnConnected = connected
        refused = null
        app?.let { VpnTileService.refresh(it) }
        Log.i(TAG, "IRNet VPN ${if (connected) "connected" else "disconnected"}")
        // Its local proxy goes with it; the app (or its saved record) names the new one.
        if (!connected) setProxy(null)
        changed(offline = false)
    }

    private fun changed(offline: Boolean) {
        networkChangedAt = SystemClock.elapsedRealtime()
        lastAt = 0
        failures = 0
        main.removeCallbacks(confirm)
        if (offline) {
            main.removeCallbacks(lookupNow)
            showOffline()
            return
        }
        showChecking()
        request(0)
        main.postDelayed(confirm, CONFIRM_MS)
    }

    /** Identifies the default network as far as the public IP could differ. */
    private fun currentNetworkKey(ctx: Context): String {
        val cm = ctx.getSystemService(ConnectivityManager::class.java) ?: return OFFLINE
        val network = cm.activeNetwork ?: return OFFLINE
        val caps = cm.getNetworkCapabilities(network) ?: return OFFLINE
        if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) return OFFLINE
        // A VPN stays up with nothing under it: IRNet's own VPN in Xray TUN
        // mode (cloned apps), where IRNet is inside it, or another app's.
        if (caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN) && !hasPhysicalInternet(cm)) return OFFLINE
        val transports = listOf(
            NetworkCapabilities.TRANSPORT_WIFI to "wifi",
            NetworkCapabilities.TRANSPORT_CELLULAR to "cell",
            NetworkCapabilities.TRANSPORT_ETHERNET to "eth",
            NetworkCapabilities.TRANSPORT_VPN to "vpn",
            NetworkCapabilities.TRANSPORT_BLUETOOTH to "bt",
        ).filter { caps.hasTransport(it.first) }.joinToString("+") { it.second }
        val validated = caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
        val lp = cm.getLinkProperties(network)
        // IPv4 only: rotating IPv6 privacy addresses don't change the lookup.
        val v4 = lp?.linkAddresses?.mapNotNull { (it.address as? Inet4Address)?.hostAddress }?.sorted()
        return "$network|$transports|$validated|${lp?.interfaceName}|$v4"
    }

    /** Wi-Fi, mobile data or the like is connected (not just a VPN). */
    @Suppress("DEPRECATION")
    private fun hasPhysicalInternet(cm: ConnectivityManager): Boolean = cm.allNetworks.any { n ->
        val c = cm.getNetworkCapabilities(n) ?: return@any false
        c.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN) &&
            c.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
    }

    // ───────────────────────────── output ─────────────────────────────

    private fun show(s: IpState) {
        state = s
        notifications?.show(s, vpnInfo())
    }

    private fun vpnInfo(): VpnInfo? = if (vpnConnected) VpnInfo(vpnName) else null

    private fun showChecking() {
        show(last?.let { IpState.Located(it, checking = true) } ?: IpState.Starting)
    }

    private fun showOffline() {
        show(IpState.Offline)
        push(null)
    }

    /** Sends a result (or null: none) to the Dart side, when the UI is running. */
    private fun push(info: IpInfo?) {
        val channel = dart ?: return
        try {
            channel.invokeMethod("onIpChanged", info?.toMap() ?: emptyMap<String, Any?>())
        } catch (e: Exception) {
            Log.w(TAG, "Couldn't reach the app", e)
        }
    }

    private fun interactive(): Boolean {
        val pm = app?.getSystemService(PowerManager::class.java) ?: return true
        return pm.isInteractive
    }

    private fun prefs(ctx: Context) = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** What versions before the monitor saved. */
    private fun legacyLast(ctx: Context): IpInfo? {
        val p = prefs(ctx)
        val cc = p.getString("countryCode", null)
        if (cc.isNullOrBlank()) return null
        return IpInfo(
            countryCode = cc,
            country = p.getString("country", "") ?: "",
            regionName = "",
            city = p.getString("city", "") ?: "",
            isp = p.getString("isp", "") ?: "",
            ip = p.getString("ip", "") ?: "",
            lat = null,
            lon = null,
        )
    }
}
