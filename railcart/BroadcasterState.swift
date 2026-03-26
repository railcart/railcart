//
//  BroadcasterState.swift
//  railcart
//
//  Observable broadcaster discovery state that persists across view navigation.
//

import Foundation
import Observation

@MainActor
@Observable
final class BroadcasterState {
    var broadcasters: [BroadcasterInfo] = []
    var connectionStatus: String = "Disconnected"
    var peerStats: PeerStats?
    var isSearching = false
}
