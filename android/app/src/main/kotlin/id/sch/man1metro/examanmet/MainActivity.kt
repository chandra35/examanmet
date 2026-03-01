package id.sch.man1metro.examanmet

import android.accessibilityservice.AccessibilityServiceInfo
import android.app.ActivityManager
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.ClipData
import android.content.ClipboardManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.res.Configuration
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.MediaPlayer
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
import android.view.accessibility.AccessibilityManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val CHANNEL = "id.sch.man1metro.examanmet/lockdown"
    private val EVENT_CHANNEL = "id.sch.man1metro.examanmet/security_events"
    private var isLockdownActive = false
    private val handler = Handler(Looper.getMainLooper())
    private var securityEventSink: EventChannel.EventSink? = null
    private var alertMediaPlayer: MediaPlayer? = null

    // Bluetooth state change receiver
    private val bluetoothReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (!isLockdownActive) return
            when (intent?.action) {
                BluetoothAdapter.ACTION_STATE_CHANGED -> {
                    val state = intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)
                    if (state == BluetoothAdapter.STATE_ON) {
                        sendSecurityEvent("bluetooth_turned_on")
                    }
                }
                BluetoothAdapter.ACTION_CONNECTION_STATE_CHANGED -> {
                    val state = intent.getIntExtra(BluetoothAdapter.EXTRA_CONNECTION_STATE, -1)
                    if (state == BluetoothAdapter.STATE_CONNECTED) {
                        sendSecurityEvent("bluetooth_device_connected")
                    }
                }
            }
        }
    }

    // Headset plug/unplug receiver
    private val headsetReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (!isLockdownActive) return
            if (intent?.action == Intent.ACTION_HEADSET_PLUG) {
                val state = intent.getIntExtra("state", -1)
                val name = intent.getStringExtra("name") ?: "unknown"
                if (state == 1) {
                    sendSecurityEvent("headset_connected:$name")
                }
            }
        }
    }

    // Periodically re-apply immersive mode to combat any system UI leaks
    private val immersiveRunnable = object : Runnable {
        override fun run() {
            if (isLockdownActive) {
                hideSystemUI()
                handler.postDelayed(this, 1500) // Re-apply every 1.5 seconds
            }
        }
    }

    // Periodically run security audit checks
    private val securityAuditRunnable = object : Runnable {
        override fun run() {
            if (isLockdownActive) {
                performSecurityAudit()
                handler.postDelayed(this, 5000) // Check every 5 seconds
            }
        }
    }

    // Detect when system dialogs (notification panel, power menu) are opened
    private val systemDialogReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (isLockdownActive && intent?.action == Intent.ACTION_CLOSE_SYSTEM_DIALOGS) {
                val reason = intent.getStringExtra("reason") ?: ""
                // Re-hide system UI immediately when notification panel or power menu appears
                hideSystemUI()
                // Send event to Flutter side
                when (reason) {
                    "homekey" -> sendSecurityEvent("home_pressed")
                    "recentapps" -> sendSecurityEvent("recent_pressed")
                    "notification" -> sendSecurityEvent("notification_pulled")
                    "globalactions" -> sendSecurityEvent("power_menu")
                    else -> sendSecurityEvent("system_dialog:$reason")
                }
            }
        }
    }

    // Detect screen on/off
    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (!isLockdownActive) return
            when (intent?.action) {
                Intent.ACTION_SCREEN_OFF -> {
                    sendSecurityEvent("screen_off")
                }
                Intent.ACTION_SCREEN_ON -> {
                    // Re-apply full lockdown when screen turns on
                    handler.postDelayed({
                        if (isLockdownActive) {
                            hideSystemUI()
                            try { startLockTask() } catch (_: Exception) {}
                        }
                    }, 300)
                    sendSecurityEvent("screen_on")
                }
                Intent.ACTION_USER_PRESENT -> {
                    // Device unlocked — re-apply lockdown
                    if (isLockdownActive) {
                        hideSystemUI()
                        bringAppToFront()
                    }
                    sendSecurityEvent("device_unlocked")
                }
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Security event stream to Flutter
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    securityEventSink = events
                }
                override fun onCancel(arguments: Any?) {
                    securityEventSink = null
                }
            })

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
                        runOnUiThread {
                            hideSystemUI()
                            // Enable screen pinning — blocks Home, Recent, and notifications
                            try {
                                startLockTask()
                            } catch (_: Exception) {}
                        }
                        handler.post(immersiveRunnable)
                        handler.post(securityAuditRunnable)
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }

                "stopKioskMode" -> {
                    try {
                        isLockdownActive = false
                        handler.removeCallbacks(immersiveRunnable)
                        handler.removeCallbacks(securityAuditRunnable)
                        runOnUiThread {
                            try {
                                stopLockTask()
                            } catch (_: Exception) {}
                            showSystemUI()
                        }
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

                // NEW: Full security audit — returns map of security threats
                "securityAudit" -> {
                    val audit = mutableMapOf<String, Any>()
                    audit["developer_options"] = isDeveloperOptionsEnabled()
                    audit["usb_debugging"] = isUsbDebuggingEnabled()
                    audit["accessibility_services"] = getActiveAccessibilityServices()
                    audit["is_multi_window"] = isInMultiWindowMode
                    audit["overlay_permission"] = checkOverlayApps()
                    audit["is_rooted"] = isDeviceRooted()
                    audit["bluetooth_enabled"] = isBluetoothEnabled()
                    audit["bluetooth_connected_devices"] = getConnectedBluetoothDevices()
                    audit["headset_connected"] = isHeadsetConnected()
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                        audit["is_in_picture_in_picture"] = isInPictureInPictureMode
                    }
                    result.success(audit)
                }

                // Check Bluetooth status and connected devices
                "checkBluetooth" -> {
                    val btInfo = mutableMapOf<String, Any>()
                    btInfo["enabled"] = isBluetoothEnabled()
                    btInfo["connected_devices"] = getConnectedBluetoothDevices()
                    result.success(btInfo)
                }

                // Check headset/earphone connection
                "checkHeadset" -> {
                    result.success(isHeadsetConnected())
                }

                // Check root status
                "checkRoot" -> {
                    result.success(isDeviceRooted())
                }

                // Play alert sound
                "playAlertSound" -> {
                    playAlertSound()
                    result.success(true)
                }

                // Stop alert sound
                "stopAlertSound" -> {
                    stopAlertSound()
                    result.success(true)
                }

                // Clear clipboard silently (no Android 13+ toast)
                "clearClipboard" -> {
                    clearClipboardSilently()
                    result.success(true)
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

        // Register broadcast receivers for system events
        registerSystemReceivers()

        // Register Bluetooth & headset receivers
        registerSecurityReceivers()
    }

    /**
     * Register broadcast receivers for system-level event detection
     */
    private fun registerSystemReceivers() {
        try {
            // Detect notification panel, power menu, etc.
            @Suppress("DEPRECATION")
            registerReceiver(
                systemDialogReceiver,
                IntentFilter(Intent.ACTION_CLOSE_SYSTEM_DIALOGS)
            )
        } catch (_: Exception) {}

        try {
            // Detect screen on/off
            val screenFilter = IntentFilter().apply {
                addAction(Intent.ACTION_SCREEN_OFF)
                addAction(Intent.ACTION_SCREEN_ON)
                addAction(Intent.ACTION_USER_PRESENT)
            }
            registerReceiver(screenReceiver, screenFilter)
        } catch (_: Exception) {}
    }

    /**
     * Register Bluetooth and headset broadcast receivers
     */
    private fun registerSecurityReceivers() {
        try {
            val btFilter = IntentFilter().apply {
                addAction(BluetoothAdapter.ACTION_STATE_CHANGED)
                addAction(BluetoothAdapter.ACTION_CONNECTION_STATE_CHANGED)
            }
            registerReceiver(bluetoothReceiver, btFilter)
        } catch (_: Exception) {}

        try {
            registerReceiver(
                headsetReceiver,
                IntentFilter(Intent.ACTION_HEADSET_PLUG)
            )
        } catch (_: Exception) {}
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
        } else if (!hasFocus && isLockdownActive) {
            // User pulled down notification bar or opened system dialog — re-hide ASAP
            handler.postDelayed({
                if (isLockdownActive) {
                    hideSystemUI()
                }
            }, 100)
        }
    }

    override fun onResume() {
        super.onResume()
        if (isLockdownActive) {
            hideSystemUI()
            // Re-apply screen pinning in case it was dropped
            try { startLockTask() } catch (_: Exception) {}
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
     * Detect multi-window mode changes (split screen) and block them
     */
    override fun onMultiWindowModeChanged(isInMultiWindowMode: Boolean, newConfig: Configuration) {
        super.onMultiWindowModeChanged(isInMultiWindowMode, newConfig)
        if (isInMultiWindowMode && isLockdownActive) {
            // Force exit multi-window mode by re-launching ourselves fullscreen
            sendSecurityEvent("multi_window_detected")
            handler.postDelayed({
                if (isLockdownActive) {
                    try {
                        val intent = Intent(this, MainActivity::class.java).apply {
                            addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            addFlags(Intent.FLAG_ACTIVITY_LAUNCH_ADJACENT) // Exit split screen
                        }
                        startActivity(intent)
                        hideSystemUI()
                    } catch (_: Exception) {}
                }
            }, 200)
        }
    }

    /**
     * Detect Picture-in-Picture changes and block
     */
    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        if (isInPictureInPictureMode && isLockdownActive) {
            sendSecurityEvent("pip_detected")
            // Move task to front to exit PiP
            val activityManager = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                try { activityManager.appTasks[0].moveToFront() } catch (_: Exception) {}
            }
        }
    }

    /**
     * Force bring this app back to the foreground.
     */
    private fun bringAppToFront() {
        try {
            val activityManager = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                val tasks = activityManager.appTasks
                if (tasks.isNotEmpty()) {
                    tasks[0].moveToFront()
                }
            }
        } catch (e: Exception) {
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
        if (isLockdownActive) {
            // Block ALL long press keys during lockdown
            when (keyCode) {
                KeyEvent.KEYCODE_HOME,
                KeyEvent.KEYCODE_ASSIST,
                KeyEvent.KEYCODE_SEARCH,
                KeyEvent.KEYCODE_APP_SWITCH,
                KeyEvent.KEYCODE_POWER,
                KeyEvent.KEYCODE_VOLUME_UP,
                KeyEvent.KEYCODE_VOLUME_DOWN -> return true
            }
        }
        return super.onKeyLongPress(keyCode, event)
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        if (isLockdownActive) {
            when (keyCode) {
                // Block assistant/search keys
                KeyEvent.KEYCODE_ASSIST,
                KeyEvent.KEYCODE_SEARCH,
                KeyEvent.KEYCODE_VOICE_ASSIST -> return true
                // Block app switcher
                KeyEvent.KEYCODE_APP_SWITCH -> return true
                // Block Home key
                KeyEvent.KEYCODE_HOME -> {
                    event?.startTracking()
                    return true
                }
                // Block volume keys (prevent triggering power menu combo)
                KeyEvent.KEYCODE_VOLUME_UP,
                KeyEvent.KEYCODE_VOLUME_DOWN -> {
                    event?.startTracking()
                    return true
                }
                // Block menu key
                KeyEvent.KEYCODE_MENU -> return true
                // Block camera key
                KeyEvent.KEYCODE_CAMERA -> return true
            }
        }
        return super.onKeyDown(keyCode, event)
    }

    override fun onKeyUp(keyCode: Int, event: KeyEvent?): Boolean {
        if (isLockdownActive) {
            when (keyCode) {
                KeyEvent.KEYCODE_VOLUME_UP,
                KeyEvent.KEYCODE_VOLUME_DOWN,
                KeyEvent.KEYCODE_HOME,
                KeyEvent.KEYCODE_APP_SWITCH,
                KeyEvent.KEYCODE_MENU,
                KeyEvent.KEYCODE_CAMERA -> return true
            }
        }
        return super.onKeyUp(keyCode, event)
    }

    // ==================== Security Audit Methods ====================

    /**
     * Check if Developer Options is enabled
     */
    private fun isDeveloperOptionsEnabled(): Boolean {
        return try {
            Settings.Global.getInt(contentResolver, Settings.Global.DEVELOPMENT_SETTINGS_ENABLED, 0) != 0
        } catch (_: Exception) { false }
    }

    /**
     * Check if USB Debugging (ADB) is enabled
     */
    private fun isUsbDebuggingEnabled(): Boolean {
        return try {
            Settings.Global.getInt(contentResolver, Settings.Global.ADB_ENABLED, 0) != 0
        } catch (_: Exception) { false }
    }

    /**
     * Get list of active accessibility services (potential screen readers / auto-clickers)
     */
    private fun getActiveAccessibilityServices(): List<String> {
        val services = mutableListOf<String>()
        try {
            val am = getSystemService(Context.ACCESSIBILITY_SERVICE) as AccessibilityManager
            val enabledServices = am.getEnabledAccessibilityServiceList(
                AccessibilityServiceInfo.FEEDBACK_ALL_MASK
            )
            // Whitelist system services, flag third-party ones
            val systemPackages = setOf(
                "com.google.android.marvin.talkback",  // TalkBack (accessibility)
                "com.samsung.accessibility",            // Samsung accessibility
                "com.android.systemui",                 // System UI
            )
            for (service in enabledServices) {
                val packageName = service.resolveInfo?.serviceInfo?.packageName ?: continue
                if (!systemPackages.contains(packageName)) {
                    services.add(packageName)
                }
            }
        } catch (_: Exception) {}
        return services
    }

    /**
     * Perform periodic security audit and send events to Flutter
     */
    private fun performSecurityAudit() {
        if (!isLockdownActive) return

        // Check developer options
        if (isDeveloperOptionsEnabled()) {
            sendSecurityEvent("developer_options_enabled")
        }

        // Check USB debugging
        if (isUsbDebuggingEnabled()) {
            sendSecurityEvent("usb_debugging_enabled")
        }

        // Check suspicious accessibility services
        val suspiciousServices = getActiveAccessibilityServices()
        if (suspiciousServices.isNotEmpty()) {
            sendSecurityEvent("accessibility_service:${suspiciousServices.joinToString(",")}")
        }

        // Check multi-window
        if (isInMultiWindowMode) {
            sendSecurityEvent("multi_window_active")
        }

        // Check PiP
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N && isInPictureInPictureMode) {
            sendSecurityEvent("pip_active")
        }

        // Check Bluetooth connected devices
        val btDevices = getConnectedBluetoothDevices()
        if (btDevices.isNotEmpty()) {
            sendSecurityEvent("bluetooth_connected:${btDevices.joinToString(",")}")
        }

        // Check headset
        if (isHeadsetConnected()) {
            sendSecurityEvent("headset_connected")
        }

        // Check root
        if (isDeviceRooted()) {
            sendSecurityEvent("device_rooted")
        }
    }

    /**
     * Send a security event to Flutter via EventChannel
     */
    private fun sendSecurityEvent(event: String) {
        handler.post {
            try {
                securityEventSink?.success(event)
            } catch (_: Exception) {}
        }
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

    // ==================== Bluetooth Detection ====================

    /**
     * Check if Bluetooth is currently enabled
     */
    private fun isBluetoothEnabled(): Boolean {
        return try {
            val bluetoothManager = getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
            bluetoothManager?.adapter?.isEnabled == true
        } catch (_: Exception) { false }
    }

    /**
     * Get list of currently connected Bluetooth device names
     */
    private fun getConnectedBluetoothDevices(): List<String> {
        val devices = mutableListOf<String>()
        try {
            val bluetoothManager = getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
            val adapter = bluetoothManager?.adapter ?: return devices

            // Check common audio profiles
            val profiles = listOf(
                BluetoothProfile.HEADSET,
                BluetoothProfile.A2DP
            )
            for (profile in profiles) {
                adapter.getProfileProxy(this, object : BluetoothProfile.ServiceListener {
                    override fun onServiceConnected(profileType: Int, proxy: BluetoothProfile?) {
                        proxy?.connectedDevices?.forEach { device ->
                            try {
                                val name = device.name ?: device.address
                                if (!devices.contains(name)) {
                                    devices.add(name)
                                }
                            } catch (_: SecurityException) {}
                        }
                        adapter.closeProfileProxy(profileType, proxy)
                    }
                    override fun onServiceDisconnected(profile: Int) {}
                }, profile)
            }

            // Also check bonded (paired) devices that might be connected
            try {
                val bondedDevices = adapter.bondedDevices
                // Note: bondedDevices shows paired, not necessarily connected
                // The profile proxy check above is more accurate
            } catch (_: SecurityException) {}
        } catch (_: Exception) {}
        return devices
    }

    // ==================== Headset Detection ====================

    /**
     * Check if any headset/earphone is currently connected (wired or wireless)
     */
    private fun isHeadsetConnected(): Boolean {
        return try {
            val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                val devices = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
                devices.any { device ->
                    device.type == AudioDeviceInfo.TYPE_WIRED_HEADSET ||
                    device.type == AudioDeviceInfo.TYPE_WIRED_HEADPHONES ||
                    device.type == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP ||
                    device.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO ||
                    device.type == AudioDeviceInfo.TYPE_USB_HEADSET ||
                    (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                        device.type == AudioDeviceInfo.TYPE_HEARING_AID) ||
                    (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                        device.type == AudioDeviceInfo.TYPE_BLE_HEADSET)
                }
            } else {
                @Suppress("DEPRECATION")
                audioManager.isWiredHeadsetOn || audioManager.isBluetoothA2dpOn || audioManager.isBluetoothScoOn
            }
        } catch (_: Exception) { false }
    }

    // ==================== Root Detection ====================

    /**
     * Check if the device is rooted using multiple detection methods
     */
    private fun isDeviceRooted(): Boolean {
        return checkRootBinary() || checkSuExists() || checkRootPaths() || checkDangerousProps() || checkRootManagementApps()
    }

    private fun checkRootBinary(): Boolean {
        val paths = arrayOf(
            "/system/bin/su", "/system/xbin/su", "/sbin/su",
            "/system/su", "/system/bin/.ext/.su",
            "/system/usr/we-need-root/su-backup",
            "/system/xbin/mu", "/data/local/xbin/su",
            "/data/local/bin/su", "/data/local/su"
        )
        return paths.any { File(it).exists() }
    }

    private fun checkSuExists(): Boolean {
        return try {
            val process = Runtime.getRuntime().exec(arrayOf("/system/xbin/which", "su"))
            val reader = process.inputStream.bufferedReader()
            val result = reader.readLine()
            reader.close()
            result != null
        } catch (_: Exception) { false }
    }

    private fun checkRootPaths(): Boolean {
        val paths = arrayOf(
            "/system/app/Superuser.apk",
            "/system/app/SuperSU.apk",
            "/system/app/Magisk.apk",
            "/system/etc/init.d/99telecominfra"
        )
        return paths.any { File(it).exists() }
    }

    private fun checkDangerousProps(): Boolean {
        return try {
            val process = Runtime.getRuntime().exec("getprop ro.debuggable")
            val reader = process.inputStream.bufferedReader()
            val result = reader.readLine()?.trim()
            reader.close()
            result == "1"
        } catch (_: Exception) { false }
    }

    private fun checkRootManagementApps(): Boolean {
        val rootApps = arrayOf(
            "com.topjohnwu.magisk", "eu.chainfire.supersu",
            "com.koushikdutta.superuser", "com.noshufou.android.su",
            "com.thirdparty.superuser", "com.yellowes.su",
            "com.kingroot.kinguser", "com.kingo.root",
            "com.smediapartner.rooting", "com.zhiqupk.root.global"
        )
        return rootApps.any { pkg ->
            try {
                packageManager.getPackageInfo(pkg, 0)
                true
            } catch (_: Exception) { false }
        }
    }

    // ==================== Alert Sound ====================

    /**
     * Play alert sound from Flutter assets for security violations
     */
    private fun playAlertSound() {
        try {
            stopAlertSound() // Stop any existing playback
            val assetManager = assets
            val fd = assetManager.openFd("flutter_assets/assets/sounds/alert.wav")
            alertMediaPlayer = MediaPlayer().apply {
                setDataSource(fd.fileDescriptor, fd.startOffset, fd.length)
                fd.close()
                // Play at max volume regardless of device settings
                setVolume(1.0f, 1.0f)
                isLooping = false
                prepare()
                start()
                setOnCompletionListener {
                    it.release()
                    alertMediaPlayer = null
                }
            }
        } catch (e: Exception) {
            android.util.Log.e("ExaManmet", "Failed to play alert sound: ${e.message}")
        }
    }

    /**
     * Stop currently playing alert sound
     */
    private fun stopAlertSound() {
        try {
            alertMediaPlayer?.let {
                if (it.isPlaying) it.stop()
                it.release()
            }
            alertMediaPlayer = null
        } catch (_: Exception) {}
    }

    /**
     * Clear clipboard silently without triggering Android 13+ "Copied" toast.
     * Uses clearPrimaryClip() on API 28+ which doesn't show a visual indicator.
     */
    private fun clearClipboardSilently() {
        try {
            val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                // API 28+: clearPrimaryClip() silently clears without toast
                clipboard.clearPrimaryClip()
            } else {
                // Older APIs: set empty clip (no toast on these versions anyway)
                clipboard.setPrimaryClip(ClipData.newPlainText("", ""))
            }
        } catch (_: Exception) {}
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
        } catch (e: Exception) {}
        return running
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        // Don't call super - Flutter handles back navigation
    }

    override fun onDestroy() {
        handler.removeCallbacks(immersiveRunnable)
        handler.removeCallbacks(securityAuditRunnable)
        try { unregisterReceiver(systemDialogReceiver) } catch (_: Exception) {}
        try { unregisterReceiver(screenReceiver) } catch (_: Exception) {}
        try { unregisterReceiver(bluetoothReceiver) } catch (_: Exception) {}
        try { unregisterReceiver(headsetReceiver) } catch (_: Exception) {}
        stopAlertSound()
        super.onDestroy()
    }
}
