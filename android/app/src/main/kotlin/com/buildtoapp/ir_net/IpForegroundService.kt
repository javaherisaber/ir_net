package com.buildtoapp.ir_net

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Typeface
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.graphics.drawable.IconCompat

class IpForegroundService : Service() {

    companion object {
        private const val CHANNEL_ID = "ip_notification_channel"
        private const val NOTIFICATION_ID = 1001
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        startForegroundWithNotification()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (manager.getNotificationChannel(CHANNEL_ID) == null) {
                val channel = NotificationChannel(
                    CHANNEL_ID,
                    "IP Location",
                    NotificationManager.IMPORTANCE_LOW
                ).apply {
                    description = "Shows current IP location info"
                    setShowBadge(false)
                }
                manager.createNotificationChannel(channel)
            }
        }
    }

    private fun startForegroundWithNotification() {
        val prefs = getSharedPreferences("ip_notification", Context.MODE_PRIVATE)
        val countryCode = prefs.getString("countryCode", null)
        val country = prefs.getString("country", null)
        val city = prefs.getString("city", null)
        val isp = prefs.getString("isp", null)
        val ip = prefs.getString("ip", null)

        val hasSavedData = !countryCode.isNullOrBlank()

        val title: String
        val contentText: String
        val smallIcon: IconCompat

        if (hasSavedData) {
            val flagEmoji = countryCodeToFlagEmoji(countryCode!!)
            title = "$flagEmoji $country"
            contentText = "IP: $ip | $city"
            smallIcon = IconCompat.createWithBitmap(createCountryCodeBitmap(countryCode))
        } else {
            title = "IRNet"
            contentText = "Monitoring IP location..."
            smallIcon = IconCompat.createWithResource(this, android.R.drawable.ic_dialog_info)
        }

        val launchIntent = Intent(this, MainActivity::class.java).apply {
            action = Intent.ACTION_MAIN
            addCategory(Intent.CATEGORY_LAUNCHER)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED
        }
        val pendingIntent = PendingIntent.getActivity(
            this, 0, launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(smallIcon)
            .setContentTitle(title)
            .setContentText(contentText)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun createCountryCodeBitmap(countryCode: String): Bitmap {
        val size = 96
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = android.graphics.Color.WHITE
            textSize = if (countryCode.length <= 2) 64f else 48f
            typeface = Typeface.DEFAULT_BOLD
            textAlign = Paint.Align.CENTER
        }
        val x = size / 2f
        val y = size / 2f - (textPaint.descent() + textPaint.ascent()) / 2f
        canvas.drawText(countryCode.uppercase(), x, y, textPaint)
        return bitmap
    }

    private fun countryCodeToFlagEmoji(countryCode: String): String {
        return countryCode.uppercase().map { char ->
            String(Character.toChars(0x1F1E6 - 'A'.code + char.code))
        }.joinToString("")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
