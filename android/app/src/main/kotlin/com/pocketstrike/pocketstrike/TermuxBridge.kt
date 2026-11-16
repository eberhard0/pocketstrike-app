package com.pocketstrike.pocketstrike

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicInteger

/**
 * Runs a shell command inside Termux through its RUN_COMMAND service and hands the output back to
 * Flutter. Termux is a separate app with a full Linux userland (git, python, pip…), so this is how
 * PocketStrike's agent gets a real shell that the app's own sandbox cannot provide.
 *
 * Requires, on the user's side:
 *   - Termux installed (F-Droid / GitHub build, not the dead Play build),
 *   - `allow-external-apps=true` in ~/.termux/termux.properties,
 *   - the first call accepted in Termux's permission prompt.
 */
object TermuxBridge {
    private const val TERMUX_PKG = "com.termux"
    private const val RUN_SERVICE = "com.termux.app.RunCommandService"
    private const val ACTION_RUN = "com.termux.RUN_COMMAND"

    private const val EXTRA_PATH = "com.termux.RUN_COMMAND_PATH"
    private const val EXTRA_ARGS = "com.termux.RUN_COMMAND_ARGUMENTS"
    private const val EXTRA_WORKDIR = "com.termux.RUN_COMMAND_WORKDIR"
    private const val EXTRA_BACKGROUND = "com.termux.RUN_COMMAND_BACKGROUND"
    private const val EXTRA_SESSION_ACTION = "com.termux.RUN_COMMAND_SESSION_ACTION"
    private const val EXTRA_PENDING_INTENT = "com.termux.RUN_COMMAND_PENDING_INTENT"

    // Keys inside the result the PendingIntent carries back.
    private const val EXTRA_RESULT_BUNDLE = "result"
    private const val KEY_STDOUT = "stdout"
    private const val KEY_STDERR = "stderr"
    private const val KEY_EXIT = "exitCode"
    private const val KEY_ERR = "err"
    private const val KEY_ERRMSG = "errmsg"

    private val counter = AtomicInteger(1000)

    /**
     * Runs `command` via `bash -lc` in the background and completes [result] with a map of
     * stdout / stderr / exitCode once Termux reports back, or an error if Termux can't be reached.
     */
    fun run(context: Context, command: String, workdir: String?, timeoutMs: Long, result: MethodChannel.Result) {
        val app = context.applicationContext
        val id = counter.incrementAndGet()
        val replyAction = "$TERMUX_PKG.result.$id.${System.currentTimeMillis()}"
        val main = Handler(Looper.getMainLooper())
        var finished = false

        val receiver = object : BroadcastReceiver() {
            override fun onReceive(c: Context, intent: Intent) {
                if (finished) return
                finished = true
                runCatching { app.unregisterReceiver(this) }
                val bundle: Bundle? = intent.getBundleExtra(EXTRA_RESULT_BUNDLE)
                if (bundle == null) {
                    main.post { result.success(mapOf("ok" to false, "error" to "Termux returned no result bundle")) }
                    return
                }
                val out = bundle.getString(KEY_STDOUT) ?: ""
                val err = bundle.getString(KEY_STDERR) ?: ""
                val exit = bundle.getInt(KEY_EXIT, -1)
                val internalErr = bundle.getInt(KEY_ERR, 0)
                val errmsg = bundle.getString(KEY_ERRMSG) ?: ""
                main.post {
                    result.success(
                        mapOf(
                            "ok" to true,
                            "stdout" to out,
                            "stderr" to err,
                            "exitCode" to exit,
                            "internalErr" to internalErr,
                            "errmsg" to errmsg,
                        ),
                    )
                }
            }
        }

        val filter = IntentFilter(replyAction)
        if (Build.VERSION.SDK_INT >= 33) {
            app.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            app.registerReceiver(receiver, filter)
        }

        // A mutable broadcast PendingIntent Termux fills with the result.
        val replyIntent = Intent(replyAction).setPackage(app.packageName)
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0)
        val pending = PendingIntent.getBroadcast(app, id, replyIntent, flags)

        val service = Intent().apply {
            setClassName(TERMUX_PKG, RUN_SERVICE)
            action = ACTION_RUN
            putExtra(EXTRA_PATH, "/data/data/com.termux/files/usr/bin/bash")
            putExtra(EXTRA_ARGS, arrayOf("-lc", command))
            if (!workdir.isNullOrBlank()) putExtra(EXTRA_WORKDIR, workdir)
            putExtra(EXTRA_BACKGROUND, true)
            putExtra(EXTRA_SESSION_ACTION, "0")
            putExtra(EXTRA_PENDING_INTENT, pending)
        }

        try {
            if (Build.VERSION.SDK_INT >= 26) app.startForegroundService(service) else app.startService(service)
        } catch (e: Exception) {
            finished = true
            runCatching { app.unregisterReceiver(receiver) }
            result.success(
                mapOf(
                    "ok" to false,
                    "error" to "Could not reach Termux (${e.javaClass.simpleName}). " +
                        "Open Termux once, and make sure external apps are allowed. In Termux run: " +
                        "echo 'allow-external-apps=true' >> ~/.termux/termux.properties && termux-reload-settings",
                ),
            )
            return
        }

        main.postDelayed({
            if (!finished) {
                finished = true
                runCatching { app.unregisterReceiver(receiver) }
                result.success(
                    mapOf(
                        "ok" to false,
                        "error" to "Timed out after ${timeoutMs / 1000}s waiting for Termux. " +
                            "The command may still be running in Termux.",
                    ),
                )
            }
        }, timeoutMs)
    }
}
