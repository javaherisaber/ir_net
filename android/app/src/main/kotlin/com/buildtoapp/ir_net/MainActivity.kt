package com.buildtoapp.ir_net

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference

class MainActivity : FlutterActivity() {

    companion object {
        private const val CHANNEL = "ir_net/system_events"
        private const val USAGE_CHANNEL = "ir_net/net_usage"
        private const val SHARE_CHANNEL = "ir_net/share"
        private const val XRAY_CHANNEL = "ir_net/xray"
        private const val NOTIFY_CHANNEL = "ir_net/notify"
        private const val VPN_STATUS_CHANNEL = "ir_net/vpn_status"
        private const val REQUEST_NOTIFICATION_PERMISSION = 1001

        /** For closing the UI from the notification's Exit button. */
        var current: WeakReference<MainActivity>? = null
    }

    private var systemChannel: MethodChannel? = null
    private var vpnStatus: VpnStatusStream? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        AppExit.cancel() // reopened while an exit was finishing
        current = WeakReference(this)
        super.onCreate(savedInstanceState)
    }

    override fun onDestroy() {
        if (current?.get() === this) current = null
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, USAGE_CHANNEL)
            .setMethodCallHandler(NetworkUsageHandler(applicationContext))

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SHARE_CHANNEL)
            .setMethodCallHandler(ShareHandler(this))

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, XRAY_CHANNEL)
            .setMethodCallHandler(XrayTester(applicationContext))

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, NOTIFY_CHANNEL)
            .setMethodCallHandler(AlertNotifier(applicationContext))

        val status = VpnStatusStream(applicationContext)
        vpnStatus = status
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, VPN_STATUS_CHANNEL).setStreamHandler(status)

        val system = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        systemChannel = system
        IpMonitor.start(applicationContext)
        IpMonitor.attach(system)
        system.setMethodCallHandler { call, result ->
            when (call.method) {
                // The IP lookup runs in IpMonitor, which also keeps the
                // notification current; results come back as "onIpChanged".
                "lookupIp" -> {
                    val maxAge = call.argument<Number>("maxAgeMs")?.toLong() ?: 0L
                    IpMonitor.requestFromApp(
                        applicationContext, call.argument<String>("proxy"), maxAge, call.argument<String>("vpnName")
                    )
                    result.success(null)
                }
                "exitApp" -> {
                    result.success(null)
                    AppExit.now(applicationContext)
                }
                "cancelNotification" -> {
                    IpNotificationManager(applicationContext).cancel()
                    result.success(null)
                }
                "stopService" -> {
                    stopService(Intent(this, IpForegroundService::class.java))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        systemChannel?.let { IpMonitor.detach(it) }
        systemChannel = null
        vpnStatus?.onCancel(null)
        vpnStatus = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onStart() {
        super.onStart()
        requestNotificationPermission()
        IpForegroundService.start(this)
    }

    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS)
                != PackageManager.PERMISSION_GRANTED
            ) {
                ActivityCompat.requestPermissions(
                    this,
                    arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                    REQUEST_NOTIFICATION_PERMISSION
                )
            }
        }
    }
}
