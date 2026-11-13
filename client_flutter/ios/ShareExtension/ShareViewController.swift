// ADR-060 — "Sinhron" in the iPhone share sheet.
//
// No Rust, no database, no network: the extension only copies what was
// shared into the App Group (`Share/<id>/` + `share.json`) and opens the app
// with `sinhron://share?id=<id>`; the app asks "Send to…" and sends it the
// usual way (ShareBridge in Runner/ShareBridge.swift → Dart). Copies are
// files on disk (no big buffers): videos and files are copied as they are,
// pictures other than JPEG / PNG / GIF become a ≤2048 px JPEG (ImageIO,
// the core re-encodes to that size anyway) — well inside the extension's
// memory limit. Files are protected (`.complete`) and out of backups; the
// app deletes them once sent or cancelled, and anything older than a day.

import ImageIO
import UIKit
import UniformTypeIdentifiers

let kShareAppGroup = "group.com.sinhron.sinhron"

final class ShareViewController: UIViewController {
  private let card = UIView()
  private let spinner = UIActivityIndicatorView(style: .medium)
  private let label = UILabel()
  private let button = UIButton(type: .system)
  private var started = false

  private static var ru: Bool { (Locale.preferredLanguages.first ?? "").hasPrefix("ru") }
  private static func t(_ en: String, _ ru: String) -> String { Self.ru ? ru : en }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = UIColor.black.withAlphaComponent(0.25)
    card.backgroundColor = .systemBackground
    card.layer.cornerRadius = 16
    card.translatesAutoresizingMaskIntoConstraints = false
    label.text = Self.t("Opening Sinhron…", "Открываем Sinhron…")
    label.numberOfLines = 0
    label.textAlignment = .center
    label.font = .preferredFont(forTextStyle: .body)
    button.setTitle("OK", for: .normal)
    button.isHidden = true
    button.addTarget(self, action: #selector(close), for: .touchUpInside)
    spinner.startAnimating()
    let stack = UIStackView(arrangedSubviews: [spinner, label, button])
    stack.axis = .vertical
    stack.spacing = 12
    stack.alignment = .center
    stack.translatesAutoresizingMaskIntoConstraints = false
    card.addSubview(stack)
    view.addSubview(card)
    NSLayoutConstraint.activate([
      card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      card.widthAnchor.constraint(equalToConstant: 280),
      stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 24),
      stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20),
      stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
      stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
    ])
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard !started else { return }
    started = true
    let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
    Task { @MainActor in
      let id = await ShareInbox.save(items)
      guard let id else {
        self.show(Self.t("Nothing here Sinhron can send.", "Здесь нет ничего, что Sinhron может отправить."))
        return
      }
      if self.openApp(URL(string: "sinhron://share?id=\(id)")!) {
        // Give the system a moment to switch, then close the sheet.
        try? await Task.sleep(nanoseconds: 600_000_000)
        self.close()
      } else {
        self.show(Self.t("Saved. Open Sinhron to choose a chat.", "Сохранено. Откройте Sinhron и выберите чат."))
      }
    }
  }

  private func show(_ text: String) {
    spinner.stopAnimating()
    spinner.isHidden = true
    label.text = text
    button.isHidden = false
  }

  @objc private func close() {
    extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
  }

  /// A share extension has no `openURL`; the app object up the responder
  /// chain still opens our own scheme.
  private func openApp(_ url: URL) -> Bool {
    let sel = NSSelectorFromString("openURL:options:completionHandler:")
    var r: UIResponder? = self
    while let x = r {
      if let app = x as? UIApplication, app.responds(to: sel) {
        typealias Open = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, (@convention(block) (Bool) -> Void)?) -> Void
        let imp = app.method(for: sel)
        unsafeBitCast(imp, to: Open.self)(app, sel, url as NSURL, NSDictionary(), nil)
        return true
      }
      r = x.next
    }
    return false
  }
}

/// Copies shared items into the App Group, one folder per share.
enum ShareInbox {
  static let maxItems = 20

  /// The share's id, or nil when nothing could be kept.
  static func save(_ items: [NSExtensionItem]) async -> String? {
    let fm = FileManager.default
    guard let group = fm.containerURL(forSecurityApplicationGroupIdentifier: kShareAppGroup) else { return nil }
    var root = group.appendingPathComponent("Share", isDirectory: true)
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    var noBackup = URLResourceValues()
    noBackup.isExcludedFromBackup = true
    try? root.setResourceValues(noBackup)
    let id = "i" + String(Int(Date().timeIntervalSince1970 * 1000), radix: 36) + String(Int.random(in: 0..<46656), radix: 36)
    let folder = root.appendingPathComponent(id, isDirectory: true)
    try? fm.createDirectory(at: folder, withIntermediateDirectories: true)

    var files: [[String: Any]] = []
    var texts: [String] = []
    var n = 0
    for provider in items.flatMap({ $0.attachments ?? [] }) {
      if files.count >= maxItems { break }
      n += 1
      if let f = await file(from: provider, into: folder, index: n) {
        files.append(f)
      } else if let t = await text(from: provider), !t.isEmpty, !texts.contains(t) {
        texts.append(t)
      }
    }
    if files.isEmpty && texts.isEmpty {
      try? fm.removeItem(at: folder)
      return nil
    }
    let manifest: [String: Any] = [
      "id": id,
      "text": texts.joined(separator: "\n"),
      // Paths relative to the share's folder: the app's container path differs.
      "files": files,
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: manifest) else { return nil }
    let url = folder.appendingPathComponent("share.json")
    do {
      try data.write(to: url, options: [.atomic, .completeFileProtection])
    } catch {
      return nil
    }
    return id
  }

