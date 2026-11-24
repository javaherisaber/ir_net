package com.buildtoapp.ir_net

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.util.Log
import androidx.core.content.ContextCompat
import com.github.blueboytm.flutter_v2ray.v2ray.V2rayConnectionCoordinator
import io.flutter.plugin.common.EventChannel

/**
 * flutter_v2ray's status broadcasts for one Flutter engine (channel
 * "ir_net/vpn_status"). The plugin's own status stream keeps its sink in a
 * static field that any engine's teardown clears: when Android replaces
 * IRNet's activity (a launcher tap that clears the task), the old engine's
 * detach silences the new one, connects never "complete" and the app stops
 * a working VPN after its 20 s timeout. This stream belongs to its engine.
 */
class VpnStatusStream(private val context: Context) : EventChannel.StreamHandler {
    private var receiver: BroadcastReceiver? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        onCancel(null)
        val r = object : BroadcastReceiver() {
            override fun onReceive(c: Context, intent: Intent) {
                try {
                    val mode = intent.getStringExtra("SERVICE_MODE")
                    // Late reports from the other mode's service during a switch.
                    if (!V2rayConnectionCoordinator.acceptsStatusFrom(mode)) return
                    @Suppress("DEPRECATION")
                    val state = intent.getSerializableExtra("STATE")?.toString() ?: return
                    events.success(
                        mapOf(
                            "state" to state.removePrefix("V2RAY_"),
                            "duration" to (intent.getStringExtra("DURATION") ?: ""),
                            "uploadSpeed" to intent.getLongExtra("UPLOAD_SPEED", 0),
                            "downloadSpeed" to intent.getLongExtra("DOWNLOAD_SPEED", 0),
                            "upload" to intent.getLongExtra("UPLOAD_TRAFFIC", 0),
                            "download" to intent.getLongExtra("DOWNLOAD_TRAFFIC", 0),
                        )
                    )
                } catch (e: Exception) {
                    Log.w("IRNetVpnStatus", "Bad status broadcast", e)
                }
            }
        }
        ContextCompat.registerReceiver(context, r, IntentFilter("V2RAY_CONNECTION_INFO"), ContextCompat.RECEIVER_NOT_EXPORTED)
        receiver = r
    }

    override fun onCancel(arguments: Any?) {
        receiver?.let {
            try {
                context.unregisterReceiver(it)
            } catch (_: Exception) {
            }
        }
        receiver = null
    }
}
