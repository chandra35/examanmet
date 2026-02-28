import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  
  private var secureField: UITextField?
  
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    
    // Setup method channel for lockdown features
    if let controller = window?.rootViewController as? FlutterViewController {
      let lockdownChannel = FlutterMethodChannel(
        name: "id.sch.man1metro.examanmet/lockdown",
        binaryMessenger: controller.binaryMessenger
      )
      
      lockdownChannel.setMethodCallHandler { [weak self] (call, result) in
        switch call.method {
        case "setSecureFlag":
          let args = call.arguments as? [String: Any]
          let secure = args?["secure"] as? Bool ?? true
          if secure {
            self?.enableScreenshotPrevention()
          } else {
            self?.disableScreenshotPrevention()
          }
          result(true)
          
        case "keepScreenAwake":
          let args = call.arguments as? [String: Any]
          let awake = args?["awake"] as? Bool ?? true
          UIApplication.shared.isIdleTimerDisabled = awake
          result(true)
          
        case "startKioskMode":
          // iOS uses Guided Access (must be enabled manually in Settings)
          // We can request Single App Mode if MDM is configured
          UIAccessibility.requestGuidedAccessSession(enabled: true) { success in
            result(success)
          }
          
        case "stopKioskMode":
          UIAccessibility.requestGuidedAccessSession(enabled: false) { success in
            result(success)
          }
          
        case "checkFloatingApps":
          // iOS doesn't have floating apps
          result(false)
          
        case "checkBlockedApps":
          // iOS doesn't allow checking other running apps
          result([String]())
          
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }
    
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
  
  /// Prevent screenshots using a secure text field overlay
  private func enableScreenshotPrevention() {
    guard secureField == nil else { return }
    
    DispatchQueue.main.async { [weak self] in
      let field = UITextField()
      field.isSecureTextEntry = true
      field.isUserInteractionEnabled = false
      
      if let window = self?.window {
        window.addSubview(field)
        field.centerYAnchor.constraint(equalTo: window.centerYAnchor).isActive = true
        field.centerXAnchor.constraint(equalTo: window.centerXAnchor).isActive = true
        
        // Make the secure field's layer the window's layer
        window.layer.superlayer?.addSublayer(field.layer)
        field.layer.sublayers?.first?.addSublayer(window.layer)
      }
      
      self?.secureField = field
    }
  }
  
  /// Remove screenshot prevention
  private func disableScreenshotPrevention() {
    DispatchQueue.main.async { [weak self] in
      self?.secureField?.removeFromSuperview()
      self?.secureField = nil
    }
  }
  
  // Disable multi-tasking app switcher snapshot
  override func applicationWillResignActive(_ application: UIApplication) {
    // Show blank view when going to app switcher
    let blurEffect = UIBlurEffect(style: .light)
    let blurView = UIVisualEffectView(effect: blurEffect)
    blurView.frame = window?.bounds ?? UIScreen.main.bounds
    blurView.tag = 999
    window?.addSubview(blurView)
  }
  
  override func applicationDidBecomeActive(_ application: UIApplication) {
    // Remove blur when coming back
    window?.viewWithTag(999)?.removeFromSuperview()
  }
}
