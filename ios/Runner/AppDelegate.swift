import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    registerNotificationCategories()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // Sunucu push'unun `aps.category` degerleri (CONTRACTS §2.5; Faz 2 F2.C.5). Kategoriler EYLEMSIZDIR: "Onayla" /
  // "Vanayi Kapat" gibi dugmeler arka planda kimlik dogrulamali komut ister; dokunma uygulamayi acar (karar F2-7).
  // Kritik uyari izni istenmez (7.2b-3); izin penceresi burada ACILMAZ.
  private func registerNotificationCategories() {
    let ids = ["SAFETY_ALARM", "SAFETY_INFO", "PEACE_CLOSE_ALL"]
    let categories = Set(ids.map { id in
      UNNotificationCategory(identifier: id, actions: [], intentIdentifiers: [], options: [])
    })
    UNUserNotificationCenter.current().setNotificationCategories(categories)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
