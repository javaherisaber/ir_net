package com.buildtoapp.ir_net

import android.app.Activity
import android.content.ClipData
import android.content.Intent
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/** Own subclass so the provider never clashes with a plugin's FileProvider. */
class ExportFileProvider : FileProvider()

/** Opens the system share sheet for an exported report (`ir_net/share`). */
class ShareHandler(private val activity: Activity) : MethodChannel.MethodCallHandler {

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "shareFile") {
            result.notImplemented()
            return
        }
        val path = call.argument<String>("path")
        if (path == null) {
            result.error("BAD_ARGS", "path is required", null)
            return
        }
        try {
            val uri = FileProvider.getUriForFile(
                activity, "${activity.packageName}.exports", File(path)
            )
            val subject = call.argument<String>("subject") ?: File(path).name
            val send = Intent(Intent.ACTION_SEND).apply {
                type = call.argument<String>("mimeType") ?: "application/octet-stream"
                putExtra(Intent.EXTRA_STREAM, uri)
                putExtra(Intent.EXTRA_SUBJECT, subject)
                // Lets the chooser preview the file and grants read access to the target.
                clipData = ClipData.newRawUri(subject, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            activity.startActivity(Intent.createChooser(send, subject))
            result.success(null)
        } catch (e: Exception) {
            result.error("SHARE_FAILED", e.message, null)
        }
    }
}
