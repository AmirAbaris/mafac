//
//  MafacApp.swift
//  Mafac
//
//  App entry point. SwiftUI lifecycle, single-window macOS app.
//

import SwiftUI

@main
struct MafacApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.automatic)
        .windowResizability(.contentSize)
        .commands {
            // Menu customization arrives in later phases (e.g. ⌘M to
            // insert a math block, ⌘N for new note). Left as default
            // for Phase 0.
        }
    }
}
