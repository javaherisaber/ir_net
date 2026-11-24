package com.buildtoapp.ir_net

import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log

/**
 * Keeps IRNet's process alive so [IpMonitor] can update the IP location
 * notification the moment the network or VPN changes, with or without the
 * UI open. The monitor's notification is this service's.
 */
class IpForegroundService : Service() {

    companion object {
        fun start(context: Context) {
            val intent = Intent(context, IpForegroundService::class.java)
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Exception) {
                // Not allowed from the background right now; IpMonitor still
                // updates the notification while the process runs.
                Log.w("IRNetIpService", "Couldn't start the IP service", e)
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        IpMonitor.start(this)
        val notification = IpMonitor.notification(this)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(IpNotificationManager.NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(IpNotificationManager.NOTIFICATION_ID, notification)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int = START_STICKY

    override fun onDestroy() {
        IpMonitor.stop()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
