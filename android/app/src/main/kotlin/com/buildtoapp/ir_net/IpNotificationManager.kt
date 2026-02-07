package com.buildtoapp.ir_net

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Typeface
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.graphics.drawable.IconCompat

class IpNotificationManager(private val context: Context) {

    companion object {
        private const val CHANNEL_ID = "ip_notification_channel"
        private const val NOTIFICATION_ID = 1001
    }

    private val notificationManager =
        context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    init {
        createNotificationChannel()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "IP Location",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Shows current IP location info"
                setShowBadge(false)
            }
            notificationManager.createNotificationChannel(channel)
        }
    }

    fun showOrUpdateNotification(
        countryCode: String,
        country: String,
        city: String,
        isp: String,
        ip: String
    ) {
        val flagEmoji = countryCodeToFlagEmoji(countryCode)
        val title = "$flagEmoji $country"
        val contentText = "IP: $ip | $city"
        val bigText = "IP: $ip\nCity: $city\nISP: $isp"

        val iconBitmap = createCountryCodeBitmap(countryCode)

        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(IconCompat.createWithBitmap(iconBitmap))
            .setContentTitle(title)
            .setContentText(contentText)
            .setStyle(NotificationCompat.BigTextStyle().bigText(bigText))
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setSilent(true)

        notificationManager.notify(NOTIFICATION_ID, builder.build())
    }

    fun cancelNotification() {
        notificationManager.cancel(NOTIFICATION_ID)
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
}