  private static func file(from p: NSItemProvider, into folder: URL, index: Int) async -> [String: Any]? {
    if p.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
      return await copy(p, type: .movie, into: folder, index: index, picture: false)
    }
    if p.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
      if let f = await copy(p, type: .image, into: folder, index: index, picture: true) { return f }
      return await screenshot(p, into: folder, index: index)
    }
    // A web link is text; a file URL (Files, Mail attachments) is a file.
    if p.hasItemConformingToTypeIdentifier(UTType.url.identifier)
      && !p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
    {
      return nil
    }
    if p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
      && !p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
    {
      return nil
    }
    if p.hasItemConformingToTypeIdentifier(UTType.data.identifier) {
      return await copy(p, type: .data, into: folder, index: index, picture: false)
    }
    return nil
  }

  /// `loadFileRepresentation` hands a temporary file, valid only inside the
  /// callback: moved into [folder] there.
  private static func copy(_ p: NSItemProvider, type: UTType, into folder: URL, index: Int, picture: Bool) async
    -> [String: Any]?
  {
    let suggested = p.suggestedName
    return await withCheckedContinuation { (done: CheckedContinuation<[String: Any]?, Never>) in
      _ = p.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
        guard let url else { return done.resume(returning: nil) }
        let name = safeName(suggested.map { n in
          n.contains(".") || url.pathExtension.isEmpty ? n : "\(n).\(url.pathExtension)"
        } ?? url.lastPathComponent)
        let ext = (name as NSString).pathExtension.lowercased()
        let uti = UTType(filenameExtension: ext)
        if picture, let uti, !(uti.conforms(to: .jpeg) || uti.conforms(to: .png) || uti.conforms(to: .gif)) {
          let base = (name as NSString).deletingPathExtension
          let out = folder.appendingPathComponent("\(index)_\(base).jpg")
          if jpeg(from: url, to: out) {
            return done.resume(returning: entry(out, name: "\(base).jpg", mime: "image/jpeg"))
          }
        }
        let out = folder.appendingPathComponent("\(index)_\(name)")
        do {
          try FileManager.default.copyItem(at: url, to: out)
        } catch {
          return done.resume(returning: nil)
        }
        let mime = uti?.preferredMIMEType ?? (picture ? "image/jpeg" : "application/octet-stream")
        done.resume(returning: entry(out, name: name, mime: mime))
      }
    }
  }

  /// Screenshots and some apps hand an image object, not a file.
  private static func screenshot(_ p: NSItemProvider, into folder: URL, index: Int) async -> [String: Any]? {
    await withCheckedContinuation { (done: CheckedContinuation<[String: Any]?, Never>) in
      p.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { item, _ in
        var data: Data?
        if let image = item as? UIImage {
          data = image.jpegData(compressionQuality: 0.92)
        } else if let d = item as? Data {
          data = d
        }
        guard let data else { return done.resume(returning: nil) }
        let tmp = folder.appendingPathComponent("\(index)_raw")
        let out = folder.appendingPathComponent("\(index)_image.jpg")
        do {
          try data.write(to: tmp)
          defer { try? FileManager.default.removeItem(at: tmp) }
          guard jpeg(from: tmp, to: out) else { return done.resume(returning: nil) }
        } catch {
          return done.resume(returning: nil)
        }
        done.resume(returning: entry(out, name: "image.jpg", mime: "image/jpeg"))
      }
    }
  }

  private static func text(from p: NSItemProvider) async -> String? {
    for type in [UTType.url, UTType.plainText] where p.hasItemConformingToTypeIdentifier(type.identifier) {
      let s: String? = await withCheckedContinuation { done in
        p.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, _ in
          if let u = item as? URL { return done.resume(returning: u.isFileURL ? nil : u.absoluteString) }
          if let s = item as? String { return done.resume(returning: s) }
          if let s = item as? NSAttributedString { return done.resume(returning: s.string) }
          if let d = item as? Data { return done.resume(returning: String(data: d, encoding: .utf8)) }
          done.resume(returning: nil)
        }
      }
      if let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { return s }
    }
    return nil
  }

  /// Any picture → JPEG, longest side ≤ 2048, upright, no metadata (no GPS).
  private static func jpeg(from src: URL, to dst: URL) -> Bool {
    guard let source = CGImageSourceCreateWithURL(src as CFURL, nil) else { return false }
    let opts: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: 2048,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary),
      let dest = CGImageDestinationCreateWithURL(dst as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
    else { return false }
    CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
    return CGImageDestinationFinalize(dest)
  }

  private static func entry(_ url: URL, name: String, mime: String) -> [String: Any] {
    let fm = FileManager.default
    try? fm.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
    let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    return ["path": url.lastPathComponent, "name": name, "mime": mime, "size": size]
  }

  private static func safeName(_ n: String) -> String {
    let bad = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
    var s = n.components(separatedBy: bad).joined(separator: "_").trimmingCharacters(in: .whitespaces)
    while s.hasPrefix(".") { s.removeFirst() }
    if s.isEmpty { s = "file" }
    return String(s.prefix(120))
  }
}
