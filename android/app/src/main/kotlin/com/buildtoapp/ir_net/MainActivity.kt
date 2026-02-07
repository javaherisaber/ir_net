package com.buildtoapp.ir_net

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    companion object {
        private const val CHANNEL = "ir_net/system_events"
        private const val REQUEST_NOTIFICATION_PERMISSION = 1001
    }

    private lateinit var notificationManager: IpNotificationManager

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        notificationManager = IpNotificationManager(this)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "updateNotification" -> {
                        val countryCode = call.argument<String>("countryCode") ?: ""
                        val country = call.argument<String>("country") ?: ""
                        val city = call.argument<String>("city") ?: ""
                        val isp = call.argument<String>("isp") ?: ""
                        val ip = call.argument<String>("ip") ?: ""

                        notificationManager.showOrUpdateNotification(
                            countryCode, country, city, isp, ip
                        )
                        result.success(null)
                    }
                    "cancelNotification" -> {
                        notificationManager.cancelNotification()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onStart() {
        super.onStart()
        requestNotificationPermission()
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
