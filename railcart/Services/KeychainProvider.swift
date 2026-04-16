//
//  KeychainProvider.swift
//  railcart
//
//  Protocol wrapper over KeychainHelper so views and services can be
//  injected with a live, mock, or demo provider via SwiftUI environment.
//

import Foundation
import SwiftUI

@MainActor
protocol KeychainProviding: Sendable {
    func save(_ key: KeychainHelper.Key, value: String) throws
    func load(_ key: KeychainHelper.Key) -> String?
    func delete(_ key: KeychainHelper.Key)
    func hasKey(_ key: KeychainHelper.Key) -> Bool
    var canUseBiometry: Bool { get }
    func authenticateWithBiometry(reason: String) async -> Bool
}

struct LiveKeychainProvider: KeychainProviding {
    func save(_ key: KeychainHelper.Key, value: String) throws {
        try KeychainHelper.save(key, value: value)
    }
    func load(_ key: KeychainHelper.Key) -> String? { KeychainHelper.load(key) }
    func delete(_ key: KeychainHelper.Key) { KeychainHelper.delete(key) }
    func hasKey(_ key: KeychainHelper.Key) -> Bool { KeychainHelper.hasKey(key) }
    var canUseBiometry: Bool { KeychainHelper.canUseBiometry }
    func authenticateWithBiometry(reason: String) async -> Bool {
        await KeychainHelper.authenticateWithBiometry(reason: reason)
    }
}

/// In-memory keychain for demo/screenshot mode. Pre-populated with the
/// values needed for an "unlocked" wallet so the unlock flow is skipped.
@MainActor
final class DemoKeychainProvider: KeychainProviding {
    private var storage: [KeychainHelper.Key: String]

    init(values: [KeychainHelper.Key: String] = [:]) {
        self.storage = values
    }

    func save(_ key: KeychainHelper.Key, value: String) throws { storage[key] = value }
    func load(_ key: KeychainHelper.Key) -> String? { storage[key] }
    func delete(_ key: KeychainHelper.Key) { storage.removeValue(forKey: key) }
    func hasKey(_ key: KeychainHelper.Key) -> Bool { storage[key] != nil }
    var canUseBiometry: Bool { false }
    func authenticateWithBiometry(reason: String) async -> Bool { false }
}

/// Crashes on any call — guarantees we always inject a real implementation.
struct UnimplementedKeychainProvider: KeychainProviding {
    func save(_ key: KeychainHelper.Key, value: String) throws { fatalError("KeychainProvider not injected") }
    func load(_ key: KeychainHelper.Key) -> String? { fatalError("KeychainProvider not injected") }
    func delete(_ key: KeychainHelper.Key) { fatalError("KeychainProvider not injected") }
    func hasKey(_ key: KeychainHelper.Key) -> Bool { fatalError("KeychainProvider not injected") }
    var canUseBiometry: Bool { fatalError("KeychainProvider not injected") }
    func authenticateWithBiometry(reason: String) async -> Bool { fatalError("KeychainProvider not injected") }
}

private struct KeychainProviderKey: EnvironmentKey {
    @MainActor static let defaultValue: any KeychainProviding = UnimplementedKeychainProvider()
}

extension EnvironmentValues {
    var keychain: any KeychainProviding {
        get { self[KeychainProviderKey.self] }
        set { self[KeychainProviderKey.self] = newValue }
    }
}
