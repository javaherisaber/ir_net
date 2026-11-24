package com.buildtoapp.ir_net

import android.app.ActivityManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.util.Log
import com.github.blueboytm.flutter_v2ray.v2ray.V2rayController

/** Shuts IRNet down completely: VPN, monitor, notification, UI and processes. */
object AppExit {
    private const val TAG = "IRNetExit"

    /** flutter_v2ray runs the VPN in this separate process. */
    private const val VPN_PROCESS_SUFFIX = ":RunSoLibV2RayDaemon"

    private val main = Handler(Looper.getMainLooper())

    @Volatile
    private var exiting = false

    /** The final kill, or the fallback for an exit the app was asked to do. */
    private var pending: Runnable? = null

    /** Exits after [delayMs] unless [cancel]led first (the app normally exits sooner). */
    fun later(context: Context, delayMs: Long) {
        val app = context.applicationContext
        val run = Runnable { now(app) }
        pending?.let { main.removeCallbacks(it) }
        pending = run
        main.postDelayed(run, delayMs)
    }

    /**
     * IRNet was started again (Quick Settings tile, launcher) while an exit
     * was finishing: keep the process, or the kill would take the new VPN
     * connection down with it.
     */
    fun cancel() {
        pending?.let { main.removeCallbacks(it) }
        pending = null
        exiting = false
    }

    fun now(context: Context) {
        if (exiting) return
        exiting = true
        pending?.let { main.removeCallbacks(it) }
        val app = context.applicationContext
        try {
            V2rayController.StopV2ray(app)
        } catch (t: Throwable) {
            Log.w(TAG, "Couldn't stop the VPN", t)
        }
        IpMonitor.stop()
        IpNotificationManager(app).cancel()
        app.stopService(Intent(app, IpForegroundService::class.java))
        MainActivity.current?.get()?.finishAndRemoveTask()
        // Give the VPN a moment to tear down, then make sure nothing is left.
        val kill = Runnable {
            val am = app.getSystemService(ActivityManager::class.java)
            am?.runningAppProcesses
                ?.filter { it.pid != Process.myPid() && it.processName.endsWith(VPN_PROCESS_SUFFIX) }
                ?.forEach { Process.killProcess(it.pid) }
            Process.killProcess(Process.myPid())
        }
        pending = kill
        main.postDelayed(kill, 1_500L)
    }
}

/** Buttons in the ongoing notification. */
class NotificationActionReceiver : BroadcastReceiver() {
    companion object {
        const val ACTION_EXIT = "com.buildtoapp.ir_net.action.EXIT"
        const val ACTION_DISCONNECT = "com.buildtoapp.ir_net.action.DISCONNECT"
    }

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            ACTION_EXIT -> IpMonitor.requestExit(context)
            ACTION_DISCONNECT -> IpMonitor.requestDisconnect(context)
        }
    }
}
