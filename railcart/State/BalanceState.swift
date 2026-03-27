//
//  BalanceState.swift
//  railcart
//
//  Observable balance state that persists across view navigation.
//

import Foundation
import Observation

@MainActor
@Observable
final class BalanceState {
    var balances: [TokenBalance] = []
}
