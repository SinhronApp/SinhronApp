import Flutter
import Foundation

// ADR-060 — what the Share Extension (ios/ShareExtension) left in the App
// Group reaches Dart (channel `dev.sinhron/share`, lib/core/incoming_share.dart).
//
//   sinhron://share?id=<id>   the extension opened the app for that share
//   takeInitial()             the newest share not yet handed over (cold
//                             start, or the extension couldn't open the app)
//   finished(id)              sent or cancelled — its folder is deleted
//
// `Share/<id>/share.json` lists the files by name inside that folder; Dart
// gets absolute paths. Folders older than a day are swept on attach.

final class ShareBridge {
  static let shared = ShareBridge()
  static let appGroup = "group.com.sinhron.sinhron"

  private var channel: FlutterMethodChannel?

  /// Handed to Dart already (it de-duplicates too).
  private var given = Set<String>()

  private var root: URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroup)?
      .appendingPathComponent("Share", isDirectory: true)
  }

  func attach(messenger: FlutterBinaryMessenger) {
    let ch = FlutterMethodChannel(name: "dev.sinhron/share", binaryMessenger: messenger)
    ch.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(nil) }
      switch call.method {
      case "takeInitial":
        result(self.newest())
      case "finished":
        if let id = call.arguments as? String, let dir = self.folder(id) {
          try? FileManager.default.removeItem(at: dir)
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    channel = ch
    sweep()
  }

  /// `sinhron://share?id=…` — false for any other link.
  @discardableResult
  func received(_ url: URL) -> Bool {
    guard url.scheme?.lowercased() == "sinhron", url.host?.lowercased() == "share" else { return false }
    let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value
    guard let id, let share = load(id) else { return true }
    given.insert(id)
    channel?.invokeMethod("share", arguments: share)
    return true
  }

  private func folder(_ id: String) -> URL? {
    guard !id.isEmpty, id.count <= 40, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
    return root?.appendingPathComponent(id, isDirectory: true)
  }

  /// The share as Dart reads it, or nil.
  private func load(_ id: String) -> [String: Any]? {
    guard let dir = folder(id),
      let data = try? Data(contentsOf: dir.appendingPathComponent("share.json")),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    let files: [[String: Any]] = ((json["files"] as? [[String: Any]]) ?? []).compactMap { f in
      // Only a plain name inside this share's folder.
      guard let name = f["path"] as? String, !name.contains("/"), !name.hasPrefix(".") else { return nil }
      var out = f
      out["path"] = dir.appendingPathComponent(name).path
      return out
    }
    return ["id": id, "text": (json["text"] as? String) ?? "", "files": files]
  }

  /// The newest share from the last hour not handed over yet.
  private func newest() -> [String: Any]? {
    let fm = FileManager.default
    guard let root,
      let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])
    else { return nil }
    let hourAgo = Date().addingTimeInterval(-3600)
    let fresh = dirs.compactMap { d -> (String, Date)? in
      let date = (try? d.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
      return date > hourAgo && !given.contains(d.lastPathComponent) ? (d.lastPathComponent, date) : nil
    }
    guard let id = fresh.max(by: { $0.1 < $1.1 })?.0, let share = load(id) else { return nil }
    given.insert(id)
    return share
  }

  /// Left behind (the app was closed before choosing a chat): gone after a day.
  private func sweep() {
    let fm = FileManager.default
    guard let root,
      let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])
    else { return }
    let dayAgo = Date().addingTimeInterval(-86400)
    for d in dirs {
      let date = (try? d.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
      if date < dayAgo { try? fm.removeItem(at: d) }
    }
  }
}
