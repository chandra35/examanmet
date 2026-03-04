package id.sch.man1metro.examanmet

import android.accessibilityservice.AccessibilityServiceInfo
import android.app.ActivityManager
import android.app.NotificationManager
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
import android.telephony.PhoneStateListener
import android.telephony.TelephonyManager
import android.view.KeyEvent
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import android.view.accessibility.AccessibilityManager
import android.graphics.PixelFormat
import android.view.Gravity
import android.view.MotionEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val CHANNEL = "id.sch.man1metro.examanmet/lockdown"
    private val EVENT_CHANNEL = "id.sch.man1metro.examanmet/security_events"
    private var isLockdownActive = false
    private var isExiting = false  // Prevents bring-to-front during app exit
    private var userLeaveHintFired = false  // Distinguishes Home vs Recent button
    private val handler = Handler(Looper.getMainLooper())
    private var securityEventSink: EventChannel.EventSink? = null
    private var alertMediaPlayer: MediaPlayer? = null
    private var statusBarBlocker: View? = null  // Invisible overlay to block status bar swipe
    private var protectionLevel: String = "basic"  // "basic" or "full"
    private var previousDndFilter: Int = NotificationManager.INTERRUPTION_FILTER_ALL
    private var dndEnabled = false
    private var phoneStateListener: PhoneStateListener? = null

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
                collapseStatusBar()
                handler.postDelayed(this, 800) // Re-apply every 800ms (was 1.5s)
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
                        isExiting = false  // Reset exit flag when starting lockdown
                        runOnUiThread {
                            hideSystemUI()
                            // Only add overlay blocker on full protection level
                            if (protectionLevel == "full") {
                                addStatusBarBlocker()
                            }
                            // Screen Pinning: completely blocks status bar, home, recent
                            // Shows system dialog for confirmation on first call
                            try {
                                startLockTask()
                            } catch (e: Exception) {
                                debugLog("Screen pinning failed: ${e.message}")
                            }
                        }
                        handler.post(immersiveRunnable)
                        // Only run aggressive security audit on full protection
                        if (protectionLevel == "full") {
                            handler.post(securityAuditRunnable)
                        }
                        // Enable DND mode to block ALL notifications & calls (both levels)
                        enableDndMode()
                        // Start phone state listener to detect incoming calls
                        startPhoneStateListener()
                        // Cancel any existing notifications
                        cancelAllNotifications()
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }

                "stopKioskMode" -> {
                    try {
                        isLockdownActive = false
                        isExiting = true  // Prevent ALL bring-to-front after exit
                        // Remove ALL pending handler callbacks to prevent any lingering actions
                        handler.removeCallbacksAndMessages(null)
                        runOnUiThread {
                            // Stop screen pinning first
                            try {
                                stopLockTask()
                            } catch (e: Exception) {
                                debugLog("Stop lock task failed: ${e.message}")
                            }
                            removeStatusBarBlocker()
                            showSystemUI()
                        }
                        // Restore DND mode & stop phone listener
                        disableDndMode()
                        stopPhoneStateListener()
                        // Re-post only the non-lockdown related runnables if needed
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }

                "checkFloatingApps" -> {
                    val hasOverlay = checkOverlayApps()
                    result.success(hasOverlay)
                }

                "checkOverlayPermission" -> {
                    val hasPermission = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        Settings.canDrawOverlays(this)
                    } else {
                        true // Pre-M doesn't need runtime permission
                    }
                    result.success(hasPermission)
                }

                "requestOverlayPermission" -> {
                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && !Settings.canDrawOverlays(this)) {
                            val intent = Intent(
                                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                                android.net.Uri.parse("package:$packageName")
                            )
                            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(intent)
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }

                "checkBlockedApps" -> {
                    val packages = call.argument<List<String>>("packages") ?: emptyList()
                    val running = checkRunningApps(packages)
                    result.success(running)
                }

                "isScreenPinned" -> {
                    result.success(isInLockTaskMode())
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

                // Kill background cheating & bloatware apps
                "killSuspiciousApps" -> {
                    val killed = killSuspiciousBackgroundApps()
                    result.success(killed)
                }

                // Check current keyboard (IME)
                "checkKeyboard" -> {
                    val imeInfo = checkCurrentKeyboard()
                    result.success(imeInfo)
                }

                // Get device manufacturer info (for OEM-specific handling)
                "getDeviceInfo" -> {
                    val info = mutableMapOf<String, Any>()
                    info["manufacturer"] = Build.MANUFACTURER.lowercase()
                    info["brand"] = Build.BRAND.lowercase()
                    info["model"] = Build.MODEL
                    info["sdk_int"] = Build.VERSION.SDK_INT
                    info["android_version"] = Build.VERSION.RELEASE ?: "unknown"
                    result.success(info)
                }

                // Check if this OEM needs special autostart/background permission
                "needsOemPermission" -> {
                    val manufacturer = Build.MANUFACTURER.lowercase()
                    val needsPermission = manufacturer in listOf(
                        "vivo", "oppo", "realme", "oneplus",
                        "xiaomi", "redmi", "poco",
                        "huawei", "honor",
                        "samsung", "meizu", "letv", "asus"
                    )
                    val intentActions = getOemAutostartIntents()
                    result.success(mapOf(
                        "needs_permission" to needsPermission,
                        "manufacturer" to manufacturer,
                        "has_intent" to intentActions.isNotEmpty()
                    ))
                }

                // Set protection level from Flutter
                "setProtectionLevel" -> {
                    protectionLevel = call.argument<String>("level") ?: "basic"
                    result.success(true)
                }

                // Check DND policy access
                "checkDndAccess" -> {
                    val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                    result.success(nm.isNotificationPolicyAccessGranted)
                }

                // Request DND policy access (opens system settings)
                "requestDndAccess" -> {
                    try {
                        val intent = Intent(Settings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS)
                        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }

                // Open OEM-specific autostart/background permission settings
                "openOemPermissionSettings" -> {
                    val opened = openOemAutostartSettings()
                    result.success(opened)
                }

                else -> result.notImplemented()
            }
        }
    }

    /**
     * Get list of OEM-specific autostart/background permission intents.
     * Different manufacturers have different settings pages.
     */
    private fun getOemAutostartIntents(): List<Intent> {
        val intents = mutableListOf<Intent>()
        val manufacturer = Build.MANUFACTURER.lowercase()

        when {
            manufacturer.contains("vivo") -> {
                intents.add(Intent().setClassName("com.vivo.permissionmanager", "com.vivo.permissionmanager.activity.BgStartUpManagerActivity"))
                intents.add(Intent().setClassName("com.iqoo.secure", "com.iqoo.secure.ui.phoneoptimize.BgStartUpManager"))
                intents.add(Intent().setClassName("com.vivo.abe", "com.vivo.applicationbehaviorengine.ui.ExcessivePowerManagerActivity"))
            }
            manufacturer.contains("xiaomi") || manufacturer.contains("redmi") || manufacturer.contains("poco") -> {
                intents.add(Intent().setClassName("com.miui.securitycenter", "com.miui.permcenter.autostart.AutoStartManagementActivity"))
            }
            manufacturer.contains("oppo") || manufacturer.contains("realme") || manufacturer.contains("oneplus") -> {
                intents.add(Intent().setClassName("com.coloros.safecenter", "com.coloros.safecenter.startupapp.StartupAppListActivity"))
                intents.add(Intent().setClassName("com.oppo.safe", "com.oppo.safe.permission.startup.StartupAppListActivity"))
                intents.add(Intent().setClassName("com.coloros.safecenter", "com.coloros.safecenter.permission.startup.StartupAppListActivity"))
            }
            manufacturer.contains("huawei") || manufacturer.contains("honor") -> {
                intents.add(Intent().setClassName("com.huawei.systemmanager", "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity"))
                intents.add(Intent().setClassName("com.huawei.systemmanager", "com.huawei.systemmanager.optimize.process.ProtectActivity"))
            }
            manufacturer.contains("samsung") -> {
                intents.add(Intent().setClassName("com.samsung.android.lool", "com.samsung.android.sm.ui.battery.BatteryActivity"))
            }
        }

        // Filter to only resolvable intents
        return intents.filter { intent ->
            intent.resolveActivity(packageManager) != null
        }
    }

    /**
     * Try to open OEM autostart/background permission settings.
     * Tries multiple known intents until one works.
     */
    private fun openOemAutostartSettings(): Boolean {
        val intents = getOemAutostartIntents()
        for (intent in intents) {
            try {
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(intent)
                return true
            } catch (_: Exception) {}
        }
        // Fallback: open app info page where user can find battery/background settings
        try {
            val intent = Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
            intent.data = android.net.Uri.parse("package:$packageName")
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
            return true
        } catch (_: Exception) {}
        return false
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        hideSystemUI()

        // Instantly re-hide system UI when it becomes visible (swipe-down detection)
        setupSystemUiVisibilityListener()

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
     * Kill known cheating apps, screen recorders, remote desktop, adware/bloatware.
     * Returns list of package names that were targeted for kill.
     */
    private fun killSuspiciousBackgroundApps(): List<String> {
        val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val killed = mutableListOf<String>()

        val blacklist = listOf(
            // === Screen Mirroring / Remote Desktop ===
            "com.teamviewer.teamviewer.market.mobile",
            "com.teamviewer.host.market",
            "com.teamviewer.quicksupport.market",
            "com.anydesk.anydeskandroid",
            "com.rustdesk.rustdesk",
            "com.microsoft.rdc.android",
            "com.microsoft.rdc.androidx",
            "com.chrome.remote.desktop",
            "com.realvnc.viewer.android",
            "com.splashtop.remote.pad.v2",
            "com.airdroid.app",
            "com.sand.airdroid",
            "com.lge.smartshare",
            "com.samsung.android.smartmirroring",
            "tv.parsec.client",
            "com.squirrels.reflector",
            "com.apowersoft.mirror",
            "com.vysor.app",

            // === Screen Recorder ===
            "com.kimcy929.screenrecorder",
            "com.hecorat.screenrecorder.free",
            "com.duapps.recorder",
            "com.nll.screenrecorder",
            "com.mobizen.recorder",
            "com.rsupport.mobizen.sec",
            "com.az.screenrecorder",
            "com.rec.screen.recorder",
            "com.screencastomatic.app",
            "com.wondershare.democreator",
            "com.apowersoft.screenrecorder",
            "app.screenrecorder.xrecorder",
            "com.recording.screenrecorder",

            // === Virtual Camera / Streaming ===
            "com.dev47apps.droidcam",
            "com.dev47apps.droidcamx",
            "com.lenzai.streamer",
            "com.pas.webcam",

            // === Dual/Clone/Parallel Space ===
            "com.lbe.parallel.intl",
            "com.lbe.parallel.intl.arm64",
            "com.excelliance.dualaid",
            "com.ludashi.dualspace",
            "info.cloneapp.mochat.in.goast",
            "com.polestar.multiaccount",
            "com.oasisfeng.island",
            "com.nox.mopen.app",

            // === Floating / Overlay Cheating ===
            "com.flatingchat.floatingchat",
            "com.lwi.android.flapps",
            "com.xda.onehandy",
            "com.bigtincan.android.airy",
            "com.easyapps.catbrowser",
            "com.nicepage.floatingbrowser",
            "com.AgileStar.FloatingBrowser",

            // === VPN / Proxy (optional — bisa bypass filter) ===
            // "org.torproject.torbrowser",
            // "com.psiphon3",
            // "com.psiphon3.subscription",

            // === Xiaomi / MIUI Bloatware & Ads ===
            "com.miui.msa",
            "com.miui.hybrid.accessory",
            "com.xiaomi.gamecenter.sdk.service",
            "com.miui.daemon",
            "com.miui.analytics",
            "com.xiaomi.ab",
            "com.xiaomi.joyose",

            // === Oppo / Realme / ColorOS ===
            "com.heytap.market",
            "com.heytap.browser",
            "com.coloros.gamespace",
            "com.opos.ads",
            "com.nearme.gamecenter",
            "com.coloros.floatassistant",

            // === Vivo / FuntouchOS ===
            "com.vivo.game",
            "com.vivo.easyshare",
            "com.vivo.appstore",
            "com.bbk.appstore",
            "com.vivo.floatingball",

            // === Transsion (Itel / Infinix / Tecno) ===
            "com.transsion.hubservice",
            "com.palm.store",
            "com.phoenix.browser",
            "com.transsion.overlayservice",
            "com.transsion.applock",

            // === Samsung ===
            "com.samsung.android.game.gamehome",
            "com.samsung.android.game.gametools",
            "com.samsung.android.app.edgescreen",

            // === Huawei ===
            "com.huawei.appmarket",
            "com.huawei.gamebox",
            "com.huawei.gameassistant",

            // === General cheating / note apps ===
            "com.google.ar.lens",
            "com.google.android.apps.docs",
            "com.evernote",
            "com.microsoft.office.onenote",
            "com.automattic.simplenote",

            // === AI / ChatGPT ===
            "com.openai.chatgpt",
            "com.google.android.apps.bard",
            "com.microsoft.copilot",

            // === Keyboard Ad SDKs / Adware Keyboards (kill ad services, not keyboard itself) ===
            "com.cootek.smartinputv5.ads",
            "com.cootek.smartinputv5.skin",
            "com.emoji.keyboard.touchpal.ads",
            "com.qisi.inputmethod.ads",
            "com.jb.emoji.gokeyboard",
            "com.jb.gokeyboard.ads",
            "com.jb.gokeyboard.plugin",
            "com.cmcm.live",
            "com.kkkeyboard.emoji.keyboard",
            "com.hit.language.emoji.keyboard",
            "com.macaron.keyboard.inputmethod",
            "com.newcheetah.inputmethod",
            "com.icoretec.keyboard",
            "com.yy.biu.inputmethod"
        )

        for (pkg in blacklist) {
            try {
                am.killBackgroundProcesses(pkg)
                killed.add(pkg)
            } catch (_: Exception) {}
        }

        return killed
    }

    /**
     * Check current active keyboard (IME) and classify it
     */
    private fun checkCurrentKeyboard(): Map<String, Any> {
        val result = mutableMapOf<String, Any>()
        val currentIme = Settings.Secure.getString(contentResolver, Settings.Secure.DEFAULT_INPUT_METHOD) ?: ""
        result["current_ime"] = currentIme

        // Extract package name from IME id (format: com.package.name/.ServiceName)
        val packageName = currentIme.split("/").firstOrNull() ?: ""
        result["package_name"] = packageName

        // Known safe keyboards
        val safeKeyboards = listOf(
            "com.google.android.inputmethod.latin",   // Gboard
            "com.android.inputmethod.latin",          // AOSP Keyboard
            "com.samsung.android.honeyboard",         // Samsung Keyboard
            "com.sec.android.inputmethod",            // Samsung (old)
            "com.miui.inputmethod.wubi",              // MIUI default
            "com.sohu.inputmethod.sogou.xiaomi",      // Xiaomi Sogou
            "com.baidu.input_mi",                     // Xiaomi Baidu
            "com.oppo.ime",                           // Oppo keyboard
            "com.heytap.inputmethod",                 // Oppo/Realme
            "com.vivo.ai.ime",                        // Vivo keyboard
            "com.bbk.inputmethod",                    // Vivo (old)
            "com.touchtype.swiftkey",                 // SwiftKey (Microsoft)
            "com.huawei.inputmethod",                 // Huawei keyboard
            "com.transsion.input",                    // Itel/Infinix/Tecno
            "com.google.android.tts",                 // Google TTS
            "com.android.adbkeyboard"                 // Debug (ignore)
        )

        // Known adware keyboards
        val adwareKeyboards = listOf(
            "com.cootek.smartinputv5",                 // TouchPal
            "com.emoji.keyboard.touchpal",            // Facemoji / TouchPal variant
            "com.qisi.inputmethod",                   // Kika Keyboard
            "com.jb.emoji.gokeyboard",                // GO Keyboard
            "com.jb.gokeyboard",                      // GO Keyboard variant
            "com.cmcm.live",                          // Cheetah Keyboard
            "com.hit.language.emoji.keyboard",         // HiType Keyboard
            "com.kkkeyboard.emoji.keyboard",          // KK Keyboard
            "com.newcheetah.inputmethod",             // New Cheetah KB
            "com.macaron.keyboard.inputmethod",       // Macaron Keyboard
            "com.icoretec.keyboard",                  // iCore Keyboard
            "com.yy.biu.inputmethod",                 // Biu Keyboard
            "com.fotoable.keyboard",                  // Fotoable Keyboard
            "com.camelgames.itype"                    // FunType Keyboard
        )

        val isSafe = safeKeyboards.any { packageName.startsWith(it) }
        val isAdware = adwareKeyboards.any { packageName.startsWith(it) }

        result["is_safe"] = isSafe
        result["is_adware"] = isAdware

        // Get a user-friendly keyboard name
        try {
            val appInfo = packageManager.getApplicationInfo(packageName, 0)
            result["keyboard_name"] = packageManager.getApplicationLabel(appInfo).toString()
        } catch (_: Exception) {
            result["keyboard_name"] = packageName
        }

        return result
    }

    /**
     * Programmatically collapse the notification/status bar panel.
     * Uses reflection to access hidden StatusBarManager.collapsePanels() API.
     */
    @Suppress("DiscouragedPrivateApi")
    private fun collapseStatusBar() {
        try {
            val sbService = getSystemService("statusbar")
            if (sbService != null) {
                val clazz = sbService.javaClass
                val collapse = clazz.getMethod("collapsePanels")
                collapse.invoke(sbService)
            }
        } catch (_: Exception) {
            // Fallback: send CLOSE_SYSTEM_DIALOGS broadcast (works on Android < 12)
            try {
                @Suppress("DEPRECATION")
                val closeIntent = Intent(Intent.ACTION_CLOSE_SYSTEM_DIALOGS)
                sendBroadcast(closeIntent)
            } catch (_: Exception) {}
        }
    }

    /**
     * Add a thin invisible overlay on the very top edge of the screen
     * to physically block swipe-down gestures from reaching the system.
     * Height: only 6dp (the gesture detection zone) — does NOT overlap toolbar.
     * Requires SYSTEM_ALERT_WINDOW permission.
     */
    private fun addStatusBarBlocker() {
        if (statusBarBlocker != null) return  // Already added

        try {
            // Check if we have overlay permission
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && !Settings.canDrawOverlays(this)) {
                return
            }

            val blocker = View(this)
            blocker.setBackgroundColor(0) // Fully transparent

            // Consume all touches in this thin strip to block swipe-down gesture
            blocker.setOnTouchListener { _, _ ->
                if (isLockdownActive) {
                    collapseStatusBar()
                    true // Consume the event
                } else {
                    false
                }
            }

            // Very thin: only 6dp — just enough to catch the swipe-start gesture
            val blockerHeight = (6 * resources.displayMetrics.density).toInt()

            val params = WindowManager.LayoutParams(
                WindowManager.LayoutParams.MATCH_PARENT,
                blockerHeight,
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                    WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
                else
                    @Suppress("DEPRECATION")
                    WindowManager.LayoutParams.TYPE_SYSTEM_ERROR,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                    or WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL
                    or WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN
                    or WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
                PixelFormat.TRANSLUCENT
            )
            params.gravity = Gravity.TOP or Gravity.START

            val wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
            wm.addView(blocker, params)
            statusBarBlocker = blocker
        } catch (e: Exception) {
            // Overlay permission denied or other error
        }
    }

    /**
     * Get the actual status bar height in pixels.
     */
    private fun getStatusBarHeight(): Int {
        val resourceId = resources.getIdentifier("status_bar_height", "dimen", "android")
        return if (resourceId > 0) {
            resources.getDimensionPixelSize(resourceId)
        } else {
            // Fallback: 24dp
            (24 * resources.displayMetrics.density).toInt()
        }
    }

    /**
     * Remove the status bar blocker overlay.
     */
    private fun removeStatusBarBlocker() {
        statusBarBlocker?.let { blocker ->
            try {
                val wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
                wm.removeView(blocker)
            } catch (_: Exception) {}
            statusBarBlocker = null
        }
    }

    // ========================================================
    // DND (Do Not Disturb) MODE — Block ALL notifications & calls
    // This prevents WhatsApp notifications, calls, etc. during exam
    // ========================================================

    /**
     * Enable Do Not Disturb mode to suppress ALL notifications and calls.
     * This blocks: heads-up notifications, sounds, vibrations, WhatsApp calls, phone calls.
     * Safe for all OEMs — no aggressive UI actions.
     */
    private fun enableDndMode() {
        try {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (nm.isNotificationPolicyAccessGranted) {
                // Save current filter so we can restore later
                previousDndFilter = nm.currentInterruptionFilter
                // Set to TOTAL SILENCE — blocks everything
                nm.setInterruptionFilter(NotificationManager.INTERRUPTION_FILTER_NONE)
                dndEnabled = true
                debugLog("DND mode ENABLED (total silence)")
            } else {
                debugLog("DND mode NOT enabled — no policy access granted")
            }
        } catch (e: Exception) {
            debugLog("DND enable error: ${e.message}")
        }
    }

    /**
     * Disable DND mode and restore previous interruption filter.
     */
    private fun disableDndMode() {
        try {
            if (dndEnabled) {
                val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                if (nm.isNotificationPolicyAccessGranted) {
                    nm.setInterruptionFilter(previousDndFilter)
                    debugLog("DND mode DISABLED — restored to filter $previousDndFilter")
                }
                dndEnabled = false
            }
        } catch (e: Exception) {
            debugLog("DND disable error: ${e.message}")
        }
    }

    /**
     * Cancel all pending notifications from all apps.
     * This clears any notifications that slipped through before DND was enabled.
     */
    private fun cancelAllNotifications() {
        try {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.cancelAll()  // Cancel our own notifications
        } catch (_: Exception) {}
    }

    /**
     * Start listening for phone state changes.
     * Detects incoming cellular calls and reports them as violations.
     * Note: WhatsApp/VoIP calls are handled by DND mode, not this listener.
     */
    @Suppress("DEPRECATION")
    private fun startPhoneStateListener() {
        try {
            val tm = getSystemService(Context.TELEPHONY_SERVICE) as TelephonyManager
            phoneStateListener = object : PhoneStateListener() {
                override fun onCallStateChanged(state: Int, phoneNumber: String?) {
                    if (!isLockdownActive) return
                    when (state) {
                        TelephonyManager.CALL_STATE_RINGING -> {
                            sendSecurityEvent("incoming_call")
                            // Re-apply lockdown: bring app to front + hide UI
                            handler.postDelayed({
                                if (isLockdownActive && !isExiting) {
                                    hideSystemUI()
                                    collapseStatusBar()
                                    if (protectionLevel == "full") {
                                        bringAppToFront()
                                    }
                                }
                            }, 500)
                        }
                        TelephonyManager.CALL_STATE_OFFHOOK -> {
                            sendSecurityEvent("call_answered")
                            // Aggressively bring back on full protection
                            if (protectionLevel == "full") {
                                handler.postDelayed({
                                    if (isLockdownActive && !isExiting) bringAppToFront()
                                }, 300)
                            }
                        }
                    }
                }
            }
            tm.listen(phoneStateListener, PhoneStateListener.LISTEN_CALL_STATE)
            debugLog("Phone state listener started")
        } catch (e: Exception) {
            debugLog("Phone state listener error: ${e.message}")
        }
    }

    /**
     * Stop the phone state listener.
     */
    @Suppress("DEPRECATION")
    private fun stopPhoneStateListener() {
        try {
            phoneStateListener?.let { listener ->
                val tm = getSystemService(Context.TELEPHONY_SERVICE) as TelephonyManager
                tm.listen(listener, PhoneStateListener.LISTEN_NONE)
            }
            phoneStateListener = null
            debugLog("Phone state listener stopped")
        } catch (_: Exception) {}
    }

    private fun debugLog(msg: String) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            android.util.Log.d("ExaManmet", msg)
        }
    }

    /**
     * Listen for system UI visibility changes and immediately re-hide.
     * This catches the moment user swipes down to reveal status bar
     * and hides it back almost instantly (< 100ms).
     */
    @Suppress("DEPRECATION")
    private fun setupSystemUiVisibilityListener() {
        window.decorView.setOnSystemUiVisibilityChangeListener { visibility ->
            if (isLockdownActive && !isExiting) {
                // If any system bar became visible, re-hide immediately
                val isFullscreen = visibility and View.SYSTEM_UI_FLAG_FULLSCREEN != 0
                if (!isFullscreen) {
                    // Status bar appeared — hide it immediately
                    handler.postDelayed({
                        if (isLockdownActive && !isExiting) {
                            hideSystemUI()
                            collapseStatusBar()
                        }
                    }, 50)  // 50ms delay — instant to human eyes
                }
            }
        }
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

    /**
     * Check if the app is currently in Lock Task (screen pinning) mode.
     */
    private fun isInLockTaskMode(): Boolean {
        val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            am.lockTaskModeState != ActivityManager.LOCK_TASK_MODE_NONE
        } else {
            @Suppress("DEPRECATION")
            am.isInLockTaskMode
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (isExiting) return
        if (hasFocus && isLockdownActive) {
            hideSystemUI()
            // Re-pin screen if student somehow unpinned
            if (!isInLockTaskMode()) {
                try {
                    startLockTask()
                } catch (_: Exception) {}
            }
        } else if (!hasFocus && isLockdownActive) {
            // Always re-hide UI and collapse status bar
            collapseStatusBar()
            hideSystemUI()
            // Only do aggressive retries + bringToFront on full protection
            if (protectionLevel == "full") {
                val isOldApi = Build.VERSION.SDK_INT <= Build.VERSION_CODES.P
                val firstDelay = if (isOldApi) 200L else 50L
                handler.postDelayed({
                    if (isLockdownActive && !isExiting) {
                        collapseStatusBar()
                        hideSystemUI()
                    }
                }, firstDelay)
                handler.postDelayed({
                    if (isLockdownActive && !isExiting) {
                        collapseStatusBar()
                        hideSystemUI()
                        bringAppToFront()
                    }
                }, firstDelay * 2)
            }
        }
    }

    override fun onResume() {
        super.onResume()
        userLeaveHintFired = false  // Reset for next pause cycle
        if (isLockdownActive && !isExiting) {
            hideSystemUI()
            collapseStatusBar()
            // Stop bring-to-front retries since we're back in foreground
            handler.removeCallbacks(bringToFrontRunnable)
        }
    }

    /**
     * Called when user intentionally leaves the activity (Home button).
     * NOT called for incoming calls, system dialogs, or Recent button.
     * This works on ALL Android versions including 12+ where ACTION_CLOSE_SYSTEM_DIALOGS is deprecated.
     */
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (isLockdownActive && !isExiting) {
            userLeaveHintFired = true
            sendSecurityEvent("home_pressed")
        }
    }

    /**
     * When app is paused (user somehow left), aggressively bring it back to front.
     * Also sends security events for Home/Recent detection on Android 12+.
     */
    override fun onPause() {
        super.onPause()
        if (isLockdownActive && !isExiting) {
            // Send security event for violation tracking (both levels)
            if (!userLeaveHintFired) {
                sendSecurityEvent("recent_pressed")
            }
            // Bring-to-front: ONLY on full protection level
            // On basic level, just report the violation — don't fight the OS
            if (protectionLevel == "full") {
                handler.removeCallbacks(bringToFrontRunnable)
                if (Build.VERSION.SDK_INT <= Build.VERSION_CODES.P) {
                    handler.postDelayed(bringToFrontRunnable, 300)
                } else {
                    handler.post(bringToFrontRunnable)
                }
            }
        }
    }

    /**
     * Runnable that aggressively brings app to front with retries.
     * On API <= 28 (Android 9-), uses gentler intervals to avoid Vivo/Oppo/Xiaomi
     * OEM task managers killing the app for "excessive background activity".
     * On API 29+, uses ultra-fast retries since those OEMs relaxed restrictions.
     */
    private val bringToFrontRunnable = object : Runnable {
        private var retryCount = 0
        override fun run() {
            if (!isLockdownActive || isExiting) {
                retryCount = 0
                return
            }
            collapseStatusBar()
            bringAppToFront()
            hideSystemUI()
            retryCount++

            // Gentler on Android 9 and below (Vivo/Oppo OEM kill protection)
            val isOldApi = Build.VERSION.SDK_INT <= Build.VERSION_CODES.P
            val delay = if (isOldApi) {
                // Gentler: 200ms -> 500ms -> 1000ms
                when {
                    retryCount < 3 -> 200L
                    retryCount < 8 -> 500L
                    else -> 1000L
                }
            } else {
                // Aggressive: 50ms -> 150ms -> 300ms
                when {
                    retryCount < 5 -> 50L
                    retryCount < 15 -> 150L
                    else -> 300L
                }
            }
            handler.postDelayed(this, delay)
        }
    }

    /**
     * When app is stopped (fully in background), bring it back immediately.
     */
    override fun onStop() {
        super.onStop()
        if (isLockdownActive && !isExiting) {
            // Only bring-to-front on full protection level
            if (protectionLevel == "full") {
                bringAppToFront()
                collapseStatusBar()
                val isOldApi = Build.VERSION.SDK_INT <= Build.VERSION_CODES.P
                val baseDelay = if (isOldApi) 300L else 50L
                handler.postDelayed({
                    if (isLockdownActive && !isExiting) { bringAppToFront(); collapseStatusBar() }
                }, baseDelay)
                handler.postDelayed({
                    if (isLockdownActive && !isExiting) { bringAppToFront(); hideSystemUI() }
                }, baseDelay * 2)
                if (!isOldApi) {
                    handler.postDelayed({
                        if (isLockdownActive && !isExiting) bringAppToFront()
                    }, 300)
                }
            }
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
     * Uses multiple methods for maximum compatibility:
     * 1) AppTask.moveToFront() - preferred method
     * 2) ActivityManager.moveTaskToFront() - fallback with MOVE_TASK_WITH_HOME
     * 3) Launch intent - last resort
     */
    private fun bringAppToFront() {
        try {
            val activityManager = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            
            // Method 1: AppTask.moveToFront()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                val tasks = activityManager.appTasks
                if (tasks.isNotEmpty()) {
                    tasks[0].moveToFront()
                }
            }
            
            // Method 2: moveTaskToFront with MOVE_TASK_WITH_HOME flag
            // This ensures our task replaces the home screen
            @Suppress("DEPRECATION")
            val runningTasks = activityManager.getRunningTasks(1)
            if (runningTasks.isNotEmpty()) {
                activityManager.moveTaskToFront(taskId, ActivityManager.MOVE_TASK_WITH_HOME)
            }
        } catch (e: Exception) {
            // Method 3: Launch intent as last resort
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

    /**
     * Intercept touch events starting from the very top edge of the screen
     * to prevent pulling down the notification shade/quick settings.
     * Uses a thin 8dp zone at the top edge — narrow enough to not interfere
     * with toolbar buttons (which start at the same region in immersive mode).
     */
    private var touchStartY = 0f
    private var touchStartX = 0f
    override fun dispatchTouchEvent(ev: MotionEvent?): Boolean {
        if (isLockdownActive && ev != null) {
            // Very thin edge zone — only the first 8dp from the screen edge
            val edgeZone = 8 * resources.displayMetrics.density

            when (ev.action) {
                MotionEvent.ACTION_DOWN -> {
                    touchStartY = ev.rawY
                    touchStartX = ev.rawX
                }
                MotionEvent.ACTION_MOVE -> {
                    // Only block if: started in top edge AND moved significantly downward
                    val deltaY = ev.rawY - touchStartY
                    val deltaX = Math.abs(ev.rawX - touchStartX)
                    if (touchStartY < edgeZone && deltaY > edgeZone * 2 && deltaY > deltaX) {
                        // This is a swipe-down from the top edge — block it
                        collapseStatusBar()
                        hideSystemUI()
                        return true
                    }
                }
            }
        }
        return super.dispatchTouchEvent(ev)
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
            // Whitelist known OEM/system accessibility services (NOT cheating tools)
            val systemPackages = setOf(
                // Google
                "com.google.android.marvin.talkback",      // TalkBack
                "com.google.android.accessibility",        // Google Accessibility Suite
                "com.google.android.apps.accessibility",   // Google accessibility tools
                // Samsung
                "com.samsung.accessibility",               // Samsung accessibility
                "com.samsung.android.accessibility.talkback", // Samsung TalkBack
                "com.samsung.android.visionintelligence",  // Samsung Vision
                "com.samsung.android.bixby",               // Bixby
                // Android System
                "com.android.systemui",                    // System UI
                "com.android.server.accessibility",        // System accessibility
                // Transsion (itel, Tecno, Infinix)
                "com.transsion.mol",                       // Transsion MOL system service
                "com.transsion.hilauncher",                // HiLauncher
                "com.transsion.languagepackage",           // Language pack
                "com.transsion.assistant",                 // Transsion assistant
                "com.transsion.remotehelp",                // Remote help
                // Xiaomi / Redmi / POCO
                "com.miui.accessibility",                  // MIUI accessibility
                "com.miui.contentcatcher",                 // MIUI content catcher
                "com.miui.voiceassist",                    // Mi Voice
                "com.xiaomi.accessibility",                // Xiaomi accessibility
                // Oppo / Realme / OnePlus (ColorOS)
                "com.coloros.accessibility",               // ColorOS
                "com.oplus.accessibility",                 // Oplus accessibility
                "com.oppo.accessibility",                  // Oppo accessibility
                "com.heytap.accessibilityservice",         // HeyTap
                // Vivo (FuntouchOS / OriginOS)
                "com.vivo.accessibility",                  // Vivo accessibility
                "com.vivo.assistant",                      // Vivo assistant
                // Huawei / Honor (HarmonyOS / EMUI)
                "com.huawei.accessibility",                // Huawei accessibility
                "com.huawei.bone",                         // Huawei AI
                // Other system services
                "com.motorola.accessibility",              // Motorola
                "com.lge.accessibility",                   // LG
                "com.sec.android.app.servicemodeapp",      // Samsung service mode
                // Common non-cheating services
                "eu.thedarken.sdm",                        // SD Maid
                "com.touchtype.swiftkey",                  // SwiftKey keyboard accessibility
                "org.mozilla.firefox",                     // Firefox accessibility
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

    /**
     * Check if any non-system app is actively using overlay.
     * Uses AppOpsManager on API 26+ for accurate detection.
     * Does NOT flag just having the permission — only active usage.
     */
    private fun checkOverlayApps(): Boolean {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                // Check if any non-system app is actively drawing overlays
                val appOps = getSystemService(Context.APP_OPS_SERVICE) as android.app.AppOpsManager
                val pm = packageManager
                val packages = pm.getInstalledPackages(0)
                // Known safe OEM overlay packages
                val safeOverlayPackages = setOf(
                    "com.android.systemui",
                    "com.google.android.inputmethod.latin",
                    "com.google.android.gms",
                    "com.google.android.projection.gearhead",
                    // Transsion (itel/Tecno/Infinix)
                    "com.transsion.mol",
                    "com.transsion.hilauncher",
                    "com.transsion.toolbox",
                    // Samsung
                    "com.samsung.android.app.smartcapture",
                    "com.samsung.android.game.gametools", 
                    "com.samsung.android.smartface",
                    // Xiaomi
                    "com.miui.securitycenter",
                    "com.miui.home",
                    // Oppo/Realme
                    "com.coloros.gamespace",
                    "com.oplus.gamespace",
                    // Vivo
                    "com.vivo.smartshot",
                )
                for (pkg in packages) {
                    val pkgName = pkg.packageName ?: continue
                    if (safeOverlayPackages.contains(pkgName)) continue
                    // Skip system apps  
                    if (pkg.applicationInfo?.flags?.and(android.content.pm.ApplicationInfo.FLAG_SYSTEM) != 0) continue
                    try {
                        val mode = appOps.unsafeCheckOpNoThrow(
                            android.app.AppOpsManager.OPSTR_SYSTEM_ALERT_WINDOW,
                            pkg.applicationInfo?.uid ?: continue,
                            pkgName
                        )
                        if (mode == android.app.AppOpsManager.MODE_ALLOWED) {
                            // Only flag if it's a known cheating overlay app
                            val suspiciousOverlays = setOf(
                                "com.lwi.android.flapps", // Floating Apps
                                "com.floatingwindow", 
                                "com.lwi.android.flapps.trial",
                                "com.overlaymanager",
                                "com.xda.overlays",
                            )
                            if (suspiciousOverlays.contains(pkgName)) return true
                        }
                    } catch (_: Exception) {}
                }
                false
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
            process.destroy()
            result != null
        } catch (_: Exception) { false }
        catch (_: Error) { false } // Catch NoClassDefFoundError / SELinux errors on Vivo/Oppo
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
            process.destroy()
            result == "1"
        } catch (_: Exception) { false }
        catch (_: Error) { false } // Catch SELinux/security errors on OEM ROMs
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
