//
//  KeychainManager.swift
//  Dayflow
//

import Foundation
import Security
import LocalAuthentication

/// Provider credentials are stored separately from exportable AI configuration.
final class LocalProviderCredentialStore: @unchecked Sendable {
  static let shared = LocalProviderCredentialStore()
  private let directory: URL
  private let legacyRead: (String) -> String?
  private let lock = NSLock()

  init(directory: URL? = nil,
       legacyRead: @escaping (String) -> String? = {
         AppStoragePaths.isIsolated ? nil : KeychainManager.shared.retrieveWithoutInteraction(for: $0)
       }) {
    self.directory = directory ?? AppStoragePaths.applicationSupport
      .appendingPathComponent("ProviderCredentials", isDirectory: true)
    self.legacyRead = legacyRead
  }

  func retrieve(for identifier: String) -> String? {
    lock.lock()
    defer { lock.unlock() }
    let url = fileURL(for: identifier)
    if FileManager.default.fileExists(atPath: url.path) {
      guard let data = try? Data(contentsOf: url),
        let value = String(data: data, encoding: .utf8), !value.isEmpty else { return nil }
      return value
    }
    // A missing/blocked legacy key is recorded too, so normal requests never keep
    // querying Keychain. Re-entering the key replaces this empty migration record.
    let legacy = legacyRead(identifier) ?? ""
    guard writeLocked(legacy, for: identifier) else { return nil }
    return legacy.isEmpty ? nil : legacy
  }

  @discardableResult
  func store(_ value: String, for identifier: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return writeLocked(value, for: identifier)
  }

  @discardableResult
  func delete(for identifier: String) -> Bool {
    // Retain an empty record to prevent deleted credentials being re-migrated.
    store("", for: identifier)
  }

  private func fileURL(for identifier: String) -> URL {
    let name = identifier.utf8.map { String(format: "%02x", $0) }.joined()
    return directory.appendingPathComponent(name + ".credential")
  }

  private func writeLocked(_ value: String, for identifier: String) -> Bool {
    do {
      let manager = FileManager.default
      try manager.createDirectory(at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
      let url = fileURL(for: identifier)
      let data = Data(value.utf8)
      let temporary = directory.appendingPathComponent(UUID().uuidString + ".tmp")
      defer { try? manager.removeItem(at: temporary) }
      guard manager.createFile(atPath: temporary.path, contents: nil,
        attributes: [.posixPermissions: 0o600]) else { return false }
      try data.write(to: temporary)
      guard rename(temporary.path, url.path) == 0 else { return false }
      return try Data(contentsOf: url) == data
    } catch {
      return false
    }
  }
}

/// Thread-safe manager for securely storing API keys in macOS Keychain
final class KeychainManager {

  static let shared = KeychainManager()

  private let servicePrefix = "local.targetflow.apikeys"
  private let queue = DispatchQueue(label: "local.targetflow.keychain", qos: .userInitiated)

  private init() {}

  /// Stores an API key in the keychain
  /// - Parameters:
  ///   - apiKey: The API key to store
  ///   - provider: The provider identifier (e.g., "gemini", "dayflow")
  /// - Returns: true if successful, false otherwise
  @discardableResult
  func store(_ apiKey: String, for provider: String) -> Bool {
    if AppStoragePaths.isIsolated {
      return LocalProviderCredentialStore.shared.store(apiKey, for: provider)
    }
    return queue.sync {
      guard let data = apiKey.data(using: .utf8) else { return false }

      let service = "\(servicePrefix).\(provider)"
      let itemQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: provider,
      ]

      let updateStatus = SecItemUpdate(
        itemQuery as CFDictionary,
        [kSecValueData as String: data] as CFDictionary
      )
      if updateStatus == errSecSuccess {
        return true
      }
      guard updateStatus == errSecItemNotFound else {
        return false
      }

      let addQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: provider,
        kSecValueData as String: data,
        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
      ]

      return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }
  }

  /// Retrieves an API key from the keychain
  /// - Parameter provider: The provider identifier
  /// - Returns: The API key if found, nil otherwise
  func retrieve(for provider: String) -> String? {
    if AppStoragePaths.isIsolated {
      return LocalProviderCredentialStore.shared.retrieve(for: provider)
    }
    let timestamp = DateFormatter.localizedString(
      from: Date(), dateStyle: .none, timeStyle: .medium)
    print("\n🔐 [KeychainManager] Retrieving key for '\(provider)' at \(timestamp)")

    return queue.sync {
      let service = "\(servicePrefix).\(provider)"
      print("   Service: \(service)")
      print("   Account: \(provider)")

      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: provider,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
      ]

      var result: AnyObject?
      let status = SecItemCopyMatching(query as CFDictionary, &result)

      // Log the status code for debugging
      switch status {
      case errSecSuccess:
        print("✅ [KeychainManager] SecItemCopyMatching succeeded")
      case errSecItemNotFound:
        print("❌ [KeychainManager] Item not found in keychain (errSecItemNotFound)")
      case errSecAuthFailed:
        print("❌ [KeychainManager] Authentication failed (errSecAuthFailed)")
      case errSecInteractionNotAllowed:
        print("❌ [KeychainManager] Interaction not allowed (errSecInteractionNotAllowed)")
        print("   This usually means the keychain is locked or inaccessible")
      case errSecParam:
        print("❌ [KeychainManager] Invalid parameters (errSecParam)")
      case errSecNotAvailable:
        print("❌ [KeychainManager] Keychain services not available (errSecNotAvailable)")
      default:
        print("❌ [KeychainManager] Unknown error code: \(status)")
      }

      guard status == errSecSuccess else {
        print("   Failed with status: \(status)")
        return nil
      }

      guard let data = result as? Data else {
        print("❌ [KeychainManager] Result is not Data type")
        print("   Result type: \(type(of: result))")
        return nil
      }

      print("   Retrieved data: \(data.count) bytes")

      guard let apiKey = String(data: data, encoding: .utf8) else {
        print("❌ [KeychainManager] Failed to decode data as UTF-8 string")
        return nil
      }

      print("✅ [KeychainManager] Successfully retrieved key")
      print("   Key length: \(apiKey.count) characters")

      return apiKey
    }
  }

  /// Reads a legacy credential only when macOS can return it without prompting.
  func retrieveWithoutInteraction(for provider: String) -> String? {
    guard !AppStoragePaths.isIsolated else { return nil }
    return queue.sync {
      let context = LAContext()
      context.interactionNotAllowed = true
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "\(servicePrefix).\(provider)",
        kSecAttrAccount as String: provider,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
        kSecUseAuthenticationContext as String: context,
      ]
      var result: AnyObject?
      guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
        let data = result as? Data else { return nil }
      return String(data: data, encoding: .utf8)
    }
  }

  /// Deletes an API key from the keychain
  /// - Parameter provider: The provider identifier
  /// - Returns: true if successful, false otherwise
  @discardableResult
  func delete(for provider: String) -> Bool {
    if AppStoragePaths.isIsolated {
      return LocalProviderCredentialStore.shared.delete(for: provider)
    }
    return queue.sync {
      let service = "\(servicePrefix).\(provider)"

      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: provider,
      ]

      let status = SecItemDelete(query as CFDictionary)
      return status == errSecSuccess || status == errSecItemNotFound
    }
  }

}
