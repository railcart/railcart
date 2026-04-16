//
//  RailcartDefaults.swift
//  railcart
//
//  Process-wide UserDefaults handle. Swappable so test/UI-test/demo
//  modes can isolate persistence from the user's real defaults.
//

import Foundation

enum RailcartDefaults {
    static var store: UserDefaults = .standard
}
