//
//  qlspectrumApp.swift
//  qlspectrum
//
//  Created by Alex Krysiuk on 12/14/25.
//

import SwiftUI

@main
struct qlspectrumApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .background(WindowAccessor())
        }
    }
}

// Helper to access and style the NSWindow
struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                window.backgroundColor = .black
                window.titlebarAppearsTransparent = true
            }
        }
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {}
}
