import Flutter
import UIKit

// ADR-043 — invite links reach the app through the scene: a cold start
// carries them in the connection options, a running app gets them as a
// user activity (universal link) or an URL context (`sinhron://`). Each
// override hands the call on to Flutter's own scene delegate first.
// ADR-060 — `sinhron://share?id=…` (from the Share Extension) goes to
// ShareBridge instead.
class SceneDelegate: FlutterSceneDelegate {
  override func scene(
    _ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    for activity in connectionOptions.userActivities where activity.activityType == NSUserActivityTypeBrowsingWeb {
      if let url = activity.webpageURL { LinksBridge.shared.received(url) }
    }
    for context in connectionOptions.urlContexts where !ShareBridge.shared.received(context.url) {
      LinksBridge.shared.received(context.url)
    }
  }

  override func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
    super.scene(scene, continue: userActivity)
    if userActivity.activityType == NSUserActivityTypeBrowsingWeb, let url = userActivity.webpageURL {
      LinksBridge.shared.received(url)
    }
  }

  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    super.scene(scene, openURLContexts: URLContexts)
    for context in URLContexts where !ShareBridge.shared.received(context.url) {
      LinksBridge.shared.received(context.url)
    }
  }
}

// ADR-043 — invite links into the app.
//
//   https://<server>/join#…   universal link (applinks:<server> entitlement,
//                             the server's apple-app-site-association)
//   sinhron://join#…          the /join page's "Open in the app" button
//   https://<server>/i/<id>#… a short link (the same, resolved in Rust);
//   sinhron://i/<server>/<id>#…  its page's button
//
// Channel `dev.sinhron/links`: Dart → `takeInitial()` (a link that started
// the app before Dart listened); native → `link(url)`. A link stays pending
// until Dart accepted it, so a cold start doesn't lose it.


final class LinksBridge {
    static let shared = LinksBridge()
    private var channel: FlutterMethodChannel?
    private var pending: String?

    func attach(messenger: FlutterBinaryMessenger) {
        let ch = FlutterMethodChannel(name: "dev.sinhron/links", binaryMessenger: messenger)
        ch.setMethodCallHandler { [weak self] call, result in
            guard call.method == "takeInitial" else { return result(FlutterMethodNotImplemented) }
            result(self?.pending)
            self?.pending = nil
        }
        channel = ch
    }

    func received(_ url: URL) {
        let s = url.absoluteString
        guard Self.isInvite(url) else { return }
        pending = s
        channel?.invokeMethod("link", arguments: s) { [weak self] r in
            // Dart took it (no error, a handler exists) — don't hand it over twice.
            if !(r is FlutterError), (r as? NSObject) !== FlutterMethodNotImplemented, self?.pending == s {
                self?.pending = nil
            }
        }
    }

    static func isInvite(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https": return url.path == "/join" || url.path.hasPrefix("/join/") || url.path.hasPrefix("/i/")
        case "sinhron": return url.host?.lowercased() == "join" || url.host?.lowercased() == "i"
        default: return false
        }
    }
}
