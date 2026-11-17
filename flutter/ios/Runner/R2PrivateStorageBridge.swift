import Flutter
import Foundation
import Security

final class R2PrivateStorageBridge {
  private let channel: FlutterMethodChannel

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "app.r2gallery/private-storage", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "prepare" else { result(FlutterMethodNotImplemented); return }
      do {
        try Self.prepare()
        result(true)
      } catch {
        // パス・作品名・Keychainの内容や例外をFlutterへ返さない。
        result(FlutterError(code: "private_storage_unavailable",
          message: "アプリ専用保存の保護設定を確認できませんでした", details: nil))
      }
    }
  }

  private static func prepare() throws {
    let manager = FileManager.default
    var support = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask,
      appropriateFor: nil, create: true).resolvingSymlinksInPath()
    let cache = try manager.url(for: .cachesDirectory, in: .userDomainMask,
      appropriateFor: nil, create: true).resolvingSymlinksInPath()
    // cache管理DBの署名URL等もこのrootにあるため、個々のmediaフォルダだけに限定しない。
    try excludeFromBackup(&support)
    // 既存の永続保存・再開用データを移動も削除もせず、既存フォルダにも属性を付ける。
    for (base, name) in [(support, "offline"), (support, "transfers"),
                         (support, "web-stage"), (cache, "offline-playback")] {
      var directory = base.appendingPathComponent(name, isDirectory: true).resolvingSymlinksInPath()
      guard directory.path.hasPrefix(base.path + "/") else { throw StorageError.unavailable }
      try manager.createDirectory(at: directory, withIntermediateDirectories: true)
      try excludeFromBackup(&directory)
    }
    try protectExistingKeychainItems()
  }

  private static func excludeFromBackup(_ url: inout URL) throws {
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try url.setResourceValues(values)
    guard try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true
      else { throw StorageError.unavailable }
  }

  private static func protectExistingKeychainItems() throws {
    // 値は読み出さない。既定serviceのr2g.*だけを属性更新し、既存DEKを再生成しない。
    let service = "flutter_secure_storage_service"
    let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
      kSecAttrService: service, kSecAttrSynchronizable: false,
      kSecReturnAttributes: true, kSecMatchLimit: kSecMatchLimitAll]
    var found: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &found)
    if status == errSecItemNotFound { return }
    guard status == errSecSuccess, let items = found as? [[String: Any]] else {
      throw StorageError.unavailable
    }
    for item in items {
      guard let account = item[kSecAttrAccount as String] as? String, account.hasPrefix("r2g.") else { continue }
      let specific: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
        kSecAttrService: service, kSecAttrAccount: account, kSecAttrSynchronizable: false]
      let attributes: [CFString: Any] = [kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
      guard SecItemUpdate(specific as CFDictionary, attributes as CFDictionary) == errSecSuccess else {
        throw StorageError.unavailable
      }
    }
  }

  private enum StorageError: Error { case unavailable }
}
