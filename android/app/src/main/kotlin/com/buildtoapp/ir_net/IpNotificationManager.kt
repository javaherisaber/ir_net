package com.buildtoapp.ir_net

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Typeface
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.graphics.drawable.IconCompat

/**
 * The ongoing notification: IRNet's foreground service's, and while IRNet's
 * VPN is connected also the VPN service's (see [NOTIFICATION_ID]).
 */
class IpNotificationManager(private val context: Context) {

    companion object {
        const val CHANNEL_ID = "ip_notification_channel"

        /**
         * The id flutter_v2ray's VPN service gives its foreground notification
         * (V2rayCoreManager.NOTIFICATION_ID). Sharing it makes Android show one
         * notification for both services: it stays while either runs, the
         * plugin can't cancel it while IRNet's service holds it, and IpMonitor
         * replaces the plugin's content as soon as the VPN connects or stops.
         */
        const val NOTIFICATION_ID = 1

        /** The id before it was shared. */
        private const val OLD_NOTIFICATION_ID = 1001
    }

    private val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    init {
        manager.cancel(OLD_NOTIFICATION_ID)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && manager.getNotificationChannel(CHANNEL_ID) == null) {
            val channel = NotificationChannel(CHANNEL_ID, "IP Location", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Shows current IP location info"
                setShowBadge(false)
            }
            manager.createNotificationChannel(channel)
        }
    }

    fun show(state: IpState, vpn: VpnInfo?) {
        try {
            manager.notify(NOTIFICATION_ID, build(state, vpn))
        } catch (e: SecurityException) {
            // Notifications not allowed.
        }
    }

    fun cancel() = manager.cancel(NOTIFICATION_ID)

    fun build(state: IpState, vpn: VpnInfo?): Notification {
        val texts = NotificationText.of(state, vpn)
        val icon = when (state) {
            is IpState.Located -> IconCompat.createWithBitmap(countryCodeBitmap(state.info.countryCode))
            is IpState.Unavailable, IpState.Offline -> IconCompat.createWithResource(context, android.R.drawable.ic_dialog_alert)
            IpState.Starting -> IconCompat.createWithResource(context, android.R.drawable.ic_dialog_info)
        }

        val launchIntent = Intent(context, MainActivity::class.java).apply {
            action = Intent.ACTION_MAIN
            addCategory(Intent.CATEGORY_LAUNCHER)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED
        }
        val open = PendingIntent.getActivity(
            context, 0, launchIntent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        fun action(requestCode: Int, action: String) = PendingIntent.getBroadcast(
            context, requestCode,
            Intent(context, NotificationActionReceiver::class.java).setAction(action),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(icon)
            .setContentTitle(texts.title)
            .setContentText(texts.text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(texts.bigText))
            .setContentIntent(open)
        // Buttons show when the notification is expanded.
        if (vpn != null) {
            builder.addAction(
                android.R.drawable.ic_lock_power_off, "Disconnect", action(2, NotificationActionReceiver.ACTION_DISCONNECT)
            )
        }
        return builder
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Exit IRNet", action(1, NotificationActionReceiver.ACTION_EXIT))
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setShowWhen(false)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
    }

    private fun countryCodeBitmap(countryCode: String): Bitmap {
        val size = 96
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = android.graphics.Color.WHITE
            textSize = if (countryCode.length <= 2) 64f else 48f
            typeface = Typeface.DEFAULT_BOLD
            textAlign = Paint.Align.CENTER
        }
        val y = size / 2f - (paint.descent() + paint.ascent()) / 2f
        canvas.drawText(countryCode.uppercase(), size / 2f, y, paint)
        return bitmap
    }
}
