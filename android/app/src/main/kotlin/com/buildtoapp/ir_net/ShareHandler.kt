package com.buildtoapp.ir_net

import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/** Own subclass so the provider never clashes with a plugin's FileProvider. */
class ExportFileProvider : FileProvider()

/**
 * Opens the system share sheet for an exported report, or puts a screenshot
 * on the clipboard (`ir_net/share`).
 */
class ShareHandler(private val activity: Activity) : MethodChannel.MethodCallHandler {

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "shareFile" -> shareFile(call, result)
            "copyImage" -> copyImage(call, result)
            else -> result.notImplemented()
        }
    }

    private fun shareFile(call: MethodCall, result: MethodChannel.Result) {
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

    /** Clipboard images travel as content URIs, so the PNG goes to cache/clipboard/. */
    private fun copyImage(call: MethodCall, result: MethodChannel.Result) {
        val png = call.argument<ByteArray>("png")
        if (png == null) {
            result.error("BAD_ARGS", "png is required", null)
            return
        }
        try {
            // Only the latest copy can still be pasted.
            val dir = File(activity.cacheDir, "clipboard")
            dir.deleteRecursively()
            dir.mkdirs()
            val file = File(dir, call.argument<String>("name") ?: "IRNet.png")
            file.writeBytes(png)
            val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.exports", file)
            val clipboard = activity.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            clipboard.setPrimaryClip(ClipData.newUri(activity.contentResolver, file.name, uri))
            result.success(null)
        } catch (e: Exception) {
            result.error("COPY_FAILED", e.message, null)
        }
    }
}
