//
//  ShieldState.swift
//  railcart
//
//  Observable shield/unshield state that persists across view navigation.
//

import Foundation
import Observation

@MainActor
@Observable
final class ShieldState {
    var ethBalance: String = ""
    var txHash: String?
    var unshieldTxHash: String?
    var statusMessage: String?
    var proofProgress: Double?
}
