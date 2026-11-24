package com.buildtoapp.ir_net

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * One-off alerts (channel "ir_net/notify"): VPN dropped, kill switch,
 * subscription and Kerio balance warnings. Separate from the ongoing IP
 * location notification so users can mute one without the other.
 */
class AlertNotifier(private val context: Context) : MethodChannel.MethodCallHandler {
    companion object {
        private const val CHANNEL_ID = "irnet_alerts"
    }

    init {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(CHANNEL_ID, "Alerts", NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = "VPN drops, subscription and balance warnings"
            }
            (context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                .createNotificationChannel(channel)
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "show") {
            result.notImplemented()
            return
        }
        val title = call.argument<String>("title") ?: "IRNet"
        val body = call.argument<String>("body") ?: ""
        // The same id replaces an earlier alert instead of stacking.
        val id = (call.argument<String>("id") ?: "$title$body").hashCode()
        val open = context.packageManager.getLaunchIntentForPackage(context.packageName)?.apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val pending = open?.let {
            PendingIntent.getActivity(context, 0, it, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        }
        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setAutoCancel(true)
            .setContentIntent(pending)
            .build()
        try {
            NotificationManagerCompat.from(context).notify(id, notification)
            result.success(true)
        } catch (e: SecurityException) {
            // POST_NOTIFICATIONS not granted.
            result.success(false)
        }
    }
}
