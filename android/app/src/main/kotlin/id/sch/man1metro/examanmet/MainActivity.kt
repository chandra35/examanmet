package id.sch.man1metro.examanmet

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.KeyEvent
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "id.sch.man1metro.examanmet/lockdown"
    private var isLockdownActive = false
    private val handler = Handler(Looper.getMainLooper())

    // Periodically re-apply immersive mode to combat any system UI leaks
    private val immersiveRunnable = object : Runnable {
        override fun run() {
            if (isLockdownActive) {
                hideSystemUI()
                handler.postDelayed(this, 1500) // Re-apply every 1.5 seconds
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "setSecureFlag" -> {
                    val secure = call.argument<Boolean>("secure") ?: true
                    runOnUiThread {
                        if (secure) {
                            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        }
                    }
                    result.success(true)
                }

                "keepScreenAwake" -> {
                    val awake = call.argument<Boolean>("awake") ?: true
                    runOnUiThread {
                        if (awake) {
                            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        }
                    }
                    result.success(true)
                }

                "startKioskMode" -> {
                    try {
                        isLockdownActive = true
                        // Note: startLockTask() removed — it shows "App is pinned" dialog
                        // on non-Device-Owner devices. Immersive mode + force bring-to-front
                        // already provides sufficient lockdown.
                        runOnUiThread { hideSystemUI() }
                        handler.post(immersiveRunnable)
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }

                "stopKioskMode" -> {
                    try {
                        isLockdownActive = false
                        handler.removeCallbacks(immersiveRunnable)
                        runOnUiThread { showSystemUI() }
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }

                "checkFloatingApps" -> {
                    val hasOverlay = checkOverlayApps()
                    result.success(hasOverlay)
                }

                "checkBlockedApps" -> {
                    val packages = call.argument<List<String>>("packages") ?: emptyList()
                    val running = checkRunningApps(packages)
                    result.success(running)
                }

                else -> result.notImplemented()
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        hideSystemUI()
    }

    /**
     * Hide system UI (status bar + navigation bar) using immersive sticky mode.
     */
    private fun hideSystemUI() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.setDecorFitsSystemWindows(false)
            window.insetsController?.let { controller ->
                controller.hide(WindowInsets.Type.statusBars() or WindowInsets.Type.navigationBars())
                controller.systemBarsBehavior =
                    WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            }
        } else {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = (
                View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                    or View.SYSTEM_UI_FLAG_FULLSCREEN
                    or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                    or View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                    or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                    or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
            )
        }
        window.addFlags(WindowManager.LayoutParams.FLAG_FULLSCREEN)
    }

    /**
     * Show system UI again (when exiting lockdown)
     */
    private fun showSystemUI() {
        window.clearFlags(WindowManager.LayoutParams.FLAG_FULLSCREEN)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.setDecorFitsSystemWindows(true)
            window.insetsController?.show(WindowInsets.Type.statusBars() or WindowInsets.Type.navigationBars())
        } else {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = View.SYSTEM_UI_FLAG_VISIBLE
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && isLockdownActive) {
            hideSystemUI()
        }
    }

    override fun onResume() {
        super.onResume()
        if (isLockdownActive) {
            hideSystemUI()
        }
    }

    /**
     * When app is paused (user somehow left), aggressively bring it back to front.
     */
    override fun onPause() {
        super.onPause()
        if (isLockdownActive) {
            // Schedule bring-to-front after a short delay
            handler.postDelayed({
                if (isLockdownActive) {
                    bringAppToFront()
                }
            }, 300)
        }
    }

    /**
     * When app is stopped (fully in background), bring it back immediately.
     */
    override fun onStop() {
        super.onStop()
        if (isLockdownActive) {
            bringAppToFront()
        }
    }

    /**
     * Force bring this app back to the foreground.
     */
    private fun bringAppToFront() {
        try {
            val activityManager = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                // Move our task to front
                val tasks = activityManager.appTasks
                if (tasks.isNotEmpty()) {
                    tasks[0].moveToFront()
                }
            }
        } catch (e: Exception) {
            // Fallback: launch ourselves again
            try {
                val intent = Intent(this, MainActivity::class.java).apply {
                    addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    addFlags(Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)
                }
                startActivity(intent)
            } catch (_: Exception) {}
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (intent.action == Intent.ACTION_ASSIST ||
            intent.action == "android.intent.action.VOICE_ASSIST" ||
            intent.action == "android.intent.action.SEARCH_LONG_PRESS") {
            return
        }
    }

    override fun onKeyLongPress(keyCode: Int, event: KeyEvent?): Boolean {
        if (keyCode == KeyEvent.KEYCODE_HOME ||
            keyCode == KeyEvent.KEYCODE_ASSIST ||
            keyCode == KeyEvent.KEYCODE_SEARCH ||
            keyCode == KeyEvent.KEYCODE_APP_SWITCH) {
            return true
        }
        return super.onKeyLongPress(keyCode, event)
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        if (isLockdownActive) {
            when (keyCode) {
                KeyEvent.KEYCODE_ASSIST,
                KeyEvent.KEYCODE_SEARCH,
                KeyEvent.KEYCODE_VOICE_ASSIST -> return true
                KeyEvent.KEYCODE_APP_SWITCH -> return true
                KeyEvent.KEYCODE_HOME -> {
                    event?.startTracking()
                    return true
                }
            }
        }
        return super.onKeyDown(keyCode, event)
    }

    private fun checkOverlayApps(): Boolean {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                Settings.canDrawOverlays(this)
            } else {
                false
            }
        } catch (e: Exception) {
            false
        }
    }

    private fun checkRunningApps(blockedPackages: List<String>): List<String> {
        val running = mutableListOf<String>()
        try {
            val activityManager = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                val tasks = activityManager.appTasks
                for (task in tasks) {
                    val info = task.taskInfo
                    val packageName = info.baseActivity?.packageName
                    if (packageName != null && blockedPackages.contains(packageName)) {
                        running.add(packageName)
                    }
                }
            }
        } catch (e: Exception) {
            // Silently handle
        }
        return running
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        // Don't call super - Flutter handles back navigation
    }

    override fun onDestroy() {
        handler.removeCallbacks(immersiveRunnable)
        super.onDestroy()
    }
}
