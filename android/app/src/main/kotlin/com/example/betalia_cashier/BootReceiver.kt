package com.example.betalia_cashier

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        Log.d("BetaliaBoot", "Receiver triggered with action: ${intent.action}")

        if (intent.action == Intent.ACTION_BOOT_COMPLETED ||
            intent.action == "android.intent.action.QUICKBOOT_POWERON" ||
            intent.action == "com.example.betalia_cashier.TEST_BOOT") {

            launchApp(context)
        }
    }

    private fun launchApp(context: Context) {
        Log.d("BetaliaBoot", "Attempting to launch MainActivity...")

        val activityIntent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }

        // Method 1: Try direct background launch (Works on emulators if ADB root is on)
        try {
            context.startActivity(activityIntent)
            Log.d("BetaliaBoot", "Direct startActivity called successfully!")
        } catch (e: Exception) {
            Log.e("BetaliaBoot", "Direct launch failed: ${e.message}")
        }

        // Method 2: Modern Notification Fallback
        val channelId = "betalia_boot_channel"
        val pendingIntent = PendingIntent.getActivity(
            context,
            0,
            activityIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                channelId,
                "Betalia Cashier Auto Start",
                NotificationManager.IMPORTANCE_HIGH
            )
            notificationManager.createNotificationChannel(channel)
        }

        val notificationBuilder = NotificationCompat.Builder(context, channelId)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle("Betalia Cashier")
            .setContentText("Tap to open cashier terminal")
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setFullScreenIntent(pendingIntent, true)
            .setAutoCancel(true)

        notificationManager.notify(777, notificationBuilder.build())
    }
}